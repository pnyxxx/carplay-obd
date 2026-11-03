import ActivityKit
import Foundation

/// Données de la Live Activity (écran verrouillé, Dynamic Island, CarPlay).
/// Partagé entre l'app et l'extension : garder ce fichier identique pour les deux cibles.
struct TelemetryAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// Pression de turbo relative (bar).
        var boostBar: Double?
        /// Pic de turbo depuis la dernière mise à jour : on ne rate pas les pointes entre deux rafraîchissements.
        var peakBoostBar: Double?
        var rpm: Double?
        var coolantC: Double?
        var intakeAirC: Double?
        var connected: Bool
        var statusText: String
    }

    /// Échelle des jauges (fixée au démarrage de la Live Activity).
    var boostMaxBar: Double
    var rpmMax: Double
    var redlineRPM: Double
}

extension TelemetryAttributes.ContentState {
    static let waiting = TelemetryAttributes.ContentState(
        boostBar: nil, peakBoostBar: nil, rpm: nil, coolantC: nil, intakeAirC: nil,
        connected: false, statusText: "Connexion…"
    )
}
