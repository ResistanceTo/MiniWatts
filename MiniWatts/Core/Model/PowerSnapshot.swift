import Foundation

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
    /// The hottest *live* reading, which is what the zone is represented by
    /// wherever one number has to stand for it. Nil when the zone has nothing but
    /// calibration constants in it.
    let hottest: Double?

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
nonisolated struct PowerSnapshot {
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
    let inputWatts: Double?
    /// Power crossing into (+) or out of (−) the battery, in watts.
    let batteryWatts: Double?

    private let zoneHottest: [ThermalZone: HIDSensors.Reading]

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

        // Names repeat — an iPhone 17 reports four separate sensors all called
        // "gas gauge battery" — so first wins, which is what a linear `first(where:)`
        // over the service list used to do.
        var byName: [String: HIDSensors.Reading] = [:]
        var temperatures: [HIDSensors.Reading] = []
        for reading in sensors {
            if byName[reading.name] == nil { byName[reading.name] = reading }
            // A reading on the temperature page that no phone could produce is not a
            // temperature — it is a sentinel or a raw counter, and it used to be drawn
            // on the heat map as if it were a reading. It stays in `sensors`, which
            // Raw data shows unedited, and out of everything that treats a number as
            // degrees.
            if reading.kind == .temperature, HIDSensors.plausibleCelsius.contains(reading.value) {
                temperatures.append(reading)
            }
        }
        self.temperatures = temperatures

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

        if let voltage = usbVoltage, let current = usbCurrent, voltage > 0.5 {
            inputWatts = voltage * current
        } else if let voltage = coilVoltage, let current = coilCurrent, voltage > 0.5 {
            inputWatts = voltage * current
        } else {
            inputWatts = nil
        }

        let registryVoltage = Self.int("Voltage", in: registry).map { Double($0) / 1000 }
        let registryCurrent = Self.int("InstantAmperage", in: registry).map { Double($0) / 1000 }
        if let voltage = registryVoltage, let current = registryCurrent {
            batteryWatts = voltage * current
        } else if let current = cellCurrent, let voltage = cellVoltage {
            batteryWatts = current * voltage
        } else {
            batteryWatts = nil
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
                    hottest: hottestByZone[zone]?.value
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
        if registry["ExternalConnected"] != nil { return bool("ExternalConnected", in: registry) }
        if let state = powerSource?["Power Source State"] as? String { return state == "AC Power" }
        return bool("Raw External Connected", in: powerSource)
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

    /// powerd's verdict when we can get it; otherwise the shape a hold takes from
    /// outside: plugged in, below full, not charging, and no current into the battery.
    /// That is what Optimized Battery Charging and a charge limit look like.
    var isChargingOnHold: Bool {
        if let text = chargeStatusText { return text == "Charging On Hold" }
        guard externalConnected, !isCharging, !fullyCharged,
              let level = percent, level >= 50, level < 100 else { return false }
        if let current = batteryRailCurrent { return abs(current) < 0.3 }
        return true
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

    var batteryTemperature: Double? { registryTemperature ?? temperature(in: .battery) }
    var chargerTemperature: Double? { temperature(in: .charger) }
    var socTemperature: Double? { temperature(in: .soc) }

    /// True when power is arriving over the coil rather than the port.
    var isWirelessInput: Bool { (wirelessInputVoltage ?? 0) > 1 && (usbInputVoltage ?? 0) < 1 }

    // MARK: - Merged power

    var batteryVoltage: Double? { registryVoltage ?? batteryRailVoltage }
    var batteryCurrent: Double? { registryCurrent ?? batteryRailCurrent }

    /// Share of the adapter's power that actually reaches the cell. The remainder
    /// leaves as heat in the cable, the charge IC and the coil.
    var conversionEfficiency: Double? {
        guard let inputWatts, inputWatts > 0.5, let batteryWatts, batteryWatts > 0 else { return nil }
        return min(batteryWatts / inputWatts, 1) * 100
    }

    var conversionLossWatts: Double? {
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
        guard let drop = inputVoltageDropVolts, drop > 0,
              let current = usbInputCurrent, current >= Self.measurableInputAmps
        else { return nil }
        return drop / current * 1000
    }

    /// What the phone is taking as a share of the current the adapter offered, 0…1.
    var inputCurrentUtilisation: Double? {
        guard !isWirelessInput, let current = usbInputCurrent,
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

    private func bool(_ key: String, in dictionary: [String: Any]?) -> Bool {
        guard let dictionary else { return false }
        if let value = dictionary[key] as? Bool { return value }
        if let number = dictionary[key] as? NSNumber { return number.boolValue }
        return false
    }
}
