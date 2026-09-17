import Foundation

/// What the fit concluded about the charging path, and how much of it to believe.
nonisolated struct PathResistanceEstimate: Hashable {
    /// Resistance of the whole path in milliohms: the charger's own output
    /// impedance, the cable's VBUS and ground conductors, both sets of contacts,
    /// and the phone's board up to the sensor. Not the cable alone — nothing here
    /// can separate a thin cable from a loose plug or a soft charger.
    let milliohms: Double
    let sampleCount: Int
    /// Amps between the smallest and largest accepted reading. A slope fitted
    /// across a narrow range is a slope fitted out of noise, so this is shown
    /// rather than hidden: it is the difference between a measurement and a guess.
    let currentSpread: Double
    /// Where the line crosses zero current — the charger's setpoint as the phone
    /// would see it with nothing in the way. Comparing it with the negotiated
    /// voltage is a second, independent check on the same connection.
    let openCircuitVolts: Double
    /// Share of the variance the straight line accounts for, 0…1.
    let fitQuality: Double

    /// The voltage this path costs at a given current.
    func dropVolts(at amps: Double) -> Double { milliohms / 1000 * amps }

    /// The power it turns into heat at a given current.
    func lossWatts(at amps: Double) -> Double { dropVolts(at: amps) * amps }
}

/// Estimates the resistance of the charging path from the port's own sensors.
///
/// There is no cable on the other end of an iPhone that the phone can interrogate.
/// While charging the phone is the sink, so the charger — not the phone — is the
/// one that talks to the cable's e-marker, and nothing about the cable's identity
/// reaches iOS at all. What does reach it is the electrical consequence: `Charger
/// VQ0u` is the voltage measured at the phone's own port, and `Charger IQ0u` the
/// current through it. A resistive path between the charger and the phone makes
/// the first fall as the second rises, and the slope of that line is the
/// resistance.
///
/// So the fit is `V = a + b·I` over one PD contract, and `−b` is the resistance.
/// Fitting rather than subtracting matters: the adapter's reported voltage is the
/// profile's ceiling and not a measurement (two MagSafe samples minutes apart both
/// read 6800 mV while the current into the cell fell by a third), so there is no
/// trustworthy reference to subtract from. The intercept absorbs whatever the
/// charger's real setpoint is, and none of it has to be known in advance. The
/// method is the one WhatCable uses on macOS against the SMC's DC-in rail.
///
/// Four rules keep the fit honest, and all four were needed:
/// - **Reset on the contract.** Charger swap, cable swap, unplug, or a
///   renegotiation to another voltage all move the intercept, and samples from
///   either side of that are not on the same line.
/// - **Settle first.** The readings during a renegotiation are a transient, so the
///   first few ticks after a change are dropped.
/// - **Drop repeats.** The sensors publish at about 1 Hz and the tick reads at 1 Hz
///   without being in step, so the same pair can be read twice. An identical sample
///   adds no information to a regression but does inflate the sample count, which
///   would make a fit look better-supported than it is.
/// - **Refuse to answer without spread.** During constant-current charging the
///   current barely moves; the range that makes this measurable comes from the
///   taper past ~80%, from thermal throttling, and from the phone's own load. Until
///   the current has actually moved, there is no estimate — not a bad one.
///
/// Wireless is excluded outright: there is no coil-current sensor on the models
/// checked, and a coil gap is not a cable.
nonisolated final class PathResistanceMeter {
    /// What identifies one charging path. Anything that changes here invalidates
    /// every sample taken before it.
    struct Fingerprint: Hashable {
        let adapter: String
        let contractMillivolts: Int
        let contractMilliamps: Int

        init?(_ snapshot: PowerSnapshot) {
            guard snapshot.externalConnected, !snapshot.isWirelessInput, !snapshot.adapterIsWireless
            else { return nil }
            adapter = [snapshot.adapterName, snapshot.adapterSerial, snapshot.adapterModel]
                .compactMap { $0 }.joined(separator: "|")
            contractMillivolts = snapshot.adapterVoltageMillivolts ?? 0
            contractMilliamps = snapshot.adapterCurrentMilliamps ?? 0
        }
    }

    /// Ticks discarded after the path changes, ~5 s at the one-second tick. Long
    /// enough to cover a PD renegotiation.
    private static let settleTicks = 5
    /// Below this the phone is barely drawing and the drop is unmeasurable. Defined
    /// on `PowerSnapshot` rather than here because its single-sample
    /// `inputPathMilliohms` has to refuse at the same current or the two disagree
    /// about when there is anything to measure — and that file, unlike this one, is
    /// compiled into the widget extension as well.
    private static let minimumAmps = PowerSnapshot.measurableInputAmps
    /// Nothing is reported under these: too few points, or too little movement in
    /// the current to fit a slope to.
    private static let requiredSamples = 24
    private static let requiredSpread = 0.25
    /// A path outside this is not a path — the fit has caught something else moving.
    private static let plausibleMilliohms: ClosedRange<Double> = 1...5000

    private(set) var estimate: PathResistanceEstimate?

    private var fingerprint: Fingerprint?
    private var settling = 0
    private var last: (volts: Double, amps: Double)?

    // Running sums, so the fit covers the whole contract without keeping the
    // samples that produced it.
    private var n = 0.0
    private var sumI = 0.0, sumV = 0.0, sumII = 0.0, sumIV = 0.0, sumVV = 0.0
    private var minI = Double.greatestFiniteMagnitude, maxI = -Double.greatestFiniteMagnitude

    func reset() {
        fingerprint = nil
        settling = 0
        last = nil
        clear()
        estimate = nil
    }

    func add(_ snapshot: PowerSnapshot) {
        guard let current = Fingerprint(snapshot) else {
            // Unplugged, or wireless. Keep the last estimate on screen rather than
            // blanking it the instant a cable is pulled — but drop the samples, so
            // the next connection starts clean.
            fingerprint = nil
            clear()
            return
        }
        if current != fingerprint {
            fingerprint = current
            settling = Self.settleTicks
            last = nil
            clear()
            estimate = nil
        }
        if settling > 0 {
            settling -= 1
            return
        }

        guard let volts = snapshot.usbInputVoltage, let amps = snapshot.usbInputCurrent,
              volts > 0.5, amps >= Self.minimumAmps else { return }
        // The sensors publish at their own rate; an unchanged pair is the same
        // reading seen twice, not a second measurement.
        if let last, last.volts == volts, last.amps == amps { return }
        last = (volts, amps)

        n += 1
        sumI += amps
        sumV += volts
        sumII += amps * amps
        sumIV += amps * volts
        sumVV += volts * volts
        minI = min(minI, amps)
        maxI = max(maxI, amps)

        estimate = fit() ?? estimate
    }

    private func clear() {
        n = 0
        sumI = 0; sumV = 0; sumII = 0; sumIV = 0; sumVV = 0
        minI = .greatestFiniteMagnitude
        maxI = -.greatestFiniteMagnitude
    }

    /// Ordinary least squares on the running sums. Returns nil whenever the data
    /// does not support an answer, which is most of the time early in a charge.
    private func fit() -> PathResistanceEstimate? {
        let spread = maxI - minI
        guard n >= Double(Self.requiredSamples), spread >= Self.requiredSpread else { return nil }

        let denominator = n * sumII - sumI * sumI
        guard denominator > 0 else { return nil }
        let slope = (n * sumIV - sumI * sumV) / denominator
        let intercept = (sumV - slope * sumI) / n

        // A rising voltage under rising current is not a resistance. It happens
        // when the charger is still ramping, and the honest answer is silence.
        guard slope < 0 else { return nil }
        let milliohms = -slope * 1000
        guard Self.plausibleMilliohms.contains(milliohms) else { return nil }

        let varianceV = sumVV - sumV * sumV / n
        let explained = varianceV > 0 ? (slope * (sumIV - sumI * sumV / n)) / varianceV : 0

        return PathResistanceEstimate(milliohms: milliohms,
                                      sampleCount: Int(n),
                                      currentSpread: spread,
                                      openCircuitVolts: intercept,
                                      fitQuality: min(max(explained, 0), 1))
    }
}
