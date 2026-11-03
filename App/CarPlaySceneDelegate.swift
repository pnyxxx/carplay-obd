import CarPlay
import UIKit

/// Vraie app CarPlay (icône sur l'écran d'accueil CarPlay), catégorie « driving task ».
///
/// ⚠️ iOS n'affiche cette app dans CarPlay que si la signature contient le droit
/// `com.apple.developer.carplay-driving-task`, accordé par Apple à un compte développeur payant.
/// Sans ce droit, ce code est simplement inactif (la scène CarPlay ne se connecte jamais).
///
/// Usage privé sur circuit : on ignore volontairement la consigne d'Apple « pas plus d'un
/// rafraîchissement toutes les 10 s » et on met à jour 5 fois par seconde.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var refreshTask: Task<Void, Never>?
    private var carScale: CGFloat = 2

    private let boostItem = CPListItem(text: "Turbo", detailText: nil, image: nil)
    private let rpmItem = CPListItem(text: "Régime", detailText: nil, image: nil)
    private let coolantItem = CPListItem(text: "Eau", detailText: nil, image: UIImage(systemName: "thermometer.medium"))
    private let airItem = CPListItem(text: "Air admission", detailText: nil, image: UIImage(systemName: "wind"))
    private let connectionItem = CPListItem(text: "Connexion", detailText: nil, image: UIImage(systemName: "antenna.radiowaves.left.and.right"))
    private var lastTexts: [ObjectIdentifier: String] = [:]

    // MARK: - Cycle de vie CarPlay

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        carScale = max(1, interfaceController.carTraitCollection.displayScale)

        boostItem.handler = { _, completion in
            TelemetryStore.shared.resetPeak()
            completion()
        }
        connectionItem.handler = { _, completion in
            let store = TelemetryStore.shared
            if store.isRunning { store.stop(keepLiveActivity: true) } else { store.start(.adapter) }
            completion()
        }

        let gauges = CPListSection(items: [boostItem, rpmItem, coolantItem, airItem], header: "Moteur", sectionIndexTitle: nil)
        let controls = CPListSection(items: [connectionItem], header: nil, sectionIndexTitle: nil)
        let template = CPListTemplate(title: "TrackGauge", sections: [gauges, controls])
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController) {
        refreshTask?.cancel()
        refreshTask = nil
        self.interfaceController = nil
    }

    // MARK: - Mise à jour

    private func refresh() {
        let store = TelemetryStore.shared
        let snapshot = store.gaugeSnapshot
        let imageSize = CPListItem.maximumImageSize

        update(boostItem,
               text: "Turbo  \(Format.boost(snapshot.boostBar)) bar",
               detail: "max \(Format.boost(snapshot.peakBoostBar))" + (snapshot.targetBar.map { " · consigne \(Format.boost($0))" } ?? "") + " — toucher pour remettre à zéro",
               image: GaugeRenderer.boostIcon(snapshot, size: imageSize, scale: carScale))
        update(rpmItem,
               text: "\(Format.rpm(snapshot.rpm)) tr/min",
               detail: snapshot.rpm.map { $0 >= snapshot.redlineRPM ? "ZONE ROUGE" : "" } ?? "",
               image: GaugeRenderer.rpmIcon(snapshot, size: imageSize, scale: carScale))
        update(coolantItem, text: "Eau  \(Format.temp(snapshot.coolantC))", detail: nil, image: nil)
        update(airItem, text: "Air admission  \(Format.temp(snapshot.intakeAirC))", detail: nil, image: nil)
        update(connectionItem,
               text: store.isRunning ? "Arrêter la lecture OBD" : "Démarrer la lecture OBD",
               detail: snapshot.connected ? (store.adapterName ?? "Connecté") : "Non connecté",
               image: nil)
    }

    /// Ne touche à l'élément que si son contenu a changé.
    private func update(_ item: CPListItem, text: String, detail: String?, image: UIImage?) {
        let key = ObjectIdentifier(item)
        let signature = text + "|" + (detail ?? "")
        if lastTexts[key] != signature {
            lastTexts[key] = signature
            item.setText(text)
            item.setDetailText(detail)
        }
        if let image {
            item.setImage(image)
        }
    }
}
