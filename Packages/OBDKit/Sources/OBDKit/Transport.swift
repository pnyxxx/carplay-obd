import Foundation

/// Lien série vers un adaptateur ELM327 (Bluetooth LE, simulateur…).
public protocol ELMTransport: AnyObject, Sendable {
    /// Envoie une commande (sans le « \r » final) et renvoie tout ce qui a été reçu jusqu'au prompt « > ».
    func send(_ command: String, timeout: Duration) async throws -> String
}

public enum TransportError: Error, Equatable, Sendable, CustomStringConvertible {
    case timeout
    case disconnected
    case notReady
    case busy

    public var description: String {
        switch self {
        case .timeout: return "Pas de réponse de l'adaptateur (délai dépassé)"
        case .disconnected: return "Adaptateur déconnecté"
        case .notReady: return "Adaptateur pas prêt"
        case .busy: return "Une commande est déjà en cours"
        }
    }
}

extension Duration {
    /// Durée en secondes (Double).
    public var inSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
