import SwiftUI

struct DevicesView: View {
    @Environment(PowerMonitor.self) private var monitor

    /// One card per accessory. BatteryCenter hands back a separate `BCBatteryDevice`
    /// for each piece of a multi-part accessory — left earbud, right earbud, case —
    /// so entries sharing a `groupName` are gathered back into one card here.
    private var groups: [DeviceGroup] {
        let accessories = monitor.devices.filter { !$0.isInternal }
        return Dictionary(grouping: accessories) { $0.groupName ?? $0.id }
            .map { DeviceGroup(id: $0.key,
                               entries: $0.value.sorted { $0.parts < $1.parts }) }
            .sorted { $0.entries[0].name < $1.entries[0].name }
    }

    var body: some View {
        PageScaffold("Devices", glow: .mwWireless) {
            thisPhonePanel
            if groups.isEmpty {
                accessoriesPlaceholder
            } else {
                ForEach(groups) { group in
                    DeviceCard(group: group)
                }
            }
        }
    }

    private var thisPhonePanel: some View {
        let snapshot = monitor.snapshot
        // An iPad was shown with an iPhone's glyph (#13).
        let isTablet = DeviceForm.current == .tablet
        return Panel("This device", systemImage: isTablet ? "ipad" : "iphone",
                     trailing: Text(verbatim: monitor.deviceModelIdentifier)) {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: isTablet ? "ipad" : "iphone.gen3")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.mwAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.statusText)
                            .font(.system(size: 14, weight: .semibold))
                        Text(snapshot.externalConnected
                             ? "\(snapshot.inputWatts.map(Formatting.watts) ?? "—") W in"
                             : "on battery")
                            .mwMono(size: 11)
                            .foregroundStyle(Color.mwMuted)
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(snapshot.percent.map(String.init) ?? "—")
                            .mwReadout(size: 30)
                        Text(verbatim: "%")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.mwMuted)
                    }
                }
                if let percent = snapshot.percent {
                    ChargeBar(percent: Double(percent),
                              isCharging: snapshot.isCharging,
                              tint: percent <= 20 ? .mwDanger : .mwBattery)
                }
            }
        }
    }

    /// The accessory list is real code and renders whenever BatteryCenter answers,
    /// but on current iOS it never does from a sandboxed app: the framework loads,
    /// the controller is built, and `connectedDevices` comes back empty while the
    /// system's own Batteries widget shows the same devices.
    ///
    /// So the section says that, rather than promising the feature is on its way. It
    /// used to read "Coming later" under an hourglass, which is a promise this project
    /// is not in a position to keep: what is in the way is a denied XPC call, not an
    /// unwritten screen. `EmptyNote` is the component for a probe that legitimately has
    /// nothing to report, and this is one.
    private var accessoriesPlaceholder: some View {
        Panel("Accessories", systemImage: "airpods") {
            EmptyNote(text: monitor.batteryCenterStatus
                      ?? "Accessory battery levels aren't available on this version of iOS.")
        }
    }

}

/// One accessory, with every piece BatteryCenter reported for it.
struct DeviceGroup: Identifiable {
    let id: String
    let entries: [ExternalBatteryDevice]

    var lead: ExternalBatteryDevice { entries[0] }
    /// A pair of AirPods has a level per piece and none for the whole.
    var isMultipart: Bool { entries.count > 1 || lead.parts != 0 }
    var isCharging: Bool { entries.contains(where: \.isCharging) }
    var isLowBattery: Bool { entries.contains(where: \.isLowBattery) }
    /// The level to headline with: the lowest piece, which is the one that will
    /// run out first and the only one worth a single number.
    var percent: Int? { entries.compactMap(\.percent).min() }
}

struct DeviceCard: View {
    let group: DeviceGroup

    private var device: ExternalBatteryDevice { group.lead }

    var body: some View {
        Panel {
            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Color.mwWireless)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if let transport = device.transport {
                                Text(transport.title).mwMono(size: 10).foregroundStyle(Color.mwMuted)
                            }
                            if let vendor = device.vendor {
                                Text(verbatim: vendor).mwMono(size: 10).foregroundStyle(Color.mwMuted)
                            }
                            if group.isCharging {
                                Label("charging", systemImage: "bolt.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.mwBattery)
                            }
                            if group.isLowBattery {
                                Label("low", systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.mwDanger)
                            }
                        }
                    }
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        if group.lead.isApproximate, group.percent != nil {
                            Text(verbatim: "~")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.mwMuted)
                        }
                        Text(group.percent.map(String.init) ?? "—")
                            .mwReadout(size: 26)
                        Text(verbatim: "%")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.mwMuted)
                    }
                }

                if group.isMultipart {
                    HStack(spacing: 10) {
                        ForEach(group.entries) { entry in
                            PartGauge(entry: entry)
                        }
                    }
                } else if let percent = group.percent {
                    ChargeBar(percent: Double(percent),
                              isCharging: group.isCharging,
                              tint: tint(percent))
                }
            }
        }
    }

    private func tint(_ percent: Int) -> Color {
        percent <= 20 ? .mwDanger : (group.isCharging ? .mwBattery : .mwWireless)
    }
}

struct PartGauge: View {
    let entry: ExternalBatteryDevice

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                Group {
                    if let partTitle = entry.partTitle { Text(partTitle) } else { Text(verbatim: entry.name) }
                }
                .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.mwMuted)
                    .lineLimit(1)
                if entry.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.mwBattery)
                }
            }
            Text(entry.percent.map { "\($0)%" } ?? "—")
                .mwReadout(size: 15)
            ChargeBar(percent: Double(entry.percent ?? 0),
                      isCharging: entry.isCharging,
                      tint: (entry.percent ?? 0) <= 20 ? .mwDanger : .mwBattery,
                      height: 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.mwMuted.opacity(0.07))
        )
    }
}

struct ChargeBar: View {
    let percent: Double
    var isCharging: Bool = false
    var tint: Color = .mwBattery
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.mwMuted.opacity(0.15))
                Capsule()
                    .fill(Theme.gradient(tint))
                    .frame(width: max(height, geometry.size.width * min(max(percent / 100, 0), 1)))
                    .shadow(color: isCharging ? tint.opacity(0.5) : .clear, radius: 5)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: percent)
    }
}
