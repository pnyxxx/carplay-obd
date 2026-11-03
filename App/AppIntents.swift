import AppIntents

/// « Démarrer la télémétrie » : utilisable dans Raccourcis, avec Siri, ou en automatisation
/// « Quand CarPlay se connecte » pour que tout démarre tout seul en montant dans la voiture.
/// LiveActivityIntent permet de lancer la Live Activity même si l'app est en arrière-plan.
struct StartTelemetryIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Démarrer la télémétrie"

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = TelemetryStore.shared
        if !store.isRunning {
            store.start(.adapter)
        }
        if store.settings.autoStartLiveActivity && !store.liveActivityActive {
            store.startLiveActivity()
        }
        return .result()
    }
}

struct StopTelemetryIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter la télémétrie"

    @MainActor
    func perform() async throws -> some IntentResult {
        TelemetryStore.shared.stop()
        return .result()
    }
}

struct TrackGaugeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTelemetryIntent(),
            phrases: ["Démarrer \(.applicationName)", "Lancer la télémétrie \(.applicationName)"],
            shortTitle: "Démarrer",
            systemImageName: "gauge.with.dots.needle.67percent"
        )
        AppShortcut(
            intent: StopTelemetryIntent(),
            phrases: ["Arrêter \(.applicationName)"],
            shortTitle: "Arrêter",
            systemImageName: "stop.circle"
        )
    }
}
