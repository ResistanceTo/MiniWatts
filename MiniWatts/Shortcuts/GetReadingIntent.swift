import AppIntents
import Foundation

/// Hands one live reading to Shortcuts.
///
/// Asked for in issue #9, for a charging automation: when the battery gets hot, switch a
/// smart plug off. So the one thing this must never do is return a number it did not
/// just measure — see `ReadingMetric.value(in:)`.
///
/// It runs in MiniWatts' own process. When the app is not running, iOS launches it in
/// the background to perform the intent: no scene, no `RootView`, and no tick, because
/// the tick only runs in the foreground. Two consequences:
///
/// - `PowerMonitor.snapshot` is useless here — it is as old as the last tick, which may
///   be hours. The intent reads fresh through `readNow()`, which also skips everything
///   the tick does besides reading (sessions, the live activity, the widget).
/// - It must read through `PowerMonitor` at all rather than build its own sensors. A
///   process gets exactly one working HID client and a second one reads NaN, so an
///   intent that created its own would return no temperature while the app was open.
///   `@Dependency` hands it the one `MiniWattsApp.init` registered.
struct GetReadingIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Get Reading" }

    nonisolated static var description: IntentDescription? {
        IntentDescription("Reads one value from the phone's sensors at the moment the action runs. When a sensor does not answer, the action returns no value — never 0, and never an older reading — so a shortcut can tell the difference.")
    }

    @Parameter(title: "Reading", default: .batteryTemperature)
    var metric: ReadingMetric

    @Parameter(title: "Unit", default: .celsius)
    var unit: TemperatureUnit

    nonisolated static var parameterSummary: some ParameterSummary {
        // The unit only means something for the three temperatures, so it is only
        // offered for them.
        When(\.$metric, .oneOf, [.batteryTemperature, .socTemperature, .hottestTemperature]) {
            Summary("Get \(\.$metric) in \(\.$unit)")
        } otherwise: {
            Summary("Get \(\.$metric)")
        }
    }

    @Dependency private var monitor: PowerMonitor

    nonisolated func perform() async throws -> some IntentResult & ReturnsValue<Double?> {
        let monitor = monitor
        let metric = metric
        let unit = unit
        // The snapshot is made and consumed on the main actor, where the sensors live;
        // only the number crosses back.
        let value = await MainActor.run { () -> Double? in
            metric.value(in: monitor.readNow()).map { metric.present($0, in: unit) }
        }
        return .result(value: value)
    }
}

/// What the action can return: the four readings the live activity offers, under the
/// same names and taken from the same snapshot fields — so "SoC temperature" in a
/// shortcut is the number the Dynamic Island shows — plus the charge level, which an
/// automation wants and the live activity has no need to be told.
nonisolated enum ReadingMetric: String, AppEnum {
    case batteryTemperature
    case socTemperature
    case hottestTemperature
    case chargingPower
    case chargeLevel

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Reading" }

    static var caseDisplayRepresentations: [ReadingMetric: DisplayRepresentation] {
        [
            .batteryTemperature: "Battery temperature",
            .socTemperature: "SoC temperature",
            .hottestTemperature: "Hottest component",
            .chargingPower: "Charging power",
            .chargeLevel: "Charge level",
        ]
    }

    var isTemperature: Bool {
        switch self {
        case .batteryTemperature, .socTemperature, .hottestTemperature: true
        case .chargingPower, .chargeLevel: false
        }
    }

    /// The reading in its own unit — °C, W or % — or nil when there is none.
    ///
    /// Nil is load-bearing. The automation this exists for is a cutoff: charger off
    /// above 40 °C. A missing reading handed over as 0, or as the last value seen, makes
    /// that comparison false for as long as the sensor stays silent, and the charger
    /// stays on — it fails open, and silently, which is the one way a safety cutoff
    /// must never fail. Returned as no value, Shortcuts' "does not have any value" can
    /// catch it and switch the plug off anyway. It is also what the rest of the app
    /// already does: a missing reading renders as a dash, never as 0.
    func value(in snapshot: PowerSnapshot) -> Double? {
        switch self {
        case .batteryTemperature:
            snapshot.batteryTemperature
        case .socTemperature:
            snapshot.socTemperature
        case .hottestTemperature:
            snapshot.hottestSensor?.value
        case .chargingPower:
            // Unplugged is not a missing reading but a known zero: nothing is charging.
            // Plugged in and unmeasured is the case that stays nil. The figure itself
            // is `ChargeReading`'s, which is what the live activity and widget show.
            snapshot.externalConnected ? ChargeReading(snapshot).watts : 0
        case .chargeLevel:
            snapshot.percent.map(Double.init)
        }
    }

    /// Converted and rounded for Shortcuts, which prints whatever it is given: a raw
    /// sensor value arrives as 36.203125. One decimal for temperatures, which is what
    /// the app shows, and two for watts.
    func present(_ value: Double, in unit: TemperatureUnit) -> Double {
        switch self {
        case .batteryTemperature, .socTemperature, .hottestTemperature:
            (unit.convert(celsius: value) * 10).rounded() / 10
        case .chargingPower:
            (value * 100).rounded() / 100
        case .chargeLevel:
            value
        }
    }
}

nonisolated enum TemperatureUnit: String, AppEnum {
    case celsius
    case fahrenheit

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Temperature unit" }

    static var caseDisplayRepresentations: [TemperatureUnit: DisplayRepresentation] {
        [
            .celsius: "Celsius",
            .fahrenheit: "Fahrenheit",
        ]
    }

    func convert(celsius: Double) -> Double {
        switch self {
        case .celsius: celsius
        case .fahrenheit: celsius * 9 / 5 + 32
        }
    }
}
