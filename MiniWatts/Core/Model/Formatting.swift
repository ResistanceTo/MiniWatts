import Foundation

nonisolated enum Formatting {
    static func temperature(_ celsius: Double, in unit: TemperatureDisplayUnit) -> String {
        unit.reading(celsius)
    }

    static func watts(_ value: Double) -> String {
        String(format: abs(value) < 10 ? "%.2f" : "%.1f", value)
    }

    static func volts(_ value: Double) -> String {
        String(format: "%.2f V", value)
    }

    static func amps(_ value: Double) -> String {
        String(format: "%.2f A", value)
    }

    static func wattHours(_ value: Double) -> String {
        String(format: value < 1 ? "%.3f Wh" : "%.2f Wh", value)
    }

    static func milliAmpHours(_ value: Double) -> String {
        String(format: "%.0f mAh", value)
    }

    static func percent(_ value: Double, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f %%", value)
    }

    /// "1h 04m", "4m 12s", "38s"
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, secs) }
        return "\(secs)s"
    }

    static func minutesRemaining(_ minutes: Int) -> String {
        duration(TimeInterval(minutes) * 60)
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second())
    }
}
