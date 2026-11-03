import ActivityKit
import Foundation

/// Pilote la Live Activity affichée sur l'écran verrouillé, la Dynamic Island et le Dashboard CarPlay.
///
/// iOS limite la fréquence des mises à jour (budget non publié par Apple) : au-delà, il ne les affiche plus
/// que toutes les 5 à 15 s tant que l'écran de l'iPhone est éteint. Pour ménager ce budget, on n'envoie une
/// mise à jour que si une valeur change de façon visible (au plus une par `minInterval`), sinon toutes les 5 s.
@MainActor
final class LiveActivityController {
    private(set) var activity: Activity<TelemetryAttributes>?
    private var lastSent = Date.distantPast
    private var latest: TelemetryAttributes.ContentState?
    private var lastSentState: TelemetryAttributes.ContentState?
    /// Envoi « de maintien » quand rien ne bouge (garde la Live Activity fraîche).
    private let heartbeat: TimeInterval = 5
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

    /// Reprend la Live Activity d'un lancement précédent (l'app a pu être relancée en arrière-plan,
    /// où iOS n'autorise pas à en créer une nouvelle). Renvoie vrai si une activité est reprise.
    func adoptExisting() -> Bool {
        let running = Activity<TelemetryAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        guard let current = running.first else { return false }
        for extra in running.dropFirst() {
            Task { await extra.end(nil, dismissalPolicy: .immediate) }
        }
        activity = current
        return true
    }

    func start(attributes: TelemetryAttributes, state: TelemetryAttributes.ContentState) throws {
        // Une seule Live Activity à la fois : on ferme celles d'une session précédente.
        for old in Activity<TelemetryAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        lastSent = Date()
    }

    /// Transmet le dernier état. Envoi seulement si un changement est visible (au plus une fois par
    /// `minInterval`), ou toutes les `heartbeat` secondes si rien ne bouge.
    func submit(_ state: TelemetryAttributes.ContentState) {
        guard activity != nil else { return }
        latest = state

        let elapsed = Date().timeIntervalSince(lastSent)
        let significant = lastSentState.map { Self.visiblyDifferent(state, from: $0) } ?? true
        if significant {
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
        } else if elapsed >= heartbeat {
            flush()
        }
    }

    /// Vrai si l'affichage changerait de façon perceptible.
    private static func visiblyDifferent(_ a: TelemetryAttributes.ContentState, from b: TelemetryAttributes.ContentState) -> Bool {
        func moved(_ x: Double?, _ y: Double?, by threshold: Double) -> Bool {
            switch (x, y) {
            case let (x?, y?): return abs(x - y) >= threshold
            case (nil, nil): return false
            default: return true
            }
        }
        return a.connected != b.connected
            || a.statusText != b.statusText
            || moved(a.boostBar, b.boostBar, by: 0.05)
            || moved(a.powerCh, b.powerCh, by: 5)
            || moved(a.coolantC, b.coolantC, by: 1)
            || moved(a.oilC, b.oilC, by: 1)
            || moved(a.rpm, b.rpm, by: 150)
            || moved(a.intakeAirC, b.intakeAirC, by: 2)
            || moved(a.peakBoostBar, b.peakBoostBar, by: 0.05)
            || moved(a.peakPowerCh, b.peakPowerCh, by: 5)
    }

    private func flush() {
        guard let activity, let state = latest else { return }
        latest = nil
        lastSentState = state
        lastSent = Date()
        sentTimes.append(lastSent)
        if sentTimes.count > 200 { sentTimes.removeFirst(sentTimes.count - 200) }
        // Si l'app cesse de mettre à jour (adaptateur perdu), la Live Activity affichera « Signal perdu ».
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(max(20, heartbeat * 4)))
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
