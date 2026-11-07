import CoreGraphics
import Foundation

/// Where in the phone a temperature sensor sits.
///
/// Sensor names differ between iPhone models, so nothing is matched exactly:
/// every name falls into a zone by keyword, and anything unrecognised lands in
/// `.other` and is still shown. A new phone model degrades to a longer "other"
/// list rather than to an empty screen.
nonisolated enum ThermalZone: String, CaseIterable, Identifiable {
    case battery
    case charger
    case wirelessCoil
    case soc
    case storage
    case radio
    case display
    case camera
    case surface
    case other

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .battery: return "Battery"
        case .charger: return "Charge IC"
        case .wirelessCoil: return "Wireless coil"
        case .soc: return "SoC dies"
        case .storage: return "Storage"
        case .radio: return "Radios"
        case .display: return "Display"
        case .camera: return "Camera"
        case .surface: return "Chassis"
        case .other: return "Other sensors"
        }
    }

    var symbol: String {
        switch self {
        case .battery: return "battery.100"
        case .charger: return "bolt.square"
        case .wirelessCoil: return "wave.3.right.circle"
        case .soc: return "cpu"
        case .storage: return "internaldrive"
        case .radio: return "antenna.radiowaves.left.and.right"
        case .display: return "square.on.square"
        case .camera: return "camera"
        case .surface: return DeviceForm.current == .tablet ? "ipad" : "iphone"
        case .other: return "sensor"
        }
    }

    /// Schematic position on the device silhouette, in unit coordinates
    /// (0,0 = top-left, 1,1 = bottom-right), upright.
    ///
    /// iOS reports sensor names and temperatures and nothing else — there are no
    /// coordinates to read — so these are fixed per zone, while real internal
    /// layouts differ from generation to generation.
    ///
    /// On a phone they follow the usual arrangement of a recent iPhone: the logic
    /// board with the SoC and storage stacked in the upper third behind the camera
    /// plateau, the battery as the large mass through the middle and lower half, and
    /// the charge IC down by the port. That is why the top of the phone runs hot to
    /// the touch near the cameras while charging: the SoC is what is under there,
    /// not the cameras.
    ///
    /// On an iPad they follow the iPad Pro 11-inch, the one iPad a dump has come from
    /// (iPad13,4, #13): iFixit's teardown of that body finds the logic board "betwixt
    /// the battery cells", a strip down the middle with a cell either side, and the
    /// charge IC sits by the USB-C port at the bottom. The battery is drawn on both
    /// sides for that reason — see `glowPositions(on:)`.
    func position(on form: DeviceForm) -> CGPoint {
        switch form {
        case .phone:
            switch self {
            case .camera: return CGPoint(x: 0.28, y: 0.11)
            case .radio: return CGPoint(x: 0.63, y: 0.12)
            case .soc: return CGPoint(x: 0.37, y: 0.24)
            case .display: return CGPoint(x: 0.70, y: 0.31)
            case .storage: return CGPoint(x: 0.31, y: 0.35)
            case .wirelessCoil: return CGPoint(x: 0.52, y: 0.50)
            case .battery: return CGPoint(x: 0.44, y: 0.65)
            case .surface: return CGPoint(x: 0.73, y: 0.71)
            case .charger: return CGPoint(x: 0.50, y: 0.87)
            case .other: return CGPoint(x: 0.26, y: 0.83)
            }
        case .tablet:
            switch self {
            case .camera: return CGPoint(x: 0.18, y: 0.08)
            case .radio: return CGPoint(x: 0.66, y: 0.08)
            case .soc: return CGPoint(x: 0.50, y: 0.27)
            case .display: return CGPoint(x: 0.82, y: 0.22)
            case .storage: return CGPoint(x: 0.50, y: 0.45)
            case .wirelessCoil: return CGPoint(x: 0.50, y: 0.62)
            case .battery: return CGPoint(x: 0.21, y: 0.56)
            case .surface: return CGPoint(x: 0.80, y: 0.78)
            case .charger: return CGPoint(x: 0.50, y: 0.89)
            case .other: return CGPoint(x: 0.20, y: 0.86)
            }
        }
    }

    /// Where the zone glows. One spot, where its pin is, except an iPad's battery,
    /// which is two cells either side of the logic board and warms both.
    func glowPositions(on form: DeviceForm) -> [CGPoint] {
        let pin = position(on: form)
        guard form == .tablet, self == .battery else { return [pin] }
        return [pin, CGPoint(x: 1 - pin.x, y: pin.y)]
    }

    /// Display order, hottest-interest first.
    var order: Int { ThermalZone.allCases.firstIndex(of: self) ?? 99 }
}

/// The body a heat map is drawn on: the sensors and their names differ between an
/// iPhone and an iPad, and so does where the parts sit.
nonisolated enum DeviceForm: Sendable {
    case phone
    case tablet

    /// From the model identifier, so the simulator draws the device it simulates.
    static let current: DeviceForm = PowerSnapshot.modelIdentifier.hasPrefix("iPad") ? .tablet : .phone
}

nonisolated enum SensorCatalog {
    /// Human labels for the sensors we understand. Everything else keeps its raw name.
    private static let labels: [String: LocalizedStringResource] = [
        "Charger VQ0u": "USB-C input voltage",
        "Charger IQ0u": "USB-C input current",
        "Charger VQ1u": "Wireless input voltage",
        "Charger IQ1u": "Wireless input current",
        "Charger VQ0l": "Battery rail voltage",
        "Charger IQ0B": "Current into battery",
        "PMU VP0u": "Battery pack voltage",
        "gas gauge battery": "Battery cell",
        "Charger TQ0j": "Charge IC junction",
        "Charger TQ0d": "Charge IC die",
    ]

    /// The translated label for a sensor we recognise, or nil for one we do not.
    /// Callers show the hardware name itself in that case — `Charger VQ0u` is not
    /// copy, and must never reach the string catalog as a lookup key.
    static func label(for name: String) -> LocalizedStringResource? {
        labels[name]
    }

    /// Sorts a sensor name into a zone by whole words rather than by substring.
    ///
    /// Substring matching was wrong in both directions: "surface" contains "rf"
    /// and would have been filed as a radio, while "cellular" contains "cell" and
    /// would have been filed as the battery. Names are split into words and a word
    /// has to start with the keyword, which keeps "tdie1" matching "tdie" without
    /// letting "surface" match "rf".
    ///
    /// Run-together names are split as well — see `words(in:)` — and the CPU
    /// clusters, the image processor and the power manager's die sensors count as
    /// the SoC. An iPad Pro M1 (#13) lists `pACC MTR Temp Sensor2`–`9`, `eACC MTR …`
    /// and `ISP MTR Temp Sensor5`, and an iPhone 11 (#14) `pACC Temp Sensor0`, which
    /// read up to 53 °C there: all of them sat under "Other sensors", and a CPU
    /// cluster at 53 °C was missing from the SoC zone's figure.
    static func zone(for name: String) -> ThermalZone {
        let words = Self.words(in: name)
        func has(_ keywords: String...) -> Bool {
            keywords.contains { keyword in words.contains { $0.hasPrefix(keyword) } }
        }
        // Order matters: the first zone that matches wins, so the specific names
        // are tested before the ones that would also match something generic.
        if has("modem", "baseband", "wifi", "antenna", "cellular", "nfc", "uwb", "bt", "radio") { return .radio }
        if has("cam") { return .camera }
        if has("wlc", "coil", "magsafe", "wireless", "qi") { return .wirelessCoil }
        if has("charger", "chg", "tcpm", "usb", "vbus") { return .charger }
        if has("battery", "batt", "gauge", "gas", "cell", "pack") { return .battery }
        if has("nand", "ssd", "flash", "nvme") { return .storage }
        if has("display", "lcd", "oled", "backlight") { return .display }
        if has("tdie", "tcal", "soc", "cpu", "gpu", "ane", "pmu", "die",
               "pacc", "eacc", "isp", "mtr", "pmgr", "amc", "odts") { return .soc }
        if has("skin", "chassis", "enclosure", "front", "back", "rear", "case") { return .surface }
        return .other
    }

    /// The lowercased words of a sensor name: each run of letters and digits, plus the
    /// words inside a run-together one.
    ///
    /// An iPhone 11 names sensors `FrontCameraDie`, `CGRearCam` and `BCMLBSkin`. As
    /// single words those matched nothing, or the wrong thing — `frontcameradie`
    /// starts with "front" and was filed as chassis. Split at each change of case they
    /// are front · camera · die, cg · rear · cam and bcmlb · skin. The whole word is
    /// kept too, so a name that matched before still matches: `pACC` stays `pacc` as
    /// well as becoming p · acc. A capital followed by a digit does not split, so
    /// `TQ0d` stays one word.
    static func words(in name: String) -> [String] {
        var words: [String] = []
        for token in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let characters = Array(token)
            var parts: [String] = []
            var current = ""
            for (index, character) in characters.enumerated() {
                if character.isUppercase, !current.isEmpty, index > 0 {
                    let previous = characters[index - 1]
                    let next = index + 1 < characters.count ? characters[index + 1] : nil
                    if previous.isLowercase || (previous.isUppercase && next?.isLowercase == true) {
                        parts.append(current)
                        current = ""
                    }
                }
                current.append(character)
            }
            if !current.isEmpty { parts.append(current) }
            words.append(token.lowercased())
            if parts.count > 1 { words.append(contentsOf: parts.map { $0.lowercased() }) }
        }
        return words
    }
}
