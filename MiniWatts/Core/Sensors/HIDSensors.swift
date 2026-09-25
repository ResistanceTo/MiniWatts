import Foundation

/// Reads Apple's vendor power and temperature sensors through the private
/// `IOHIDEventSystemClient` API.
///
/// On iOS a sandboxed process may create exactly one client; every additional
/// client in the same process returns NaN for every service. So a single
/// instance is created at launch and reused for the life of the app.
///
/// Two vendor usage pages carry what we want:
///   0xff08  AppleVendorPowerSensor  usage 2 = current (A), usage 3 = voltage (V)
///   0xff00  AppleVendor             usage 5 = temperature (°C)
///
/// Names seen on recent iPhones (they vary by model, so nothing here is hardcoded
/// as required — see `SensorCatalog` for the classification):
///   Charger VQ0u / IQ0u    USB-C input voltage / current
///   Charger VQ1u / IQ1u    wireless (MagSafe) input voltage / current
///   Charger IQ0B           current delivered into the battery
///   Charger VQ0l, PMU VP0u battery-side voltage
///   gas gauge battery      battery temperature
///   Charger TQ0j / TQ0d    charger junction / die temperature
///   PMU tdie1…n            SoC die temperatures
nonisolated final class HIDSensors {
    enum Kind: Int, Sendable {
        case current = 2
        case voltage = 3
        case temperature = 5
        case other = 0
    }

    struct Reading: Identifiable, Hashable, Sendable {
        let name: String
        let kind: Kind
        let value: Double
        /// Position in the service list. Names repeat — an iPhone 17 reports four
        /// separate sensors all called "gas gauge battery" — so the index is what
        /// makes a row identifiable.
        let index: Int
        var id: String { "\(index)#\(name)" }

        var formatted: String {
            switch kind {
            case .current: return String(format: "%.3f A", value)
            case .voltage: return String(format: "%.3f V", value)
            case .temperature: return Formatting.temperature(value)
            case .other: return String(format: "%.3f", value)
            }
        }
    }

    /// One HID service as the system reports it, before any value is read.
    struct ServiceInfo: Identifiable, Hashable, Sendable {
        let name: String
        let usagePage: Int
        let usage: Int
        var id: String { "\(name)#\(usagePage)#\(usage)" }
    }

    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias SetMatchingFn = @convention(c) (CFTypeRef, CFDictionary?) -> Void
    private typealias CopyServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEventFn = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias GetFloatFn = @convention(c) (CFTypeRef, Int32) -> Double

    private static let powerEventType: Int64 = 25       // kIOHIDEventTypePower
    private static let temperatureEventType: Int64 = 15 // kIOHIDEventTypeTemperature
    static let powerUsagePage = 0xff08
    static let vendorUsagePage = 0xff00

    private struct Service {
        let ref: CFTypeRef
        let name: String
        let usagePage: Int
        let usage: Int
        let eventType: Int64
    }

    private let client: CFTypeRef
    private let setMatching: SetMatchingFn
    private let copyServices: CopyServicesFn
    private let copyProperty: CopyPropertyFn
    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private var services: [Service] = []

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let create = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", SetMatchingFn.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", CopyServicesFn.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", CopyPropertyFn.self),
              let copyEvent = sym("IOHIDServiceClientCopyEvent", CopyEventFn.self),
              let getFloat = sym("IOHIDEventGetFloatValue", GetFloatFn.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue()
        else { return nil }
        self.client = client
        self.setMatching = setMatching
        self.copyServices = copyServices
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        rescan()
    }

    var isEmpty: Bool { services.isEmpty }
    var serviceCount: Int { services.count }

    /// Re-enumerates the sensor services. Cheap enough to call every few seconds;
    /// the charger's sensors only appear once something is plugged in.
    func rescan() {
        var found: [Service] = []
        // Every service on the power page, not just the handful we name: unknown
        // rails still carry usable volts and amps and are worth showing.
        found += discover(matching: ["PrimaryUsagePage": Self.powerUsagePage],
                          eventType: Self.powerEventType)
        // Temperature sensors. The whole matrix, so wireless coils, NAND and every
        // PMU die show up alongside the battery.
        found += discover(matching: ["PrimaryUsagePage": Self.vendorUsagePage, "PrimaryUsage": 5],
                          eventType: Self.temperatureEventType)
        services = found
    }

    /// Current value of every discovered sensor. Sensors that return NaN (nothing
    /// plugged in, rail powered down) are skipped rather than shown as zero.
    ///
    /// Nothing else is filtered here: the Raw data screen shows this list and says it
    /// is unedited. Values that cannot be temperatures are dropped a layer up, where
    /// `PowerSnapshot` decides what counts as one — see `plausibleCelsius`.
    func read() -> [Reading] {
        services.enumerated().compactMap { index, service in
            guard let event = copyEvent(service.ref, service.eventType, 0, 0)?.takeRetainedValue() else { return nil }
            let value = getFloat(event, Int32(service.eventType << 16))
            guard value.isFinite else { return nil }
            return Reading(name: service.name,
                           kind: Kind(rawValue: service.usage) ?? .other,
                           value: value,
                           index: index)
        }
    }

    /// What a temperature sensor on a phone can physically report.
    ///
    /// NaN is not the only way a sensor says "nothing here". Reports from models this
    /// app has never run on include a charge IC reading −9199.4 °C, which is a
    /// sentinel or a raw counter that happens to sit on the temperature page — and the
    /// app dutifully printed it as a temperature. A reading outside this range is not
    /// a cold phone, it is a sensor that does not mean what its usage page says, so it
    /// is dropped and the value shows as absent.
    ///
    /// Only temperature is checked. Volts and amps have shown no comparable sentinel,
    /// and a range tight enough to catch one would risk hiding a real rail on a model
    /// nobody here has seen.
    static let plausibleCelsius = -40.0...150.0

    /// Every HID service in the system, matched or not. Debug view only: this is how
    /// the sensor names above were found in the first place, and how they get found
    /// again on a phone model this app has never seen.
    func fullInventory() -> [ServiceInfo] {
        // nil, not an empty dictionary: an empty matching dictionary matches
        // nothing, which is why this used to come back empty and the button in the
        // debug view looked dead.
        let all = discover(matching: nil, eventType: 0).map {
            ServiceInfo(name: $0.name, usagePage: $0.usagePage, usage: $0.usage)
        }
        rescan() // the matching dictionary is client state; put it back
        return all.sorted { ($0.usagePage, $0.usage, $0.name) < ($1.usagePage, $1.usage, $1.name) }
    }

    private func discover(matching: [String: Any]?, eventType: Int64) -> [Service] {
        setMatching(client, matching as CFDictionary?)
        let refs = copyServices(client)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return refs.map { ref in
            func number(_ key: String) -> Int {
                (copyProperty(ref, key as CFString)?.takeRetainedValue() as? NSNumber)?.intValue ?? 0
            }
            let name = copyProperty(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            return Service(ref: ref,
                           name: name,
                           usagePage: number("PrimaryUsagePage"),
                           usage: number("PrimaryUsage"),
                           eventType: eventType)
        }
    }
}
