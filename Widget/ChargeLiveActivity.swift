import ActivityKit
import SwiftUI
import WidgetKit

struct ChargeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChargeActivityAttributes.self) { context in
            ChargeActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            // The Dynamic Island is always dark.
            let palette = WidgetPalette(.dark)
            let state = context.state
            let reading = state.reading
            let tint = palette.tint(for: state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(verbatim: reading.percentText)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: reading.symbolName)
                            .foregroundStyle(palette.tint(for: reading))
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(reading.statusTitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.center) {
                    PrimaryMetricView(state: state,
                                      palette: palette,
                                      size: 28,
                                      isStale: context.isStale,
                                      inlineCaption: false)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        SecondaryMetrics(state: state, palette: palette)
                        LevelBar(percent: reading.percent,
                                 tint: palette.tint(for: reading),
                                 track: palette.track,
                                 height: 5)
                        ActivityFootnote(context: context, palette: palette)
                    }
                }
            } compactLeading: {
                Image(systemName: symbol(for: state.selectedMetric))
                    .foregroundStyle(context.isStale ? palette.muted : tint)
            } compactTrailing: {
                CompactMetricValue(state: state)
                    .foregroundStyle(context.isStale ? palette.muted : tint)
            } minimal: {
                Image(systemName: symbol(for: state.selectedMetric))
                    .foregroundStyle(context.isStale ? palette.muted : tint)
            }
            .keylineTint(tint)
        }
    }
}

struct ChargeActivityLockScreenView: View {
    @Environment(\.colorScheme) private var scheme
    let context: ActivityViewContext<ChargeActivityAttributes>

    var body: some View {
        let palette = WidgetPalette(scheme)
        let state = context.state
        let reading = state.reading
        // The Lock Screen gives an activity about 160 pt of height. Everything here has
        // to fit inside it, padding included, or the system clips the top and bottom.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PrimaryMetricView(state: state,
                                  palette: palette,
                                  size: 34,
                                  isStale: context.isStale)
                Spacer(minLength: 8)
                Text(verbatim: reading.percentText)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            SecondaryMetrics(state: state, palette: palette)
                .opacity(context.isStale ? 0.55 : 1)
            LevelBar(percent: reading.percent,
                     tint: palette.tint(for: reading),
                     track: palette.track,
                     height: 6)
            ActivityFootnote(context: context, palette: palette)
        }
        .padding(16)
        .activitySystemActionForegroundColor(palette.tint(for: state))
    }
}

/// The selected reading: symbol, number and a caption saying what it is. On the Lock
/// Screen the caption follows the number on the same line; the island's centre is
/// too narrow for that, so there it goes underneath.
private struct PrimaryMetricView: View {
    let state: ChargeActivityContentState
    let palette: WidgetPalette
    let size: CGFloat
    let isStale: Bool
    var inlineCaption = true

    var body: some View {
        let layout = inlineCaption
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: symbol(for: state.selectedMetric))
                    .font(.system(size: size * 0.5, weight: .bold))
                Text(verbatim: numericValue(for: state.selectedMetric, state: state)
                    .map(oneDecimal) ?? "—")
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(verbatim: unit(for: state.selectedMetric))
                    .font(.system(size: max(11, size * 0.42),
                                  weight: .medium,
                                  design: .rounded))
            }
            .foregroundStyle(isStale ? palette.muted : palette.tint(for: state))
            .lineLimit(1)
            .layoutPriority(1)

            caption
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label(for: state.selectedMetric))
        .accessibilityValue(Text(verbatim: formattedValue(for: state.selectedMetric,
                                                          state: state)))
        .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var caption: some View {
        switch state.selectedMetric {
        case .chargingPower:
            if let source = state.reading.source {
                Text(source.caption)
            }
        case .hottestTemperature:
            if let name = state.hottestSensorName {
                Text(verbatim: name)
                    .fontDesign(.monospaced)
            } else {
                Text(label(for: .hottestTemperature))
            }
        case .socTemperature, .batteryTemperature:
            Text(label(for: state.selectedMetric))
        }
    }
}

/// The three readings that are not the primary one, one line each. A cell of icon,
/// label and value stacked three high did not fit the Lock Screen's height, and
/// repeated the primary reading besides.
private struct SecondaryMetrics: View {
    let state: ChargeActivityContentState
    let palette: WidgetPalette

    var body: some View {
        HStack(spacing: 10) {
            ForEach(LiveActivityMetric.allCases.filter { $0 != state.selectedMetric }) { metric in
                HStack(spacing: 4) {
                    Image(systemName: symbol(for: metric))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(metricTint(metric, state: state, palette: palette))
                    Text(shortLabel(for: metric))
                        .foregroundStyle(palette.muted)
                    Text(verbatim: shortValue(for: metric, state: state))
                        .monospacedDigit()
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label(for: metric))
                .accessibilityValue(Text(verbatim: formattedValue(for: metric, state: state)))
            }
        }
    }
}

private struct CompactMetricValue: View {
    let state: ChargeActivityContentState

    var body: some View {
        Text(verbatim: shortValue(for: state.selectedMetric, state: state))
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}

/// Status and when the charge began — or, once the app has stopped updating, a plain
/// statement that the numbers above are paused. The temperatures are in the row above.
struct ActivityFootnote: View {
    let context: ActivityViewContext<ChargeActivityAttributes>
    let palette: WidgetPalette

    var body: some View {
        HStack(spacing: 6) {
            if context.isStale {
                Label("Paused — open MiniWatts to resume", systemImage: "pause.circle")
                    .foregroundStyle(palette.loss)
            } else {
                Text(context.state.reading.statusTitle)
            }
            Spacer(minLength: 6)
            Text("Since \(Text(context.attributes.startedAt, style: .time))")
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private func numericValue(
    for metric: LiveActivityMetric,
    state: ChargeActivityContentState
) -> Double? {
    switch metric {
    case .chargingPower: state.reading.watts
    case .socTemperature: state.socTemperature
    case .batteryTemperature: state.batteryTemperature
    case .hottestTemperature: state.hottestTemperature
    }
}

private func label(for metric: LiveActivityMetric) -> LocalizedStringKey {
    switch metric {
    case .chargingPower: "Charging power"
    case .socTemperature: "SoC temperature"
    case .batteryTemperature: "Battery temperature"
    case .hottestTemperature: "Hottest component"
    }
}

private func shortLabel(for metric: LiveActivityMetric) -> LocalizedStringKey {
    switch metric {
    case .chargingPower: "Power"
    case .socTemperature: "SoC"
    case .batteryTemperature: "Battery"
    case .hottestTemperature: "Hottest"
    }
}

private func symbol(for metric: LiveActivityMetric) -> String {
    switch metric {
    case .chargingPower: "bolt.fill"
    case .socTemperature: "cpu"
    case .batteryTemperature: "battery.75percent"
    case .hottestTemperature: "thermometer.high"
    }
}

private func metricTint(
    _ metric: LiveActivityMetric,
    state: ChargeActivityContentState,
    palette: WidgetPalette
) -> Color {
    switch metric {
    case .chargingPower: palette.tint(for: state.reading)
    case .socTemperature: palette.temperatureTint(state.socTemperature)
    case .batteryTemperature: palette.temperatureTint(state.batteryTemperature)
    case .hottestTemperature: palette.temperatureTint(state.hottestTemperature)
    }
}

private func unit(for metric: LiveActivityMetric) -> String {
    metric == .chargingPower ? "W" : "°"
}

private func oneDecimal(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

private func shortValue(
    for metric: LiveActivityMetric,
    state: ChargeActivityContentState
) -> String {
    guard let value = numericValue(for: metric, state: state) else { return "—" }
    return oneDecimal(value) + unit(for: metric)
}

private func formattedValue(
    for metric: LiveActivityMetric,
    state: ChargeActivityContentState
) -> String {
    guard numericValue(for: metric, state: state) != nil else {
        return String(localized: "No reading")
    }
    return shortValue(for: metric, state: state)
}

#Preview("Lock Screen", as: .content,
         using: ChargeActivityAttributes(startedAt: .now.addingTimeInterval(-1_800),
                                         startPercent: 41)) {
    ChargeLiveActivity()
} contentStates: {
    ChargeActivityContentState(
        reading: ChargeReading(date: .now,
                               percent: 72,
                               externalConnected: true,
                               isCharging: true,
                               watts: 18.4,
                               source: .charger,
                               batteryTemperature: 33.6),
        socTemperature: 39.2,
        hottestTemperature: 41.3,
        hottestSensorName: "PMU tdie1",
        selectedMetric: .chargingPower
    )
}
