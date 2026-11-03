import OBDKit
import SwiftUI

/// Tableau de bord plein écran, en temps réel (iPhone fixé au pare-brise, portrait ou paysage).
struct DashboardView: View {
    @Environment(TelemetryStore.self) private var store
    @State private var showSettings = false
    @State private var showDevices = false

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                if landscape {
                    HStack(alignment: .top, spacing: 20) {
                        BoostPanel()
                            .frame(width: min(geo.size.height * 0.95, geo.size.width * 0.48))
                        VStack(spacing: 12) {
                            StatusBar()
                            RPMPanel()
                            TemperatureRow()
                            Spacer(minLength: 0)
                            ControlBar(showSettings: $showSettings, showDevices: $showDevices)
                        }
                    }
                    .padding(.horizontal)
                } else {
                    VStack(spacing: 14) {
                        StatusBar()
                        BoostPanel()
                        RPMPanel()
                        TemperatureRow()
                        Spacer(minLength: 0)
                        ControlBar(showSettings: $showSettings, showDevices: $showDevices)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(store)
        }
        .sheet(isPresented: $showDevices) {
            DevicePickerView().environment(store)
        }
    }
}

// MARK: - Turbo

struct BoostPanel: View {
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        let scale = max(store.settings.boostMaxBar, 0.5)
        VStack(spacing: 6) {
            ZStack {
                ArcGauge(
                    fraction: store.boostBar.map { $0 / scale },
                    peakFraction: store.peakBoostBar.map { $0 / scale },
                    targetFraction: store.boostTargetBar.map { $0 / scale },
                    lineWidth: 18,
                    showNeedle: true
                )
                .animation(.linear(duration: 0.08), value: store.boostBar ?? 0)

                GaugeScaleLabels(maxValue: scale, lineWidth: 18)

                VStack(spacing: 0) {
                    Text(Format.boost(store.boostBar))
                        .font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("bar turbo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .offset(y: 54)
            }
            .aspectRatio(1, contentMode: .fit)

            HStack(spacing: 14) {
                Button {
                    store.resetPeak()
                } label: {
                    Label("max \(Format.boost(store.peakBoostBar))", systemImage: "arrow.up.to.line")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                if let target = store.boostTargetBar {
                    Label("consigne \(Format.boost(target))", systemImage: "scope")
                        .foregroundStyle(.yellow)
                }
                if store.boostSensorSaturated {
                    Label("capteur saturé", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))

            BoostSparkline(samples: store.boostHistory, scale: scale)
                .frame(height: 44)
        }
    }
}

/// Graduations autour de l'arc (0 → max).
struct GaugeScaleLabels: View {
    let maxValue: Double
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2 - lineWidth * 2.4
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ForEach(0..<5, id: \.self) { index in
                let fraction = Double(index) / 4
                let angle = (135 + 270 * fraction) * .pi / 180
                Text(String(format: maxValue < 2.5 ? "%.1f" : "%.0f", maxValue * fraction))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            }
        }
    }
}

/// Courbe des 20 dernières secondes de turbo.
struct BoostSparkline: View {
    let samples: [TelemetryStore.BoostSample]
    let scale: Double

    var body: some View {
        GeometryReader { geo in
            let now = samples.last?.time ?? 0
            Path { path in
                for (index, sample) in samples.enumerated() {
                    let x = geo.size.width * (1 - (now - sample.time) / 20)
                    let y = geo.size.height * (1 - min(max(sample.bar / scale, 0), 1))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05))
            )
        }
    }
}

// MARK: - Régime

struct RPMPanel: View {
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        let overRedline = (store.rpm ?? 0) >= store.settings.redlineRPM
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Format.rpm(store.rpm))
                    .font(.system(size: 46, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(GaugePalette.rpm(store.rpm, redline: store.settings.redlineRPM))
                Text("tr/min").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let speed = store.speedKmh ?? store.gpsSpeedKmh {
                    Text("\(Int(speed.rounded()))")
                        .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    Text("km/h").font(.callout).foregroundStyle(.secondary)
                }
            }
            RPMBar(rpm: store.rpm, rpmMax: store.settings.rpmMax, redline: store.settings.redlineRPM, height: 18)
                .animation(.linear(duration: 0.08), value: store.rpm ?? 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(overRedline ? Color.red.opacity(0.35) : Color.white.opacity(0.06))
        )
    }
}

// MARK: - Températures

struct TemperatureRow: View {
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            ValueTile(title: "Eau", value: Format.temp(store.coolantC), color: GaugePalette.coolant(store.coolantC), symbol: "thermometer.medium")
            ValueTile(title: "Air admission", value: Format.temp(store.intakeAirC), color: .white, symbol: "wind")
            if store.oilC != nil {
                ValueTile(title: "Huile", value: Format.temp(store.oilC), color: .orange, symbol: "drop.fill")
            } else {
                ValueTile(title: "Batterie", value: store.batteryV.map { String(format: "%.1f V", $0) } ?? "–", color: .white, symbol: "minus.plus.batteryblock")
            }
        }
    }
}

struct ValueTile: View {
    let title: String
    let value: String
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - État de la connexion

struct StatusBar: View {
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 10, height: 10)
            Text(statusText)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if case .running = store.connection {
                Text(String(format: "%.0f Hz · %.0f ms", store.stats.fastUpdatesPerSecond, store.stats.averageLatencyMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if store.liveActivityActive {
                Image(systemName: "carplay")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Affiché dans CarPlay")
            }
        }
        .padding(.top, 4)
    }

    private var dotColor: Color {
        switch store.connection {
        case .running: return .green
        case .idle: return .gray
        case .waiting: return .orange
        default: return .yellow
        }
    }

    private var statusText: String {
        switch store.connection {
        case .idle: return "Déconnecté"
        case .searching: return "Recherche de l'adaptateur OBD…"
        case .connecting(let name): return "Connexion à \(name)…"
        case .initializing(let text): return text
        case .running: return store.adapterName ?? "Connecté"
        case .waiting(let reason): return reason
        }
    }
}

// MARK: - Commandes

struct ControlBar: View {
    @Environment(TelemetryStore.self) private var store
    @Binding var showSettings: Bool
    @Binding var showDevices: Bool

    var body: some View {
        VStack(spacing: 10) {
            if let error = store.liveActivityError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                if store.isRunning {
                    Button(role: .destructive) {
                        store.stop()
                    } label: {
                        Label("Arrêter", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                } else {
                    Button {
                        store.start(.adapter)
                    } label: {
                        Label("Connecter", systemImage: "antenna.radiowaves.left.and.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)

                    Button {
                        store.start(.demo)
                    } label: {
                        Label("Démo", systemImage: "play.fill")
                    }
                    .buttonStyle(.glass)
                }

                Button {
                    if store.liveActivityActive { store.stopLiveActivity() } else { store.startLiveActivity() }
                } label: {
                    Image(systemName: store.liveActivityActive ? "carplay" : "rectangle.badge.plus")
                        .foregroundStyle(store.liveActivityActive ? Color.green : Color.white)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(store.liveActivityActive ? "Retirer de CarPlay" : "Afficher dans CarPlay")

                Button {
                    showDevices = true
                } label: {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Choisir l'adaptateur")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Réglages")
            }
            .controlSize(.large)
        }
        .padding(.bottom, 6)
    }
}
