import Foundation

/// The scale a temperature is shown in.
///
/// Every reading is measured, stored and compared in Celsius — the colour steps, the
/// sentinels, the session files, the live activity's payload — and converted only at
/// the moment a number is put in front of someone (#25). Raw data is the exception:
/// it shows what the sensors returned, and they return Celsius.
///
/// Compiled into both targets: the widget and the live activity show temperatures too.
nonisolated enum TemperatureDisplayUnit: String, Codable, Hashable, Sendable {
    case celsius
    case fahrenheit

    /// The unit as it follows a reading.
    var symbol: String { self == .celsius ? "°C" : "°F" }

    func value(fromCelsius celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// The number alone: "36.4".
    func number(_ celsius: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", value(fromCelsius: celsius))
    }

    /// The number and its unit: "36.4 °C".
    func reading(_ celsius: Double, decimals: Int = 1) -> String {
        "\(number(celsius, decimals: decimals)) \(symbol)"
    }

    /// The unit the region asks for, including the override in Settings › General ›
    /// Language & Region › Temperature.
    ///
    /// No API names it directly. `Locale.measurementSystem` does not — a US region set
    /// to Celsius still reports `.us` — and `MeasurementFormatter` never converts a
    /// temperature at all. A format style with `usage: .weather` does follow both: it
    /// writes 212 for 100 °C in `en_US` and in `zh_CN@mu=fahrenhe`, and 100 in
    /// `en_US@mu=celsius`. The digits are pinned to POSIX so the check does not depend
    /// on which numerals the locale writes.
    ///
    /// Worked out once per process. A change to the system setting reaches the app the
    /// next time it is launched.
    static let regional: TemperatureDisplayUnit = {
        let digits = FloatingPointFormatStyle<Double>.number
            .precision(.fractionLength(0))
            .locale(Locale(identifier: "en_US_POSIX"))
        let text = Measurement(value: 100, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather, numberFormatStyle: digits)
                .locale(.current))
        return text.contains("212") ? .fahrenheit : .celsius
    }()
}

/// What the user picked in Settings. `automatic` follows the system.
nonisolated enum TemperatureUnitSetting: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case celsius
    case fahrenheit

    var id: Self { self }

    var resolved: TemperatureDisplayUnit {
        switch self {
        case .automatic: .regional
        case .celsius: .celsius
        case .fahrenheit: .fahrenheit
        }
    }

    static let storageKey = "temperatureUnit"

    /// The copy the widget extension reads. The app keeps its own in the standard
    /// defaults and mirrors every change here; a re-signed copy may have no App Group,
    /// in which case this suite is private to each process and the widget simply finds
    /// nothing and follows the system.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshot.groupIdentifier)
    }

    /// The setting as the widget extension sees it.
    static var shared: TemperatureUnitSetting {
        sharedDefaults?.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .automatic
    }
}
