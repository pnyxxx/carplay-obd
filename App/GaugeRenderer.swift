import SwiftUI
import UIKit

/// Données figées pour dessiner une image de jauges (images de l'app CarPlay).
struct GaugeSnapshot: Equatable {
    var boostBar: Double?
    var peakBoostBar: Double?
    var targetBar: Double?
    var rpm: Double?
    var coolantC: Double?
    var intakeAirC: Double?
    var connected: Bool
    var boostMaxBar: Double
    var rpmMax: Double
    var redlineRPM: Double
}

/// Transforme les jauges SwiftUI en images (UIImage) pour les endroits qui n'acceptent que des images.
@MainActor
enum GaugeRenderer {
    /// Petit cadran de turbo seul (images de liste CarPlay).
    static func boostIcon(_ snapshot: GaugeSnapshot, size: CGSize, scale: CGFloat) -> UIImage? {
        let view = ArcGauge(
            fraction: snapshot.boostBar.map { $0 / max(snapshot.boostMaxBar, 0.5) },
            peakFraction: snapshot.peakBoostBar.map { $0 / max(snapshot.boostMaxBar, 0.5) },
            lineWidth: max(3, size.width / 9)
        )
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.uiImage
    }

    /// Petite barre de régime (images de liste CarPlay).
    static func rpmIcon(_ snapshot: GaugeSnapshot, size: CGSize, scale: CGFloat) -> UIImage? {
        let view = VStack {
            Spacer(minLength: 0)
            RPMBar(rpm: snapshot.rpm, rpmMax: snapshot.rpmMax, redline: snapshot.redlineRPM, height: size.height / 3)
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return renderer.uiImage
    }
}
