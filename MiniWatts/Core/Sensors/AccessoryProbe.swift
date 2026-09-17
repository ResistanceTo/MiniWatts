import Foundation

/// Asks the IOKit registry for the accessory-manager family: the nodes iOS keeps
/// for whatever is plugged into the USB-C port.
///
/// This exists to settle one question that cannot be answered by reading headers:
/// **does anything in `IOAccessoryManager` survive the app sandbox?** The answer
/// decides whether MiniWatts can ever name the charger's own manufacturer, model
/// and serial, report the port's connect type and current limit, or say anything
/// at all about the cable — everything issue #7 asked for.
///
/// Where the names come from. `/usr/lib/libIOAccessoryManager.dylib` is on every
/// iPhone; disassembling it (iOS 27, iPhone18,4) shows that its getters are not
/// user-client calls at all — `IOAccessoryManagerGetUSBChargingVoltage` is
/// literally `IORegistryEntryCreateCFProperty(service, "IOAccessoryUSBChargingVoltage")`
/// followed by `CFNumberGetValue`, and `IOAccessoryManagerGetUSBConnectType` is a
/// bulk `IORegistryEntryCreateCFProperties` plus two dictionary lookups. So there
/// is nothing to gain from calling those functions with guessed signatures: read
/// the same registry keys directly, which is what this does. `IOServiceMatching`
/// is called with the literal `"IOAccessoryManager"` in that library, so the class
/// name below is measured rather than assumed; the rest of the candidate classes
/// and every key is a string lifted from the same binary's `__cstring` section.
///
/// Both a bulk fetch and a per-key fetch are made for each service, and both are
/// recorded. The sandbox filters `IOPMPowerSource` down to two keys rather than
/// refusing it outright, so "the dictionary came back" is not the same question as
/// "this key came back", and a probe that only did one of the two could report a
/// wall that is not there.
///
/// Nothing here writes, opens a user client, or has a side effect: every call is a
/// registry read. A class that does not exist returns an empty iterator, which is
/// a result and not an error — the report keeps those rows so the dump says which
/// of macOS's USB-PD nodes iOS does not have.
nonisolated final class AccessoryProbe {
    // MARK: Report

    struct KeyReading: Identifiable, Hashable {
        let key: String
        /// nil when the key returned nothing: absent, or filtered away.
        let value: String?
        var id: String { key }
    }

    struct ServiceReading: Identifiable, Hashable {
        let matchedClass: String
        let index: Int
        /// What the service calls itself, which may be a subclass of the matched name.
        let className: String
        let name: String
        /// Everything `IORegistryEntryCreateCFProperties` returned, stringified.
        let bulk: [String: String]
        /// Set when the bulk fetch failed outright, as an IOReturn.
        let bulkError: String?
        /// The targeted reads, including the ones that came back empty.
        let keys: [KeyReading]
        var id: String { "\(matchedClass)#\(index)" }

        var readableKeys: [KeyReading] { keys.filter { $0.value != nil } }
    }

    struct ClassReading: Identifiable, Hashable {
        let className: String
        /// Set when the match itself was refused, as opposed to matching nothing.
        let matchError: String?
        let services: [ServiceReading]
        var id: String { className }
    }

    struct Report: Hashable {
        let date: Date
        /// Whether `libIOAccessoryManager.dylib` loaded, and how many of the
        /// getters below it still exports. Presence only — none of them is called.
        let library: String
        let symbols: [String: Bool]
        let classes: [ClassReading]

        var serviceCount: Int { classes.reduce(0) { $0 + $1.services.count } }
        var readableKeyCount: Int {
            classes.reduce(0) { $0 + $1.services.reduce(0) { $0 + $1.readableKeys.count } }
        }
        /// The one-line verdict, which is the whole point of running this.
        var headline: String {
            guard serviceCount > 0 else { return "No accessory service matched." }
            return "\(serviceCount) services, \(readableKeyCount) keys readable."
        }
    }

    // MARK: What to ask for

    /// Candidate registry classes. The first group is iOS's own accessory family,
    /// taken from `libIOAccessoryManager`'s string table — only `IOAccessoryManager`
    /// is known to be a class there, the others may turn out to be property keys,
    /// in which case they simply match nothing. The second group is what WhatCable
    /// reads on macOS: the USB-PD port-partner and cable e-marker nodes, listed so
    /// the dump states plainly whether iOS publishes them at all.
    private static let classNames = [
        "IOAccessoryManager",
        "IOAccessoryPort",
        "IOAccessoryDevicePort",
        "IOAccessoryPrimaryDevicePort",
        "IOAccessoryIDBusTransport",
        "IOPortTransportStateCC",
        "IOPortTransportComponentCCUSBPDSOP",
        "IOPortTransportComponentCCUSBPDSOPp",
        "IOPortFeaturePowerSource",
        "AppleHPMDeviceHALType3",
        "AppleHPMLDCMType2",
    ]

    /// Every key worth asking each matched service for. The `IOAccessory*` names
    /// are verbatim from `libIOAccessoryManager`; the trailing group is what the
    /// macOS USB-PD nodes carry, including the `Metadata` dictionary whose `VDOs`
    /// array is the cable's e-marker.
    private static let keyNames = [
        "IOAccessoryUSBConnectType",
        "IOAccessoryUSBConnectTypePublished",
        "IOAccessoryUSBActive",
        "IOAccessoryUSBChargingVoltage",
        "IOAccessoryUSBCurrentLimit",
        "IOAccessoryUSBCurrentLimitBase",
        "IOAccessoryUSBCurrentLimitMaximum",
        "IOAccessoryUSBCurrentLimitOffset",
        "IOAccessoryPowerMode",
        "IOAccessoryActivePowerMode",
        "IOAccessorySupportedPowerModes",
        "IOAccessoryPowerCurrentLimits",
        "IOAccessorySleepPowerCurrentLimit",
        "IOAccessoryDetect",
        "IOAccessoryID",
        "IOAccessoryDigitalID",
        "IOAccessoryAccessoryManufacturer",
        "IOAccessoryAccessoryName",
        "IOAccessoryAccessoryModelNumber",
        "IOAccessoryAccessorySerialNumber",
        "IOAccessoryAccessoryFirmwareVersion",
        "IOAccessoryAccessoryHardwareVersion",
        "IOAccessoryAccessoryPPID",
        "IOAccessoryAccessoryVersionInfo",
        "IOAccessoryManagerType",
        "IOAccessoryManagerAccessoryDeviceUID",
        "IOAccessoryManagerSleepPower",
        "IOAccessoryTransportType",
        "IOAccessoryPortStreamType",
        "IOAccessoryPortManagerPrimaryPort",
        "IOAccessoryInterfaceDeviceInfo",
        "FeaturesSupported",
        "TransportType",
        "Metadata",
        "Vendor ID",
        "Product ID",
        "Vendor ID (SOP1)",
        "Product ID (SOP1)",
        "Specification Revision",
    ]

    /// Read-only getters in `libIOAccessoryManager`, checked for presence with
    /// `dlsym` and never called. Whether the symbol is still exported says which
    /// iOS version removed what — the same way `+sharedInstance` disappearing from
    /// `BCBatteryDeviceController` was the whole story on the Devices tab.
    private static let symbolNames = [
        "IOAccessoryManagerGetUSBConnectType",
        "IOAccessoryManagerGetUSBConnectTypePublished",
        "IOAccessoryManagerGetUSBChargingVoltage",
        "IOAccessoryManagerGetUSBCurrentLimit",
        "IOAccessoryManagerGetUSBCurrentLimitMaximum",
        "IOAccessoryManagerGetAccessoryID",
        "IOAccessoryManagerGetDigitalID",
        "IOAccessoryManagerGetType",
        "IOAccessoryManagerGetPowerMode",
        "IOAccessoryManagerGetActivePowerMode",
        "IOAccessoryManagerCopyDeviceInfo",
        "IOAccessoryManagerCopyAccessoryDeviceUID",
        "IOAccessoryManagerGetServiceWithPrimaryPort",
        "IOAccessoryManagerLDCMGetMeasurementStatus",
        "IOAccessoryEAInterfaceCopyDeviceVendorName",
        "IOAccessoryEAInterfaceCopyDeviceSerialNumber",
    ]

    // MARK: IOKit

    private typealias ServiceMatchingFn =
        @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFDictionary>?
    private typealias GetMatchingServicesFn =
        @convention(c) (mach_port_t, CFDictionary?, UnsafeMutablePointer<UInt32>) -> kern_return_t
    private typealias IteratorNextFn = @convention(c) (UInt32) -> UInt32
    private typealias ObjectReleaseFn = @convention(c) (UInt32) -> kern_return_t
    private typealias CreatePropertiesFn =
        @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, CFAllocator?, UInt32) -> kern_return_t
    private typealias CreatePropertyFn =
        @convention(c) (UInt32, CFString, CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias NameFn = @convention(c) (UInt32, UnsafeMutablePointer<CChar>) -> kern_return_t

    private let serviceMatching: ServiceMatchingFn
    private let getMatchingServices: GetMatchingServicesFn
    private let iteratorNext: IteratorNextFn
    private let objectRelease: ObjectReleaseFn
    private let createProperties: CreatePropertiesFn
    private let createProperty: CreatePropertyFn
    private let objectGetClass: NameFn?
    private let entryGetName: NameFn?

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let matching = sym("IOServiceMatching", ServiceMatchingFn.self),
              let services = sym("IOServiceGetMatchingServices", GetMatchingServicesFn.self),
              let next = sym("IOIteratorNext", IteratorNextFn.self),
              let release = sym("IOObjectRelease", ObjectReleaseFn.self),
              let properties = sym("IORegistryEntryCreateCFProperties", CreatePropertiesFn.self),
              let property = sym("IORegistryEntryCreateCFProperty", CreatePropertyFn.self)
        else { return nil }
        serviceMatching = matching
        getMatchingServices = services
        iteratorNext = next
        objectRelease = release
        createProperties = properties
        createProperty = property
        objectGetClass = sym("IOObjectGetClass", NameFn.self)
        entryGetName = sym("IORegistryEntryGetName", NameFn.self)
    }

    // MARK: Probe

    func run() -> Report {
        Report(date: .now,
               library: Self.libraryStatus(),
               symbols: Self.symbolPresence(),
               classes: Self.classNames.map { probe(className: $0) })
    }

    private func probe(className: String) -> ClassReading {
        guard let matching = serviceMatching(className) else {
            return ClassReading(className: className, matchError: "no matching dictionary", services: [])
        }
        var iterator: UInt32 = 0
        // IOServiceGetMatchingServices consumes the +1 reference from
        // IOServiceMatching, so it is handed over unretained rather than let ARC
        // release it a second time. Same contract as `IOKitBattery`.
        let result = getMatchingServices(0 /* kIOMainPortDefault */, matching.takeUnretainedValue(), &iterator)
        guard result == KERN_SUCCESS else {
            return ClassReading(className: className, matchError: Self.ioReturn(result), services: [])
        }
        defer { _ = objectRelease(iterator) }

        var services: [ServiceReading] = []
        var service = iteratorNext(iterator)
        // A registry family with an unexpected number of nodes is interesting, but
        // the debug page is not the place to render hundreds of them.
        while service != 0, services.count < 16 {
            services.append(read(service: service, matchedClass: className, index: services.count))
            _ = objectRelease(service)
            service = iteratorNext(iterator)
        }
        if service != 0 { _ = objectRelease(service) }
        return ClassReading(className: className, matchError: nil, services: services)
    }

    private func read(service: UInt32, matchedClass: String, index: Int) -> ServiceReading {
        var bulk: [String: String] = [:]
        var bulkError: String?
        var properties: Unmanaged<CFDictionary>?
        let result = createProperties(service, &properties, kCFAllocatorDefault, 0)
        if result == KERN_SUCCESS, let dictionary = properties?.takeRetainedValue() as? [String: Any] {
            bulk = dictionary.mapValues { Self.describe($0) }
        } else if result != KERN_SUCCESS {
            bulkError = Self.ioReturn(result)
        }

        let keys = Self.keyNames.map { key in
            KeyReading(key: key,
                       value: createProperty(service, key as CFString, kCFAllocatorDefault, 0)
                           .map { Self.describe($0.takeRetainedValue()) })
        }

        return ServiceReading(matchedClass: matchedClass,
                              index: index,
                              className: name(of: service, using: objectGetClass) ?? matchedClass,
                              name: name(of: service, using: entryGetName) ?? "?",
                              bulk: bulk,
                              bulkError: bulkError,
                              keys: keys)
    }

    /// `io_name_t` is a 128-byte C buffer; it has no Swift type without IOKit's
    /// headers, which iOS does not ship, so it is spelled out here.
    private func name(of service: UInt32, using function: NameFn?) -> String? {
        guard let function else { return nil }
        var buffer = [CChar](repeating: 0, count: 128)
        guard function(service, &buffer) == KERN_SUCCESS else { return nil }
        // Up to the terminator, then decoded: `String(cString:)` on an array is
        // deprecated, and the name is ASCII in practice but UTF-8 is what it is.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    // MARK: Formatting

    private static func libraryStatus() -> String {
        guard dlopen("/usr/lib/libIOAccessoryManager.dylib", RTLD_NOW) != nil else {
            return "libIOAccessoryManager.dylib did not load"
        }
        let present = symbolPresence().values.filter { $0 }.count
        return "libIOAccessoryManager.dylib loaded, \(present)/\(symbolNames.count) getters exported"
    }

    private static func symbolPresence() -> [String: Bool] {
        guard let handle = dlopen("/usr/lib/libIOAccessoryManager.dylib", RTLD_NOW) else {
            return symbolNames.reduce(into: [:]) { $0[$1] = false }
        }
        return symbolNames.reduce(into: [:]) { result, name in
            result[name] = dlsym(handle, name) != nil
        }
    }

    /// Data is hexed rather than described: a digital ID or an e-marker VDO array
    /// is the one thing here worth seeing byte for byte, and `String(describing:)`
    /// renders it as a byte count.
    private static func describe(_ value: Any) -> String {
        if let data = value as? Data {
            let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined()
            return data.count > 64 ? "<\(hex)… \(data.count) bytes>" : "<\(hex)>"
        }
        let text = String(describing: value)
            .replacingOccurrences(of: "\n", with: " ")
        return text.count > 240 ? String(text.prefix(240)) + "…" : text
    }

    /// The codes worth naming. `kIOReturnNotPrivileged` is the sandbox saying no,
    /// and is the one this probe exists to find.
    private static func ioReturn(_ code: kern_return_t) -> String {
        let value = UInt32(bitPattern: code)
        let known: [UInt32: String] = [
            0xe000_02bc: "kIOReturnError",
            0xe000_02c0: "kIOReturnNoDevice",
            0xe000_02c1: "kIOReturnNotPrivileged",
            0xe000_02c2: "kIOReturnBadArgument",
            0xe000_02c7: "kIOReturnUnsupported",
            0xe000_02d9: "kIOReturnNotAttached",
            0xe000_02e2: "kIOReturnNotPermitted",
            0xe000_02f0: "kIOReturnNotFound",
        ]
        let hex = String(format: "0x%08x", value)
        return known[value].map { "\($0) (\(hex))" } ?? hex
    }
}
