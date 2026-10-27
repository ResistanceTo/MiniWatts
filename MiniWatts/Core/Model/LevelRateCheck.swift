import Foundation

/// The battery level's rise, turned into watts, set against what the cell sensors
/// measured over exactly the same stretch.
///
/// This is the one check that does not lean on the sensors it is checking. On the
/// iPhone 18 Pro at high power `IQ0u` and `IQ0B` both read about half (see
/// `PowerSnapshot.readsHalfAtHighPower`), so comparing one sensor against the other
/// finds nothing. The level is reported by powerd from the gauge, and it rises at
/// the rate the whole charge goes in, however many paths it takes.
///
/// It is coarse. The level arrives in whole percent — in 5 % steps on the iOS 27 dumps
/// seen so far — and turning percent into watt-hours needs the pack energy, which
/// comes from Settings or `PowerMonitor.modelRating`. The level is a charge count
/// costed at a nominal 3.87 V while the sensors multiply by the real cell voltage,
/// around 4.2 V while charging, and a worn battery holds less than its rating. Those
/// pull a correct reading's ratio to somewhere around 0.8–1.1. Hence wide bands:
/// a ratio of 2 says something, a ratio of 1.2 does not.
nonisolated struct LevelRateCheck: Hashable, Sendable {
    /// Watts implied by the level's rise and the pack energy.
    let levelWatts: Double
    /// Mean of the cell sensors' watts over the same stretch.
    let cellWatts: Double
    /// The pack energy the level was costed at.
    let packWattHours: Double
    /// How far the level rose, in percent.
    let percentRise: Int
    /// How long the level took to rise that far.
    let span: TimeInterval

    enum Verdict: Hashable, Sendable {
        /// Within what the coarse inputs allow for a correct reading.
        case agrees
        /// The level is rising far faster than the cell sensors account for: they are
        /// seeing only part of the charge.
        case sensorsShort
        /// Neither. Usually a pack energy that does not match the phone.
        case inconclusive
    }

    var ratio: Double { levelWatts / cellWatts }

    var verdict: Verdict {
        if ratio >= Self.shortRatio { return .sensorsShort }
        if Self.agreeingRatios.contains(ratio) { return .agrees }
        return .inconclusive
    }

    /// The half reading is a ratio of about 2. 1.6 leaves room for the voltage and
    /// wear effects above without coming near a correct reading.
    static let shortRatio = 1.6
    static let agreeingRatios = 0.7...1.3
    /// The level must have moved at least this far for the check to mean anything.
    /// One whole 5 % step, or several 1 % steps.
    static let minimumRise = 3
    static let minimumSpan: TimeInterval = 90
    /// Below this the cell is barely taking anything and the ratio is noise.
    static let minimumCellWatts = 1.0
}
