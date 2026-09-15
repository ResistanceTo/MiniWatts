import SwiftUI

/// The app's palette, resolved against the colour scheme explicitly.
///
/// The app's `Color.mw` builds a dynamic `UIColor` around a trait-resolution closure.
/// A widget is archived and drawn by the system rather than rendered live, and a
/// closure is not something to trust across that trip, so the extension picks each
/// value from `colorScheme` itself instead of sharing `Theme.swift`. Hex values match
/// the app's.
struct WidgetPalette {
    let accent: Color
    let battery: Color
    let wireless: Color
    let loss: Color
    let muted: Color
    let track: Color
    let canvasTop: Color
    let canvas: Color
    let temperatureCold: Color
    let temperatureCool: Color
    let temperatureWarm: Color
    let temperatureHot: Color
    let temperatureVeryHot: Color

    init(_ scheme: ColorScheme) {
        let dark = scheme == .dark
        accent = Color(rgb: dark ? 0x35DFFF : 0x0086B3)
        battery = Color(rgb: dark ? 0x3FE08C : 0x0E9B57)
        wireless = Color(rgb: dark ? 0xB49BFF : 0x6B4EE6)
        loss = Color(rgb: dark ? 0xFFB443 : 0xB86A00)
        muted = Color(rgb: dark ? 0x8C93A6 : 0x60687A)
        track = Color(rgb: dark ? 0x8C93A6 : 0x60687A).opacity(0.2)
        canvasTop = Color(rgb: dark ? 0x0C1018 : 0xF7F9FC)
        canvas = Color(rgb: dark ? 0x06070A : 0xEEF1F6)
        temperatureCold = Color(rgb: dark ? 0x4DA3FF : 0x2C7BE5)
        temperatureCool = Color(rgb: dark ? 0x3FE08C : 0x0E9B57)
        temperatureWarm = Color(rgb: dark ? 0xF2D14B : 0xB08900)
        temperatureHot = Color(rgb: dark ? 0xFFA340 : 0xB86A00)
        temperatureVeryHot = Color(rgb: dark ? 0xFF6058 : 0xC5342B)
    }

    /// The same rule as the app's dial: cyan from a cable, violet from a coil, amber
    /// on battery.
    func tint(for reading: ChargeReading?) -> Color {
        guard let reading else { return muted }
        guard reading.externalConnected else { return loss }
        return reading.isWireless ? wireless : accent
    }

    func temperatureTint(_ celsius: Double?) -> Color {
        guard let celsius else { return muted }
        switch celsius {
        case ..<28: return temperatureCold
        case ..<34: return temperatureCool
        case ..<39: return temperatureWarm
        case ..<44: return temperatureHot
        default: return temperatureVeryHot
        }
    }

    func tint(for state: ChargeActivityContentState) -> Color {
        switch state.selectedMetric {
        case .chargingPower:
            return tint(for: state.reading)
        case .socTemperature:
            return temperatureTint(state.socTemperature)
        case .batteryTemperature:
            return temperatureTint(state.batteryTemperature)
        case .hottestTemperature:
            return temperatureTint(state.hottestTemperature)
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
