import AppIntents

/// « Démarrer la télémétrie » : à lancer par l'automatisation Raccourcis « Quand CarPlay se connecte ».
/// LiveActivityIntent : iOS autorise ici à créer la Live Activity même si l'app est en arrière-plan.
struct StartTelemetryIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Démarrer la télémétrie"

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = TelemetryStore.shared
        store.wake()
        if store.settings.autoStartLiveActivity && !store.liveActivityActive {
            store.startLiveActivity()
        }
        // iOS laisse l'app tourner pendant l'exécution du raccourci : on en profite pour
        // aller jusqu'à la connexion avec la voiture (20 s maximum).
        let deadline = Date().addingTimeInterval(20)
        while !store.isConnected && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .result()
    }
}

/// « Arrêter la télémétrie » : pour l'automatisation « Quand CarPlay se déconnecte ».
struct StopTelemetryIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Arrêter la télémétrie"

    @MainActor
    func perform() async throws -> some IntentResult {
        TelemetryStore.shared.stop(byUser: false)
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
