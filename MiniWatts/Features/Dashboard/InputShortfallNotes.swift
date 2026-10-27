import SwiftUI

/// What the page knows about the iPhone 18 Pro's half reading: the caution that it
/// can happen, and the battery level check's answer once there is one. See
/// `PowerSnapshot.mayReadHalfInput` and `LevelRateCheck`.
///
/// Neither changes a number. Both say what was measured and what it implies.
struct InputShortfallNotes: View {
    let snapshot: PowerSnapshot
    let check: LevelRateCheck?
    /// Whether to show the check when it found nothing wrong. The Power page does,
    /// as a quiet confirmation; the Adapter page has no use for it.
    var showsAgreement = true

    /// True when either the caution or a short verdict applies.
    static func applies(to snapshot: PowerSnapshot, check: LevelRateCheck?) -> Bool {
        check?.verdict == .sensorsShort || showsCaution(snapshot, check)
    }

    /// The caution, unless the level has since shown the reading is whole.
    private static func showsCaution(_ snapshot: PowerSnapshot, _ check: LevelRateCheck?) -> Bool {
        snapshot.mayReadHalfInput && check?.verdict != .agrees && check?.verdict != .sensorsShort
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if Self.showsCaution(snapshot, check) {
                EmptyNote(text: "On the iPhone 18 Pro, wired charging above about 30 W can read about half on every sensor here: people with an inline meter saw the input and the cell figures both at half the real power. Nothing is corrected. Once the battery level has risen a few percent, it is used to check.",
                          systemImage: "exclamationmark.triangle")
            }
            if let check {
                switch check.verdict {
                case .sensorsShort:
                    EmptyNote(text: "The battery level is rising \(String(format: "%.1f", check.ratio))× as fast as the cell sensors account for — about \(Formatting.watts(check.levelWatts)) W from the level against \(Formatting.watts(check.cellWatts)) W measured — so they are seeing only part of the charge, and the figures here are low. Nothing is corrected. Worked out for a \(String(format: "%.1f", check.packWattHours)) Wh battery; the right value for yours goes in Settings.",
                              systemImage: "exclamationmark.triangle")
                case .agrees where showsAgreement:
                    EmptyNote(text: "Battery level check: rising at about \(Formatting.watts(check.levelWatts)) W, in line with the \(Formatting.watts(check.cellWatts)) W the cell sensors measure.",
                              systemImage: "checkmark.circle")
                case .inconclusive where showsAgreement:
                    EmptyNote(text: "Battery level check: rising at about \(Formatting.watts(check.levelWatts)) W against \(Formatting.watts(check.cellWatts)) W measured at the cell — too far apart to agree, too close to call. It is worked out for a \(String(format: "%.1f", check.packWattHours)) Wh battery; if that is not your phone's, set it in Settings.")
                default:
                    EmptyView()
                }
            }
        }
    }
}
