import ActivityKit
import Foundation

/// Données de la Live Activity (écran verrouillé, Dynamic Island, CarPlay).
/// Partagé entre l'app et l'extension : garder ce fichier identique pour les deux cibles.
struct TelemetryAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Pression de turbo relative (bar).
        var boostBar: Double?
        /// Max de turbo maintenu quelques secondes après le pic (nil = rien à signaler).
        var peakBoostBar: Double?
        var rpm: Double?
        var coolantC: Double?
        var intakeAirC: Double?
        /// Puissance instantanée (ch).
        var powerCh: Double?
        /// Max de puissance maintenu quelques secondes après le pic.
        var peakPowerCh: Double?
        var connected: Bool
        var statusText: String
    }

    /// Échelle des jauges (fixée au démarrage de la Live Activity).
    var boostMaxBar: Double
    var rpmMax: Double
    var redlineRPM: Double
    /// Échelle de la barre de puissance (ch). Optionnel : compatible avec une Live Activity déjà en cours.
    var maxPowerCh: Double?
}

extension TelemetryAttributes.ContentState {
    static let waiting = TelemetryAttributes.ContentState(
        boostBar: nil, peakBoostBar: nil, rpm: nil, coolantC: nil, intakeAirC: nil, powerCh: nil, peakPowerCh: nil,
        connected: false, statusText: "Connexion…"
    )
}
