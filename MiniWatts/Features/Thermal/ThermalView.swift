import SwiftUI

struct ThermalView: View {
    @Environment(PowerMonitor.self) private var monitor

    private var snapshot: PowerSnapshot { monitor.snapshot }

    /// One reading per zone, which is what the map draws: the hottest *live* one,
    /// or for the battery the median its readout uses.
    ///
    /// It used to take `readings.first`, which included `PMU tcal` — a calibration
    /// constant pinned at 51.8 °C. That made the SoC blob permanently red and put a
    /// 52° pin on the map while the "Hottest" readout right underneath, which does
    /// exclude it, said 44°. The same screen contradicted itself.
    private var zoneReadings: [(zone: ThermalZone, celsius: Double)] {
        snapshot.temperaturesByZone.compactMap { group in
            group.representative.map { (group.zone, $0) }
        }
    }

    var body: some View {
        PageScaffold("Thermal", glow: glowColor) {
            statePanel
            if snapshot.temperatures.isEmpty {
                Panel("Sensors", systemImage: "sensor") {
                    EmptyNote(text: snapshot.temperatureWarnings.isEmpty
                              ? "No temperature sensors were found. The simulator has none; on a device they appear as soon as the app has read the HID service list."
                              : "Temperature sensors answered, but every value was excluded from derived readings. See the filter details below.",
                              systemImage: "exclamationmark.triangle")
                }
                if !snapshot.temperatureWarnings.isEmpty {
                    temperatureWarningsPanel
                }
            } else {
                mapPanel
                trendPanel
                if !snapshot.temperatureWarnings.isEmpty {
                    temperatureWarningsPanel
                }
                ForEach(snapshot.temperaturesByZone) { group in
                    zonePanel(group)
                }
                modelNote
            }
        }
    }

    /// Which sensors exist, what they are called and how they are scaled is different
    /// on every model and documented nowhere. Readings outside anything physical are
    /// dropped by `HIDSensors`, but a value that is wrong and still looks plausible
    /// cannot be caught that way, so the page says so rather than implying otherwise.
    private var modelNote: some View {
        EmptyNote(text: "Sensor names and scales differ by iPhone model, and this build was checked on an iPhone Air. Impossible readings stay in Raw data but are left out of derived temperatures; a reading that is merely wrong cannot be spotted that way — if something here looks off for your model, it may well be.",
                  systemImage: "exclamationmark.circle")
            .padding(.horizontal, 4)
    }

    private var glowColor: Color {
        snapshot.hottestSensor.map { Color.mwTemperature($0.value) } ?? .mwAccent
    }

    // MARK: System verdict

    private var statePanel: some View {
        Panel("System thermal state", systemImage: "cpu",
              trailing: Text(verbatim: Formatting.duration(Date.now.timeIntervalSince(monitor.thermal.stateSince)))) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: monitor.thermal.state.symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(stateTint)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.thermal.state.title)
                            .mwReadout(size: 24)
                            .foregroundStyle(stateTint)
                        Text(monitor.thermal.state.chargingEffect)
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                severityMeter
                if snapshot.externalConnected, monitor.thermal.state.isThrottling {
                    Text("Charge power below the adapter's rating right now is expected: system thermal pressure may be limiting current.")
                        .font(.caption2)
                        .foregroundStyle(Color.mwDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var stateTint: Color {
        switch monitor.thermal.state {
        case .nominal: return .mwBattery
        case .fair: return .mwLoss
        default: return .mwDanger
        }
    }

    private var severityMeter: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mwMuted.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(colors: [.mwBattery, .mwLoss, .mwDanger],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * monitor.thermal.state.severity)
                }
            }
            .frame(height: 6)
            HStack {
                ForEach([ProcessInfo.ThermalState.nominal, .fair, .serious, .critical],
                        id: \.rawValue) { state in
                    Text(state.title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(state == monitor.thermal.state ? stateTint : Color.mwMuted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: monitor.thermal.state)
    }

    // MARK: Map

    private var mapPanel: some View {
        Panel("Heat map · schematic", systemImage: "iphone.gen3",
              trailing: Text("\(snapshot.temperatures.count) sensors")) {
            VStack(spacing: 12) {
                PhoneHeatMap(readings: zoneReadings)
                    .frame(maxWidth: .infinity)
                TemperatureScale()
                if let hottest = snapshot.hottestSensor {
                    // All three carry the name of the sensor they came from, and the
                    // row is top-aligned. Only "Hottest" used to have that line, which
                    // left it three rows tall next to two-row neighbours — and a
                    // centred `HStack` pushed the shorter columns down, so none of the
                    // captions or numbers lined up. Naming the source on all three is
                    // also the more useful answer: the caption already says what the
                    // reading is, so the raw name adds where it came from rather than
                    // repeating it, and on this screen "which die is hottest right now"
                    // is the whole question.
                    HStack(alignment: .top, spacing: 10) {
                        Metric(caption: "Hottest",
                               value: String(format: "%.1f", hottest.value),
                               unit: "°C",
                               tint: .mwTemperature(hottest.value),
                               footnote: sensorSource(hottest),
                               size: 22)
                        Metric(caption: "Battery",
                               value: snapshot.batteryTemperature.map { String(format: "%.1f", $0) } ?? "—",
                               unit: "°C",
                               tint: snapshot.batteryTemperature.map { Color.mwTemperature($0) } ?? .primary,
                               footnote: batteryTemperatureSource,
                               size: 22)
                        Metric(caption: "Charge IC",
                               value: snapshot.chargerTemperature.map { String(format: "%.1f", $0) } ?? "—",
                               unit: "°C",
                               tint: snapshot.chargerTemperature.map { Color.mwTemperature($0) } ?? .primary,
                               footnote: snapshot.hottestSensor(in: .charger).map(sensorSource),
                               size: 22)
                    }
                }
                Text("The temperatures are measured; the positions are not. iOS reports sensor names and values and no coordinates at all, so each zone is drawn at a fixed spot that follows the usual layout of a recent iPhone — logic board up top behind the cameras, battery through the middle, charge IC by the port. Real layouts differ by model. Read this as a legend for the list below, not as a map of your phone.")
                    .font(.caption2)
                    .foregroundStyle(Color.mwMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var trendPanel: some View {
        Panel("Hottest sensor, last 3 minutes", systemImage: "chart.line.uptrend.xyaxis") {
            LiveTemperatureChart(samples: monitor.live)
        }
    }

    private var temperatureWarningsPanel: some View {
        Panel("Excluded from derived temperatures", systemImage: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(snapshot.temperatureWarnings, id: \.self) { warning in
                    Text(verbatim: warning)
                        .mwMono(size: 11)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Where the battery figure came from. Usually a HID sensor; on the simulator —
    /// and anywhere else the registry is not filtered — it is the registry itself,
    /// which is a different provenance and worth saying so.
    private var batteryTemperatureSource: Text? {
        if snapshot.registryTemperature != nil { return Text(verbatim: "IOPMPowerSource") }
        if snapshot.batteryTemperatureReadings.count > 1 {
            return Text(verbatim: "median of \(snapshot.batteryTemperatureReadings.count) battery sensors")
        }
        return snapshot.hottestSensor(in: .battery).map(sensorSource)
    }

    // MARK: Zones

    /// How one sensor is labelled: the translated name when we recognise it, with
    /// the hardware name kept underneath, and the bare hardware name when we do not.
    private func sensorSource(_ reading: HIDSensors.Reading) -> Text {
        Text(verbatim: "\(reading.name) · #\(reading.index)")
    }

    private func sensorLabels(_ reading: HIDSensors.Reading) -> (title: Text, subtitle: Text?) {
        let source = sensorSource(reading)
        guard let label = SensorCatalog.label(for: reading.name) else {
            return (Text(verbatim: reading.name), source)
        }
        return (Text(label), source)
    }

    private func zonePanel(_ group: ZoneTemperatures) -> some View {
        Panel(group.zone.title, systemImage: group.zone.symbol,
              trailing: group.representative.map { Text(verbatim: String(format: "%.1f °C", $0)) }) {
            VStack(spacing: 10) {
                ForEach(group.readings) { reading in
                    let labels = sensorLabels(reading)
                    BarRow(title: labels.title,
                           detail: String(format: "%.1f °C", reading.value),
                           fraction: (reading.value - 20) / 30,
                           tint: .mwTemperature(reading.value),
                           subtitle: labels.subtitle)
                }
            }
        }
    }
}
