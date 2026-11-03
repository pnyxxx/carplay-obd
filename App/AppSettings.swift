import Foundation
import OBDKit

/// Réglages persistants (UserDefaults, JSON).
struct AppSettings: Codable, Equatable {
    // Véhicule (valeurs par défaut : BMW 320d E90, moteur N47/M47)
    var boostMaxBar: Double = 2.0
    var rpmMax: Double = 5000
    var redlineRPM: Double = 4500
    /// Durée d'affichage du max de turbo après le pic (s).
    var peakHoldSeconds: Double = 5

    // CarPlay / Live Activity
    var autoStartLiveActivity = true
    var liveActivityInterval: Double = 1.0

    // Démarrage automatique
    var autoConnect = true

    // Arrière-plan
    var keepAliveWithGPS = true

    // OBD (expert)
    var multiPID = true
    var responseCount = true
    var aggressiveTiming = true
    var physicalAddressing = true
    var boostSource: String = "auto"   // "auto" ou BoostSource.rawValue
    var verboseLog = false

    // Adaptateur mémorisé
    var savedAdapterID: UUID?
    var savedAdapterName: String?

    var sessionConfig: SessionConfig {
        var config = SessionConfig()
        config.multiPID = multiPID
        config.responseCount = responseCount
        config.aggressiveTiming = aggressiveTiming
        config.physicalAddressing = physicalAddressing
        config.forcedBoostSource = BoostSource(rawValue: boostSource)
        return config
    }

    private static let key = "settings.v1"

    /// Les réglages enregistrés sont superposés aux valeurs par défaut :
    /// ajouter un réglage dans une nouvelle version n'efface pas les autres.
    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultsData = try? JSONEncoder().encode(AppSettings()),
              var merged = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any] else {
            return AppSettings()
        }
        merged.merge(saved) { _, savedValue in savedValue }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: mergedData) else {
            return AppSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
