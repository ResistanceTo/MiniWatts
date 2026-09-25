import SwiftUI

/// The headline gauge: a 280° dial with two concentric arcs — the outer one is
/// what the adapter is delivering, the inner one is what reaches the cell. The
/// gap between them is the conversion loss, visible at a glance.
struct PowerRing: View {
    let inputWatts: Double?
    let batteryWatts: Double?
    /// Full-scale value. The adapter's nameplate rating when known, so the dial
    /// shows headroom rather than an arbitrary scale.
    let fullScale: Double
    /// Optional: with no reading at all the dial says so itself, and a caption
    /// underneath would only repeat it.
    let caption: LocalizedStringResource?
    var tint: Color = .mwAccent
    var size: CGFloat = 232

    /// 280 of 360 degrees, opening at the bottom.
    private let sweep: CGFloat = 280.0 / 360.0
    private let startAngle: Double = 130

    private var inputFraction: CGFloat {
        guard fullScale > 0, let inputWatts else { return 0 }
        return CGFloat(min(max(inputWatts / fullScale, 0), 1))
    }

    private var batteryFraction: CGFloat {
        guard fullScale > 0, let batteryWatts, batteryWatts > 0 else { return 0 }
        return CGFloat(min(max(batteryWatts / fullScale, 0), 1))
    }

    var body: some View {
        // Both fractions change on the one-second tick. Animating them kept the
        // dial drawing for almost half of every second while the page scrolled.
        ZStack {
            ticks
            arc(width: 14, inset: 0, fraction: inputFraction, color: tint)
            arc(width: 8, inset: 26, fraction: batteryFraction, color: .mwBattery)
            centre
        }
        .frame(width: size, height: size)
    }

    private var ticks: some View {
        Canvas { context, canvasSize in
            let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = min(canvasSize.width, canvasSize.height) / 2 - 1
            let count = 57
            for index in 0...count {
                let progress = Double(index) / Double(count)
                let angle = Angle.degrees(startAngle + progress * 280).radians
                let major = index % 7 == 0
                let length: CGFloat = major ? 9 : 5
                let start = CGPoint(x: centre.x + cos(angle) * (radius - length),
                                    y: centre.y + sin(angle) * (radius - length))
                let end = CGPoint(x: centre.x + cos(angle) * radius,
                                  y: centre.y + sin(angle) * radius)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path,
                               with: .color(.mwMuted.opacity(major ? 0.45 : 0.2)),
                               lineWidth: major ? 1.5 : 1)
            }
        }
    }

    private func arc(width: CGFloat, inset: CGFloat, fraction: CGFloat, color: Color) -> some View {
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.mwMuted.opacity(0.14), style: StrokeStyle(lineWidth: width, lineCap: .round))
            Circle()
                .trim(from: 0, to: sweep * fraction)
                .stroke(Theme.gradient(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                .shadow(color: color.opacity(fraction > 0.01 ? 0.55 : 0), radius: 10)
        }
        .rotationEffect(.degrees(startAngle))
        .padding(width / 2 + inset)
    }

    private var centre: some View {
        VStack(spacing: 2) {
            if let inputWatts {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Formatting.watts(inputWatts))
                        .mwReadout(size: 52, weight: .semibold)
                        .foregroundStyle(tint)
                    Text(verbatim: "W")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mwMuted)
                }
            } else {
                Text("no reading")
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.mwMuted.opacity(0.6))
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.mwMuted)
                    .multilineTextAlignment(.center)
            }
            if let batteryWatts, batteryWatts > 0.05 {
                Text("\(Formatting.watts(batteryWatts)) W to cell")
                    .mwMono(size: 11)
                    .foregroundStyle(Color.mwBattery)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 34)
    }
}
