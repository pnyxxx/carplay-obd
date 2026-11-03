import Foundation

/// Réglages de la session de lecture.
public struct SessionConfig: Sendable, Equatable {
    /// Regrouper plusieurs PID dans une seule requête (jusqu'à 6, en CAN surtout) : moins d'allers-retours Bluetooth.
    public var multiPID = true
    /// Ajouter le nombre de réponses attendues à la requête (« 010C1 ») : l'ELM répond sans attendre son délai.
    public var responseCount = true
    /// Délai adaptatif agressif de l'ELM (AT AT2). Repasse automatiquement en AT AT1 si trop de « NO DATA ».
    public var aggressiveTiming = true
    /// Adresser directement le calculateur moteur (CAN 11 bits) au lieu de tous les calculateurs.
    public var physicalAddressing = true
    /// Source de pression turbo imposée (nil = choix automatique : 0x70 > 0x87 > 0x0B).
    public var forcedBoostSource: BoostSource?
    /// Période des mesures lentes (températures, vitesse).
    public var slowInterval: Duration = .milliseconds(1000)
    /// Période de relecture de la pression atmosphérique.
    public var baroInterval: Duration = .seconds(15)
    /// Période de lecture de la tension batterie (AT RV).
    public var batteryInterval: Duration = .seconds(5)
    /// Délai max d'une commande normale.
    public var commandTimeout: Duration = .milliseconds(1500)

    public init() {}
}

/// Ce que l'on a appris de l'adaptateur et de la voiture pendant l'initialisation.
public struct AdapterInfo: Sendable, Equatable {
    public var identity = ""
    public var stnIdentity: String?
    public var proto: OBDProtocol = .automatic
    public var headersEnabled = false
    public var engineECU: String?
    public var respondingECUs: [String] = []
    public var supportedPIDs: Set<UInt8> = []
    public var boostSource: BoostSource?
    public var multiPID = false
    public var responseCount = false
    public var physicalAddressing = false
    public var aggressiveTiming = false
    public var maxMAPKPa: Double?
    public var initialBaroKPa: Double?
    /// Couple de référence annoncé par le calculateur (PID 0x63) : avec le PID 0x62, donne le couple réel.
    public var referenceTorqueNm: Double?
    /// PID lu à chaque cycle pour la puissance : 0x62 (couple réel) ou 0x04 (charge moteur, estimation).
    public var powerPID: UInt8?

    public init() {}
}

/// Statistiques de la boucle de lecture (rafraîchies chaque seconde).
public struct PollStats: Sendable, Equatable {
    /// Requêtes OBD par seconde.
    public var requestsPerSecond: Double = 0
    /// Mises à jour du régime / turbo par seconde (ce qui compte pour la fluidité).
    public var fastUpdatesPerSecond: Double = 0
    /// Temps moyen aller-retour d'une requête (ms).
    public var averageLatencyMs: Double = 0
    public var noDataCount = 0
    public var timeoutCount = 0

    public init() {}
}

public struct LogEntry: Sendable, Equatable {
    public enum Kind: Sendable { case command, response, info, error }
    public var date: Date
    public var kind: Kind
    public var text: String

    public init(date: Date, kind: Kind, text: String) {
        self.date = date
        self.kind = kind
        self.text = text
    }
}

public enum SessionEvent: Sendable {
    case status(String)
    case adapter(AdapterInfo)
    case readings([Reading])
    case stats(PollStats)
    case log(LogEntry)
}

public enum SessionError: Error, CustomStringConvertible, Sendable {
    case unableToConnect
    case noEngineData
    case transport(TransportError)

    public var description: String {
        switch self {
        case .unableToConnect: return "L'adaptateur ne parvient pas à dialoguer avec la voiture (contact mis ?)"
        case .noEngineData: return "La voiture ne renvoie pas le régime moteur (PID 0x0C)"
        case .transport(let error): return error.description
        }
    }
}

/// Dialogue avec un ELM327 : initialisation, détection de ce que la voiture sait faire,
/// puis boucle de lecture la plus rapide possible.
public actor ELMSession {
    private let transport: ELMTransport
    private var config: SessionConfig
    private let onEvent: @Sendable (SessionEvent) -> Void
    private(set) public var info = AdapterInfo()

    // Planification des PID
    private var fastPIDs: [UInt8] = []
    private var slowPIDs: [UInt8] = []
    private var nextDue: [UInt8: ContinuousClock.Instant] = [:]
    private var consecutiveMisses: [UInt8: Int] = [:]
    private var multiPIDBroken = false

    // Statistiques
    private var windowStart = ContinuousClock.now
    private var windowRequests = 0
    private var windowFast = 0
    private var latencySum: Double = 0
    private var stats = PollStats()
    private var recentNoData = 0
    private var recentRequests = 0
    private var consecutiveTimeouts = 0

    public init(transport: ELMTransport, config: SessionConfig = SessionConfig(), onEvent: @escaping @Sendable (SessionEvent) -> Void) {
        self.transport = transport
        self.config = config
        self.onEvent = onEvent
    }

    // MARK: - Échanges bas niveau

    private func log(_ kind: LogEntry.Kind, _ text: String) {
        onEvent(.log(LogEntry(date: Date(), kind: kind, text: text)))
    }

    /// Envoie une commande et journalise l'échange.
    private func exchange(_ command: String, timeout: Duration? = nil) async throws -> String {
        log(.command, command)
        let start = ContinuousClock.now
        do {
            let raw = try await transport.send(command, timeout: timeout ?? config.commandTimeout)
            let elapsed = (ContinuousClock.now - start).inSeconds * 1000
            latencySum += elapsed
            windowRequests += 1
            consecutiveTimeouts = 0
            log(.response, raw.replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\n", with: "") + String(format: "  (%.0f ms)", elapsed))
            return raw
        } catch let error as TransportError {
            if error == .timeout {
                stats.timeoutCount += 1
                consecutiveTimeouts += 1
            }
            log(.error, "\(command) → \(error.description)")
            throw SessionError.transport(error)
        }
    }

    /// Commande AT : renvoie le texte utile (sans écho ni prompt).
    @discardableResult
    private func at(_ command: String, timeout: Duration? = nil) async throws -> String {
        let raw = try await exchange(command, timeout: timeout)
        let lines = ELMParser.lines(raw).filter { $0.replacingOccurrences(of: " ", with: "").uppercased() != command.uppercased() }
        return lines.joined(separator: " ")
    }

    private func query(_ command: String, timeout: Duration? = nil) async throws -> ParsedResponse {
        let raw = try await exchange(command, timeout: timeout)
        return ELMParser.parse(raw, protocol: info.proto, headers: info.headersEnabled)
    }

    // MARK: - Initialisation

    /// Prépare l'adaptateur et détecte les capacités de la voiture.
    public func initialize() async throws -> AdapterInfo {
        onEvent(.status("Initialisation de l'adaptateur…"))

        // Remise à zéro. Certains clones ne renvoient rien d'exploitable : on tolère.
        let banner = (try? await at("ATZ", timeout: .seconds(4))) ?? ""
        try await at("ATE0")      // pas d'écho
        try await at("ATL0")      // pas de saut de ligne
        try await at("ATS0")      // pas d'espaces : réponses plus courtes en Bluetooth
        let headersReply = try await at("ATH1")   // en-têtes : savoir quel calculateur répond
        info.headersEnabled = headersReply.uppercased().contains("OK")

        let identity = try await at("ATI")
        info.identity = identity.isEmpty ? banner : identity
        let stn = (try? await at("STI")) ?? "?"
        if !stn.contains("?") && !stn.isEmpty { info.stnIdentity = stn }

        info.aggressiveTiming = config.aggressiveTiming
        try await at(config.aggressiveTiming ? "ATAT2" : "ATAT1")
        try await at("ATSP0")     // protocole automatique

        // La première requête lance la recherche du protocole (jusqu'à ~10 s en K-line).
        onEvent(.status("Recherche du protocole de la voiture…"))
        let firstRaw = try await exchange("0100", timeout: .seconds(20))
        if ELMParser.parse(firstRaw, protocol: .automatic, headers: false).statuses.contains(.unableToConnect) {
            throw SessionError.unableToConnect
        }

        // Le format des réponses dépend du protocole trouvé : on l'analyse seulement maintenant.
        let dpn = try await at("ATDPN")
        info.proto = OBDProtocol(dpnResponse: dpn) ?? .can11_500
        if info.proto == .automatic { throw SessionError.unableToConnect }
        onEvent(.status("Protocole : \(info.proto.label)"))

        var first = ELMParser.parse(firstRaw, protocol: info.proto, headers: info.headersEnabled)
        if first.messages.isEmpty {
            first = try await query("0100", timeout: .seconds(5))
        }
        if first.messages.isEmpty { throw SessionError.unableToConnect }

        // PID supportés, par calculateur.
        var supportedByECU: [String: Set<UInt8>] = [:]
        var ecuOrder: [String] = []
        func absorb(_ response: ParsedResponse, base: UInt8) {
            for message in response.messages {
                guard let pairs = Service01.split(message.bytes) else { continue }
                for pair in pairs where pair.pid == base {
                    if !ecuOrder.contains(message.header) { ecuOrder.append(message.header) }
                    supportedByECU[message.header, default: []].formUnion(PIDTable.supportedPIDs(base: base, bitmap: pair.data))
                }
            }
        }
        absorb(first, base: 0x00)
        for base: UInt8 in [0x20, 0x40, 0x60, 0x80] {
            let anyAnnounces = supportedByECU.values.contains { $0.contains(base) }
            guard anyAnnounces else { break }
            let response = try await query(Service01.request([base]))
            absorb(response, base: base)
        }

        // Calculateur moteur = celui qui fournit le régime (7E8 de préférence).
        let engine = ecuOrder.first(where: { $0 == "7E8" && supportedByECU[$0]?.contains(0x0C) == true })
            ?? ecuOrder.first(where: { supportedByECU[$0]?.contains(0x0C) == true })
            ?? ecuOrder.first
        info.engineECU = engine
        info.respondingECUs = ecuOrder
        info.supportedPIDs = engine.flatMap { supportedByECU[$0] } ?? []
        guard info.supportedPIDs.contains(0x0C) else { throw SessionError.noEngineData }

        // Adressage direct du moteur (CAN 11 bits) : seul le moteur répond, on peut annoncer 1 réponse.
        if config.physicalAddressing, info.proto.headerHexLength == 3, ecuOrder.count > 1,
           let engine, let id = Int(engine, radix: 16), (0x7E8...0x7EF).contains(id) {
            let request = String(id - 8, radix: 16).uppercased()
            try await at("ATSH" + request)
            let test = try await query("010C")
            if engineMessage(in: test) != nil {
                info.physicalAddressing = true
            } else {
                try await at("ATSH7DF")
            }
        }

        // Source de la pression turbo.
        info.boostSource = try await chooseBoostSource()

        // Pression atmosphérique de référence.
        if info.supportedPIDs.contains(0x33) {
            let response = try await query("0133")
            info.initialBaroKPa = decode(response).first(where: { $0.channel == .baroKPa })?.value
        }
        if info.supportedPIDs.contains(0x4F) {
            let response = try await query("014F")
            info.maxMAPKPa = decode(response).first(where: { $0.channel == .maxMAPKPa })?.value
        }
        if info.supportedPIDs.contains(0x63) {
            let response = try await query("0163")
            info.referenceTorqueNm = decode(response).first(where: { $0.channel == .referenceTorqueNm })?.value
        }
        // Puissance : couple réel du calculateur si possible, sinon charge moteur (estimation côté app).
        if info.referenceTorqueNm != nil && info.supportedPIDs.contains(0x62) {
            info.powerPID = 0x62
        } else if info.supportedPIDs.contains(0x04) {
            info.powerPID = 0x04
        }

        buildPlan()
        try await probeOptimisations()

        onEvent(.adapter(info))
        onEvent(.status("Prêt"))
        return info
    }

    private func chooseBoostSource() async throws -> BoostSource? {
        if let forced = config.forcedBoostSource { return forced }
        for source in [BoostSource.pid70, .pid87, .pid0B] where info.supportedPIDs.contains(source.pid) {
            let response = try await query(Service01.request([source.pid]))
            if decode(response).contains(where: { $0.channel == .intakePressureKPa }) {
                return source
            }
        }
        return nil
    }

    private func buildPlan() {
        var fast: [UInt8] = []
        if let boost = info.boostSource { fast.append(boost.pid) }
        fast.append(0x0C)
        if let power = info.powerPID { fast.append(power) }
        fastPIDs = fast
        slowPIDs = [0x05, 0x0F, 0x0D, 0x5C].filter { info.supportedPIDs.contains($0) }
        let now = ContinuousClock.now
        for pid in slowPIDs { nextDue[pid] = now }
        if info.supportedPIDs.contains(0x33) { nextDue[0x33] = now + config.baroInterval }
    }

    /// Vérifie que les optimisations fonctionnent avec cette voiture et cet adaptateur.
    private func probeOptimisations() async throws {
        // Requêtes multi-PID
        if config.multiPID, fastPIDs.count > 1 {
            let response = try await query(Service01.request(fastPIDs))
            let got = Set(decodePairs(response).map(\.pid))
            info.multiPID = got.isSuperset(of: fastPIDs)
        }
        // Nombre de réponses annoncé : seulement si un seul calculateur répond.
        let singleResponder = info.physicalAddressing || info.respondingECUs.count <= 1
        if config.responseCount, singleResponder {
            let pids = info.multiPID ? fastPIDs : [0x0C]
            let response = try await query(Service01.request(pids, responseCount: expectedResponses(for: pids)))
            let got = Set(decodePairs(response).map(\.pid))
            info.responseCount = !response.incomplete && got.isSuperset(of: pids)
        }
    }

    /// Nombre de réponses à annoncer à l'ELM pour une requête.
    private func expectedResponses(for pids: [UInt8]) -> Int {
        if info.proto.isCAN {
            return Service01.canFrameCount(payloadLength: Service01.payloadLength(pids))
        }
        return 1
    }

    // MARK: - Boucle de lecture

    /// Lit en continu jusqu'à l'annulation de la tâche.
    public func run() async throws {
        windowStart = .now
        var nextBattery = ContinuousClock.now

        while !Task.isCancelled {
            let now = ContinuousClock.now
            let requests = planCycle(now: now)

            for pids in requests {
                if Task.isCancelled { return }
                try await poll(pids)
            }

            if now >= nextBattery {
                nextBattery = now + config.batteryInterval
                if let reply = try? await at("ATRV"), let volts = Double(reply.uppercased().replacingOccurrences(of: "V", with: "").trimmingCharacters(in: .whitespaces)) {
                    onEvent(.readings([Reading(.batteryV, volts)]))
                }
            }

            publishStatsIfNeeded()
            try await adaptTimingIfNeeded()

            if consecutiveTimeouts >= 5 {
                throw SessionError.transport(.timeout)
            }
        }
    }

    /// Choisit les PID à lire pendant ce cycle et les regroupe en requêtes.
    private func planCycle(now: ContinuousClock.Instant) -> [[UInt8]] {
        var due: [UInt8] = []
        for pid in slowPIDs + [0x33] {
            if let date = nextDue[pid], date <= now { due.append(pid) }
        }

        let multi = info.multiPID && !multiPIDBroken
        var requests: [[UInt8]] = []
        if multi {
            // Tout ce qui est dû part avec les PID rapides, par paquets de 6 max.
            var all = fastPIDs + due
            while !all.isEmpty {
                requests.append(Array(all.prefix(6)))
                all.removeFirst(min(6, all.count))
            }
            for pid in due { reschedule(pid, now: now) }
        } else {
            requests = fastPIDs.map { [$0] }
            // Un seul PID lent par cycle pour garder un rythme régulier sur le régime / turbo.
            if let pid = due.first {
                requests.append([pid])
                reschedule(pid, now: now)
            }
        }
        return requests
    }

    private func reschedule(_ pid: UInt8, now: ContinuousClock.Instant) {
        nextDue[pid] = now + (pid == 0x33 ? config.baroInterval : config.slowInterval)
    }

    private func poll(_ pids: [UInt8]) async throws {
        let count = info.responseCount ? expectedResponses(for: pids) : nil
        recentRequests += 1
        let response: ParsedResponse
        do {
            response = try await query(Service01.request(pids, responseCount: count))
        } catch SessionError.transport(.timeout) {
            return // déjà compté ; la boucle s'arrête après plusieurs délais dépassés d'affilée
        }

        if response.statuses.contains(.noData) {
            stats.noDataCount += 1
            recentNoData += 1
        }
        if response.incomplete && count != nil {
            // L'adaptateur a coupé un message multi-trames : on n'annonce plus le nombre de réponses.
            info.responseCount = false
            log(.info, "Réponse tronquée : nombre de réponses annoncé désactivé")
            onEvent(.adapter(info))
        }

        let pairs = decodePairs(response)
        var readings: [Reading] = []
        var received = Set<UInt8>()
        for pair in pairs where pids.contains(pair.pid) {
            received.insert(pair.pid)
            readings += PIDTable.decode(pid: pair.pid, data: pair.data)
        }
        if !readings.isEmpty { onEvent(.readings(readings)) }
        if received.contains(0x0C) { windowFast += 1 }

        // PID qui ne répondent plus : retirés du plan après plusieurs échecs.
        for pid in pids where !received.contains(pid) {
            let misses = (consecutiveMisses[pid] ?? 0) + 1
            consecutiveMisses[pid] = misses
            guard misses >= 8 else { continue }
            consecutiveMisses[pid] = 0
            if pids.count > 1 && received.isEmpty && !multiPIDBroken {
                multiPIDBroken = true
                log(.info, "Requêtes groupées sans réponse : passage en requêtes simples")
            } else if !fastPIDs.contains(pid) {
                slowPIDs.removeAll { $0 == pid }
                nextDue[pid] = nil
                log(.info, "\(PIDTable.name(pid)) ne répond plus : retiré")
            }
        }
        for pid in received { consecutiveMisses[pid] = 0 }
    }

    private func adaptTimingIfNeeded() async throws {
        guard recentRequests >= 30 else { return }
        let ratio = Double(recentNoData) / Double(recentRequests)
        recentRequests = 0
        recentNoData = 0
        if ratio > 0.2 && info.aggressiveTiming {
            info.aggressiveTiming = false
            log(.info, "Trop de NO DATA (\(Int(ratio * 100)) %) : passage en AT AT1")
            try await at("ATAT1")
            onEvent(.adapter(info))
        }
    }

    private func publishStatsIfNeeded() {
        let elapsed = (ContinuousClock.now - windowStart).inSeconds
        guard elapsed >= 1 else { return }
        stats.requestsPerSecond = Double(windowRequests) / elapsed
        stats.fastUpdatesPerSecond = Double(windowFast) / elapsed
        stats.averageLatencyMs = windowRequests > 0 ? latencySum / Double(windowRequests) : 0
        onEvent(.stats(stats))
        windowStart = .now
        windowRequests = 0
        windowFast = 0
        latencySum = 0
    }

    // MARK: - Décodage

    /// Message du calculateur moteur (ou du premier qui répond si on ne le connaît pas).
    private func engineMessage(in response: ParsedResponse) -> ECUMessage? {
        let positive = response.messages.filter { $0.bytes.first == 0x41 }
        if let engine = info.engineECU, let match = positive.first(where: { $0.header == engine }) {
            return match
        }
        return positive.first
    }

    private func decodePairs(_ response: ParsedResponse) -> [(pid: UInt8, data: [UInt8])] {
        guard let message = engineMessage(in: response) else { return [] }
        return Service01.split(message.bytes) ?? []
    }

    private func decode(_ response: ParsedResponse) -> [Reading] {
        decodePairs(response).flatMap { PIDTable.decode(pid: $0.pid, data: $0.data) }
    }
}
