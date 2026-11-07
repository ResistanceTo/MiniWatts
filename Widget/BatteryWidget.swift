import SwiftUI
import WidgetKit

// MARK: - Entry

struct BatteryEntry: TimelineEntry {
    let date: Date
    let reading: ChargeReading?
    /// True when the extension read the sensors itself for this entry; false when the
    /// reading is the app's last write, from the App Group container.
    let isLive: Bool
    let lastSession: WidgetSnapshot.Session?

    static func current() -> BatteryEntry {
        let stored = WidgetSnapshot.load()
        if let live = ReadingProbe.read() {
            return BatteryEntry(date: .now, reading: live, isLive: true, lastSession: stored?.lastSession)
        }
        return BatteryEntry(date: .now, reading: stored?.reading, isLive: false, lastSession: stored?.lastSession)
    }

    static let preview = BatteryEntry(
        date: .now,
        reading: ChargeReading(date: .now, percent: 72, externalConnected: true, isCharging: true,
                               watts: 18.4, source: .charger, batteryTemperature: 33.6),
        isLive: true,
        lastSession: WidgetSnapshot.Session(start: .now.addingTimeInterval(-9_000),
                                            end: .now.addingTimeInterval(-3_600),
                                            startPercent: 31, endPercent: 88,
                                            storedWattHours: 7.9, deliveredWattHours: 10.2,
                                            efficiencyPercent: 77, peakWatts: 21.3, isWireless: false))
}

// MARK: - Provider

struct BatteryProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry { .preview }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(context.isPreview ? .preview : .current())
    }

    /// One entry per refresh. Charge power is not something to extrapolate into the
    /// future, so there is nothing to schedule ahead — only when to ask again: sooner
    /// while plugged in, when there is something moving to show. iOS treats the date
    /// as a request and fits it to the widget's budget.
    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        let entry = BatteryEntry.current()
        let pluggedIn = entry.reading?.externalConnected == true
        let next = Date.now.addingTimeInterval(pluggedIn ? 5 * 60 : 30 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Widget

struct BatteryWidget: Widget {
    let kind = "org.zhaohe.MiniWatts.battery"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteryProvider()) { entry in
            BatteryWidgetView(entry: entry)
        }
        .configurationDisplayName("Charge power")
        .description("Charge power and level, read from the phone's own sensors.")
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct BatteryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: BatteryEntry

    var body: some View {
        let palette = WidgetPalette(scheme)
        content(palette)
            .containerBackground(for: .widget) {
                switch family {
                case .systemSmall, .systemMedium:
                    LinearGradient(colors: [palette.canvasTop, palette.canvas],
                                   startPoint: .top, endPoint: .bottom)
                default:
                    Color.clear
                }
            }
    }

    @ViewBuilder
    private func content(_ palette: WidgetPalette) -> some View {
        switch family {
        case .systemMedium: MediumBatteryView(entry: entry, palette: palette)
        case .accessoryCircular: CircularBatteryView(entry: entry)
        case .accessoryRectangular: RectangularBatteryView(entry: entry)
        case .accessoryInline: InlineBatteryView(entry: entry)
        default: SmallBatteryView(entry: entry, palette: palette)
        }
    }
}

// MARK: - Home Screen

struct SmallBatteryView: View {
    let entry: BatteryEntry
    let palette: WidgetPalette

    var body: some View {
        if let reading = entry.reading {
            let tint = palette.tint(for: reading)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: reading.symbolName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                    Text(reading.statusTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Spacer(minLength: 4)
                if let watts = reading.watts, let source = reading.source {
                    WattsReadout(watts: watts, tint: tint, palette: palette, size: 34)
                    Text(source.caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                } else {
                    Text(verbatim: reading.percentText)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                }
                Spacer(minLength: 6)
                LevelBar(percent: reading.percent, tint: tint, track: palette.track)
                HStack(spacing: 4) {
                    if reading.watts != nil {
                        Text(verbatim: reading.percentText)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    FreshnessLabel(entry: entry)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.top, 5)
            }
        } else {
            NoReadingView(palette: palette)
        }
    }
}

struct MediumBatteryView: View {
    let entry: BatteryEntry
    let palette: WidgetPalette

    var body: some View {
        if let reading = entry.reading {
            let tint = palette.tint(for: reading)
            HStack(spacing: 14) {
                ZStack {
                    LevelRing(percent: reading.percent, tint: tint, track: palette.track)
                    VStack(spacing: 0) {
                        if let watts = reading.watts {
                            WattsReadout(watts: watts, tint: tint, palette: palette, size: 26)
                            Text(verbatim: reading.percentText)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(palette.muted)
                        } else {
                            Text(verbatim: reading.percentText)
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(tint)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: reading.symbolName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(tint)
                        Text(reading.statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    if let source = reading.source, reading.watts != nil {
                        Text(source.caption)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(palette.muted)
                    }
                    if let temperature = reading.batteryTemperature {
                        HStack(spacing: 4) {
                            Text("Battery")
                            Text(verbatim: Formatting.temperature(temperature,
                                                                  in: TemperatureUnitSetting.shared.resolved))
                                .monospacedDigit()
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.muted)
                    }
                    Spacer(minLength: 0)
                    if let session = entry.lastSession {
                        LastChargeSummary(session: session, palette: palette)
                    }
                    FreshnessLabel(entry: entry)
                        .font(.system(size: 10))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NoReadingView(palette: palette)
        }
    }
}

struct LastChargeSummary: View {
    let session: WidgetSnapshot.Session
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Last charge")
                .font(.system(size: 9, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(palette.muted)
            HStack(spacing: 6) {
                Text(verbatim: "+\(max(session.endPercent - session.startPercent, 0))%")
                Text(verbatim: Formatting.wattHours(session.storedWattHours))
                if let efficiency = session.efficiencyPercent {
                    Text(verbatim: String(format: "%.0f%%", efficiency))
                        .foregroundStyle(palette.loss)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }
}

struct WattsReadout: View {
    let watts: Double
    let tint: Color
    let palette: WidgetPalette
    let size: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: Formatting.watts(watts))
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: "W")
                .font(.system(size: size * 0.44, weight: .medium, design: .rounded))
                .foregroundStyle(palette.muted)
        }
    }
}

/// Says how old the numbers are, and where they came from. A widget can sit on the
/// Home Screen for an hour between refreshes; a power reading with no time on it
/// would read as current when it is not.
struct FreshnessLabel: View {
    let entry: BatteryEntry

    var body: some View {
        if let reading = entry.reading {
            if entry.isLive {
                Text("Updated \(Text(reading.date, style: .time))")
            } else {
                Text("From app \(Text(reading.date, style: .time))")
            }
        }
    }
}

struct NoReadingView: View {
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bolt.slash")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(palette.muted)
            Text("No reading")
                .font(.system(size: 14, weight: .semibold))
            Text("Open MiniWatts once, then check back.")
                .font(.system(size: 11))
                .foregroundStyle(palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Lock Screen

struct CircularBatteryView: View {
    let entry: BatteryEntry

    var body: some View {
        let reading = entry.reading
        Gauge(value: Double(reading?.percent ?? 0), in: 0...100) {
            Image(systemName: reading?.symbolName ?? "battery.0percent")
        } currentValueLabel: {
            // While plugged in the centre shows the power going in and the ring shows
            // the level; on battery the centre is the level itself.
            if let reading, reading.externalConnected, let watts = reading.watts {
                Text(verbatim: "\(Int(watts.rounded()))W")
            } else {
                Text(verbatim: reading?.percent.map(String.init) ?? "—")
            }
        }
        .gaugeStyle(.accessoryCircular)
        .widgetAccentable()
    }
}

struct RectangularBatteryView: View {
    let entry: BatteryEntry

    var body: some View {
        if let reading = entry.reading {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: reading.symbolName)
                    Text(reading.statusTitle)
                        .lineLimit(1)
                }
                .font(.headline)
                .widgetAccentable()
                if let watts = reading.watts, let source = reading.source {
                    HStack(spacing: 4) {
                        Text(verbatim: "\(Formatting.watts(watts)) W")
                            .monospacedDigit()
                        Text(source.caption)
                    }
                    .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(verbatim: reading.percentText)
                        .monospacedDigit()
                    FreshnessLabel(entry: entry)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("No reading")
        }
    }
}

struct InlineBatteryView: View {
    let entry: BatteryEntry

    var body: some View {
        if let reading = entry.reading {
            if let watts = reading.watts {
                Label {
                    Text(verbatim: "\(Formatting.watts(watts)) W · \(reading.percentText)")
                } icon: {
                    Image(systemName: reading.symbolName)
                }
            } else {
                Label {
                    Text(verbatim: reading.percentText)
                } icon: {
                    Image(systemName: reading.symbolName)
                }
            }
        } else {
            Text("No reading")
        }
    }
}

#Preview(as: .systemSmall) {
    BatteryWidget()
} timeline: {
    BatteryEntry.preview
}

#Preview(as: .systemMedium) {
    BatteryWidget()
} timeline: {
    BatteryEntry.preview
}
