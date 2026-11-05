import ActivityKit
import Foundation

/// Pilote la Live Activity affichée sur l'écran verrouillé, la Dynamic Island et le Dashboard CarPlay.
///
/// iOS accorde aux Live Activities un budget de mises à jour qui se recharge lentement (non publié par Apple).
/// Une fois épuisé, il ne les affiche plus que toutes les 15 à 20 s tant que l'écran de l'iPhone est éteint
/// (constaté : épuisé en ~1 min à 2 envois/s, en ~5 min en n'envoyant que les changements visibles).
/// On tient donc notre propre réserve, plus prudente que celle d'iOS : pleine, on envoie tout changement visible ;
/// à mesure qu'elle baisse, seuls les changements de plus en plus importants partent. Le rythme moyen reste
/// ainsi soutenable sans fin, au lieu de geler au bout de quelques minutes.
@MainActor
final class LiveActivityController {
    struct Budget: Equatable {
        /// Nombre d'envois que la réserve peut contenir.
        var capacity: Double
        /// Envois regagnés par seconde (rythme moyen soutenable).
        var refillPerSecond: Double
    }

    enum Pace: String, CaseIterable {
        case fast, balanced, eco

        /// nil = pas de réserve : tout changement visible part (iOS finit par geler l'affichage).
        var budget: Budget? {
            switch self {
            case .fast: return nil
            case .balanced: return Budget(capacity: 100, refillPerSecond: 0.4)   // 24 / min en moyenne
            case .eco: return Budget(capacity: 60, refillPerSecond: 0.25)        // 15 / min en moyenne
            }
        }

        var label: String {
            switch self {
            case .fast: return "Maximum (sans limite)"
            case .balanced: return "Équilibré (conseillé)"
            case .eco: return "Économe"
            }
        }
    }

    private(set) var activity: Activity<TelemetryAttributes>?
    private var lastSent = Date.distantPast
    private var latest: TelemetryAttributes.ContentState?
    private var lastSentState: TelemetryAttributes.ContentState?
    /// Envoi « de maintien » quand rien ne bouge (garde la Live Activity fraîche).
    private let heartbeat: TimeInterval = 10
    private var flushTask: Task<Void, Never>?
    private var sentTimes: [Date] = []

    /// Intervalle minimal entre deux mises à jour (s).
    var minInterval: TimeInterval = 1

    /// Réserve d'envois (nil = illimitée).
    var budget: Budget? = Pace.balanced.budget {
        didSet {
            if let budget { tokens = min(tokens, budget.capacity) } else { tokens = 0 }
            if oldValue == nil, let budget { tokens = budget.capacity }
        }
    }
    private var tokens: Double = Pace.balanced.budget?.capacity ?? 0
    private var lastRefill = Date()

    /// Relance périodique : une Live Activity neuve repart avec un budget iOS neuf (constaté : tout relancer
    /// redonne 4-5 min de temps réel). nil = désactivée.
    var rotationInterval: TimeInterval? = 240
    private var activityStart = Date()
    private var nextRotationAttempt = Date.distantPast
    /// Événements à noter dans le journal (relance réussie ou refusée).
    var onEvent: ((String) -> Void)?

    /// Compte rendu chaque minute (pour le journal) : envois de la minute écoulée, réserve restante.
    var onMinuteReport: ((Int, Double?) -> Void)?
    private var lastReport = Date()

    /// Réserve restante (0…1), nil si illimitée.
    var reserve: Double? {
        guard let budget else { return nil }
        refill()
        return tokens / budget.capacity
    }

    private func refill() {
        let now = Date()
        if let budget {
            tokens = min(budget.capacity, tokens + now.timeIntervalSince(lastRefill) * budget.refillPerSecond)
        }
        lastRefill = now
    }

    /// Un envoi est-il permis par la réserve ?
    private var canSpend: Bool { budget == nil || tokens >= 1 }

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
        activityStart = Date()
        return true
    }

    func start(attributes: TelemetryAttributes, state: TelemetryAttributes.ContentState) throws {
        // Une seule Live Activity à la fois : on ferme celles d'une session précédente.
        for old in Activity<TelemetryAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(30))
        activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
        activityStart = Date()
        lastSent = Date()
    }

    /// Crée une Live Activity neuve puis ferme l'ancienne, seulement si iOS accepte la nouvelle
    /// (iOS peut refuser quand l'app est en arrière-plan : l'ancienne continue alors, rien ne disparaît).
    private func rotateIfNeeded(with state: TelemetryAttributes.ContentState) {
        guard let rotationInterval, activity != nil,
              Date().timeIntervalSince(activityStart) >= rotationInterval,
              Date() >= nextRotationAttempt else { return }
        rotateNow(with: state)
    }

    /// Relance immédiate (raccourci « Relancer l'affichage CarPlay ») : budget iOS neuf.
    @discardableResult
    func rotateNow(with state: TelemetryAttributes.ContentState) -> Bool {
        guard let current = activity else { return false }
        do {
            let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(max(20, heartbeat * 4)))
            let fresh = try Activity.request(attributes: current.attributes, content: content, pushType: nil)
            activity = fresh
            activityStart = Date()
            lastSent = Date()
            lastSentState = state
            sentTimes.append(lastSent)
            Task { await current.end(nil, dismissalPolicy: .immediate) }
            onEvent?("Live Activity relancée (budget iOS neuf)")
            return true
        } catch {
            nextRotationAttempt = Date().addingTimeInterval(30)
            onEvent?("Relance de la Live Activity refusée par iOS : \(error.localizedDescription)")
            return false
        }
    }

    /// Transmet le dernier état. Part si le changement est assez important pour la réserve restante
    /// (au plus une fois par `minInterval`), ou toutes les `heartbeat` secondes si rien ne bouge.
    func submit(_ state: TelemetryAttributes.ContentState) {
        guard activity != nil else { return }
        rotateIfNeeded(with: state)
        latest = state
        refill()
        reportIfNeeded()

        let elapsed = Date().timeIntervalSince(lastSent)
        let importance = lastSentState.map { Self.importance(state, from: $0) } ?? .infinity
        // Réserve pleine : tout changement visible (importance ≥ 1) part. Réserve vide : il faut un changement
        // 4 fois plus grand (ex. 0,2 bar de turbo, 20 ch). Les changements d'état passent toujours.
        let scarcity = budget.map { 1 - min(max(tokens / $0.capacity, 0), 1) } ?? 0
        let threshold = 1 + 3 * scarcity
        let significant = importance >= threshold && (canSpend || importance >= 100)
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
        } else if elapsed >= heartbeat && canSpend {
            flush()
        }
    }

    /// Importance d'un changement, en « pas visibles » (1 = juste perceptible) ; 100 = changement d'état.
    private static func importance(_ a: TelemetryAttributes.ContentState, from b: TelemetryAttributes.ContentState) -> Double {
        if a.connected != b.connected || a.statusText != b.statusText { return 100 }
        func steps(_ x: Double?, _ y: Double?, per step: Double) -> Double {
            switch (x, y) {
            case let (x?, y?): return abs(x - y) / step
            case (nil, nil): return 0
            default: return 10   // valeur qui apparaît ou disparaît (ex. pastille MAX)
            }
        }
        return [
            steps(a.boostBar, b.boostBar, per: 0.05),
            steps(a.powerCh, b.powerCh, per: 5),
            steps(a.coolantC, b.coolantC, per: 1),
            steps(a.oilC, b.oilC, per: 1),
            steps(a.rpm, b.rpm, per: 150),
            steps(a.intakeAirC, b.intakeAirC, per: 2),
            steps(a.peakBoostBar, b.peakBoostBar, per: 0.05),
            steps(a.peakPowerCh, b.peakPowerCh, per: 5),
        ].max() ?? 0
    }

    private func reportIfNeeded() {
        guard Date().timeIntervalSince(lastReport) >= 60 else { return }
        lastReport = Date()
        onMinuteReport?(updatesLastMinute, reserve)
    }

    private func flush() {
        guard let activity, let state = latest else { return }
        refill()
        latest = nil
        lastSentState = state
        if budget != nil { tokens = max(0, tokens - 1) }
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
