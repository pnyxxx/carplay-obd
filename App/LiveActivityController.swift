import ActivityKit
import Foundation

/// Pilote la Live Activity affichée sur l'écran verrouillé, la Dynamic Island et le Dashboard CarPlay.
///
/// iOS limite la fréquence des mises à jour (budget non publié par Apple) : on envoie au plus une mise à jour
/// par intervalle réglable, et on transmet le pic de turbo de l'intervalle pour ne rien rater.
@MainActor
final class LiveActivityController {
    private(set) var activity: Activity<TelemetryAttributes>?
    private var lastSent = Date.distantPast
    private var latest: TelemetryAttributes.ContentState?
    private var peakSinceLastSend: Double?
    private var flushTask: Task<Void, Never>?
    private var sentTimes: [Date] = []

    /// Intervalle minimal entre deux mises à jour (s).
    var minInterval: TimeInterval = 1

    var isActive: Bool {
        guard let activity else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Mises à jour envoyées pendant la dernière minute (diagnostic).
    var updatesLastMinute: Int {
        let limit = Date().addingTimeInterval(-60)
        return sentTimes.filter { $0 > limit }.count
    }

    func start(attributes: TelemetryAttributes, state: TelemetryAttributes.ContentState) throws {
        // Une seule Live Activity à la fois : on ferme celles d'une session précédente.
        for old in Activity<TelemetryAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        lastSent = Date()
        peakSinceLastSend = nil
    }

    /// Transmet le dernier état ; l'envoi réel est limité à `minInterval`.
    func submit(_ state: TelemetryAttributes.ContentState) {
        guard activity != nil else { return }
        latest = state
        if let boost = state.boostBar {
            peakSinceLastSend = max(peakSinceLastSend ?? boost, boost)
        }

        let elapsed = Date().timeIntervalSince(lastSent)
        if elapsed >= minInterval {
            flush()
        } else if flushTask == nil {
            let delay = minInterval - elapsed
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.flushTask = nil
                self?.flush()
            }
        }
    }

    private func flush() {
        guard let activity, var state = latest else { return }
        state.peakBoostBar = peakSinceLastSend ?? state.boostBar
        peakSinceLastSend = nil
        latest = nil
        lastSent = Date()
        sentTimes.append(lastSent)
        if sentTimes.count > 200 { sentTimes.removeFirst(sentTimes.count - 200) }
        // Si l'app cesse de mettre à jour (adaptateur perdu), la Live Activity affichera « Signal perdu ».
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(max(15, minInterval * 5)))
        Task { await activity.update(content) }
    }

    func stop() {
        flushTask?.cancel()
        flushTask = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
