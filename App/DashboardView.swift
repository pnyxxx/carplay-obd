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
                        BoostPanel(maxGaugeSide: geo.size.height * 0.72)
                            .frame(width: min(geo.size.height * 0.9, geo.size.width * 0.45))
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
                    VStack(spacing: 12) {
                        StatusBar()
                        BoostPanel(maxGaugeSide: min(geo.size.width * 0.74, geo.size.height * 0.31))
                        RPMPanel()
                        TemperatureRow()
                        Spacer(minLength: 0)
                        HintCard()
                        ControlBar(showSettings: $showSettings, showDevices: $showDevices)
                    }
                    .padding(.horizontal)
                }

                if store.blackScreenActive {
                    BlackScreenView()
                }
            }
        }
        // Chaque contact avec l'écran repousse le passage en écran noir.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in store.noteInteraction() })
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                store.checkIdleForBlackScreen(sheetOpen: showSettings || showDevices)
            }
        }
        .statusBarHidden(store.blackScreenActive)
        .persistentSystemOverlays(store.blackScreenActive ? .hidden : .automatic)
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
    var maxGaugeSide: CGFloat

    var body: some View {
        let scale = max(store.settings.boostMaxBar, 0.5)
        let side = max(maxGaugeSide, 160)
        VStack(spacing: 6) {
            ZStack {
                ArcGauge(
                    fraction: store.boostBar.map { $0 / scale },
                    peakFraction: store.displayedPeakBar.map { $0 / scale },
                    targetFraction: store.boostTargetBar.map { $0 / scale },
                    lineWidth: side * 0.06,
                    showNeedle: store.boostBar != nil
                )
                .animation(.linear(duration: 0.08), value: store.boostBar ?? 0)

                GaugeScaleLabels(maxValue: scale, lineWidth: side * 0.06)

                // Valeur au centre, sous le pivot de l'aiguille.
                VStack(spacing: 0) {
                    if let boost = store.boostBar {
                        Text(Format.boost(boost))
                            .font(.system(size: side * 0.17, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                    } else {
                        Text("—")
                            .font(.system(size: side * 0.12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text("bar turbo")
                        .font(.system(size: max(11, side * 0.05), weight: .semibold))
                        .foregroundStyle(.secondary)
                    if let peak = store.displayedPeakBar {
                        PeakBadge(value: peak, font: .system(size: max(12, side * 0.06), weight: .heavy))
                            .padding(.top, 4)
                    }
                }
                .offset(y: side * 0.2)
            }
            .frame(width: side, height: side)

            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Text("Pic session \(Format.boost(store.peakBoostBar))")
                    if store.peakBoostBar != nil {
                        Button {
                            store.resetPeak()
                        } label: {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remettre le pic à zéro")
                    }
                }
                if let target = store.boostTargetBar {
                    Text("Consigne \(Format.boost(target))")
                        .foregroundStyle(.yellow)
                }
                if store.boostSensorSaturated {
                    Label("capteur saturé", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)

            if store.boostHistory.count > 2 {
                BoostSparkline(samples: store.boostHistory, scale: scale)
                    .frame(height: 40)
            }
        }
    }
}

/// Graduations autour de l'arc (0 → max).
struct GaugeScaleLabels: View {
    let maxValue: Double
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2 - lineWidth * 2.6
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ForEach(0..<5, id: \.self) { index in
                let fraction = Double(index) / 4
                let angle = (135 + 270 * fraction) * .pi / 180
                Text(String(format: maxValue < 2.5 ? "%.1f" : "%.0f", maxValue * fraction))
                    .font(.system(size: max(10, side * 0.045)).monospacedDigit())
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            .overlay(alignment: .topLeading) {
                Text("Turbo · 20 dernières secondes")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
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
                if let rpm = store.rpm {
                    Text(Format.rpm(rpm))
                        .font(.system(size: 42, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(GaugePalette.rpm(rpm, redline: store.settings.redlineRPM))
                } else {
                    Text("—")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("tr/min").font(.callout).foregroundStyle(.secondary)
                Spacer()
                // Puissance, comme sur les écrans « performance » des voitures.
                if let power = store.powerCh {
                    Text(Format.power(power))
                        .font(.system(size: 36, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.cyan)
                    Text(store.powerFromECU ? "ch" : "ch ≈").font(.callout).foregroundStyle(.secondary)
                }
            }
            RPMBar(rpm: store.rpm, rpmMax: store.settings.rpmMax, redline: store.settings.redlineRPM, height: 14)
                .animation(.linear(duration: 0.08), value: store.rpm ?? 0)
            if store.powerCh != nil {
                PowerBar(power: store.powerCh, peak: store.displayedPeakPowerCh, maxPower: store.settings.maxPowerCh, height: 8)
                    .animation(.linear(duration: 0.08), value: store.powerCh ?? 0)
            }
            HStack(spacing: 14) {
                if let torque = store.torqueNm {
                    Text("\(Int(torque.rounded())) Nm")
                }
                if store.isRunning, let speed = store.speedKmh ?? store.gpsSpeedKmh {
                    Text("\(Int(speed.rounded())) km/h")
                }
                Spacer()
                if let peak = store.displayedPeakPowerCh {
                    PeakBadge(text: "MAX \(Format.power(peak)) ch")
                }
            }
            .font(.subheadline.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
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
            ValueTile(title: "Eau", value: store.coolantC.map { Format.temp($0) }, color: GaugePalette.coolant(store.coolantC), symbol: "thermometer.medium")
            ValueTile(title: "Air admis.", value: store.intakeAirC.map { Format.temp($0) }, color: .white, symbol: "wind")
            if store.oilC != nil {
                ValueTile(title: "Huile", value: store.oilC.map { Format.temp($0) }, color: .orange, symbol: "drop.fill")
            } else {
                ValueTile(title: "Batterie", value: store.batteryV.map { String(format: "%.1f V", $0) }, color: .white, symbol: "minus.plus.batteryblock")
            }
        }
    }
}

struct ValueTile: View {
    let title: String
    let value: String?
    let color: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value ?? "—")
                .font(.system(size: value == nil ? 22 : 28, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(value == nil ? Color.secondary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - Écran noir

/// Écran entièrement noir (luminosité au minimum) : l'écran reste allumé, donc CarPlay reste en temps réel.
struct BlackScreenView: View {
    @Environment(TelemetryStore.self) private var store
    @State private var showHint = true

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                if showHint {
                    VStack(spacing: 10) {
                        Image(systemName: "moon.fill").font(.title2)
                        Text("Écran noir : CarPlay reste en temps réel.\nTouche l'écran pour revenir.")
                            .multilineTextAlignment(.center)
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.35))
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { store.exitBlackScreen() }
            .task {
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeOut(duration: 1)) { showHint = false }
            }
    }
}

// MARK: - Aide

/// Mode d'emploi affiché tant qu'aucune donnée n'arrive.
struct HintCard: View {
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        if let text = hint {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.cyan)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.cyan.opacity(0.08)))
        }
    }

    private var hint: String? {
        switch store.connection {
        case .idle:
            return store.settings.savedAdapterID == nil
                ? "Branche le Veepeak sur la prise OBD, mets le contact, puis touche « Connecter ». Pas de voiture sous la main ? Touche « Démo »."
                : "Mets le contact puis touche « Connecter » : l'app se reconnecte à \(store.settings.savedAdapterName ?? "ton adaptateur")."
        case .searching, .connecting:
            return "Contact mis ? L'adaptateur doit être branché. Ne l'appaire pas dans les réglages Bluetooth de l'iPhone."
        case .waiting:
            return "L'app réessaie toute seule. Si ça dure, vérifie que le contact est mis."
        case .standby:
            return "En veille pour économiser la batterie : l'app repartira seule quand la voiture se rallume. Touche « Relancer » pour forcer."
        case .initializing, .running:
            return nil
        }
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
                Text(String(format: "%.0f mesures/s", store.stats.fastUpdatesPerSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if store.liveActivityActive {
                Label("CarPlay", systemImage: "carplay")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.top, 4)
    }

    private var dotColor: Color {
        switch store.connection {
        case .running: return .green
        case .idle: return .gray
        case .waiting: return .orange
        case .standby: return .blue
        default: return .yellow
        }
    }

    private var statusText: String {
        switch store.connection {
        case .idle: return store.source == nil ? "Déconnecté" : "Démarrage…"
        case .searching: return "Recherche de l'adaptateur OBD…"
        case .connecting(let name): return "Connexion à \(name)…"
        case .initializing(let text): return text
        case .running: return store.adapterName ?? "Connecté"
        case .waiting(let reason): return reason
        case .standby(let reason): return "En veille : \(reason)"
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

            // Action principale, en grand.
            primaryButton
                .controlSize(.large)

            // Actions secondaires, chacune avec son nom.
            HStack(spacing: 8) {
                ToolButton(
                    title: store.source == .demo ? "Stop démo" : "Démo",
                    systemImage: store.source == .demo ? "stop.fill" : "play.fill",
                    active: store.source == .demo
                ) {
                    if store.source == .demo { store.stop() } else { store.start(.demo) }
                }

                ToolButton(title: "CarPlay", systemImage: "carplay", active: store.liveActivityActive) {
                    if store.liveActivityActive { store.stopLiveActivity() } else { store.startLiveActivity() }
                }

                ToolButton(title: "Écran noir", systemImage: "moon.fill", active: false) {
                    store.enterBlackScreen()
                }

                ToolButton(title: "Adaptateur", systemImage: "antenna.radiowaves.left.and.right", active: false) {
                    showDevices = true
                }

                ToolButton(title: "Réglages", systemImage: "gearshape.fill", active: false) {
                    showSettings = true
                }
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if store.isStandby {
            HStack(spacing: 10) {
                Button {
                    store.wake()
                } label: {
                    Label("Relancer", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                Button(role: .destructive) {
                    store.stop()
                } label: {
                    Label("Arrêter", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        } else if store.source == .adapter {
            Button(role: .destructive) {
                store.stop()
            } label: {
                Label(store.isConnected ? "Déconnecter" : "Annuler la connexion", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
        } else {
            Button {
                store.start(.adapter)
            } label: {
                Label("Connecter à la voiture", systemImage: "car.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
    }
}

/// Bouton carré : icône + nom en dessous.
struct ToolButton: View {
    let title: String
    let systemImage: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ToolButtonLabel(title: title, systemImage: systemImage, active: active)
        }
        .buttonStyle(.plain)
    }
}

struct ToolButtonLabel: View {
    let title: String
    let systemImage: String
    let active: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .frame(height: 24)
            Text(title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(active ? Color.green : Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(active ? Color.green.opacity(0.15) : Color.white.opacity(0.08))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }
}
