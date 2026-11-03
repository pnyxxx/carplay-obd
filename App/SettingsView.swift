import OBDKit
import SwiftUI

struct SettingsView: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $store.settings.boostMaxBar, in: 1...4, step: 0.25) {
                        LabeledContent("Échelle turbo", value: String(format: "%.2f bar", store.settings.boostMaxBar))
                    }
                    Stepper(value: $store.settings.rpmMax, in: 3000...9000, step: 250) {
                        LabeledContent("Régime max", value: "\(Int(store.settings.rpmMax)) tr/min")
                    }
                    Stepper(value: $store.settings.redlineRPM, in: 2000...9000, step: 250) {
                        LabeledContent("Zone rouge", value: "\(Int(store.settings.redlineRPM)) tr/min")
                    }
                } header: {
                    Text("Véhicule")
                } footer: {
                    Text("Valeurs par défaut prévues pour une BMW 320d E90. L'échelle de la Live Activity est fixée à son démarrage.")
                }

                Section {
                    Toggle("Afficher automatiquement à la connexion", isOn: $store.settings.autoStartLiveActivity)
                    Picker("Rafraîchissement", selection: $store.settings.liveActivityInterval) {
                        Text("0,5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    LabeledContent("Mises à jour envoyées", value: "\(store.liveActivityUpdatesPerMinute) / min")
                } header: {
                    Text("CarPlay (Live Activity)")
                } footer: {
                    Text("Dans CarPlay, les jauges apparaissent sur le Dashboard (écran partagé carte + infos). iOS limite le rythme des mises à jour : l'app envoie le pic de turbo de chaque intervalle pour ne rien rater. Les jauges de l'iPhone, elles, sont en temps réel.")
                }

                Section {
                    Toggle("Activer automatiquement à la connexion", isOn: $store.settings.autoStartNowPlaying)
                    Picker("Rafraîchissement", selection: $store.settings.nowPlayingInterval) {
                        Text("0,25 s").tag(0.25)
                        Text("0,5 s").tag(0.5)
                        Text("1 s").tag(1.0)
                    }
                    LabeledContent("Pochettes envoyées", value: "\(store.nowPlayingUpdatesPerMinute) / min")
                } header: {
                    Text("CarPlay : écran « À l'écoute » (expérimental)")
                } footer: {
                    Text("Sans autorisation Apple : l'app joue un son silencieux et se présente comme un morceau de musique. Ouvre « À l'écoute » dans CarPlay pour voir les jauges en grand. Le bouton « suivant » remet le pic de turbo à zéro. Coupe la musique des autres apps.")
                }

                Section {
                    Toggle("Rester actif grâce au GPS", isOn: $store.settings.keepAliveWithGPS)
                } header: {
                    Text("Arrière-plan")
                } footer: {
                    Text("Empêche iOS de suspendre la lecture OBD quand l'écran est verrouillé ou que CarPlay est au premier plan. Donne aussi la vitesse GPS.")
                }

                Section {
                    if let name = store.settings.savedAdapterName {
                        LabeledContent("Adaptateur mémorisé", value: name)
                        Button("Oublier cet adaptateur", role: .destructive) { store.forgetAdapter() }
                    } else {
                        Text("Aucun : le premier adaptateur OBD trouvé sera utilisé.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Adaptateur")
                }

                Section {
                    Toggle("Requêtes groupées (multi-PID)", isOn: $store.settings.multiPID)
                    Toggle("Annoncer le nombre de réponses", isOn: $store.settings.responseCount)
                    Toggle("Délai adaptatif agressif (AT AT2)", isOn: $store.settings.aggressiveTiming)
                    Toggle("Adresser directement le moteur", isOn: $store.settings.physicalAddressing)
                    Picker("Source turbo", selection: $store.settings.boostSource) {
                        Text("Automatique").tag("auto")
                        ForEach(BoostSource.allCases, id: \.rawValue) { source in
                            Text(source.label).tag(source.rawValue)
                        }
                    }
                    Toggle("Journal détaillé", isOn: $store.settings.verboseLog)
                    NavigationLink("Diagnostic") { DiagnosticsView() }
                } header: {
                    Text("OBD (expert)")
                } footer: {
                    Text("Appliqué à la prochaine connexion. Tout est activé par défaut pour aller le plus vite possible ; l'app revient d'elle-même en mode prudent si la voiture ne suit pas.")
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
        }
    }
}

struct DevicePickerView: View {
    @Environment(TelemetryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.devices.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Recherche… (contact mis, adaptateur branché)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(store.devices) { device in
                        Button {
                            store.connect(to: device)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: device.looksLikeOBD ? "car.fill" : "dot.radiowaves.left.and.right")
                                    .foregroundStyle(device.looksLikeOBD ? Color.green : Color.secondary)
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                    if device.id == store.settings.savedAdapterID {
                                        Text("Mémorisé").font(.caption).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                Text("\(device.rssi) dBm").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("Ne pas appairer l'adaptateur dans Réglages > Bluetooth : l'app s'y connecte directement. Le Veepeak apparaît en général sous le nom « VEEPEAK ».")
                }
            }
            .navigationTitle("Adaptateurs Bluetooth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .onAppear { store.scanForDevices() }
            .onDisappear { store.stopScan() }
        }
    }
}

struct DiagnosticsView: View {
    @Environment(TelemetryStore.self) private var store

    var body: some View {
        List {
            Section("Adaptateur") {
                LabeledContent("Nom", value: store.adapterName ?? "–")
                LabeledContent("Puce", value: store.adapterInfo?.identity ?? "–")
                if let stn = store.adapterInfo?.stnIdentity {
                    LabeledContent("STN", value: stn)
                }
                LabeledContent("Tension", value: store.batteryV.map { String(format: "%.1f V", $0) } ?? "–")
            }

            if let info = store.adapterInfo {
                Section("Voiture") {
                    LabeledContent("Protocole", value: info.proto.label)
                    LabeledContent("Calculateur moteur", value: info.engineECU ?? "–")
                    LabeledContent("Calculateurs", value: info.respondingECUs.joined(separator: ", "))
                    LabeledContent("Source turbo", value: info.boostSource?.label ?? "aucune")
                    if let maxMAP = info.maxMAPKPa {
                        LabeledContent("MAP max annoncé (0x4F)", value: String(format: "%.0f kPa", maxMAP))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PID supportés").font(.caption).foregroundStyle(.secondary)
                        Text(info.supportedPIDs.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.caption.monospaced())
                    }
                }
                Section("Optimisations actives") {
                    LabeledContent("Requêtes groupées", value: info.multiPID ? "oui" : "non")
                    LabeledContent("Nombre de réponses", value: info.responseCount ? "oui" : "non")
                    LabeledContent("Adressage direct", value: info.physicalAddressing ? "oui" : "non")
                    LabeledContent("AT AT2", value: info.aggressiveTiming ? "oui" : "non")
                }
            }

            Section("Performances") {
                LabeledContent("Requêtes / s", value: String(format: "%.1f", store.stats.requestsPerSecond))
                LabeledContent("Turbo + régime / s", value: String(format: "%.1f", store.stats.fastUpdatesPerSecond))
                LabeledContent("Aller-retour moyen", value: String(format: "%.0f ms", store.stats.averageLatencyMs))
                LabeledContent("NO DATA / délais dépassés", value: "\(store.stats.noDataCount) / \(store.stats.timeoutCount)")
                LabeledContent("Live Activity", value: "\(store.liveActivityUpdatesPerMinute) mises à jour / min")
                LabeledContent("« À l'écoute »", value: "\(store.nowPlayingUpdatesPerMinute) pochettes / min")
            }

            Section("Valeurs brutes") {
                LabeledContent("Pression admission (abs.)", value: store.intakeAKPaText)
                LabeledContent("Pression atmosphérique", value: store.baroKPa.map { String(format: "%.0f kPa", $0) } ?? "estimée")
                LabeledContent("Consigne turbo (abs.)", value: store.boostTargetKPa.map { String(format: "%.1f kPa", $0) } ?? "–")
                LabeledContent("Vitesse GPS", value: store.gpsSpeedKmh.map { String(format: "%.0f km/h", $0) } ?? "–")
            }

            Section {
                ShareLink(item: store.logText) {
                    Label("Partager le journal", systemImage: "square.and.arrow.up")
                }
                Button("Effacer le journal", role: .destructive) { store.clearLogs() }
                ForEach(Array(store.logs.suffix(150).enumerated().reversed()), id: \.offset) { _, entry in
                    Text(entry.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(color(for: entry.kind))
                }
            } header: {
                Text("Journal")
            } footer: {
                Text("En cas de souci, partage ce journal : il contient tout l'échange avec l'adaptateur.")
            }
        }
        .navigationTitle("Diagnostic")
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .command: return .cyan
        case .response: return .primary
        case .info: return .green
        case .error: return .orange
        }
    }
}

private extension TelemetryStore {
    var intakeAKPaText: String {
        intakeKPa.map { String(format: "%.1f kPa", $0) } ?? "–"
    }
}
