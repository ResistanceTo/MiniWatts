import ActivityKit
import AppIntents
import Foundation

nonisolated enum LiveActivityMetric: String, Codable, Hashable, CaseIterable, Identifiable {
    case chargingPower
    case socTemperature
    case batteryTemperature
    case hottestTemperature

    var id: Self { self }
}

/// The existing charge reading plus the extra temperatures needed by the expanded
/// activity. Keeping the `ChargeReading` intact preserves the widget wording and
/// charger-bound lifecycle while allowing the compact presentation to be selected.
nonisolated struct ChargeActivityContentState: Codable, Hashable {
    var reading: ChargeReading
    var socTemperature: Double?
    var hottestTemperature: Double?
    var hottestSensorName: String?
    var selectedMetric: LiveActivityMetric

    var date: Date { reading.date }
    var batteryTemperature: Double? { reading.batteryTemperature }
}

/// The live activity shown on the Lock Screen, in the Dynamic Island and in StandBy
/// while a charger is connected.
///
/// Compiled into both targets: the app starts and updates the activity, the widget
/// extension renders it. ActivityKit matches the two by this type.
///
/// It is only ever updated by the app, while the app is running. Nothing pushes to
/// it from outside — push updates need an APNs server and a certificate tied to a
/// developer team, and a sideloaded copy re-signed with someone else's Apple ID
/// would never receive them. So every update carries a stale date, and the
/// extension says the reading is out of date rather than showing an old number as
/// if it were current.
nonisolated struct ChargeActivityAttributes: ActivityAttributes {
    typealias ContentState = ChargeActivityContentState

    /// When the charger was connected.
    var startedAt: Date
    var startPercent: Int?
}

/// The End button on the activity.
///
/// Only the app can end an activity, and only while it runs. Unplug while MiniWatts is
/// suspended, or kill it, and the activity stays — paused, but on screen — until the
/// app runs again or iOS drops it hours later. A `LiveActivityIntent` is performed in
/// the app's process, which iOS wakes for it, so the button closes the activity
/// without opening MiniWatts. Compiled into both targets: the extension needs the type
/// to draw the button, the app performs it.
nonisolated struct EndChargeActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Live Activity"
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        for activity in Activity<ChargeActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}
