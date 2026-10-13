import Foundation

/// Confidence state for the system's charge-hold decision.
///
/// A missing battery-current sensor is evidence we do not have, rather than
/// evidence that charging is being held. Keeping that distinction prevents the
/// UI from presenting an inferred hold as a fact.
nonisolated enum ChargeHoldState: String, Codable, Hashable, Sendable {
    case held
    case notHeld
    case unknown
}

/// One advertised USB-PD / HVC power profile from the adapter's menu.
nonisolated struct PDProfile: Identifiable, Hashable {
    let index: Int
    let voltageMillivolts: Int
    let currentMilliamps: Int

    var id: Int { index }
    var volts: Double { Double(voltageMillivolts) / 1000 }
    var amps: Double { Double(currentMilliamps) / 1000 }
    var watts: Double { volts * amps }
    var label: String { String(format: "%.1f V × %.2f A", volts, amps) }
}

/// Every temperature sensor that sits in one zone of the phone.
nonisolated struct ZoneTemperatures: Identifiable, Hashable {
    let zone: ThermalZone
    /// Every reading in the zone, hottest first, calibration constants last.
    let readings: [HIDSensors.Reading]
    /// The one number that stands for the zone — on the heat map and in the zone's
    /// header. The hottest *live* reading, except in the battery zone, where it is
    /// the median: the same figure `PowerSnapshot.batteryTemperature` gives, so the
    /// map's battery pin and the Battery readout beside it cannot disagree. Nil when
    /// the zone has nothing but calibration constants in it.
    let representative: Double?

    var id: ThermalZone { zone }
}

/// One reading of everything the app can learn about power, merged from four sources:
/// - `registry`:   IOKit `IOPMPowerSource` (complete on the simulator, two keys on iOS)
/// - `powerSource`: powerd's battery description
/// - `adapterDetails`: powerd's adapter description, including the PD profile menu
/// - `sensors`: PMU / charger readings from `IOHIDEventSystemClient`
///
/// Everything derived from `sensors` is resolved once, here in `init`, and stored.
/// It used to be computed on every access, which read well but meant a SwiftUI body
/// asking for the battery temperature four times did four linear scans of forty-odd
/// readings and called `SensorCatalog.zone(for:)` — which lowercases and splits the
/// name — once per sensor per scan. At one snapshot a second and several bodies per
/// snapshot that added up to real work in the render pass. The raw dictionaries stay
/// computed: those are single hash lookups.
/// SensorProbe hands this immutable snapshot to the main actor. Its raw IOKit
/// property-list dictionaries are bridged to Swift dictionaries and no caller
/// mutates their values after construction.
/// TODO: model raw diagnostics as typed Sendable values and remove @unchecked.
nonisolated struct PowerSnapshot: @unchecked Sendable {
    let date: Date
    let registry: [String: Any]
    let powerSource: [String: Any]?
    let adapterDetails: [String: Any]?
    let sensors: [HIDSensors.Reading]
    let chargeStatus: [String: Any]?

    // MARK: - Derived from the sensors, resolved once

    /// Every temperature sensor, in the order the services were enumerated.
    let temperatures: [HIDSensors.Reading]
    /// Temperature sensors grouped by where they sit in the phone.
    let temperaturesByZone: [ZoneTemperatures]
    /// The hottest live sensor anywhere in the phone.
    let hottestSensor: HIDSensors.Reading?
    /// Temperature values that were present in the raw HID stream but were not
    /// safe to use as a derived reading. The raw sensor remains available in the
    /// Debug screen so a model-specific mapping can be investigated later.
    let temperatureWarnings: [String]
    /// Live battery-zone readings used to calculate the representative battery
    /// temperature. Keeping every reading makes the aggregation visible in the UI.
    let batteryTemperatureReadings: [HIDSensors.Reading]

    let usbInputVoltage: Double?
    let usbInputCurrent: Double?
    let wirelessInputVoltage: Double?
    let wirelessInputCurrent: Double?
    let batteryRailVoltage: Double?
    let batteryRailCurrent: Double?

    /// Power arriving from the adapter, in watts. Voltage × current at the port,
    /// or at the coil when charging wirelessly.
    ///
    /// Wireless usually stops at nil on purpose. powerd does report the pad's
    /// voltage and current, but those are the negotiated ceiling and do not move
    /// with the draw, so there is no honest input figure to put on the dial.
    ///
    /// Also nil when the sensors answered but their product cannot be the whole
    /// input — see `partialInputWatts`.
    let inputWatts: Double?
    /// What the input sensors multiply out to when that cannot be all of the input:
    /// more power is reaching the cell than they account for. nil whenever
    /// `inputWatts` is trusted, or there was nothing to multiply.
    ///
    /// An iPad Pro M1 showed 6.41 W "from charger" beside 16.6 W into the cell, and
    /// an iPhone 18 Pro Max read 21.8 W while an inline meter on the same cable read
    /// 14.55 V × 2.99 A — the voltage right, the current half. On those models
    /// `IQ0u` evidently sees one of several input paths. Which one is not known, so
    /// the figure is kept for Raw data and for saying why the input is missing, and
    /// is otherwise treated as no reading: nothing is integrated or derived from it.
    let partialInputWatts: Double?
    /// Power crossing into (+) or out of (−) the battery, in watts.
    let batteryWatts: Double?

    private let zoneHottest: [ThermalZone: HIDSensors.Reading]
    /// Set by `PowerMonitor` after a short debounce. Standalone reads (widgets,
    /// Shortcuts) leave this nil and use the sensor evidence directly.
    private var holdStateOverride: ChargeHoldState?

    init(date: Date = .now,
         registry: [String: Any] = [:],
         powerSource: [String: Any]? = nil,
         adapterDetails: [String: Any]? = nil,
         sensors: [HIDSensors.Reading] = [],
         chargeStatus: [String: Any]? = nil) {
        self.date = date
        self.registry = registry
        self.powerSource = powerSource
        self.adapterDetails = adapterDetails
        self.sensors = sensors
        self.chargeStatus = chargeStatus
        self.holdStateOverride = nil
        let externalConnected = Self.externalConnected(registry: registry, powerSource: powerSource)

        // Names repeat — an iPhone 17 reports four separate sensors all called
        // "gas gauge battery" — so first wins, which is what a linear `first(where:)`
        // over the service list used to do.
        var byName: [String: HIDSensors.Reading] = [:]
        var temperatures: [HIDSensors.Reading] = []
        var temperatureWarnings: [String] = []
        for reading in sensors {
            if byName[reading.name] == nil { byName[reading.name] = reading }
            // A reading on the temperature page that no phone could produce is not a
            // temperature — it is a sentinel or a raw counter, and it used to be drawn
            // on the heat map as if it were a reading. It stays in `sensors`, which
            // Raw data shows unedited, and out of everything that treats a number as
            // degrees.
            guard reading.kind == .temperature else { continue }
            guard HIDSensors.plausibleCelsius.contains(reading.value) else {
                temperatureWarnings.append(Self.temperatureWarning(for: reading, reason: "outside the plausible Celsius range"))
                continue
            }
            if let reason = Self.derivedTemperatureRejectionReason(for: reading,
                                                                    allSensors: sensors,
                                                                    externalConnected: externalConnected) {
                temperatureWarnings.append(Self.temperatureWarning(for: reading, reason: reason))
                continue
            }
            temperatures.append(reading)
        }
        self.temperatures = temperatures
        self.temperatureWarnings = temperatureWarnings

        func named(_ name: String) -> Double? { byName[name]?.value }
        func rail(_ kind: HIDSensors.Kind, _ fragments: [String]) -> Double? {
            sensors.first { reading in
                reading.kind == kind && fragments.contains { reading.name.localizedCaseInsensitiveContains($0) }
            }?.value
        }

        let usbVoltage = named("Charger VQ0u") ?? rail(.voltage, ["VQ0u"])
        let usbCurrent = named("Charger IQ0u") ?? rail(.current, ["IQ0u"])
        // Matched on the rail rather than the full name: "Q1u" is the charge IC's
        // second upstream port, which is where the wireless coil lands. Naming varies
        // between phone models, and a current sensor for this rail may not exist at
        // all — on the models checked so far only the voltage is exposed.
        let coilVoltage = rail(.voltage, ["Q1u"])
        let coilCurrent = rail(.current, ["Q1u"])
        let cellCurrent = named("Charger IQ0B") ?? rail(.current, ["IQ0B"])
        let cellVoltage = named("Charger VQ0l")
            ?? named("PMU VP0u")
            ?? rail(.voltage, ["VQ0l", "VP0u"])

        usbInputVoltage = usbVoltage
        usbInputCurrent = usbCurrent
        wirelessInputVoltage = coilVoltage
        wirelessInputCurrent = coilCurrent
        batteryRailVoltage = cellVoltage
        batteryRailCurrent = cellCurrent

        let sensedInputWatts: Double?
        if let voltage = usbVoltage, let current = usbCurrent, voltage > 0.5 {
            sensedInputWatts = voltage * current
        } else if let voltage = coilVoltage, let current = coilCurrent, voltage > 0.5 {
            sensedInputWatts = voltage * current
        } else {
            sensedInputWatts = nil
        }

        let registryVoltage = Self.int("Voltage", in: registry).map { Double($0) / 1000 }
        let registryCurrent = Self.int("InstantAmperage", in: registry).map { Double($0) / 1000 }
        let cellWatts: Double?
        if let voltage = registryVoltage, let current = registryCurrent {
            cellWatts = voltage * current
        } else if let current = cellCurrent, let voltage = cellVoltage {
            cellWatts = current * voltage
        } else {
            cellWatts = nil
        }
        batteryWatts = cellWatts

        if let sensed = sensedInputWatts, let cell = cellWatts, Self.exceedsInput(cell: cell, input: sensed) {
            inputWatts = nil
            partialInputWatts = sensed
        } else {
            inputWatts = sensedInputWatts
            partialInputWatts = nil
        }

        // One pass over the temperature sensors: `SensorCatalog.zone(for:)` lowercases
        // and splits the name, so it is called exactly once per sensor per snapshot.
        var grouped: [ThermalZone: [HIDSensors.Reading]] = [:]
        var hottestByZone: [ThermalZone: HIDSensors.Reading] = [:]
        var hottestOverall: HIDSensors.Reading?
        for reading in temperatures {
            let zone = SensorCatalog.zone(for: reading.name)
            grouped[zone, default: []].append(reading)
            guard Self.isLiveTemperature(reading) else { continue }
            if reading.value > (hottestByZone[zone]?.value ?? -.greatestFiniteMagnitude) {
                hottestByZone[zone] = reading
            }
            if reading.value > (hottestOverall?.value ?? -.greatestFiniteMagnitude) {
                hottestOverall = reading
            }
        }
        zoneHottest = hottestByZone
        hottestSensor = hottestOverall
        let batteryReadings = (grouped[.battery] ?? [])
            .filter(Self.isLiveTemperature)
            .sorted { $0.value < $1.value }
        batteryTemperatureReadings = batteryReadings
        let batteryMedian = Self.median(batteryReadings.map(\.value))
        temperaturesByZone = grouped
            .map { zone, readings in
                ZoneTemperatures(
                    zone: zone,
                    // Live readings first, hottest first within each half. A
                    // calibration constant sinking to the bottom of its own zone is
                    // the point: it is still listed, it just never leads.
                    readings: readings.sorted { left, right in
                        let leftLive = Self.isLiveTemperature(left)
                        let rightLive = Self.isLiveTemperature(right)
                        if leftLive != rightLive { return leftLive }
                        return left.value > right.value
                    },
                    representative: zone == .battery ? batteryMedian : hottestByZone[zone]?.value
                )
            }
            .sorted { $0.zone.order < $1.zone.order }
    }

    // MARK: - Charge state

    var isCharging: Bool {
        if registry["IsCharging"] != nil { return bool("IsCharging", in: registry) }
        return bool("Is Charging", in: powerSource)
    }

    var externalConnected: Bool {
        Self.externalConnected(registry: registry, powerSource: powerSource)
    }

    var fullyCharged: Bool {
        if registry["FullyCharged"] != nil { return bool("FullyCharged", in: registry) }
        if bool("Is Charged", in: powerSource) { return true }
        return externalConnected && !isCharging && (percent ?? 0) >= 100
    }

    var isFinishingCharge: Bool { bool("Is Finishing Charge", in: powerSource) }
    var lowPowerMode: Bool { bool("LPM Active", in: powerSource) }
    var percent: Int? { int("CurrentCapacity", in: registry) ?? int("Current Capacity", in: powerSource) }

    /// e.g. "Charging On Hold". Privileged on iOS, so usually nil there.
    var chargeStatusText: String? { chargeStatus?["chargeStatus"] as? String }

    /// The direct evidence available in this snapshot, before the monitor's
    /// hysteresis filter is applied.
    var measuredHoldState: ChargeHoldState {
        if let text = chargeStatusText {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "charging on hold" || normalized == "on hold" ? .held : .notHeld
        }
        guard externalConnected, !isCharging, !fullyCharged,
              let level = percent, level >= 50, level < 100 else { return .notHeld }
        // The merged current, not the HID rail alone. On a phone they are the same
        // number. Where the registry answers instead — the simulator — the rail is
        // absent, and asking only the rail called the hold unknown beside a cell
        // current reading of 0.00 A on the same screen.
        guard let current = batteryCurrent else { return .unknown }
        return abs(current) < 0.3 ? .held : .notHeld
    }

    /// The debounced state in the main app, or the measured state for a
    /// standalone snapshot.
    var holdState: ChargeHoldState { holdStateOverride ?? measuredHoldState }

    mutating func setHoldStateOverride(_ state: ChargeHoldState?) {
        holdStateOverride = state
    }

    var isChargingOnHold: Bool { holdState == .held }

    var holdIsUnknown: Bool {
        holdState == .unknown
    }

    var holdIsInferred: Bool { chargeStatusText == nil && isChargingOnHold }

    var statusText: LocalizedStringResource {
        if isChargingOnHold { return "Charging on hold" }
        if fullyCharged && externalConnected { return "Full" }
        if isCharging { return isFinishingCharge ? "Finishing charge" : "Charging" }
        if externalConnected { return "Plugged in, not charging" }
        return "On battery"
    }

    /// Minutes to full while charging, to empty otherwise.
    var timeRemainingMinutes: Int? {
        if let value = int("TimeRemaining", in: registry), value > 0, value != 65535 { return value }
        let key = isCharging ? "Time to Full Charge" : "Time to Empty"
        if let value = int(key, in: powerSource), value > 0 { return value }
        return nil
    }

    // MARK: - Registry electricals (simulator / macOS only)

    var registryVoltage: Double? { int("Voltage", in: registry).map { Double($0) / 1000 } }
    /// Positive while charging, negative while discharging.
    var registryCurrent: Double? { int("InstantAmperage", in: registry).map { Double($0) / 1000 } }
    /// Hundredths of a degree on every model checked — but a model that scales it
    /// differently would put a nonsense number on the Power tab, so it goes through
    /// the same plausibility check as the HID sensors.
    var registryTemperature: Double? {
        int("Temperature", in: registry)
            .map { Double($0) / 100 }
            .flatMap { HIDSensors.plausibleCelsius.contains($0) ? $0 : nil }
    }
    var cycleCount: Int? { int("CycleCount", in: registry) }
    var designCapacity: Int? { int("DesignCapacity", in: registry) }
    var maxCapacity: Int? { int("AppleRawMaxCapacity", in: registry) ?? int("NominalChargeCapacity", in: registry) }

    var healthPercent: Double? {
        guard let maxCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Double(maxCapacity) / Double(designCapacity) * 100
    }

    // MARK: - Sensors

    /// The hottest live sensor in a zone. Nil when the zone is absent, or holds
    /// nothing but calibration constants.
    func temperature(in zone: ThermalZone) -> Double? { zoneHottest[zone]?.value }

    /// The sensor behind `temperature(in:)`, so a readout can name its own source.
    func hottestSensor(in zone: ThermalZone) -> HIDSensors.Reading? { zoneHottest[zone] }

    /// `PMU tcal` read exactly 51.8 °C in every sample taken from an iPhone 17,
    /// while each neighbouring die moved several degrees between those same
    /// samples — so it is a calibration constant, not a live temperature. It stays
    /// in the zone lists, where being flat is visible, but it is kept out of
    /// anything that ranks sensors by heat, which it would otherwise win forever.
    private static func isLiveTemperature(_ reading: HIDSensors.Reading) -> Bool {
        !reading.name.localizedCaseInsensitiveContains("tcal")
    }

    /// Whether more power is reaching the cell than the input sensors account for.
    ///
    /// Energy only flows one way through a charger, so a cell figure above the input
    /// figure means the input figure is short. The margins are there because the two
    /// rails are separate sensors read a moment apart: a load step can put the cell
    /// briefly ahead by a few percent. The cases this exists for are not close —
    /// the cell side was 1.8× and 2.6× the input.
    private static func exceedsInput(cell: Double, input: Double) -> Bool {
        cell > input * 1.2 && cell - input > 1.5
    }

    /// The rail number in a charge-IC die sensor's name: "0" in `Charger TQ0d`, "2"
    /// in the `Charger TQ2d` an iPad Pro reports. nil for any other sensor.
    private static func chargeDieRail(in lowercasedName: String) -> Substring? {
        guard let prefix = lowercasedName.range(of: "tq") else { return nil }
        let tail = lowercasedName[prefix.upperBound...]
        let digits = tail.prefix(while: \.isNumber)
        let rest = tail.dropFirst(digits.count)
        guard !digits.isEmpty, rest.first == "d", !(rest.dropFirst().first?.isLetter ?? false) else { return nil }
        return digits
    }

    /// Some models expose a sentinel on the temperature usage page that is still
    /// inside the broad physical range. Keep it in the raw dump, but do not let it
    /// become the phone's hottest component or battery temperature.
    private static func derivedTemperatureRejectionReason(
        for reading: HIDSensors.Reading,
        allSensors: [HIDSensors.Reading],
        externalConnected: Bool
    ) -> String? {
        // An iPhone 11 lists nine sensors at exactly 0.0 °C — the camera dies, `AMC
        // ODTS`, `TV1s`–`TV5s` — in a 22 °C room beside neighbours at 25–33 °C. That
        // is a sensor that is switched off, not a part at freezing point. Exactly
        // zero only: a phone that really is that cold does not sit on the number.
        if reading.value == 0 {
            return "exactly 0.0 °C, which is what an unpowered sensor reports"
        }
        let name = reading.name.lowercased()
        if name.contains("tdev"), reading.value < -10 {
            return "below the plausible temperature of a powered die"
        }
        // Any rail, not only Q0: an iPhone 11 idles at `TQ0d` 97.5 °C beside a 29 °C
        // `TQ0j`, and an iPad Pro M1 does the same on `TQ2d`. Each die is checked
        // against the junction sensor of its own rail.
        guard let rail = Self.chargeDieRail(in: name), reading.value > 85 else { return nil }
        let junction = allSensors.first {
            $0.kind == .temperature
                && $0.name.localizedCaseInsensitiveContains("tq\(rail)j")
                && HIDSensors.plausibleCelsius.contains($0.value)
        }?.value
        guard externalConnected, let junction, junction >= 60 else {
            return "high charge-IC die value without a matching live junction reading"
        }
        return nil
    }

    private static func temperatureWarning(for reading: HIDSensors.Reading, reason: String) -> String {
        "[\(reading.index)] \(reading.name) = \(reading.formatted) — excluded from derived temperatures: \(reason)"
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    var batteryTemperature: Double? {
        registryTemperature ?? Self.median(batteryTemperatureReadings.map(\.value))
    }
    var chargerTemperature: Double? { temperature(in: .charger) }
    var socTemperature: Double? { temperature(in: .soc) }

    /// True when power is arriving over the coil rather than the port.
    var isWirelessInput: Bool { (wirelessInputVoltage ?? 0) > 1 && (usbInputVoltage ?? 0) < 1 }

    // MARK: - Merged power

    var batteryVoltage: Double? { registryVoltage ?? batteryRailVoltage }
    var batteryCurrent: Double? { registryCurrent ?? batteryRailCurrent }

    /// Share of measured adapter power that reaches the cell. The remainder also
    /// includes the phone's own system load, so this is charge-path efficiency.
    var chargePathEfficiency: Double? {
        guard let inputWatts, inputWatts > 0.5, let batteryWatts, batteryWatts > 0 else { return nil }
        return min(batteryWatts / inputWatts, 1) * 100
    }

    /// Adapter power not observed at the battery rail. It is not a pure heat
    /// measurement: phone load and conversion loss are mixed together.
    var unaccountedPowerWatts: Double? {
        guard let inputWatts, let batteryWatts, inputWatts > batteryWatts else { return nil }
        return inputWatts - batteryWatts
    }

    // MARK: - Adapter

    var adapter: [String: Any]? {
        (registry["AdapterDetails"] as? [String: Any])
            ?? (registry["AppleRawAdapterDetails"] as? [String: Any])
            ?? adapterDetails
    }

    var adapterName: String? {
        (adapter?["Name"] as? String) ?? (adapter?["Description"] as? String)
    }

    var adapterManufacturer: String? { adapter?["Manufacturer"] as? String }
    var adapterModel: String? { adapter?["Model"].map { String(describing: $0) } }
    var adapterSerial: String? { adapter?["SerialString"] as? String }
    var adapterIsWireless: Bool { bool("IsWireless", in: adapter) || isWirelessInput }

    /// Millivolts the adapter reports. Wired chargers use `Voltage`; the wireless
    /// ones seen so far use `AdapterVoltage`.
    var adapterVoltageMillivolts: Int? {
        int("Voltage", in: adapter) ?? int("AdapterVoltage", in: adapter)
    }

    var adapterCurrentMilliamps: Int? { int("Current", in: adapter) }

    /// The adapter's negotiated ceiling, from its own voltage and current.
    ///
    /// Not a live measurement, and it must not be shown as one. Two MagSafe samples
    /// minutes apart both read 6800 mV × 661 mA while the current into the cell
    /// fell from 0.76 A to 0.51 A; over USB-C the same pair reads exactly the
    /// `UsbHvcMenu` profile's MaxVoltage × MaxCurrent — 5 V × 3 A — while the phone
    /// was drawing 3.9 W.
    var adapterCeilingWatts: Double? {
        guard let voltage = adapterVoltageMillivolts, let current = adapterCurrentMilliamps,
              voltage > 0, current > 0 else { return nil }
        return Double(voltage) * Double(current) / 1_000_000
    }

    /// The adapter's nameplate rating: what it says it can deliver in total.
    var adapterRatedWatts: Double? {
        if let watts = int("Watts", in: adapter) { return Double(watts) }
        if let profile = negotiatedProfile { return profile.watts }
        return adapterCeilingWatts
    }

    var adapterSource: String? {
        if let text = adapter?["Source"] as? String { return text }
        if let number = adapter?["Source"] as? NSNumber { return "Source \(number.intValue)" }
        if adapterIsWireless { return "Wireless" }
        return externalConnected ? "USB-C" : nil
    }

    var adapterPowerTier: Int? { int("AdapterPowerTier", in: adapter) }

    // MARK: - The cable, by its effect

    /// The smallest input current at which a voltage drop means anything. Below it
    /// the phone is barely drawing, the drop is inside the sensor's noise, and
    /// dividing by the current turns that noise into a large resistance.
    static let measurableInputAmps = 0.15

    /// The negotiated voltage minus what is actually measured at the port.
    ///
    /// The subtrahend is a measurement; the minuend is the contract, which is a
    /// ceiling and not a reading (see `adapterCeilingWatts`). For a fixed PD profile
    /// those are the same number — the supply regulates to that voltage — so the
    /// difference is the drop across the cable and the two plugs. This is the quick
    /// answer that `PathResistanceMeter` deliberately refuses to give: no waiting for
    /// the current to move, at the cost of trusting the contract voltage.
    var inputVoltageDropVolts: Double? {
        guard !isWirelessInput, let measured = usbInputVoltage, measured > 0.5,
              let contract = adapterVoltageMillivolts, contract > 0 else { return nil }
        return Double(contract) / 1000 - measured
    }

    /// Path resistance from a single sample: the drop divided by the current through
    /// it. Below `measurableInputAmps` there is no meaningful drop to
    /// divide, and dividing by a near-zero current would produce a large number out
    /// of nothing, so it goes nil instead.
    var inputPathMilliohms: Double? {
        guard partialInputWatts == nil, let drop = inputVoltageDropVolts, drop > 0,
              let current = usbInputCurrent, current >= Self.measurableInputAmps
        else { return nil }
        return drop / current * 1000
    }

    /// What the phone is taking as a share of the current the adapter offered, 0…1.
    var inputCurrentUtilisation: Double? {
        guard !isWirelessInput, partialInputWatts == nil, let current = usbInputCurrent,
              let ceiling = adapterCurrentMilliamps, ceiling > 0 else { return nil }
        return current / (Double(ceiling) / 1000)
    }

    /// True when the port voltage has collapsed well past what PD regulation allows
    /// *and* the phone is taking far less than it was offered.
    ///
    /// Either half alone is ordinary. A small drop is just cable resistance at a
    /// current worth drawing; a low draw on its own is what a full battery, a hot
    /// phone or a charging hold looks like. Together they are the signature of a
    /// charge IC holding the current down to keep the rail up — the phone cannot
    /// take more because taking more would pull the voltage lower still.
    ///
    /// 5% is the PD regulation tolerance for a fixed profile, so anything past it is
    /// the path rather than the supply. Measured on an iPhone 17 through a
    /// non-original cable into a Mac's USB-C port: a 5.00 V contract reading 4.23 V
    /// at the port — 15% down — while the phone drew 0.95 A of the 3 A on offer,
    /// with the battery at 65% and 35 °C. The caller still has to rule out heat and
    /// a nearly-full battery; neither is the snapshot's to know.
    var isInputSagging: Bool {
        guard let drop = inputVoltageDropVolts, drop > 0,
              let contract = adapterVoltageMillivolts, contract > 0,
              let utilisation = inputCurrentUtilisation else { return false }
        return drop / (Double(contract) / 1000) >= 0.05 && utilisation < 0.6
    }

    /// Every profile the adapter advertised in its PD menu.
    var adapterProfiles: [PDProfile] {
        guard let menu = adapter?["UsbHvcMenu"] as? [[String: Any]] else { return [] }
        return menu.compactMap { entry in
            guard let voltage = int("MaxVoltage", in: entry),
                  let current = int("MaxCurrent", in: entry) else { return nil }
            // An iPhone 18 Pro Max listed a seventh profile of 65535 mV × 65535 mA,
            // which the page drew as "65.5 V × 65.53 A, 4295 W". All bits set is a
            // placeholder, not an offer; what it stands for is not known. The entry
            // is still in Raw data's adapter details.
            guard voltage > 0, current > 0, voltage != 0xFFFF, current != 0xFFFF else { return nil }
            return PDProfile(index: int("Index", in: entry) ?? 0,
                             voltageMillivolts: voltage,
                             currentMilliamps: current)
        }
        .sorted { $0.voltageMillivolts < $1.voltageMillivolts }
    }

    /// The profile currently in use, from the adapter's active index.
    var negotiatedProfile: PDProfile? {
        if let active = int("UsbHvcHvcIndex", in: adapter),
           let profile = adapterProfiles.first(where: { $0.index == active }) {
            return profile
        }
        if let voltage = adapterVoltageMillivolts, let current = adapterCurrentMilliamps, voltage > 0 {
            return PDProfile(index: -1, voltageMillivolts: voltage, currentMilliamps: current)
        }
        return nil
    }

    /// How much of the adapter's rating is actually being used, 0…1.
    var adapterUtilisation: Double? {
        guard let inputWatts, let rated = adapterRatedWatts, rated > 0 else { return nil }
        return min(inputWatts / rated, 1)
    }

    // MARK: - Helpers

    private static func externalConnected(registry: [String: Any], powerSource: [String: Any]?) -> Bool {
        if registry["ExternalConnected"] != nil { return bool("ExternalConnected", in: registry) }
        if let state = powerSource?["Power Source State"] as? String { return state == "AC Power" }
        return bool("Raw External Connected", in: powerSource)
    }

    /// IOKit reports some signed 32-bit values as wrapped unsigned numbers
    /// (a −658 mA discharge arrives as 18446744073709550958).
    static func signed(_ number: NSNumber) -> Int {
        let value = number.int64Value
        if value > Int64(Int32.max) || value < Int64(Int32.min) {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    private static func int(_ key: String, in dictionary: [String: Any]?) -> Int? {
        guard let dictionary, let number = dictionary[key] as? NSNumber else { return nil }
        return signed(number)
    }

    private func int(_ key: String, in dictionary: [String: Any]?) -> Int? {
        Self.int(key, in: dictionary)
    }

    private static func bool(_ key: String, in dictionary: [String: Any]?) -> Bool {
        guard let dictionary else { return false }
        if let value = dictionary[key] as? Bool { return value }
        if let number = dictionary[key] as? NSNumber { return number.boolValue }
        return false
    }

    private func bool(_ key: String, in dictionary: [String: Any]?) -> Bool {
        Self.bool(key, in: dictionary)
    }
}
