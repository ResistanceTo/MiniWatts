import SwiftUI
import UIKit

/// Everything the probes returned, unedited. This is the page that made the rest
/// of the app possible: sensor names differ between iPhone models, so the way to
/// support a new one is to read the inventory here and extend `SensorCatalog`.
struct DebugView: View {
    @Environment(PowerMonitor.self) private var monitor
    @State private var inventory: [HIDSensors.ServiceInfo] = []
    @State private var accessory: AccessoryProbe.Report?
    @State private var copied = false
    @State private var query = ""

    /// Case-insensitive substring match against a row's name and its value. The
    /// lists here run to seventy-odd sensors and dictionaries of fifty keys, which
    /// is not something to read top to bottom looking for one rail.
    private func matches(_ parts: String...) -> Bool {
        guard !query.isEmpty else { return true }
        return parts.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        ZStack {
            Backdrop(glow: .mwMuted, glowIntensity: 0.5)
            ScrollView {
                VStack(spacing: 14) {
                    diagnosticsPanel
                    sensorsPanel
                    inventoryPanel
                    accessoryPanel
                    dictionaryPanel("IOPMPowerSource", systemImage: "cpu", dictionary: monitor.snapshot.registry)
                    dictionaryPanel("powerd power source", systemImage: "battery.100", dictionary: monitor.snapshot.powerSource)
                    dictionaryPanel("Adapter details", systemImage: "powerplug", dictionary: monitor.snapshot.adapterDetails)
                    dictionaryPanel("Charge status", systemImage: "pause.circle", dictionary: monitor.snapshot.chargeStatus)
                    powerSourcesPanel
                    batteryCenterPanel
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
        .navigationTitle("Raw data")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Filter sensors and keys"))
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = fullDump()
                    copied = true
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .tint(.mwAccent)
            }
        }
    }

    private var diagnosticsPanel: some View {
        Panel("Probes", systemImage: "stethoscope") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(monitor.diagnostics, id: \.self) { line in
                    Text(line).mwMono(size: 11).foregroundStyle(Color.mwMuted)
                }
            }
        }
    }

    private var sensorsPanel: some View {
        Panel("Live sensors", systemImage: "sensor",
              trailing: Text(verbatim: "\(monitor.snapshot.sensors.count)")) {
            if monitor.snapshot.sensors.isEmpty {
                EmptyNote(text: "No sensors returned a finite value.")
            } else {
                VStack(spacing: 0) {
                    ForEach(monitor.snapshot.sensors
                        .filter { matches($0.name, $0.formatted) }
                        .sorted { $0.name < $1.name }) { reading in
                        DetailRow(rawLabel: reading.name, value: reading.formatted)
                    }
                }
            }
        }
    }

    private var inventoryPanel: some View {
        Panel("HID service inventory", systemImage: "list.number",
              trailing: inventory.isEmpty ? nil : Text(verbatim: "\(inventory.count)")) {
            VStack(alignment: .leading, spacing: 10) {
                if inventory.isEmpty {
                    Button {
                        Task { inventory = await monitor.hidInventory() }
                    } label: {
                        Label("Enumerate every HID service", systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .tint(.mwAccent)
                    EmptyNote(text: "Lists every service the HID event system exposes, matched or not, with its usage page and usage. This is how the power and temperature sensors were found in the first place.")
                } else {
                    ForEach(inventory.filter { matches($0.name, String(format: "0x%04x", $0.usagePage)) }) { service in
                        HStack {
                            Text(service.name).mwMono(size: 11).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(String(format: "0x%04x / %d", service.usagePage, service.usage))
                                .mwMono(size: 10)
                                .foregroundStyle(Color.mwMuted)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    /// The accessory-manager scan. This is the panel that decides whether MiniWatts
    /// can ever say anything about the charger's own identity or the cable, so the
    /// rows that came back empty are shown as well as the ones that answered: a key
    /// that is absent everywhere is the finding.
    private var accessoryPanel: some View {
        Panel("Accessory manager", systemImage: "cable.connector",
              trailing: accessory.map { Text(verbatim: $0.headline) }) {
            VStack(alignment: .leading, spacing: 10) {
                if let accessory {
                    Text(verbatim: accessory.library).mwMono(size: 11).foregroundStyle(Color.mwMuted)
                    ForEach(accessory.classes) { reading in
                        accessoryClass(reading)
                    }
                } else {
                    Button {
                        accessory = monitor.accessoryProbe()
                    } label: {
                        Label("Probe the accessory registry", systemImage: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .tint(.mwAccent)
                    EmptyNote(text: "Reads the IOAccessoryManager registry family — the charger's connect type, current limit, manufacturer, model and serial — plus the USB-PD nodes macOS publishes for the cable. Registry reads only: nothing is opened and nothing is written.")
                }
            }
        }
    }

    @ViewBuilder
    private func accessoryClass(_ reading: AccessoryProbe.ClassReading) -> some View {
        let status = reading.matchError ?? (reading.services.isEmpty ? "no service" : "\(reading.services.count)")
        if matches(reading.className, status) || reading.services.contains(where: { service in
            service.readableKeys.contains { matches($0.key, $0.value ?? "") }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(verbatim: reading.className).mwMono(size: 11).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: status).mwMono(size: 10).foregroundStyle(Color.mwMuted)
                }
                .padding(.vertical, 2)
                ForEach(reading.services) { service in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "\(service.className) · \(service.name)")
                            .mwMono(size: 10)
                            .foregroundStyle(Color.mwMuted)
                            .padding(.leading, 10)
                        // The targeted reads first: these are the keys the question
                        // is actually about. Then whatever the bulk fetch returned
                        // that they did not already cover.
                        ForEach(service.readableKeys.filter { matches($0.key, $0.value ?? "") }) { key in
                            DetailRow(rawLabel: key.key, value: key.value)
                        }
                        let extra = service.bulk.keys.sorted()
                            .filter { key in !service.readableKeys.contains { $0.key == key } }
                            .filter { matches($0, service.bulk[$0] ?? "") }
                        ForEach(extra, id: \.self) { key in
                            DetailRow(rawLabel: key, value: service.bulk[key])
                        }
                        if let bulkError = service.bulkError {
                            DetailRow(rawLabel: "bulk fetch", value: bulkError)
                        }
                        if service.readableKeys.isEmpty, service.bulk.isEmpty {
                            EmptyNote(text: "Matched, but every key came back empty.")
                        }
                    }
                }
            }
        }
    }

    private func dictionaryPanel(_ title: LocalizedStringResource, systemImage: String, dictionary: [String: Any]?) -> some View {
        Panel(title, systemImage: systemImage, trailing: dictionary.map { Text("\($0.count) keys") }) {
            if let dictionary, !dictionary.isEmpty {
                VStack(spacing: 0) {
                    ForEach(dictionary.keys.sorted()
                        .filter { matches($0, String(describing: dictionary[$0] ?? "")) }, id: \.self) { key in
                        DetailRow(rawLabel: key, value: String(describing: dictionary[key] ?? ""))
                    }
                }
            } else {
                EmptyNote(text: "Empty. On a device the sandbox filters most of this away; on the simulator it is the Mac's data.")
            }
        }
    }

    /// Every power source powerd will admit to, which is where an accessory would
    /// have to appear for any of this to be reachable without private entitlements.
    private var powerSourcesPanel: some View {
        Panel("powerd power sources", systemImage: "list.bullet.rectangle",
              trailing: Text(verbatim: "\(monitor.powerSources.count)")) {
            if monitor.powerSources.isEmpty {
                EmptyNote(text: "powerd reported no power sources.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(monitor.powerSources.enumerated()), id: \.offset) { index, source in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: (source["Name"] as? String)
                                 ?? (source["Type"] as? String)
                                 ?? "source \(index)").mwCaption()
                            ForEach(source.keys.sorted()
                                .filter { matches($0, String(describing: source[$0] ?? "")) }, id: \.self) { key in
                                DetailRow(rawLabel: key, value: String(describing: source[key] ?? ""))
                            }
                        }
                    }
                }
            }
        }
    }

    private var batteryCenterPanel: some View {
        Panel("BatteryCenter", systemImage: "square.stack.3d.up",
              trailing: Text("\(monitor.devices.count) devices")) {
            if monitor.devices.isEmpty {
                EmptyNote(text: monitor.batteryCenterDiagnostic ?? "No devices reported.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(monitor.devices) { device in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.name).mwCaption()
                            ForEach(device.raw.keys.sorted()
                                .filter { matches($0, device.raw[$0] ?? "") }, id: \.self) { key in
                                DetailRow(rawLabel: key, value: device.raw[key])
                            }
                        }
                    }
                }
            }
        }
    }

    private func fullDump() -> String {
        var lines: [String] = ["MiniWatts raw dump — \(Formatting.timestamp(.now))"]
        lines.append(contentsOf: monitor.diagnostics)
        lines.append("\n# Sensors")
        lines.append(contentsOf: monitor.snapshot.sensors.sorted { $0.name < $1.name }.map { "\($0.name) = \($0.formatted)" })
        if !inventory.isEmpty {
            lines.append("\n# HID inventory")
            lines.append(contentsOf: inventory.map { String(format: "%@  0x%04x / %d", $0.name, $0.usagePage, $0.usage) })
        }
        if accessory == nil {
            // A silently absent section reads like a probe that found nothing, which
            // is the opposite of what it means. Say so instead: the scan is behind a
            // button and a dump taken before it was pressed carries no accessory data.
            lines.append("\n# Accessory manager — not run (press Probe the accessory registry, then copy again)")
        }
        if let accessory {
            // Deliberately exhaustive, unlike the panel: a key that returned nothing
            // is the result being reported, so the dump has to carry the misses too
            // or it cannot be read as evidence later.
            lines.append("\n# Accessory manager — \(accessory.headline)")
            lines.append(accessory.library)
            lines.append(contentsOf: accessory.symbols.keys.sorted().map {
                "dlsym \($0) = \(accessory.symbols[$0] == true ? "present" : "missing")"
            })
            for reading in accessory.classes {
                let status = reading.matchError ?? (reading.services.isEmpty ? "no service" : "\(reading.services.count) services")
                lines.append("\n## \(reading.className) — \(status)")
                for service in reading.services {
                    lines.append("### [\(service.index)] \(service.className) · \(service.name)")
                    if let bulkError = service.bulkError { lines.append("bulk fetch = \(bulkError)") }
                    lines.append(contentsOf: service.bulk.keys.sorted().map { "bulk \($0) = \(service.bulk[$0]!)" })
                    lines.append(contentsOf: service.keys.map { "key \($0.key) = \($0.value ?? "—")" })
                }
            }
        }
        func dump(_ title: String, _ dictionary: [String: Any]?) {
            guard let dictionary, !dictionary.isEmpty else { return }
            lines.append("\n# \(title)")
            // A loop, not `.map { … dictionary[$0] … }`. `[String: Any]` is not
            // Sendable, and Xcode 26.6's compiler rejects capturing it in that closure
            // ("sending 'dictionary' risks causing data races") where Xcode 27's
            // accepts it. It went unnoticed while this page was `#if DEBUG`: CI builds
            // Release, so the release toolchain had never compiled this file.
            for key in dictionary.keys.sorted() {
                lines.append("\(key) = \(String(describing: dictionary[key]!))")
            }
        }
        dump("IOPMPowerSource", monitor.snapshot.registry)
        dump("powerd power source", monitor.snapshot.powerSource)
        dump("Adapter details", monitor.snapshot.adapterDetails)
        dump("Charge status", monitor.snapshot.chargeStatus)
        for device in monitor.devices {
            lines.append("\n# BatteryCenter: \(device.name)")
            lines.append(contentsOf: device.raw.keys.sorted().map { "\($0) = \(device.raw[$0] ?? "")" })
        }
        return lines.joined(separator: "\n")
    }
}
