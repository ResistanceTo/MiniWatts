import Foundation
import Observation

/// One point in the rolling live chart.
nonisolated struct LiveSample: Identifiable, Hashable {
    let date: Date
    let inputWatts: Double
    let batteryWatts: Double
    let hottestTemperature: Double?
    var id: Date { date }
}

/// Drives every probe on a one-second tick and merges the results into one
/// observable object the whole UI reads from.
@Observable
final class PowerMonitor {
    // MARK: Published state

    private(set) var snapshot = PowerSnapshot()
    private(set) var live: [LiveSample] = []
    private(set) var devices: [ExternalBatteryDevice] = []
    private(set) var sessions: [ChargeSession] = []
    private(set) var currentSession: ChargeSession?
    private(set) var sessionTotals = EnergyTotals()
    /// Watts estimated from how fast the percentage moves. The only way to see
    /// discharge power: no discharge-current sensor is exposed to a sandboxed app.
    private(set) var rateEstimateWatts: Double?
    private(set) var diagnostics: [String] = []
    /// Every power source powerd reports, not just the internal battery.
    ///
    /// BatteryCenter is built on this same list — it has a `_BCPowerSourceController`
    /// and registers for power-source change notifications — so if accessories are
    /// reachable at all from a sandboxed app, they show up here.
    private(set) var powerSources: [[String: Any]] = []
    /// False until the session file has been read. Nothing is written before then:
    /// the load is asynchronous now, and a save that landed first would overwrite
    /// the whole history with an empty array.
    private(set) var isLoaded = false

    /// Whether to hold the screen awake while the phone is plugged in.
    ///
    /// The screen locking is what used to end a charge session two minutes in — the
    /// tick stops with the app, and a full charge could never be recorded. Applied
    /// by `RootView`, which is where UIKit belongs; `Core` stays UI-free.
    var keepScreenAwakeWhileCharging: Bool {
        didSet { UserDefaults.standard.set(keepScreenAwakeWhileCharging, forKey: Self.keepAwakeKey) }
    }

    /// Whether to show the charging live activity on the Lock Screen, in the Dynamic
    /// Island and in StandBy. Applied by `RootView`, like the setting above.
    var showsLiveActivityWhileCharging: Bool {
        didSet { UserDefaults.standard.set(showsLiveActivityWhileCharging, forKey: Self.liveActivityKey) }
    }

    /// The reading used by the compact Dynamic Island presentation. This changes
    /// presentation only; the activity remains charger-bound.
    var liveActivityMetric: LiveActivityMetric {
        didSet {
            UserDefaults.standard.set(liveActivityMetric.rawValue,
                                      forKey: Self.liveActivityMetricKey)
        }
    }

    let thermal = ThermalMonitor()

    /// Called at the end of every tick. `RootView` installs it and fans the reading
    /// out to the live activity, the widget and the floating meter.
    ///
    /// A closure rather than SwiftUI's `onChange`, which is what this used to be:
    /// view updates stop when the app leaves the screen, and off screen is exactly
    /// when the floating meter is the only thing still showing a number.
    var onTick: ((PowerSnapshot) -> Void)?

    /// Usable pack energy, used to turn %/h into watts. Read from IOKit where the
    /// sandbox allows it, otherwise from the value the user sets in Settings.
    var batteryWattHours: Double {
        get {
            if let capacity = snapshot.designCapacity, capacity > 0 {
                return Double(capacity) * Self.nominalCellVoltage / 1000
            }
            return configuredBatteryWattHours
        }
    }

    var configuredBatteryWattHours: Double {
        didSet { UserDefaults.standard.set(configuredBatteryWattHours, forKey: Self.wattHoursKey) }
    }

    var sensorsAvailable: Bool { sensors != nil && !(sensors?.isEmpty ?? true) }
    var deviceModelIdentifier: String { Self.machineIdentifier }

    // MARK: Private

    private static let nominalCellVoltage = 3.87
    private static let wattHoursKey = "batteryWattHours"
    private static let keepAwakeKey = "keepScreenAwakeWhileCharging"
    private static let liveActivityKey = "showsLiveActivityWhileCharging"
    private static let liveActivityMetricKey = "liveActivityMetric"
    private static let liveWindow = 180

    private let battery = IOKitBattery()
    private let sensors = HIDSensors()
    private let batteryCenter = BatteryCenterBridge()
    private let energy = EnergyAccumulator()
    private let store = SessionStore()

    private var task: Task<Void, Never>?
    private var tick = 0
    private var lastSampleWrite: Date = .distantPast
    private var lastPersist: Date = .distantPast
    private var lastExternalConnected: Bool?
    /// The last moment the phone was actually observed plugged in. A session is
    /// closed at this point rather than at `.now`, so a charge that ended while the
    /// app was suspended is not recorded as having run until the app came back.
    private var lastConnectedObservation: Date?
    /// Set by `deleteAllSessions`. The load is asynchronous, so a delete that lands
    /// while it is still in flight would otherwise have the file's contents merged
    /// back in on top of it a moment later.
    private var discardedStoredSessions = false
    private var percentLog: [(date: Date, percent: Int)] = []
    private var lastChargingFlag: Bool?

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Self.wattHoursKey)
        configuredBatteryWattHours = stored > 0 ? stored : 15.0
        // Defaults to on: recording a whole charge is the point of the History tab,
        // and it cannot happen if the screen locks after thirty seconds.
        keepScreenAwakeWhileCharging = defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? true
        showsLiveActivityWhileCharging = defaults.object(forKey: Self.liveActivityKey) as? Bool ?? true
        liveActivityMetric = defaults.string(forKey: Self.liveActivityMetricKey)
            .flatMap(LiveActivityMetric.init(rawValue:)) ?? .chargingPower
        collectDiagnostics()
        Task { await loadStoredSessions() }
    }

    /// Reads the session file off the main thread and merges it in.
    private func loadStoredSessions() async {
        let stored = await store.loaded()
        guard !discardedStoredSessions else {
            isLoaded = true
            return
        }
        let restored = stored.map { session in
            // A session left open by a crash or a force quit is closed at its
            // last recorded point rather than being resumed.
            guard session.end == nil else { return session }
            var closed = session
            closed.end = session.start.addingTimeInterval(session.samples.last?.offset ?? 0)
            return closed
        }
        .filter(Self.isWorthKeeping)
        // A charge may have started and finished while the file was being read, so
        // merge rather than assign, keeping whatever this run has already recorded.
        let known = Set(sessions.map(\.id))
        sessions = (sessions + restored.filter { !known.contains($0.id) })
            .sorted { $0.start > $1.start }
        isLoaded = true
    }

    // MARK: Lifecycle

    func start() {
        guard task == nil else { return }
        refresh()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// Stops the tick but leaves any open session open.
    ///
    /// This is what backgrounding does now. It used to close the session, which made
    /// the History tab close to useless: `scenePhase` leaves `.active` for a pulled-down
    /// Control Center, an incoming call, the app switcher and the screen locking, so an
    /// overnight charge was recorded as a scatter of two-minute fragments instead of one
    /// session. The integrator already discards gaps longer than ten seconds, so a
    /// resumed session reports honest totals and `integratedSeconds` records how much of
    /// the wall clock was actually watched.
    func pause() {
        task?.cancel()
        task = nil
        persist()
    }

    // MARK: Refresh

    func refresh() {
        tick += 1
        thermal.update()

        let registry = battery?.readRegistryProperties() ?? [:]
        let sources = battery?.readPowerSources() ?? []
        #if DEBUG
        // Only the Raw data screen reads this, and that screen is Debug-only, so a
        // Release build was republishing the whole array once a second for nobody.
        powerSources = sources
        #endif
        let internalBattery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first

        let current = PowerSnapshot(date: .now,
                                    registry: registry,
                                    powerSource: internalBattery,
                                    adapterDetails: battery?.readAdapterDetails(),
                                    sensors: sensors?.read() ?? [],
                                    chargeStatus: battery?.readChargeStatus())
        snapshot = current

        // Charger-side sensors only exist while something is plugged in, so the
        // service list is re-enumerated on every plug event and occasionally after.
        if lastExternalConnected != current.externalConnected || tick % 15 == 0 {
            sensors?.rescan()
        }
        if tick % 5 == 1 {
            devices = batteryCenter.read()
        }

        appendLive(current)
        updateRateEstimate(current)
        updateSession(current)
        lastExternalConnected = current.externalConnected
        onTick?(current)
    }

    private func appendLive(_ snapshot: PowerSnapshot) {
        let sample = LiveSample(date: snapshot.date,
                                inputWatts: snapshot.inputWatts ?? 0,
                                batteryWatts: snapshot.batteryWatts ?? 0,
                                hottestTemperature: snapshot.hottestSensor?.value)
        live.append(sample)
        if live.count > Self.liveWindow {
            live.removeFirst(live.count - Self.liveWindow)
        }
    }

    // MARK: Sessions

    private func updateSession(_ snapshot: PowerSnapshot) {
        if snapshot.externalConnected {
            lastConnectedObservation = snapshot.date
            if currentSession == nil {
                openSession(snapshot)
            }
            energy.add(snapshot)
            sessionTotals = energy.totals
            recordSample(snapshot)
        } else {
            closeSessionIfNeeded()
        }

        if currentSession != nil, snapshot.date.timeIntervalSince(lastPersist) >= 30 {
            persist()
        }
    }

    private func openSession(_ snapshot: PowerSnapshot) {
        energy.reset()
        sessionTotals = energy.totals
        currentSession = ChargeSession(start: snapshot.date,
                                       startPercent: snapshot.percent ?? 0,
                                       adapterName: snapshot.adapterName,
                                       adapterRatedWatts: snapshot.adapterRatedWatts,
                                       isWireless: snapshot.isWirelessInput)
        lastSampleWrite = .distantPast
    }

    private func recordSample(_ snapshot: PowerSnapshot) {
        guard var session = currentSession else { return }

        session.endPercent = snapshot.percent ?? session.endPercent
        session.totals = energy.totals
        session.peakInputWatts = max(session.peakInputWatts, snapshot.inputWatts ?? 0)
        session.peakBatteryWatts = max(session.peakBatteryWatts, snapshot.batteryWatts ?? 0)
        if let temperature = snapshot.batteryTemperature {
            session.peakBatteryTemperature = max(session.peakBatteryTemperature ?? temperature, temperature)
        }
        // The adapter identifies itself a beat after the plug event, so the name
        // is filled in whenever it first becomes available.
        if session.adapterName == nil { session.adapterName = snapshot.adapterName }
        if session.adapterRatedWatts == nil { session.adapterRatedWatts = snapshot.adapterRatedWatts }
        if thermal.state.isThrottling { session.throttledSeconds += 1 }

        if snapshot.date.timeIntervalSince(lastSampleWrite) >= SessionStore.sampleInterval {
            lastSampleWrite = snapshot.date
            session.samples.append(ChargeSample(offset: snapshot.date.timeIntervalSince(session.start),
                                                inputWatts: snapshot.inputWatts ?? 0,
                                                batteryWatts: snapshot.batteryWatts ?? 0,
                                                percent: snapshot.percent ?? session.endPercent,
                                                batteryTemperature: snapshot.batteryTemperature,
                                                hottestTemperature: snapshot.hottestSensor?.value,
                                                throttled: thermal.state.isThrottling))
            // A very long charge is thinned in place: every other point goes, which
            // halves the resolution without losing the shape of the curve.
            if session.samples.count > SessionStore.sampleLimit {
                session.samples = session.samples.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
            }
        }
        currentSession = session
    }

    private func closeSessionIfNeeded() {
        guard var session = currentSession else { return }
        // The end is the last moment the charger was actually seen, not now. Unplug
        // the phone while the app is suspended and the next tick after it wakes is
        // the first that knows — dating the end from that tick would stretch every
        // such session across however long the app was away.
        session.end = max(lastConnectedObservation ?? snapshot.date, session.start)
        lastConnectedObservation = nil
        session.totals = energy.totals
        currentSession = nil
        energy.reset()
        sessionTotals = EnergyTotals()
        if Self.isWorthKeeping(session) {
            sessions.insert(session, at: 0)
        }
        // Persist either way: the periodic save wrote this session while it was
        // open, so the file has to be rewritten even when it is being discarded.
        persist()
    }

    /// A stretch of being plugged in that moved no energy is a cable reseat, or a
    /// phone sitting at 100 %, not a charge worth keeping.
    private static func isWorthKeeping(_ session: ChargeSession) -> Bool {
        session.totals.inputWattHours > 0.001 || session.gainedPercent > 0
    }

    private func persist() {
        guard isLoaded else { return }
        lastPersist = .now
        store.save(sessions + (currentSession.map { [$0] } ?? []))
    }

    func deleteSession(_ session: ChargeSession) {
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    func deleteAllSessions() {
        discardedStoredSessions = true
        sessions.removeAll()
        currentSession = nil
        energy.reset()
        sessionTotals = EnergyTotals()
        store.deleteAll()
    }

    // MARK: Rate estimate

    /// Tracks 1 % transitions and converts the slope into watts. Two transitions
    /// are needed because the first sample lands mid-percent.
    private func updateRateEstimate(_ snapshot: PowerSnapshot) {
        guard let percent = snapshot.percent else {
            rateEstimateWatts = nil
            return
        }
        if lastChargingFlag != snapshot.isCharging {
            lastChargingFlag = snapshot.isCharging
            percentLog.removeAll()
            rateEstimateWatts = nil
        }
        if percentLog.last?.percent != percent {
            percentLog.append((snapshot.date, percent))
            if percentLog.count > 7 { percentLog.removeFirst(percentLog.count - 7) }
        }
        let transitions = percentLog.dropFirst()
        guard transitions.count >= 2, let first = transitions.first, let last = transitions.last else { return }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0 else { return }
        rateEstimateWatts = Double(last.percent - first.percent) / 100 * batteryWattHours / hours
    }

    // MARK: Headline

    /// The number on the dial and the caption under it.
    ///
    /// This lives here rather than in `PowerSnapshot` because the last fallback —
    /// the %-rate estimate — is the monitor's, not the snapshot's: it is derived
    /// from how the percentage moved across several snapshots. `PowerSnapshot` used
    /// to carry a `primaryWatts` that answered a simpler version of the same
    /// question, which nothing called, while `DashboardView` open-coded this. One
    /// answer, in the layer that can actually give it.
    var headline: (watts: Double, caption: LocalizedStringResource)? {
        if snapshot.externalConnected {
            if let watts = snapshot.inputWatts {
                // Written out rather than as a ternary in the tuple. The string
                // extractor took only the first branch there — "from charger" never
                // reached the catalog and the dial's caption fell back to English on
                // every wired charge. `Text` and `LocalizedStringResource` literals
                // want to be at their own return site.
                if snapshot.isWirelessInput { return (watts, "from MagSafe") }
                return (watts, "from charger")
            }
            // Wireless charging has no input-current sensor — the PMU exposes the
            // coil voltage and nothing to multiply it by — so rather than reading
            // "no reading" while the phone is visibly charging, the dial drops to
            // the battery side and says so. A measured zero is still a reading: a
            // phone sitting at 100 % on a charger is genuinely taking nothing.
            if let watts = snapshot.batteryWatts { return (max(watts, 0), "into battery") }
            return nil
        }
        if let watts = snapshot.batteryWatts, watts != 0 { return (abs(watts), "drawn from battery") }
        if let watts = rateEstimateWatts { return (abs(watts), "from battery (%-rate estimate)") }
        return nil
    }

    // MARK: Diagnostics

    private func collectDiagnostics() {
        var lines: [String] = []
        lines.append("IOKit: \(battery == nil ? "unavailable" : "loaded")")
        lines.append("HID sensors: \(sensors == nil ? "unavailable" : "\(sensors?.serviceCount ?? 0) services")")
        lines.append("BatteryCenter: \(batteryCenter.status) via \(batteryCenter.controllerOrigin)")
        lines.append("Device: \(Self.machineIdentifier)")
        #if targetEnvironment(simulator)
        lines.append("Simulator: IOKit reads the Mac's battery, HID sensors are absent.")
        #endif
        diagnostics = lines
    }

    /// Why the accessory list is empty, in the app's voice, for the Devices screen.
    var batteryCenterStatus: LocalizedStringResource? { batteryCenter.status.userMessage }

    /// The same thing with the failing step named, for Raw data.
    var batteryCenterDiagnostic: LocalizedStringResource? { batteryCenter.status.diagnostic }

    /// Every HID service in the system, for the debug view.
    func hidInventory() -> [HIDSensors.ServiceInfo] {
        sensors?.fullInventory() ?? []
    }

    private static let machineIdentifier: String = {
        // Inside a simulator `uname` reports the Mac's architecture, so the
        // simulated model identifier is taken from the environment instead.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "\(simulated) (simulator)"
        }
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        // `info.machine` is a fixed-size C array; mirroring it avoids taking an
        // overlapping pointer to the struct that is still being written.
        return Mirror(reflecting: info.machine).children.reduce(into: "") { result, element in
            guard let byte = element.value as? Int8, byte != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(byte))))
        }
    }()
}
