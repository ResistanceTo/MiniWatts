import SwiftUI

/// A rough thermal map of the device: each sensor zone glows at its own colour
/// and position, so charging heat can be seen moving from the charge IC at the
/// bottom up through the battery and the SoC.
///
/// The positions are approximate by design — the sandbox gives temperatures and
/// sensor names, never coordinates — so this is a legend for the numbers below
/// it, not a claim about millimetres. An iPad gets an iPad: the outline, and the
/// layout under it, are not a phone's (#13, #22). Upright either way, whichever way
/// the device is held — the map is a legend, and turning it would only move the
/// pins away from the list they key.
struct DeviceHeatMap: View {
    /// One reading per zone, in Celsius.
    let readings: [(zone: ThermalZone, celsius: Double)]
    var form: DeviceForm = .current
    var unit: TemperatureDisplayUnit = .celsius
    var height: CGFloat = 250

    /// An iPhone body is about half as wide as it is tall; an iPad Pro 11-inch,
    /// 177.5 × 249.7 mm, a little under three quarters.
    private var width: CGFloat { height * (form == .phone ? 0.49 : 0.71) }
    private var cornerRadius: CGFloat { width * (form == .phone ? 0.16 : 0.075) }
    /// Sized to the narrower side, so a zone on an iPad does not swallow its neighbours.
    private var glowDiameter: CGFloat { width * (form == .phone ? 0.85 : 0.6) }

    var body: some View {
        ZStack {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            shape
                .fill(Color.mwMuted.opacity(0.08))
                .overlay(shape.strokeBorder(Color.mwCardStroke, lineWidth: 1))

            if form == .tablet {
                // The screen inside its bezel, which is most of what makes an outline
                // this shape read as an iPad rather than as a box.
                RoundedRectangle(cornerRadius: cornerRadius * 0.6, style: .continuous)
                    .strokeBorder(Color.mwCardStroke.opacity(0.8), lineWidth: 0.5)
                    .padding(width * 0.045)
            }

            // Heat blobs, clipped to the body so the glow does not spill outside.
            ZStack {
                ForEach(readings, id: \.zone) { reading in
                    ForEach(Array(reading.zone.glowPositions(on: form).enumerated()), id: \.offset) { _, point in
                        Circle()
                            .fill(
                                RadialGradient(colors: [Color.mwTemperature(reading.celsius).opacity(0.85), .clear],
                                               center: .center,
                                               startRadius: 0,
                                               endRadius: glowDiameter / 2)
                            )
                            .frame(width: glowDiameter, height: glowDiameter)
                            .position(x: width * point.x, y: height * point.y)
                    }
                }
            }
            .frame(width: width, height: height)
            .blur(radius: 14)
            .blendMode(.plusLighter)
            .clipShape(shape)

            // Sensor pins.
            ZStack {
                ForEach(readings, id: \.zone) { reading in
                    let point = reading.zone.position(on: form)
                    VStack(spacing: 2) {
                        Image(systemName: reading.zone.symbol)
                            .font(.system(size: 9, weight: .bold))
                        Text(verbatim: unit.number(reading.celsius, decimals: 0) + "°")
                            .mwMono(size: 9, weight: .semibold)
                    }
                    .foregroundStyle(Color.mwTemperature(reading.celsius))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.mwCard.opacity(0.82)))
                    .overlay(Capsule().strokeBorder(Color.mwTemperature(reading.celsius).opacity(0.5), lineWidth: 0.5))
                    .position(x: width * point.x, y: height * point.y)
                }
            }
            .frame(width: width, height: height)

            landmarks
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// Just enough of the hardware for the silhouette to read as the device it is.
    @ViewBuilder
    private var landmarks: some View {
        switch form {
        case .phone:
            // The Dynamic Island.
            Capsule()
                .fill(Color.mwCanvas)
                .frame(width: width * 0.3, height: height * 0.035)
                .position(x: width / 2, y: height * 0.055)
        case .tablet:
            // The front camera in the top bezel, and the USB-C port in the bottom one,
            // which is what the charge IC's position is relative to.
            Circle()
                .fill(Color.mwMuted.opacity(0.45))
                .frame(width: 4, height: 4)
                .position(x: width / 2, y: width * 0.0225)
            Capsule()
                .fill(Color.mwMuted.opacity(0.45))
                .frame(width: width * 0.1, height: 3)
                .position(x: width / 2, y: height - width * 0.0225)
        }
    }
}

/// The simulator has no temperature sensors, so the Thermal page never draws the map
/// there. These are the zone figures from the iPad Pro M1 dump in #13.
#Preview("iPhone and iPad") {
    let readings: [(zone: ThermalZone, celsius: Double)] = [
        (.battery, 27.8), (.charger, 31.1), (.soc, 39.9), (.storage, 31.0), (.other, 29.0),
    ]
    HStack(alignment: .bottom, spacing: 24) {
        VStack(spacing: 10) {
            DeviceHeatMap(readings: readings, form: .phone)
            TemperatureScale()
        }
        VStack(spacing: 10) {
            DeviceHeatMap(readings: readings, form: .tablet, unit: .fahrenheit, height: 320)
            TemperatureScale(unit: .fahrenheit)
        }
    }
    .padding()
}

/// The colour key for the map, written in the scale the rest of the screen uses.
/// The colour steps themselves stay where they are in Celsius.
struct TemperatureScale: View {
    var unit: TemperatureDisplayUnit = .celsius

    var body: some View {
        HStack(spacing: 6) {
            ForEach([25.0, 31.0, 36.0, 41.0, 46.0], id: \.self) { celsius in
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color.mwTemperature(celsius))
                        .frame(width: 6, height: 6)
                    Text(verbatim: unit.number(celsius, decimals: 0) + (celsius >= 46 ? "+" : ""))
                        .mwMono(size: 9)
                        .foregroundStyle(Color.mwMuted)
                }
            }
            Text(verbatim: unit.symbol).mwMono(size: 9).foregroundStyle(Color.mwMuted)
        }
    }
}
