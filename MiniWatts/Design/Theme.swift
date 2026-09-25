import SwiftUI
import UIKit

/// The palette. Every colour is defined for both appearances and resolved by the
/// system, so the whole app follows light/dark without a single `colorScheme` check
/// in a view body.
///
/// `nonisolated` is load-bearing, not tidiness. The project defaults to main-actor
/// isolation, which made the `UIColor` trait-resolution closure below main-actor
/// isolated too — and UIKit calls that closure from whatever thread is resolving a
/// dynamic colour during rendering. Under Swift 6 the compiler inserts an executor
/// check there, so the app trapped on the first frame that painted a gradient.
nonisolated extension Color {
    static func mw(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Page background, bottom of the canvas gradient.
    static let mwCanvas = Color.mw(0xEEF1F6, 0x06070A)
    /// Page background, top of the canvas gradient — a cool cast, so the screen
    /// reads as an instrument rather than a form.
    static let mwCanvasTop = Color.mw(0xF7F9FC, 0x0C1018)
    static let mwCard = Color.mw(0xFFFFFF, 0x14171F)
    static let mwCardStroke = Color.mw(0x0A0A0A, 0xFFFFFF).opacity(0.08)
    static let mwGrid = Color.mw(0x2B3A55, 0x6C8CC7).opacity(0.10)

    /// Adapter side: what arrives from the charger.
    static let mwAccent = Color.mw(0x0086B3, 0x35DFFF)
    /// Battery side: what actually reaches the cell.
    static let mwBattery = Color.mw(0x0E9B57, 0x3FE08C)
    /// Energy lost as heat.
    static let mwLoss = Color.mw(0xB86A00, 0xFFB443)
    static let mwDanger = Color.mw(0xC5342B, 0xFF6058)
    /// Wireless / MagSafe.
    static let mwWireless = Color.mw(0x6B4EE6, 0xB49BFF)
    static let mwMuted = Color.mw(0x60687A, 0x8C93A6)

    // The five steps of the temperature scale, as constants rather than as calls
    // to `mw` inside the switch below.
    //
    // This is load-bearing, not tidiness. `mw` builds a *new* `UIColor` with a
    // trait-resolution closure on every call, and a dynamic `UIColor` compares by
    // identity — two of them built from the same two hex values are not equal. So
    // a `Color` produced by calling `mw` in a view body was a different value on
    // every evaluation even when the temperature had not moved, which defeated
    // SwiftUI's equality checks: `Backdrop`'s `.animation(_:value: glow)` saw a
    // new glow every second and restarted an 0.8 s full-screen `plusLighter`
    // animation for a number that had not changed, and the heat map's blurred
    // blend layer recomposited with it. Resolving each step once fixes both the
    // per-frame allocation and the false inequality.
    private static let mwTemperatureSteps = (
        cold: Color.mw(0x2C7BE5, 0x4DA3FF),
        cool: Color.mw(0x0E9B57, 0x3FE08C),
        warm: Color.mw(0xB08900, 0xF2D14B),
        hot: Color.mw(0xB86A00, 0xFFA340),
        veryHot: Color.mw(0xC5342B, 0xFF6058)
    )

    /// Temperature scale used by the heat map and every temperature bar.
    /// Cool blue below 28 °C through to red at 44 °C and above.
    static func mwTemperature(_ celsius: Double) -> Color {
        switch celsius {
        case ..<28: return mwTemperatureSteps.cold
        case ..<34: return mwTemperatureSteps.cool
        case ..<39: return mwTemperatureSteps.warm
        case ..<44: return mwTemperatureSteps.hot
        default: return mwTemperatureSteps.veryHot
        }
    }

    static func mwPower(_ watts: Double) -> Color {
        watts >= 18 ? .mwAccent : (watts >= 7.5 ? .mwBattery : .mwMuted)
    }
}

nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

nonisolated enum Theme {
    static let cardRadius: CGFloat = 18
    static let cardPadding: CGFloat = 16

    static func gradient(_ color: Color) -> LinearGradient {
        LinearGradient(colors: [color.opacity(0.55), color],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }
}

extension View {
    /// The uppercase, tracked micro-label used above every readout.
    func mwCaption() -> some View {
        font(.system(size: 11, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .tracking(0.9)
            .foregroundStyle(Color.mwMuted)
    }

    /// A large tabular readout. Monospaced digits so the number stops jittering
    /// while it updates once a second.
    ///
    /// Readouts snap; none of them roll. The dial's did, with `.numericText()`, and
    /// on an iPhone Air that one number cost more than everything else on the Power
    /// page: the dial's `.animation` (since removed) put it into an animated
    /// transaction every second, SwiftUI drew the digit roll — blurred glyphs, and
    /// the gradient arcs around them — into a layer rendered on the CPU, and while
    /// the page scrolled that layer was redrawn on every frame. 100–180 ms of main
    /// thread a second, against 11 with the transition off. `.identity` is explicit,
    /// not left out: a readout that ends up inside an animated transaction would
    /// otherwise cross-fade.
    func mwReadout(size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        font(.system(size: size, weight: weight, design: .rounded))
            .monospacedDigit()
            .contentTransition(.identity)
    }

    func mwMono(size: CGFloat = 13, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight, design: .monospaced))
    }
}
