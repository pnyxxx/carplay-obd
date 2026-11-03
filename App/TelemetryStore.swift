import Foundation
import Observation
import OBDKit
import UIKit

/// Cerveau de l'app : connexion à l'adaptateur, boucle OBD, valeurs affichées, Live Activity CarPlay.
@MainActor
@Observable
final class TelemetryStore {
    static let shared = TelemetryStore()

    enum Source: String { case adapter, demo }

    enum ConnectionState: Equatable {
        case idle
        case searching
        case connecting(String)
        case initializing(String)
        case running
        case waiting(String)   // erreur, nouvel essai automatique
    }

    struct BoostSample { let time: TimeInterval; let bar: Double }

    // MARK: État public

    var settings = AppSettings.load() {
        didSet {
            settings.save()
            liveActivity.minInterval = settings.liveActivityInterval
            nowPlaying.minInterval = settings.nowPlayingInterval
            if settings.keepAliveWithGPS != oldValue.keepAliveWithGPS { updateKeepAlive() }
        }
    }

    private(set) var source: Source?
    private(set) var connection: ConnectionState = .idle
    private(set) var adapterName: String?
    private(set) var adapterInfo: AdapterInfo?
    private(set) var stats = PollStats()
    private(set) var logs: [LogEntry] = []
    private(set) var devices: [BLELink.Device] = []
    private(set) var liveActivityActive = false
    private(set) var liveActivityError: String?
    private(set) var nowPlayingActive = false

    // Valeurs moteur
    private(set) var rpm: Double?
    private(set) var intakeKPa: Double?
    private(set) var boostTargetKPa: Double?
    private(set) var baroKPa: Double?
    private(set) var coolantC: Double?
    private(set) var intakeAirC: Double?
    private(set) var oilC: Double?
    private(set) var speedKmh: Double?
    private(set) var gpsSpeedKmh: Double?
    private(set) var batteryV: Double?
    private(set) var peakBoostBar: Double?
    private(set) var boostHistory: [BoostSample] = []

    /// Pression de turbo relative (bar) = pression absolue − pression atmosphérique.
    var boostBar: Double? {
        guard let intakeKPa else { return nil }
        return (intakeKPa - effectiveBaroKPa) / 100
    }

    var boostTargetBar: Double? {
        guard let boostTargetKPa else { return nil }
        return (boostTargetKPa - effectiveBaroKPa) / 100
    }

    /// Le PID 0x0B plafonne à 255 kPa absolus : au-delà, la valeur affichée est fausse.
    var boostSensorSaturated: Bool {
        adapterInfo?.boostSource == .pid0B && (intakeKPa ?? 0) >= 254
    }

    var isRunning: Bool { source != nil }

    // MARK: Interne

    private let link = BLELink()
    private let liveActivity = LiveActivityController()
    private let nowPlaying = NowPlayingDisplay()
    private let keepAlive = LocationKeepAlive()
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    /// Pression atmosphérique estimée moteur arrêté, si la voiture ne fournit pas le PID 0x33.
    @ObservationIgnored private var estimatedBaroKPa: Double?

    private var effectiveBaroKPa: Double { baroKPa ?? estimatedBaroKPa ?? 101.3 }

    private init() {
        liveActivity.minInterval = settings.liveActivityInterval
        nowPlaying.minInterval = settings.nowPlayingInterval
        nowPlaying.onNextTrack = { [weak self] in self?.resetPeak() }
        link.onDevicesChanged = { [weak self] devices in
            Task { @MainActor in self?.devices = devices }
        }
        keepAlive.onSpeed = { [weak self] speed in
            self?.gpsSpeedKmh = speed
        }
        // Une Live Activity restée ouverte après un arrêt brutal de l'app est fermée au lancement.
        liveActivity.stop()
    }

    // MARK: - Démarrage / arrêt

    func start(_ newSource: Source) {
        stop(keepLiveActivity: true)
        source = newSource
        resetValues()
        UIApplication.shared.isIdleTimerDisabled = true
        updateKeepAlive()
        sessionTask = Task { [weak self] in
            await self?.sessionLoop(newSource)
        }
    }

    func stop(keepLiveActivity: Bool = false) {
        sessionTask?.cancel()
        sessionTask = nil
        if source == .adapter { link.disconnect() }
        source = nil
        connection = .idle
        UIApplication.shared.isIdleTimerDisabled = false
        keepAlive.stop()
        if !keepLiveActivity {
            stopLiveActivity()
            stopNowPlaying()
        }
    }

    func connect(to device: BLELink.Device) {
        settings.savedAdapterID = device.id
        settings.savedAdapterName = device.name
        start(.adapter)
    }

    func forgetAdapter() {
        settings.savedAdapterID = nil
        settings.savedAdapterName = nil
    }

    func scanForDevices() {
        devices = []
        Task {
            do { try await link.startScan() } catch { log(.error, "\(error)") }
        }
    }

    func stopScan() { link.stopScan() }

    func resetPeak() {
        peakBoostBar = nil
    }

    private func updateKeepAlive() {
        if isRunning && settings.keepAliveWithGPS { keepAlive.start() } else { keepAlive.stop() }
    }

    // MARK: - Boucle de session (reconnexion automatique)

    private func sessionLoop(_ source: Source) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await runSession(source)
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                attempt += 1
                let message = Self.describe(error)
                log(.error, message)
                connection = .waiting(message)
                pushLiveActivity()
                if nowPlayingActive { nowPlaying.submit(gaugeSnapshot) }
            }
            if source == .adapter { link.disconnect() }
            // Nouvel essai : rapide au début, puis toutes les 5 s (contact coupé, adaptateur hors de portée…).
            try? await Task.sleep(for: .seconds(attempt < 3 ? 2 : 5))
        }
    }

    private func runSession(_ source: Source) async throws {
        let transport: ELMTransport
        switch source {
        case .demo:
            transport = SimulatedELM()
            adapterName = "Démo (BMW 320d simulée)"
        case .adapter:
            connection = settings.savedAdapterID == nil ? .searching : .connecting(settings.savedAdapterName ?? "Adaptateur")
            let device = try await link.connect(preferred: settings.savedAdapterID)
            if settings.savedAdapterID != device.id {
                settings.savedAdapterID = device.id
                settings.savedAdapterName = device.name
            }
            adapterName = device.name
            transport = link
        }

        let (events, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        let session = ELMSession(transport: transport, config: settings.sessionConfig) { event in
            continuation.yield(event)
        }
        let consumer = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
        defer {
            continuation.finish()
            consumer.cancel()
        }

        connection = .initializing("Initialisation…")
        let info = try await session.initialize()
        adapterInfo = info
        if let baro = info.initialBaroKPa { baroKPa = baro }
        connection = .running

        if settings.autoStartLiveActivity && !liveActivity.isActive {
            startLiveActivity()
        }
        if settings.autoStartNowPlaying && !nowPlayingActive {
            startNowPlaying()
        }
        pushLiveActivity()

        try await session.run()
        try Task.checkCancellation()
    }

    // MARK: - Événements OBD

    private func handle(_ event: SessionEvent) {
        switch event {
        case .readings(let readings):
            apply(readings)
        case .stats(let stats):
            self.stats = stats
        case .adapter(let info):
            adapterInfo = info
        case .status(let text):
            if case .running = connection { return }
            connection = .initializing(text)
        case .log(let entry):
            if settings.verboseLog || entry.kind == .error || entry.kind == .info || !isRunningState {
                appendLog(entry)
            }
        }
    }

    private var isRunningState: Bool {
        if case .running = connection { return true }
        return false
    }

    private func apply(_ readings: [Reading]) {
        var boostChanged = false
        for reading in readings {
            switch reading.channel {
            case .rpm: rpm = reading.value
            case .intakePressureKPa:
                intakeKPa = reading.value
                boostChanged = true
            case .boostTargetKPa: boostTargetKPa = reading.value
            case .baroKPa: baroKPa = reading.value
            case .coolantC: coolantC = reading.value
            case .intakeAirC: intakeAirC = reading.value
            case .oilC: oilC = reading.value
            case .speedKmh: speedKmh = reading.value
            case .batteryV: batteryV = reading.value
            case .throttlePct, .engineLoadPct, .maxMAPKPa: break
            }
        }

        // Sans PID 0x33 : moteur arrêté, la pression d'admission = pression atmosphérique.
        if baroKPa == nil, let rpm, rpm < 50, let intakeKPa, (80...110).contains(intakeKPa) {
            estimatedBaroKPa = intakeKPa
        }

        if boostChanged, let boost = boostBar {
            peakBoostBar = max(peakBoostBar ?? boost, boost)
            let now = ProcessInfo.processInfo.systemUptime
            boostHistory.append(BoostSample(time: now, bar: boost))
            if let first = boostHistory.first, now - first.time > 20 {
                boostHistory.removeAll { now - $0.time > 20 }
            }
        }
        pushLiveActivity()
        if nowPlayingActive { nowPlaying.submit(gaugeSnapshot) }
    }

    /// Valeurs figées pour dessiner les jauges en image (CarPlay « À l'écoute », app CarPlay).
    var gaugeSnapshot: GaugeSnapshot {
        GaugeSnapshot(
            boostBar: boostBar,
            peakBoostBar: peakBoostBar,
            targetBar: boostTargetBar,
            rpm: rpm,
            coolantC: coolantC,
            intakeAirC: intakeAirC,
            connected: isRunningState,
            boostMaxBar: settings.boostMaxBar,
            rpmMax: settings.rpmMax,
            redlineRPM: settings.redlineRPM
        )
    }

    // MARK: - Écran « À l'écoute » de CarPlay (expérimental)

    func startNowPlaying() {
        do {
            try nowPlaying.start()
            nowPlayingActive = true
            nowPlaying.submit(gaugeSnapshot)
            log(.info, "Écran « À l'écoute » CarPlay activé")
        } catch {
            liveActivityError = "Impossible d'activer l'écran « À l'écoute » : \(error.localizedDescription)"
            log(.error, liveActivityError ?? "")
        }
    }

    func stopNowPlaying() {
        nowPlaying.stop()
        nowPlayingActive = false
    }

    var nowPlayingUpdatesPerMinute: Int { nowPlaying.updatesLastMinute }

    // MARK: - Live Activity (CarPlay)

    func startLiveActivity() {
        liveActivityError = nil
        guard liveActivity.areActivitiesEnabled else {
            liveActivityError = "Live Activities désactivées dans Réglages > TrackGauge"
            return
        }
        let attributes = TelemetryAttributes(
            boostMaxBar: settings.boostMaxBar,
            rpmMax: settings.rpmMax,
            redlineRPM: settings.redlineRPM
        )
        do {
            try liveActivity.start(attributes: attributes, state: currentActivityState())
            liveActivityActive = true
            log(.info, "Live Activity démarrée (visible dans CarPlay)")
        } catch {
            liveActivityError = "Impossible de démarrer la Live Activity : \(error.localizedDescription)"
            log(.error, liveActivityError ?? "")
        }
    }

    func stopLiveActivity() {
        liveActivity.stop()
        liveActivityActive = false
    }

    var liveActivityUpdatesPerMinute: Int { liveActivity.updatesLastMinute }

    private func pushLiveActivity() {
        guard liveActivityActive else { return }
        liveActivity.submit(currentActivityState())
    }

    private func currentActivityState() -> TelemetryAttributes.ContentState {
        let status: String
        switch connection {
        case .running: status = "OK"
        case .waiting: status = "Attente voiture…"
        case .idle: status = "Arrêté"
        default: status = "Connexion…"
        }
        return TelemetryAttributes.ContentState(
            boostBar: boostBar,
            peakBoostBar: nil,
            rpm: rpm,
            coolantC: coolantC,
            intakeAirC: intakeAirC,
            connected: isRunningState,
            statusText: status
        )
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as SessionError: return error.description
        case let error as TransportError: return error.description
        case let error as BLELink.LinkError: return error.description
        default: return error.localizedDescription
        }
    }

    // MARK: - Journal

    private func log(_ kind: LogEntry.Kind, _ text: String) {
        appendLog(LogEntry(date: Date(), kind: kind, text: text))
    }

    private func appendLog(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }

    func clearLogs() { logs.removeAll() }

    var logText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        var lines: [String] = []
        if let info = adapterInfo {
            lines.append("Adaptateur : \(adapterName ?? "?") — \(info.identity) \(info.stnIdentity ?? "")")
            lines.append("Protocole : \(info.proto.label) — ECU moteur \(info.engineECU ?? "?") — ECU : \(info.respondingECUs.joined(separator: ", "))")
            lines.append("PID supportés : " + info.supportedPIDs.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))
            lines.append("Turbo : \(info.boostSource?.label ?? "aucune source") — multi-PID \(info.multiPID) — nb réponses \(info.responseCount) — adressage direct \(info.physicalAddressing)")
        }
        lines.append(String(format: "Débit : %.1f req/s, %.1f mesures turbo+régime/s, %.0f ms par requête", stats.requestsPerSecond, stats.fastUpdatesPerSecond, stats.averageLatencyMs))
        for entry in logs {
            let prefix: String
            switch entry.kind {
            case .command: prefix = "→"
            case .response: prefix = "←"
            case .info: prefix = "ℹ︎"
            case .error: prefix = "⚠︎"
            }
            lines.append("\(formatter.string(from: entry.date)) \(prefix) \(entry.text)")
        }
        return lines.joined(separator: "\n")
    }

    private func resetValues() {
        rpm = nil; intakeKPa = nil; boostTargetKPa = nil; baroKPa = nil
        coolantC = nil; intakeAirC = nil; oilC = nil; speedKmh = nil; batteryV = nil
        peakBoostBar = nil; boostHistory = []; estimatedBaroKPa = nil
        adapterInfo = nil; stats = PollStats()
    }
}
