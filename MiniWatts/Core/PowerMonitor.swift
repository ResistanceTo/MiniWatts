import Foundation
import Observation

/// One point in the rolling live chart.
nonisolated struct LiveSample: Identifiable, Hashable {
    let date: Date
    let inputWatts: Double?
    let batteryWatts: Double?
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
    /// The level's rise against the cell sensors over the same stretch, while
    /// charging. See `LevelRateCheck`.
    private(set) var levelRateCheck: LevelRateCheck?
    /// Resistance of the whole charging path — charger, cable, both plugs — inferred
    /// from how the port voltage sags as the current rises. Nil until the current
    /// has moved far enough for the fit to mean anything. See `PathResistanceMeter`.
    private(set) var pathResistance: PathResistanceEstimate?
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

    var sensorsAvailable: Bool { sensorServiceCount > 0 }
    var deviceModelIdentifier: String {
        #if targetEnvironment(simulator)
        return "\(PowerSnapshot.modelIdentifier) (simulator)"
        #else
        return PowerSnapshot.modelIdentifier
        #endif
    }

    /// A rated pack energy for the models one has been found for, with where it came
    /// from. It only sets the default: a value entered in Settings always wins.
    struct ModelRating: Sendable {
        let wattHours: Double
        let source: String
    }

    /// Kept short on purpose. Every entry is a figure someone checked, and a wrong
    /// default is worse than the generic one — the user sees a number, not a guess.
    ///
    /// - iPhone 18 Pro Max (iPhone19,7 from issue #16's dump; iPhone19,3 per
    ///   ChargeSpeed): 5,567 mAh in iFixit's teardown, 21.75 Wh.
    /// - iPhone 17 Pro Max (iPhone18,2): 5,088 mAh × 3.87 V, 19.7 Wh, ChargeSpeed's
    ///   figure, which its author notes was not checked against a source. That is the
    ///   eSIM-only pack; models with a SIM tray are listed smaller.
    static let modelRating: ModelRating? = {
        switch PowerSnapshot.modelIdentifier {
        case "iPhone19,3", "iPhone19,7":
            return ModelRating(wattHours: 21.75, source: "iFixit teardown, 5,567 mAh")
        case "iPhone18,2":
            return ModelRating(wattHours: 19.7, source: "5,088 mAh × 3.87 V")
        default:
            return nil
        }
    }()

    /// What the pack energy starts at before anything is set in Settings.
    static var defaultBatteryWattHours: Double { modelRating?.wattHours ?? 15.0 }

    // MARK: Private

    private static let nominalCellVoltage = 3.87
    private static let wattHoursKey = "batteryWattHours"
    private static let keepAwakeKey = "keepScreenAwakeWhileCharging"
    private static let liveActivityKey = "showsLiveActivityWhileCharging"
    private static let liveActivityMetricKey = "liveActivityMetric"
    private static let liveWindow = 180
    private static let holdDebounceInterval: TimeInterval = 30
    private static let maximumRateObservationGap: TimeInterval = 120
    /// Longest step between two ticks that still counts as watching continuously.
    /// The same ten seconds the energy integrator allows.
    private static let rateContinuityInterval: TimeInterval = 10

    private let probeService = SensorProbe()
    private let batteryCenter = BatteryCenterBridge()
    private let energy = EnergyAccumulator()
    private let resistance = PathResistanceMeter()
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
    /// Last foreground observation used to accumulate thermal-pressure time. Long
    /// gaps are excluded for the same reason the energy integrator excludes them:
    /// the app cannot know what happened while it was suspended.
    private var lastThermalObservationDate: Date?
    /// Set by `deleteAllSessions`. The load is asynchronous, so a delete that lands
    /// while it is still in flight would otherwise have the file's contents merged
    /// back in on top of it a moment later.
    private var discardedStoredSessions = false
    /// Each moment the level changed, with the running cell-sensor energy at that
    /// moment, so the level's rise and the sensors can be compared over one stretch.
    private var percentLog: [(date: Date, percent: Int, cellWattHours: Double, cellSeconds: TimeInterval)] = []
    /// Running integral of the cell sensors' watts, and how many seconds of it were
    /// actually observed. Only differences between two log entries are ever used.
    private var cellWattHours: Double = 0
    private var cellSeconds: TimeInterval = 0
    private var lastCellSample: (date: Date, watts: Double)?
    private var lastChargingFlag: Bool?
    private var lastRateObservationDate: Date?
    private var stableHoldState: ChargeHoldState?
    private var holdCandidate: ChargeHoldState?
    private var holdCandidateSince: Date?
    private var sensorServiceCount: Int = 0
    /// Why the session history came up empty, when the file was there and could not
    /// be read. Kept apart from `diagnostics` because that list is rebuilt whenever
    /// the sensor count changes — on the first plug event, an appended line was gone.
    private var storeWarning: String?

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Self.wattHoursKey)
        configuredBatteryWattHours = stored > 0 ? stored : Self.defaultBatteryWattHours
        // Defaults to on: recording a whole charge is the point of the History tab,
        // and it cannot happen if the screen locks after thirty seconds.
        keepScreenAwakeWhileCharging = defaults.object(forKey: Self.keepAwakeKey) as? Bool ?? true
        showsLiveActivityWhileCharging = defaults.object(forKey: Self.liveActivityKey) as? Bool ?? true
        liveActivityMetric = defaults.string(forKey: Self.liveActivityMetricKey)
            .flatMap(LiveActivityMetric.init(rawValue:)) ?? .chargingPower
        sensorServiceCount = probeService.initialServiceCount
        collectDiagnostics()
        Task { await loadStoredSessions() }
    }

    /// Reads the session file off the main thread and merges it in.
    private func loadStoredSessions() async {
        let stored = await store.loaded()
        if let warning = await store.readWarning() {
            storeWarning = warning
            collectDiagnostics()
        }
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
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(1))
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

    private func refresh() async {
        tick += 1
        thermal.update()

        let result = await probeService.read(lastExternalConnected: lastExternalConnected,
                                             periodicRescan: tick % 15 == 0)
        guard !Task.isCancelled else { return }
        let current = stabilizedHoldSnapshot(result.snapshot)
        // Only Raw data reads this. It used to be assigned under `#if DEBUG`, when that
        // screen was Debug-only; now that the page ships, the guard made its "powerd
        // power sources" panel report none in every release build — a false statement
        // on the one page whose job is to show what the probes actually returned. The
        // write costs nothing while that page is closed: `@Observable` invalidates only
        // views that read the property, and no other view does.
        powerSources = result.sources
        snapshot = current
        if sensorServiceCount != result.serviceCount {
            sensorServiceCount = result.serviceCount
            collectDiagnostics()
        }
        if tick % 5 == 1 {
            devices = batteryCenter.read()
        }

        appendLive(current)
        updateRateEstimate(current)
        resistance.add(current)
        pathResistance = resistance.estimate
        updateSession(current)
        lastExternalConnected = current.externalConnected
        onTick?(current)
    }

    /// One fresh reading for the Shortcuts action, with none of the tick's side effects.
    ///
    /// `refresh()` cannot be reused for this. It opens and samples charge sessions and
    /// persists them, feeds the resistance fit, drives the live activity and the widget
    /// through `onTick`, and republishes `snapshot`. Shortcuts wakes the app in the
    /// background — possibly every few minutes, for an automation — and each of those
    /// would leave a one-sample session in History. This reads and returns.
    ///
    /// The HID service list is re-enumerated first. The tick does that on plug events,
    /// but the tick is paused whenever the app is in the background, which is exactly
    /// when Shortcuts runs it: a charger plugged in since the last tick would have no
    /// sensors in the list, and charging power would come back as no reading while the
    /// phone was plainly charging. Enumerating is cheap; a stale list is not.
    func readNow() async -> PowerSnapshot {
        await probeService.readNow()
    }

    private func appendLive(_ snapshot: PowerSnapshot) {
        let sample = LiveSample(date: snapshot.date,
                                inputWatts: snapshot.inputWatts,
                                batteryWatts: snapshot.batteryWatts,
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
        lastThermalObservationDate = snapshot.date
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
        if let previous = lastThermalObservationDate {
            let interval = snapshot.date.timeIntervalSince(previous)
            if interval > 0, interval <= 10, thermal.state.isThrottling {
                session.throttledSeconds += interval
            }
        }
        lastThermalObservationDate = snapshot.date
        // Carried on every tick rather than at close: the fit is what History uses to
        // compare one cable with another, and a session that ends while the app is
        // suspended is closed from `lastConnectedObservation` without another reading.
        session.recordPathFit(resistance.estimate)

        if snapshot.date.timeIntervalSince(lastSampleWrite) >= SessionStore.sampleInterval {
            lastSampleWrite = snapshot.date
            session.samples.append(ChargeSample(offset: snapshot.date.timeIntervalSince(session.start),
                                                inputWatts: snapshot.inputWatts,
                                                batteryWatts: snapshot.batteryWatts,
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
        lastThermalObservationDate = nil
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

    /// Every recorded session on the same adapter that produced a path-resistance
    /// fit, including this one, lowest resistance first.
    ///
    /// This is the comparison the number is actually for. A path resistance on its
    /// own is hard to judge — it carries the charger's regulation and both sets of
    /// contacts as well as the cable — but the same charger measured through two
    /// cables differs only by the cable and the plugs, so the difference between two
    /// rows here is the thing a user can act on.
    ///
    /// Matched on the adapter's own name, which is hardware and is compared verbatim.
    /// Wireless sessions are excluded: there is no cable in them to compare.
    func pathFitsSharingAdapter(with session: ChargeSession) -> [ChargeSession] {
        // This session has to be in the comparison for the comparison to be about it.
        // Without a fit of its own it would be a list of other sessions under a
        // heading that claims to say something about this one.
        guard let adapter = session.adapterName, !session.isWireless,
              session.pathMilliohms != nil else { return [] }
        let matching = sessions.filter {
            $0.adapterName == adapter && !$0.isWireless && $0.pathMilliohms != nil
        }
        // One row is not a comparison; it is the same number again.
        guard matching.count > 1 else { return [] }
        return matching.sorted { ($0.pathMilliohms ?? 0) < ($1.pathMilliohms ?? 0) }
    }

    func deleteAllSessions() {
        discardedStoredSessions = true
        sessions.removeAll()
        currentSession = nil
        energy.reset()
        sessionTotals = EnergyTotals()
        lastThermalObservationDate = nil
        store.deleteAll()
    }

    // MARK: Charge hold state

    /// Apply a short hysteresis window to the inferred hold state. A single HID
    /// sample can lose the battery-current rail while the phone is still charging;
    /// requiring the opposite state to persist avoids flickering between “hold” and
    /// “not charging”. Explicit unplug/charge/full transitions clear immediately.
    ///
    /// The first reading of a run is taken as it stands; only a change from it has
    /// to persist. Making the first one settle as well put thirty seconds of “hold
    /// status unknown” on every cold launch during a real hold — which, with an 80 %
    /// charge limit, is most launches — and `.unknown` is reserved for a missing
    /// current sensor, which that was not: the sensor was answering, with zero.
    private func stabilizedHoldSnapshot(_ snapshot: PowerSnapshot) -> PowerSnapshot {
        let observed = snapshot.measuredHoldState

        if stableHoldState == nil {
            stableHoldState = observed
            holdCandidate = nil
            holdCandidateSince = nil
        } else if !snapshot.externalConnected || snapshot.isCharging || snapshot.fullyCharged {
            stableHoldState = .notHeld
            holdCandidate = nil
            holdCandidateSince = nil
        } else if observed == .unknown {
            // Preserve the last known state while the current sensor is absent.
            holdCandidate = nil
            holdCandidateSince = nil
        } else if observed == stableHoldState {
            holdCandidate = nil
            holdCandidateSince = nil
        } else if holdCandidate != observed {
            holdCandidate = observed
            holdCandidateSince = snapshot.date
        } else if let since = holdCandidateSince,
                  snapshot.date.timeIntervalSince(since) >= Self.holdDebounceInterval {
            stableHoldState = observed
            holdCandidate = nil
            holdCandidateSince = nil
        }

        var adjusted = snapshot
        adjusted.setHoldStateOverride(stableHoldState ?? observed)
        return adjusted
    }

    // MARK: Rate estimate

    /// Tracks 1 % transitions and converts the slope into watts. Two transitions
    /// are needed because the first sample lands mid-percent.
    private func updateRateEstimate(_ snapshot: PowerSnapshot) {
        integrateCellEnergy(snapshot)
        guard let percent = snapshot.percent else {
            rateEstimateWatts = nil
            levelRateCheck = nil
            lastRateObservationDate = nil
            return
        }

        // What a hole in the observations costs depends on what happened in it, so
        // the log is not thrown away on every `pause()`: two transitions take
        // minutes to arrive, and someone who only ever glances at the app would
        // never see an estimate at all.
        if let previousDate = lastRateObservationDate {
            let gap = snapshot.date.timeIntervalSince(previousDate)
            if gap > Self.maximumRateObservationGap || gap < 0 {
                // The app was suspended or the source clock moved. A slope across
                // that hole would look like a near-zero discharge rate.
                percentLog.removeAll()
                rateEstimateWatts = nil
                levelRateCheck = nil
            } else if gap > Self.rateContinuityInterval, percentLog.last?.percent != percent {
                // A short hole, and the level moved somewhere inside it. When is
                // not known — only that it was before now — and stamping it now
                // would shorten the next step and overstate the rate. Start again
                // from this level: a log's first entry is never used as a time.
                // The last estimate stays up; it is at most two minutes old.
                percentLog.removeAll()
            }
            // A short hole the level sat still through has lost nothing: the log
            // only holds the moments the level changed.
        }
        lastRateObservationDate = snapshot.date

        if lastChargingFlag != snapshot.isCharging {
            lastChargingFlag = snapshot.isCharging
            percentLog.removeAll()
            rateEstimateWatts = nil
            levelRateCheck = nil
        }
        if percentLog.last?.percent != percent {
            percentLog.append((snapshot.date, percent, cellWattHours, cellSeconds))
            if percentLog.count > 7 { percentLog.removeFirst(percentLog.count - 7) }
        }
        let transitions = percentLog.dropFirst()
        guard transitions.count >= 2, let first = transitions.first, let last = transitions.last else { return }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours > 0 else { return }
        let estimate = Double(last.percent - first.percent) / 100 * batteryWattHours / hours
        rateEstimateWatts = estimate
        updateLevelRateCheck(levelWatts: estimate, from: first, to: last, charging: snapshot.isCharging)
    }

    /// Adds this tick's cell-sensor watts to the running integral, trapezoid by
    /// trapezoid. Only intervals that were watched continuously and read at both
    /// ends count; `cellSeconds` records how much that was, so a stretch the sensors
    /// were missing from is visible as missing rather than read as zero.
    private func integrateCellEnergy(_ snapshot: PowerSnapshot) {
        guard snapshot.isCharging, let watts = snapshot.batteryWatts else {
            lastCellSample = nil
            return
        }
        if let previous = lastCellSample {
            let step = snapshot.date.timeIntervalSince(previous.date)
            if step > 0, step <= Self.rateContinuityInterval {
                cellWattHours += (previous.watts + watts) / 2 * step / 3600
                cellSeconds += step
            }
        }
        lastCellSample = (snapshot.date, watts)
    }

    /// Sets the level against the cell sensors over the stretch the %-rate estimate
    /// was just taken from. Leaves the last result up when this stretch cannot say
    /// anything — too short, too little rise, or too much of it unwatched.
    private func updateLevelRateCheck(levelWatts: Double,
                                      from first: (date: Date, percent: Int, cellWattHours: Double, cellSeconds: TimeInterval),
                                      to last: (date: Date, percent: Int, cellWattHours: Double, cellSeconds: TimeInterval),
                                      charging: Bool) {
        guard charging else {
            levelRateCheck = nil
            return
        }
        let span = last.date.timeIntervalSince(first.date)
        let rise = last.percent - first.percent
        let watched = last.cellSeconds - first.cellSeconds
        let energy = last.cellWattHours - first.cellWattHours
        guard rise >= LevelRateCheck.minimumRise, span >= LevelRateCheck.minimumSpan,
              watched >= span * 0.9, energy > 0 else { return }
        let cellWatts = energy / (watched / 3600)
        guard cellWatts >= LevelRateCheck.minimumCellWatts, levelWatts > 0 else { return }
        levelRateCheck = LevelRateCheck(levelWatts: levelWatts,
                                        cellWatts: cellWatts,
                                        packWattHours: batteryWattHours,
                                        percentRise: rise,
                                        span: span)
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
                // Written out rather than as a ternary in the tuple. `LocalizedStringResource`
                // literals want to be at their own return site so both transport labels
                // reach the catalog.
                if snapshot.isWirelessInput { return (watts, "at charging coil") }
                return (watts, "at phone port")
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
        lines.append("IOKit: \(probeService.batteryAvailable ? "loaded" : "unavailable")")
        lines.append("HID sensors: \(probeService.hidAvailable ? "\(sensorServiceCount) services" : "unavailable")")
        lines.append("BatteryCenter: \(batteryCenter.status) via \(batteryCenter.controllerOrigin)")
        lines.append("Device: \(deviceModelIdentifier)")
        #if targetEnvironment(simulator)
        lines.append("Simulator: IOKit reads the Mac's battery, HID sensors are absent.")
        #endif
        if let storeWarning { lines.append(storeWarning) }
        diagnostics = lines
    }

    /// Why the accessory list is empty, in the app's voice, for the Devices screen.
    var batteryCenterStatus: LocalizedStringResource? { batteryCenter.status.userMessage }

    /// The same thing with the failing step named, for Raw data.
    var batteryCenterDiagnostic: LocalizedStringResource? { batteryCenter.status.diagnostic }

    /// Every HID service in the system, for the debug view.
    func hidInventory() async -> [HIDSensors.ServiceInfo] {
        await probeService.fullInventory()
    }

    /// What the accessory-manager registry family will admit to, for the debug view.
    /// Built on demand rather than held: it is a one-shot scan behind a button, and
    /// nothing outside Raw data reads it. See `AccessoryProbe` for what it asks and why.
    func accessoryProbe() -> AccessoryProbe.Report? {
        AccessoryProbe()?.run()
    }
}
