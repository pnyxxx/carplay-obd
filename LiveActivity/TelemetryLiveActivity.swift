import ActivityKit
import SwiftUI
import WidgetKit

@main
struct TrackGaugeWidgets: WidgetBundle {
    var body: some Widget {
        TelemetryLiveActivity()
    }
}

/// Live Activity : écran verrouillé, Dynamic Island, et CarPlay (iOS 26+) via la famille « small ».
/// Guide CarPlay d'Apple (oct. 2026) : « To enable your Live Activity in CarPlay, support the small activity family. »
struct TelemetryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TelemetryAttributes.self) { context in
            TelemetryActivityView(context: context)
        } dynamicIsland: { context in
            let state = context.state
            let attributes = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BoostDial(state: state, attributes: attributes, lineWidth: 6)
                        .frame(width: 64, height: 64)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.rpm(state.rpm))
                            .font(.title2.monospacedDigit().weight(.bold))
                            .foregroundStyle(GaugePalette.rpm(state.rpm, redline: attributes.redlineRPM))
                        Text("tr/min").font(.caption2).foregroundStyle(.secondary)
                        Text("Eau \(Format.temp(state.coolantC))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(GaugePalette.coolant(state.coolantC))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RPMBar(rpm: state.rpm, rpmMax: attributes.rpmMax, redline: attributes.redlineRPM, height: 8)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .foregroundStyle(.cyan)
                    Text(Format.boostShort(state.boostBar))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
            } compactTrailing: {
                Text(Format.rpm(state.rpm))
                    .monospacedDigit()
                    .foregroundStyle(GaugePalette.rpm(state.rpm, redline: attributes.redlineRPM))
            } minimal: {
                Text(Format.boostShort(state.boostBar))
                    .monospacedDigit()
                    .foregroundStyle(.cyan)
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Choisit la mise en page selon l'endroit où le système affiche la Live Activity.
struct TelemetryActivityView: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<TelemetryAttributes>

    var body: some View {
        switch family {
        case .small:
            // CarPlay (Dashboard) et Smart Stack de l'Apple Watch.
            SmallTelemetryView(state: context.state, attributes: context.attributes, isStale: context.isStale)
        default:
            LockScreenTelemetryView(state: context.state, attributes: context.attributes, isStale: context.isStale)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        }
    }
}

/// Cadran de turbo avec la valeur au centre.
struct BoostDial: View {
    let state: TelemetryAttributes.ContentState
    let attributes: TelemetryAttributes
    var lineWidth: CGFloat = 7
    var valueFont: Font = .system(size: 17, weight: .bold, design: .rounded)

    var body: some View {
        let scale = max(attributes.boostMaxBar, 0.5)
        ZStack {
            ArcGauge(
                fraction: state.boostBar.map { $0 / scale },
                peakFraction: state.peakBoostBar.map { $0 / scale },
                lineWidth: lineWidth
            )
            VStack(spacing: -2) {
                Text(Format.boost(state.boostBar))
                    .font(valueFont.monospacedDigit())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: state.boostBar ?? 0))
                Text("bar")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, lineWidth + 2)
        }
    }
}

/// Version CarPlay / Apple Watch : très lisible, couleurs système (s'adapte au mode jour / nuit de la voiture).
struct SmallTelemetryView: View {
    let state: TelemetryAttributes.ContentState
    let attributes: TelemetryAttributes
    let isStale: Bool

    var body: some View {
        HStack(spacing: 10) {
            BoostDial(state: state, attributes: attributes, lineWidth: 7,
                      valueFont: .system(size: 19, weight: .bold, design: .rounded))
                .frame(minWidth: 62, maxWidth: 84, minHeight: 62, maxHeight: 84)

            // CarPlay : puissance en chevaux à la place du régime.
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Format.power(state.powerCh))
                        .font(.system(size: 24, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(state.powerCh == nil ? Color.secondary : Color.cyan)
                        .contentTransition(.numericText(value: state.powerCh ?? 0))
                    Text("ch").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if let peak = state.peakPowerCh {
                        Text("max \(Format.power(peak))")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                PowerBar(power: state.powerCh, peak: state.peakPowerCh, maxPower: attributes.maxPowerCh ?? 220, height: 6)
                HStack(spacing: 8) {
                    // Huile si la voiture la fournit un jour (goutte), sinon eau (thermomètre), comme avant.
                    if let oil = state.oilC {
                        Label(Format.temp(oil), systemImage: "drop.fill")
                            .foregroundStyle(GaugePalette.oil(oil))
                    } else {
                        Label(Format.temp(state.coolantC), systemImage: "thermometer.medium")
                            .foregroundStyle(GaugePalette.coolant(state.coolantC))
                    }
                    if let peak = state.peakBoostBar {
                        PeakBadge(value: peak)
                    }
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .padding(.vertical, 4)
        .opacity(isStale || !state.connected ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) {
            if isStale || !state.connected {
                Text(isStale ? "Signal perdu" : state.statusText)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
            }
        }
    }
}

/// Écran verrouillé (et bannière) : trois jauges lisibles d'un coup d'œil.
struct LockScreenTelemetryView: View {
    let state: TelemetryAttributes.ContentState
    let attributes: TelemetryAttributes
    let isStale: Bool

    var body: some View {
        HStack(spacing: 16) {
            BoostDial(state: state, attributes: attributes, lineWidth: 8,
                      valueFont: .system(size: 22, weight: .bold, design: .rounded))
                .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Format.rpm(state.rpm))
                        .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(GaugePalette.rpm(state.rpm, redline: attributes.redlineRPM))
                        .contentTransition(.numericText(value: state.rpm ?? 0))
                    Text("tr/min").font(.caption).foregroundStyle(Color.white.opacity(0.6))
                    Spacer()
                    if isStale || !state.connected {
                        Text(isStale ? "Signal perdu" : state.statusText)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }
                RPMBar(rpm: state.rpm, rpmMax: attributes.rpmMax, redline: attributes.redlineRPM, height: 9)
                HStack(spacing: 14) {
                    if let oil = state.oilC {
                        Text("Huile \(Format.temp(oil))").foregroundStyle(GaugePalette.oil(oil))
                    }
                    Label(Format.temp(state.coolantC), systemImage: "thermometer.medium")
                        .foregroundStyle(GaugePalette.coolant(state.coolantC))
                    Label(Format.temp(state.intakeAirC), systemImage: "wind")
                        .foregroundStyle(Color.white.opacity(0.8))
                    if let power = state.powerCh {
                        Text("\(Format.power(power)) ch").foregroundStyle(Color.cyan)
                    }
                    Spacer()
                    if let peak = state.peakBoostBar {
                        PeakBadge(value: peak, font: .subheadline.weight(.heavy))
                    }
                }
                .font(.subheadline.monospacedDigit().weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .opacity(isStale ? 0.5 : 1)
    }
}
