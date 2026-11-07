import Foundation

/// How long until the battery reaches a level, from how fast the level has actually
/// been rising (#27).
///
/// powerd has a `Time to Full Charge` key and it is no help: it read −1 while charging
/// in both iOS 27 dumps taken on a charger (an iPhone 11 in #14, an 18 Pro Max in #16),
/// and 0 on battery. So the forecast is worked out here, from the same log of level
/// changes the %-rate estimate uses — which needs nothing else: not the pack energy,
/// which is a guess on most models, and not the cell sensors, which read half on an
/// 18 Pro at high power.
///
/// Charging slows down towards full. Below 80 % a phone charges at close to constant
/// current; above it the charger holds the voltage and the current tapers off, so
/// each percent takes longer than the last. The rate measured now cannot see that
/// coming, so every percent is given a relative cost on a typical curve — `weight` —
/// and the measured rate is read as so many seconds per unit of it. Below 80 % that is
/// just the measured rate carried forward; above it, it is a model, and the page says
/// so. The curve is a generic one, not this battery's: a slow charger reaches the
/// taper later and is overestimated past 80 %, a fast one early in the charge is
/// underestimated. The forecast follows the newest rate and corrects itself as the
/// level moves.
nonisolated struct ChargeForecast: Hashable, Sendable {
    /// The level when the forecast was made, and the moment it got there.
    let percent: Int
    let reachedAt: Date
    /// How far the level moves at a time. 1 on most systems; powerd's `Current
    /// Capacity` came in multiples of 5 in every iOS 27 dump in the issues, and if it
    /// really moves in fives, a level of 85 means anywhere from 85 to 89.
    let step: Int
    /// Seconds for one unit of `weight`: the time a percent takes before the taper.
    let secondsPerUnit: Double
    /// What the rate was measured over, so the page can say.
    let measuredRise: Int
    let measuredSpan: TimeInterval

    /// The level beyond which the rest of the charge is modelled, not measured.
    static let taperStart = 80

    /// A percent's relative charging time on a typical lithium-ion curve. Charging
    /// from 80 to 100 % comes to 2.9 times as long as the same twenty points below 80,
    /// which puts a phone that charges 50 to 80 % in 27 minutes at about 52 minutes
    /// for the rest: the order of what fast-charging iPhones are reported to take.
    static func weight(_ percent: Int) -> Double {
        switch percent {
        case ..<taperStart: return 1
        case ..<90: return 2
        case ..<95: return 3
        default: return 4.5
        }
    }

    private static func units(from start: Int, to end: Int) -> Double {
        guard end > start else { return 0 }
        return (start..<end).reduce(0) { $0 + weight($1) }
    }

    /// A forecast from the moments the level changed, oldest first. The first time
    /// the level was seen is not one of them: it landed somewhere inside a percent,
    /// so it says nothing about when that percent began. Needs two changes, a rise
    /// between them, and time for it.
    init?(levelChanges: [(date: Date, percent: Int)]) {
        guard levelChanges.count >= 2, let first = levelChanges.first, let last = levelChanges.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        let rise = last.percent - first.percent
        guard span > 0, rise > 0 else { return nil }
        percent = last.percent
        reachedAt = last.date
        secondsPerUnit = span / Self.units(from: first.percent, to: last.percent)
        let steps = zip(levelChanges, levelChanges.dropFirst()).map { $1.percent - $0.percent }.filter { $0 > 0 }
        step = steps.min() ?? 1
        measuredRise = rise
        measuredSpan = span
    }

    /// Seconds from `now` until the level reads `target`, or 0 once it does.
    ///
    /// The time already spent at the current level comes off — with five-percent steps
    /// that can be minutes — but never more than the current step is expected to take:
    /// if the level is late to move, the forecast holds at what lies beyond it rather
    /// than running down to zero.
    func secondsRemaining(to target: Int, from currentPercent: Int, at now: Date) -> TimeInterval {
        guard target > currentPercent else { return 0 }
        let whole = secondsPerUnit * Self.units(from: currentPercent, to: target)
        // A level this forecast did not see arrive — the log was restarted after a
        // gap — has no known start, so nothing is taken off it.
        guard currentPercent == percent else { return whole }
        let beyondStep = secondsPerUnit * Self.units(from: min(currentPercent + step, target), to: target)
        let elapsed = max(now.timeIntervalSince(reachedAt), 0)
        return max(whole - elapsed, beyondStep)
    }
}
