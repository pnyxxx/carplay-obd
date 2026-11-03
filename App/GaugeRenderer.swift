import SwiftUI
import UIKit

/// Données figées pour dessiner une image de jauges (pochette « À l'écoute », images CarPlay).
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
    /// Grande image carrée : cadran de turbo, régime, barre shift-light, températures.
    static func artwork(_ snapshot: GaugeSnapshot, side: CGFloat = 600) -> UIImage? {
        let renderer = ImageRenderer(content: ArtworkView(snapshot: snapshot).frame(width: side, height: side))
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

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

/// Pochette affichée dans l'écran « À l'écoute » de CarPlay.
private struct ArtworkView: View {
    let snapshot: GaugeSnapshot

    var body: some View {
        let scale = max(snapshot.boostMaxBar, 0.5)
        ZStack {
            Color.black
            VStack(spacing: 18) {
                ZStack {
                    ArcGauge(
                        fraction: snapshot.boostBar.map { $0 / scale },
                        peakFraction: snapshot.peakBoostBar.map { $0 / scale },
                        targetFraction: snapshot.targetBar.map { $0 / scale },
                        lineWidth: 34,
                        showNeedle: true
                    )
                    VStack(spacing: -6) {
                        Text(Format.boost(snapshot.boostBar))
                            .font(.system(size: 92, weight: .bold, design: .rounded).monospacedDigit())
                        Text("bar turbo")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    .offset(y: 96)
                }
                .frame(width: 380, height: 380)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.rpm(snapshot.rpm))
                        .font(.system(size: 64, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(GaugePalette.rpm(snapshot.rpm, redline: snapshot.redlineRPM))
                    Text("tr/min").font(.system(size: 24)).foregroundStyle(Color.white.opacity(0.6))
                    Spacer()
                    Text(Format.temp(snapshot.coolantC))
                        .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(GaugePalette.coolant(snapshot.coolantC))
                }
                RPMBar(rpm: snapshot.rpm, rpmMax: snapshot.rpmMax, redline: snapshot.redlineRPM, height: 26)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 20)
            .foregroundStyle(.white)

            if !snapshot.connected {
                Text("PAS DE SIGNAL")
                    .font(.system(size: 40, weight: .heavy))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color.orange, in: Capsule())
                    .foregroundStyle(.black)
            }
        }
    }
}
