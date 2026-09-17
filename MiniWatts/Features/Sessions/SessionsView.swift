import SwiftUI

extension ChargeSession {
    /// The adapter's own name is hardware and is shown verbatim; the fallback is
    /// copy and is translated. Keeping them apart is why `ChargeSession` exposes
    /// `fallbackTitle` rather than a single pre-rendered `String`.
    var titleText: Text {
        if let adapterName { return Text(verbatim: adapterName) }
        return Text(fallbackTitle)
    }
}

struct SessionsView: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var confirmingDelete = false

    var body: some View {
        PageScaffold("History", glow: .mwBattery, toolbar: AnyView(toolbar)) {
            if let session = monitor.currentSession {
                currentPanel(session)
            }
            if monitor.sessions.isEmpty {
                Panel("No finished charges yet", systemImage: "clock.arrow.circlepath") {
                    EmptyNote(text: "A session starts when you plug in and is saved when you unplug. Energy is integrated from the live sensors, so keep MiniWatts in the foreground for the totals to cover the whole charge.",
                              systemImage: "bolt.badge.clock")
                }
            } else {
                summaryPanel
                ForEach(monitor.sessions) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .confirmationDialog("Delete all saved sessions?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { monitor.deleteAllSessions() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var toolbar: some View {
        Button { confirmingDelete = true } label: { Image(systemName: "trash") }
            .tint(.mwDanger)
            .disabled(monitor.sessions.isEmpty)
    }

    private func currentPanel(_ session: ChargeSession) -> some View {
        Panel("In progress", systemImage: "bolt.fill",
              trailing: Text(verbatim: Formatting.duration(session.duration))) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Delivered",
                           value: monitor.sessionTotals.measuredInputWattHours.map { String(format: "%.2f", $0) } ?? "—",
                           unit: "Wh", tint: .mwAccent, size: 21)
                    Metric(caption: "Stored",
                           value: String(format: "%.2f", monitor.sessionTotals.batteryWattHours),
                           unit: "Wh", tint: .mwBattery, size: 21)
                    Metric(caption: "Gained",
                           value: "+\(session.gainedPercent)",
                           unit: "%", size: 21)
                }
                if !session.samples.isEmpty {
                    SessionPowerChart(samples: session.samples, height: 110)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.mwAccent.opacity(0.4), lineWidth: 1)
        )
    }

    private var summaryPanel: some View {
        let totalDelivered = monitor.sessions.reduce(0) { $0 + $1.totals.inputWattHours }
        let totalStored = monitor.sessions.reduce(0) { $0 + $1.totals.batteryWattHours }
        let efficiencies = monitor.sessions.compactMap(\.totals.efficiencyPercent)
        let averageEfficiency = efficiencies.isEmpty ? nil : efficiencies.reduce(0, +) / Double(efficiencies.count)
        return Panel("All sessions", systemImage: "sum", trailing: Text(verbatim: "\(monitor.sessions.count)")) {
            HStack(alignment: .top, spacing: 10) {
                Metric(caption: "Delivered",
                       value: String(format: "%.1f", totalDelivered),
                       unit: "Wh", tint: .mwAccent, size: 21)
                Metric(caption: "Stored",
                       value: String(format: "%.1f", totalStored),
                       unit: "Wh", tint: .mwBattery, size: 21)
                Metric(caption: "Round trip",
                       value: averageEfficiency.map { String(format: "%.0f", $0) } ?? "—",
                       unit: "%", tint: .mwLoss, size: 21)
            }
        }
    }
}

struct SessionRow: View {
    let session: ChargeSession

    var body: some View {
        Panel {
            VStack(spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        session.titleText
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text("\(Formatting.timestamp(session.start)) · \(Formatting.duration(session.duration))")
                            .mwMono(size: 10)
                            .foregroundStyle(Color.mwMuted)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: String(format: "%.2f Wh", session.totals.measuredInputWattHours
                                              ?? session.totals.batteryWattHours))
                            .mwReadout(size: 16)
                            .foregroundStyle(session.totals.measuredInputWattHours == nil
                                             ? Color.mwBattery : Color.mwAccent)
                        Text("\(session.startPercent)% → \(session.endPercent)%")
                            .mwMono(size: 10)
                            .foregroundStyle(Color.mwMuted)
                    }
                }
                HStack(spacing: 10) {
                    Sparkline(values: session.samples.map(\.inputWatts))
                        .frame(height: 26)
                    if let efficiency = session.totals.efficiencyPercent {
                        Pill(text: Text(verbatim: String(format: "%.0f%%", efficiency)), systemImage: "arrow.triangle.swap", tint: .mwLoss)
                    }
                    if session.throttledFraction > 0.05 {
                        Pill(text: Text("\(String(format: "%.0f%%", session.throttledFraction * 100)) hot"),
                             systemImage: "thermometer.high", tint: .mwDanger)
                    }
                    if session.isWireless {
                        Pill(text: Text("MagSafe"), systemImage: "wave.3.right", tint: .mwWireless)
                    }
                }
            }
        }
    }
}

struct SessionDetailView: View {
    let session: ChargeSession
    @Environment(PowerMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Backdrop(glow: .mwBattery)
            ScrollView {
                VStack(spacing: 14) {
                    energyPanel
                    powerPanel
                    climatePanel
                    cablePanel
                    detailsPanel
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                // Pinned to the container's width so nothing inside can widen the
                // scroll content. A paragraph inside an HStack reports an enormous
                // ideal width — the text unwrapped onto one line — and
                // `.frame(maxWidth: .infinity)` only expands, it does not clamp, so
                // that width propagates up and the page starts scrolling sideways.
                .containerRelativeFrame(.horizontal)
            }
        }
        .navigationTitle(session.titleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    monitor.deleteSession(session)
                    dismiss()
                } label: {
                    Image(systemName: "trash")
                }
                .tint(.mwDanger)
            }
        }
    }

    private var energyPanel: some View {
        Panel("Energy", systemImage: "bolt.circle",
              trailing: Text(verbatim: Formatting.duration(session.duration))) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Delivered",
                           value: session.totals.measuredInputWattHours.map { String(format: "%.2f", $0) } ?? "—",
                           unit: "Wh", tint: .mwAccent, size: 21)
                    Metric(caption: "Stored",
                           value: String(format: "%.2f", session.totals.batteryWattHours),
                           unit: "Wh", tint: .mwBattery, size: 21)
                    Metric(caption: "Lost",
                           value: String(format: "%.2f", session.totals.lossWattHours),
                           unit: "Wh", tint: .mwLoss, size: 21)
                }
                HStack(alignment: .top, spacing: 10) {
                    Metric(caption: "Into cell",
                           value: String(format: "%.0f", session.totals.batteryMilliAmpHours),
                           unit: "mAh", size: 21)
                    Metric(caption: "Round trip",
                           value: session.totals.efficiencyPercent.map { String(format: "%.0f", $0) } ?? "—",
                           unit: "%", tint: .mwLoss, size: 21)
                    Metric(caption: "Gained",
                           value: "+\(session.gainedPercent)",
                           unit: "%", tint: .mwBattery, size: 21)
                }
                if session.totals.integratedSeconds < session.duration * 0.9 {
                    Text("Measured for \(Formatting.duration(session.totals.integratedSeconds)) of \(Formatting.duration(session.duration)) — the app was backgrounded for the rest, and those gaps are excluded rather than estimated.")
                        .font(.caption2)
                        .foregroundStyle(Color.mwMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var powerPanel: some View {
        Panel("Charge curve", systemImage: "chart.xyaxis.line",
              trailing: Text("peak \(String(format: "%.1f", session.peakInputWatts)) W")) {
            if session.samples.isEmpty {
                EmptyNote(text: "This session ended before the first sample was written.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SessionPowerChart(samples: session.samples)
                    HStack(spacing: 14) {
                        LegendDot(color: .mwAccent, text: "From charger")
                        LegendDot(color: .mwBattery, text: "Into battery", dashed: true)
                        if session.throttledFraction > 0 {
                            LegendDot(color: .mwDanger.opacity(0.4), text: "Throttled")
                        }
                    }
                }
            }
        }
    }

    private var climatePanel: some View {
        Panel("Level and temperature", systemImage: "thermometer.variable") {
            if session.samples.isEmpty {
                EmptyNote(text: "No samples recorded.")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SessionClimateChart(samples: session.samples)
                    HStack(spacing: 14) {
                        LegendDot(color: .mwWireless, text: "Charge %")
                        LegendDot(color: .mwLoss, text: "Battery °C")
                    }
                }
            }
        }
    }

    /// Same charger, different cable — the comparison the path resistance exists for.
    ///
    /// A single figure is hard to judge, because it carries the charger's own
    /// regulation and both sets of contacts as well as the cable. Two sessions on the
    /// same charger differ only in what was plugged between them, so the gap between
    /// rows is the part a user can do something about. Hidden entirely until there
    /// are at least two, since one row is not a comparison.
    @ViewBuilder
    private var cablePanel: some View {
        let fits = monitor.pathFitsSharingAdapter(with: session)
        if !fits.isEmpty {
            Panel("Cable comparison", systemImage: "cable.connector.horizontal",
                  trailing: Text("\(fits.count) sessions")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(fits) { fit in
                        let isThis = fit.id == session.id
                        HStack(spacing: 10) {
                            Image(systemName: isThis ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(isThis ? Color.mwAccent : Color.mwMuted.opacity(0.5))
                            Text(verbatim: Formatting.timestamp(fit.start))
                                .mwMono(size: 12, weight: isThis ? .semibold : .regular)
                            Spacer(minLength: 8)
                            Text(verbatim: String(format: "%.0f mΩ", fit.pathMilliohms ?? 0))
                                .mwReadout(size: 14, weight: .semibold)
                                .foregroundStyle(isThis ? Color.mwAccent : Color.mwMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isThis ? Color.mwAccent.opacity(0.12) : Color.mwMuted.opacity(0.06))
                        )
                    }
                    if let note = comparisonNote(fits) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(Color.mwMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Where this session landed among the others on the same charger. Only the two
    /// ends are worth a sentence — being the best says the connection is as good as
    /// this charger has seen, and being worse than the best says by how much.
    private func comparisonNote(_ fits: [ChargeSession]) -> LocalizedStringResource? {
        guard let best = fits.first?.pathMilliohms,
              let mine = fits.first(where: { $0.id == session.id })?.pathMilliohms else { return nil }
        let excess = mine - best
        guard excess >= 25 else {
            return "The lowest path resistance recorded on this charger. Whatever was plugged in here is as good as it has seen."
        }
        let gap = String(format: "%.0f mΩ", excess)
        return "\(gap) above the best this charger has recorded. Same charger, so that difference is the cable and the plugs — not the adapter."
    }

    private var detailsPanel: some View {
        Panel("Details", systemImage: "list.bullet") {
            VStack(spacing: 0) {
                DetailRow(label: "Started", value: Formatting.timestamp(session.start))
                DetailRow(label: "Ended", value: session.end.map(Formatting.timestamp))
                DetailRow(label: "Adapter", value: session.adapterName)
                DetailRow(label: "Rated", value: session.adapterRatedWatts.map { String(format: "%.0f W", $0) })
                DetailRow(label: "Peak from charger", value: String(format: "%.2f W", session.peakInputWatts))
                DetailRow(label: "Peak into cell", value: String(format: "%.2f W", session.peakBatteryWatts))
                DetailRow(label: "Peak cell temp", value: session.peakBatteryTemperature.map { String(format: "%.1f °C", $0) })
                DetailRow(label: "Average in", value: session.totals.averageInputWatts.map { String(format: "%.2f W", $0) })
                DetailRow(label: "Path resistance",
                          value: session.pathMilliohms.map { String(format: "%.0f mΩ", $0) })
                DetailRow(label: "Throttled", value: Formatting.duration(session.throttledSeconds))
                DetailRow(label: "Samples", value: "\(session.samples.count)")
                DetailRow(label: "Transport", value: DetailRow.transportName(wireless: session.isWireless))
            }
        }
    }
}
