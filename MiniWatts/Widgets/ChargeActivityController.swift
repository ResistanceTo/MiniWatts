import ActivityKit
import Foundation

/// Starts, feeds and ends the charging live activity.
///
/// Driven only by the app's own tick, so it only moves while the app runs. ActivityKit
/// will not start an activity from the background and there is no push channel (see
/// `ChargeActivityAttributes`). That shapes everything here:
/// - an activity is only ever started while the app is in front
/// - every update carries a stale date a little past the next expected update, so once
///   the app is suspended the Lock Screen marks the reading paused instead of passing
///   off an old number as live
/// - it ends when the charger comes out — which, if that happens while the app is
///   suspended, the app only learns on its next tick. The stale date covers the gap,
///   and the End button (`EndChargeActivityIntent`) lets the user close it meanwhile.
final class ChargeActivityController {
    private var activity: Activity<ChargeActivityAttributes>?
    private var adopted = false
    private var lastSent: ChargeActivityContentState?
    private var lastSentAt: Date = .distantPast
    private var lastStartAttempt: Date = .distantPast

    /// How long past an update its reading still counts as current. Updates go out
    /// every few seconds; this tolerates a couple of missed ones and no more.
    private static let staleAfter: TimeInterval = 45
    /// Minimum spacing between updates.
    private static let minimumInterval: TimeInterval = 5
    /// An update goes out at least this often, if only to push the stale date forward.
    private static let maximumInterval: TimeInterval = 20
    /// After a refused start — too many activities, the user switched them off —
    /// wait this long before trying again rather than asking every second.
    private static let retryInterval: TimeInterval = 30

    func sync(_ snapshot: PowerSnapshot,
              selectedMetric: LiveActivityMetric,
              enabled: Bool,
              isForeground: Bool) {
        adoptExistingActivities()
        let state = Self.contentState(from: snapshot, selectedMetric: selectedMetric)
        guard enabled else {
            end(with: state, dismissal: .immediate)
            return
        }
        guard state.reading.externalConnected else {
            // Leave the final state up briefly: "unplugged at 86 %" is worth a glance.
            end(with: state, dismissal: .after(state.date.addingTimeInterval(120)))
            return
        }
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            update(activity, with: state)
        } else if isForeground {
            start(with: state)
        }
    }

    /// An activity outlives the app being killed. The first sync after launch picks up
    /// one left behind and ends any others, rather than starting a duplicate.
    private func adoptExistingActivities() {
        guard !adopted else { return }
        adopted = true
        let existing = Activity<ChargeActivityAttributes>.activities
        activity = existing.first
        for id in existing.dropFirst().map(\.id) {
            Task { await Self.end(id, nil, dismissal: .immediate) }
        }
    }

    private func start(with state: ChargeActivityContentState) {
        guard state.date.timeIntervalSince(lastStartAttempt) >= Self.retryInterval,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        lastStartAttempt = state.date
        do {
            activity = try Activity.request(
                attributes: ChargeActivityAttributes(startedAt: state.date,
                                                     startPercent: state.reading.percent),
                content: content(for: state),
                pushType: nil)
            lastSent = state
            lastSentAt = state.date
        } catch {
            // Refused: not frontmost after all, activities disabled, or the system
            // limit reached. Tried again after `retryInterval`.
        }
    }

    private func update(_ activity: Activity<ChargeActivityAttributes>,
                        with state: ChargeActivityContentState) {
        let elapsed = state.date.timeIntervalSince(lastSentAt)
        guard elapsed >= Self.minimumInterval else { return }
        if elapsed < Self.maximumInterval, let lastSent, !Self.differs(lastSent, state) { return }
        lastSent = state
        lastSentAt = state.date
        let content = content(for: state)
        let id = activity.id
        Task { await Self.update(id, content) }
    }

    private func end(with state: ChargeActivityContentState,
                     dismissal: ActivityUIDismissalPolicy) {
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        lastSentAt = .distantPast
        let final = ActivityContent(state: state, staleDate: nil)
        let id = activity.id
        Task { await Self.end(id, final, dismissal: dismissal) }
    }

    // `Activity` is not `Sendable`, and its `update` and `end` are nonisolated async.
    // Calling them on an instance that lives on the main actor — held in a property, or
    // just looked up from main-actor code — sends it off the actor, and Swift 6 refuses
    // to compile that. So the lookup and the call happen together off the actor: only an
    // id and the content, which are both `Sendable`, cross over.

    @concurrent
    nonisolated private static func update(_ id: String,
                                           _ content: ActivityContent<ChargeActivityContentState>) async {
        await activity(id)?.update(content)
    }

    @concurrent
    nonisolated private static func end(_ id: String,
                                        _ content: ActivityContent<ChargeActivityContentState>?,
                                        dismissal: ActivityUIDismissalPolicy) async {
        await activity(id)?.end(content, dismissalPolicy: dismissal)
    }

    nonisolated private static func activity(_ id: String) -> Activity<ChargeActivityAttributes>? {
        Activity<ChargeActivityAttributes>.activities.first { $0.id == id }
    }

    private func content(
        for state: ChargeActivityContentState
    ) -> ActivityContent<ChargeActivityContentState> {
        ActivityContent(state: state,
                        staleDate: state.date.addingTimeInterval(Self.staleAfter))
    }

    /// Whether a reading has moved enough to be worth an update on its own.
    private static func differs(
        _ old: ChargeActivityContentState,
        _ new: ChargeActivityContentState
    ) -> Bool {
        let oldReading = old.reading
        let newReading = new.reading
        return old.selectedMetric != new.selectedMetric
            || oldReading.percent != newReading.percent
            || oldReading.source != newReading.source
            || oldReading.isCharging != newReading.isCharging
            || oldReading.isOnHold != newReading.isOnHold
            || oldReading.isFull != newReading.isFull
            || abs((oldReading.watts ?? -1) - (newReading.watts ?? -1)) >= 0.2
            || abs((oldReading.batteryTemperature ?? 0)
                   - (newReading.batteryTemperature ?? 0)) >= 0.5
            || abs((old.socTemperature ?? 0) - (new.socTemperature ?? 0)) >= 0.5
            || abs((old.hottestTemperature ?? 0) - (new.hottestTemperature ?? 0)) >= 0.5
            || old.hottestSensorName != new.hottestSensorName
    }

    private static func contentState(
        from snapshot: PowerSnapshot,
        selectedMetric: LiveActivityMetric
    ) -> ChargeActivityContentState {
        ChargeActivityContentState(
            reading: ChargeReading(snapshot),
            socTemperature: snapshot.socTemperature,
            hottestTemperature: snapshot.hottestSensor?.value,
            hottestSensorName: snapshot.hottestSensor?.name,
            selectedMetric: selectedMetric
        )
    }
}
