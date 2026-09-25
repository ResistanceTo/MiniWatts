import Foundation

/// The IOKit and HID clients belong to one actor, so a tick and a Shortcuts read
/// cannot use the process's single HID client at the same time. The synchronous
/// system calls and snapshot assembly run off the main actor.
actor SensorProbe {
    /// IOKit returns property-list dictionaries. They are bridged into Swift value
    /// dictionaries here and never mutated after crossing to the UI actor.
    /// TODO: replace the raw [String: Any] diagnostics fields with a typed,
    /// Sendable property-list value, then remove this unchecked conformance.
    struct Result: @unchecked Sendable {
        let snapshot: PowerSnapshot
        let sources: [[String: Any]]
        let serviceCount: Int
    }

    nonisolated let batteryAvailable: Bool
    nonisolated let hidAvailable: Bool
    nonisolated let initialServiceCount: Int

    private let battery: IOKitBattery?
    private let sensors: HIDSensors?

    init() {
        let battery = IOKitBattery()
        let sensors = HIDSensors()
        self.battery = battery
        self.sensors = sensors
        batteryAvailable = battery != nil
        hidAvailable = sensors != nil
        initialServiceCount = sensors?.serviceCount ?? 0
    }

    /// Preserve the old tick order: read the known services first, then update the
    /// service list after a plug event or on the periodic rescan. The new services
    /// enter the following sample.
    func read(lastExternalConnected: Bool?, periodicRescan: Bool) -> Result {
        let (snapshot, sources) = probe()
        if lastExternalConnected != snapshot.externalConnected || periodicRescan {
            sensors?.rescan()
        }
        return Result(snapshot: snapshot,
                      sources: sources,
                      serviceCount: sensors?.serviceCount ?? 0)
    }

    /// Shortcuts needs a fresh reading even while the foreground tick is paused.
    func readNow() -> PowerSnapshot {
        sensors?.rescan()
        return probe().snapshot
    }

    func fullInventory() -> [HIDSensors.ServiceInfo] {
        sensors?.fullInventory() ?? []
    }

    private func probe() -> (snapshot: PowerSnapshot, sources: [[String: Any]]) {
        let registry = battery?.readRegistryProperties() ?? [:]
        let sources = battery?.readPowerSources() ?? []
        let internalBattery = sources.first { ($0["Type"] as? String) == "InternalBattery" } ?? sources.first
        let snapshot = PowerSnapshot(date: .now,
                                     registry: registry,
                                     powerSource: internalBattery,
                                     adapterDetails: battery?.readAdapterDetails(),
                                     sensors: sensors?.read() ?? [],
                                     chargeStatus: battery?.readChargeStatus())
        return (snapshot, sources)
    }
}
