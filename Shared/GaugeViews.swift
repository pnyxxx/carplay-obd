import SwiftUI

/// Briques graphiques communes à l'app et à la Live Activity (pas d'UIKit ici).

struct GaugeZone {
    /// Borne haute de la zone, en fraction de l'échelle (0…1).
    var upTo: Double
    var color: Color
}

enum GaugePalette {
    static let boost: [GaugeZone] = [
        GaugeZone(upTo: 0.6, color: .cyan),
        GaugeZone(upTo: 0.85, color: .orange),
        GaugeZone(upTo: 2, color: .red),
    ]

    static func color(for fraction: Double, zones: [GaugeZone]) -> Color {
        zones.first(where: { fraction <= $0.upTo })?.color ?? zones.last?.color ?? .white
    }

    static func coolant(_ celsius: Double?) -> Color {
        guard let celsius else { return .gray }
        if celsius < 70 { return .blue }
        if celsius < 106 { return .green }
        return .red
    }

    static func rpm(_ rpm: Double?, redline: Double) -> Color {
        guard let rpm else { return .gray }
        if rpm >= redline { return .red }
        if rpm >= redline * 0.85 { return .orange }
        return .white
    }
}

enum Format {
    static func boost(_ bar: Double?) -> String {
        guard let bar else { return "—" }
        return String(format: "%.2f", bar)
    }

    static func boostShort(_ bar: Double?) -> String {
        guard let bar else { return "—" }
        return String(format: "%.1f", bar)
    }

    static func rpm(_ rpm: Double?) -> String {
        guard let rpm else { return "—" }
        return String(Int(rpm.rounded()))
    }

    static func temp(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return "\(Int(celsius.rounded()))°"
    }
}

/// Jauge en arc de 270° (de 7 h à 5 h), avec repères de pic et de consigne et aiguille optionnelle.
struct ArcGauge: View {
    var fraction: Double?
    var peakFraction: Double?
    var targetFraction: Double?
    var zones: [GaugeZone] = GaugePalette.boost
    var lineWidth: CGFloat = 8
    var showNeedle = false
    var trackColor: Color = .gray.opacity(0.3)

    private let sweep = 0.75
    private let startDegrees = 135.0

    var body: some View {
        let value = clamp(fraction ?? 0)
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(trackColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(startDegrees))

            if fraction != nil {
                Circle()
                    .trim(from: 0, to: sweep * value)
                    .stroke(GaugePalette.color(for: value, zones: zones), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(startDegrees))
            }

            if let targetFraction {
                tick(targetFraction, color: .yellow)
            }
            if let peakFraction {
                tick(peakFraction, color: .white)
            }

            if showNeedle && fraction != nil {
                GeometryReader { geo in
                    let radius = min(geo.size.width, geo.size.height) / 2
                    Capsule()
                        .fill(Color.white)
                        .frame(width: radius * 0.92, height: max(3, lineWidth * 0.35))
                        .offset(x: radius * 0.46)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .rotationEffect(.degrees(startDegrees + 360 * sweep * value))
                        .shadow(color: .black.opacity(0.6), radius: 2)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: lineWidth * 1.4, height: lineWidth * 1.4)
            }
        }
        .padding(lineWidth / 2)
    }

    /// Petit repère sur l'arc (segment d'arc plus épais que la piste).
    private func tick(_ fraction: Double, color: Color) -> some View {
        let position = sweep * clamp(fraction)
        return Circle()
            .trim(from: max(0, position - 0.006), to: min(sweep, position + 0.006))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth * 1.7, lineCap: .butt))
            .rotationEffect(.degrees(startDegrees))
    }

    private func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
}

/// Pastille du max de turbo maintenu (quelques secondes après le pic).
struct PeakBadge: View {
    let value: Double
    var font: Font = .caption.weight(.heavy)

    var body: some View {
        Text("MAX \(Format.boost(value))")
            .font(font.monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.orange, in: Capsule())
            .foregroundStyle(.black)
    }
}

/// Barre de régime façon shift-light.
struct RPMBar: View {
    var rpm: Double?
    var rpmMax: Double
    var redline: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max((rpm ?? 0) / max(rpmMax, 1), 0), 1)
            let redStart = min(max(redline / max(rpmMax, 1), 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.3))
                Rectangle()
                    .fill(Color.red.opacity(0.35))
                    .frame(width: geo.size.width * (1 - redStart))
                    .offset(x: geo.size.width * redStart)
                Capsule()
                    .fill(GaugePalette.rpm(rpm, redline: redline))
                    .frame(width: max(height, geo.size.width * fraction))
                    .opacity(rpm == nil ? 0 : 1)
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}
