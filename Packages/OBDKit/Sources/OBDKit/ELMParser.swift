import Foundation

/// Protocoles OBD tels que numérotés par l'ELM327 (commande AT DPN).
public enum OBDProtocol: Int, Sendable, Codable {
    case automatic = 0
    case j1850PWM = 1
    case j1850VPW = 2
    case iso9141 = 3
    case kwp5Baud = 4
    case kwpFast = 5
    case can11_500 = 6
    case can29_500 = 7
    case can11_250 = 8
    case can29_250 = 9
    case j1939 = 0xA
    case userCAN1 = 0xB
    case userCAN2 = 0xC

    public var isCAN: Bool { rawValue >= 6 }

    public var isKWP: Bool { self == .kwp5Baud || self == .kwpFast }

    /// Longueur de l'en-tête affiché par l'ELM (en caractères hexadécimaux) quand AT H1 est actif.
    var headerHexLength: Int {
        switch self {
        case .can11_500, .can11_250, .userCAN1, .userCAN2: return 3
        case .can29_500, .can29_250, .j1939: return 8
        default: return 6
        }
    }

    public var label: String {
        switch self {
        case .automatic: return "Automatique"
        case .j1850PWM: return "SAE J1850 PWM"
        case .j1850VPW: return "SAE J1850 VPW"
        case .iso9141: return "ISO 9141-2 (K-line)"
        case .kwp5Baud: return "ISO 14230-4 KWP2000, init 5 bauds (K-line)"
        case .kwpFast: return "ISO 14230-4 KWP2000, init rapide (K-line)"
        case .can11_500: return "ISO 15765-4 CAN 11 bits 500 kbit/s"
        case .can29_500: return "ISO 15765-4 CAN 29 bits 500 kbit/s"
        case .can11_250: return "ISO 15765-4 CAN 11 bits 250 kbit/s"
        case .can29_250: return "ISO 15765-4 CAN 29 bits 250 kbit/s"
        case .j1939: return "SAE J1939 CAN"
        case .userCAN1: return "CAN utilisateur 1"
        case .userCAN2: return "CAN utilisateur 2"
        }
    }

    /// Interprète la réponse à AT DPN (« A6 » = automatique, protocole 6).
    public init?(dpnResponse: String) {
        let cleaned = dpnResponse.uppercased().filter { $0.isHexDigit || $0 == "A" }
        guard let last = cleaned.last, let value = Int(String(last), radix: 16) else { return nil }
        self.init(rawValue: value)
    }
}

/// Messages d'état ou d'erreur que l'ELM327 peut renvoyer à la place des données.
public enum ELMStatus: Equatable, Sendable {
    case noData
    case unableToConnect
    case canError
    case busError
    case busBusy
    case bufferFull
    case dataError
    case rxError
    case stopped
    case unknownCommand
    case feedbackError
    case lowVoltageReset
    case other(String)
}

/// Un message complet d'un calculateur (trames CAN ISO-TP déjà réassemblées).
public struct ECUMessage: Equatable, Sendable {
    /// En-tête de l'émetteur (« 7E8 », « 18DAF110 », « 83F110 »…), vide si les en-têtes sont désactivés.
    public var header: String
    /// Charge utile OBD : commence par 0x41 pour le service 01, 0x7F pour une réponse négative.
    public var bytes: [UInt8]

    public init(header: String, bytes: [UInt8]) {
        self.header = header
        self.bytes = bytes
    }
}

public struct ParsedResponse: Sendable {
    public var messages: [ECUMessage] = []
    public var statuses: [ELMStatus] = []
    /// Vrai si un message multi-trames n'a pas été reçu en entier.
    public var incomplete = false
}

public enum ELMParser {
    /// Découpe la réponse brute (jusqu'au prompt « > ») en lignes utiles.
    public static func lines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: ">", with: "")
            .split(whereSeparator: { $0 == "\r" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { line in
                let upper = line.uppercased()
                return !upper.hasPrefix("SEARCHING") && !(upper.hasPrefix("BUS INIT") && upper.hasSuffix("OK"))
            }
    }

    static func status(for line: String) -> ELMStatus? {
        let compact = line.uppercased().replacingOccurrences(of: " ", with: "")
        if compact == "?" { return .unknownCommand }
        if compact.contains("NODATA") { return .noData }
        if compact.contains("UNABLETOCONNECT") { return .unableToConnect }
        if compact.contains("CANERROR") { return .canError }
        if compact.contains("BUSERROR") || (compact.hasPrefix("BUSINIT") && compact.contains("ERROR")) { return .busError }
        if compact.contains("BUSBUSY") { return .busBusy }
        if compact.contains("BUFFERFULL") { return .bufferFull }
        if compact.contains("DATAERROR") { return .dataError }
        if compact.contains("RXERROR") { return .rxError }
        if compact.contains("STOPPED") { return .stopped }
        if compact.contains("FBERROR") { return .feedbackError }
        if compact.contains("LVRESET") { return .lowVoltageReset }
        if compact.contains("ERROR") { return .other(line) }
        return nil
    }

    /// Analyse la réponse d'une requête OBD.
    /// - Parameters:
    ///   - proto: protocole actif (détermine la taille des en-têtes et le format des trames)
    ///   - headers: vrai si AT H1 est actif
    public static func parse(_ raw: String, protocol proto: OBDProtocol, headers: Bool) -> ParsedResponse {
        var result = ParsedResponse()
        var dataLines: [String] = []

        for line in lines(raw) {
            if let status = status(for: line) {
                result.statuses.append(status)
                // « 7E8 03 41 0D 00 <DATA ERROR » : on jette la ligne, la donnée n'est pas fiable.
                continue
            }
            let compact = line.replacingOccurrences(of: " ", with: "").uppercased()
            guard !compact.isEmpty else { continue }
            dataLines.append(compact)
        }

        if headers {
            if proto.isCAN {
                parseCANWithHeaders(dataLines, headerLength: proto.headerHexLength, into: &result)
            } else {
                parseLegacyWithHeaders(dataLines, kwp: proto.isKWP, into: &result)
            }
        } else {
            parseWithoutHeaders(dataLines, can: proto.isCAN, into: &result)
        }
        return result
    }

    // MARK: - CAN avec en-têtes (ISO-TP réassemblé ici)

    private static func parseCANWithHeaders(_ lines: [String], headerLength: Int, into result: inout ParsedResponse) {
        struct Assembly { var expected: Int; var data: [UInt8] }
        var assemblies: [String: Assembly] = [:]
        var order: [String] = []

        for line in lines {
            guard line.count > headerLength + 1 else { continue }
            let header = String(line.prefix(headerLength))
            guard let bytes = hexBytes(String(line.dropFirst(headerLength))), let pci = bytes.first else { continue }

            switch pci >> 4 {
            case 0x0: // trame unique
                let length = Int(pci & 0x0F)
                guard length > 0 else { continue }
                let available = min(length, bytes.count - 1)
                if available < length { result.incomplete = true }
                result.messages.append(ECUMessage(header: header, bytes: Array(bytes[1..<(1 + available)])))
            case 0x1: // première trame d'un message multi-trames
                guard bytes.count >= 2 else { continue }
                let length = Int(pci & 0x0F) << 8 | Int(bytes[1])
                assemblies[header] = Assembly(expected: length, data: Array(bytes.dropFirst(2)))
                if !order.contains(header) { order.append(header) }
            case 0x2: // trame consécutive
                guard var assembly = assemblies[header] else { continue }
                assembly.data.append(contentsOf: bytes.dropFirst())
                assemblies[header] = assembly
            default: // 0x3 = contrôle de flux, ignoré
                continue
            }
        }

        for header in order {
            guard let assembly = assemblies[header] else { continue }
            if assembly.data.count >= assembly.expected {
                result.messages.append(ECUMessage(header: header, bytes: Array(assembly.data.prefix(assembly.expected))))
            } else {
                result.incomplete = true
                result.messages.append(ECUMessage(header: header, bytes: assembly.data))
            }
        }
    }

    // MARK: - K-line / J1850 avec en-têtes

    private static func parseLegacyWithHeaders(_ lines: [String], kwp: Bool, into result: inout ParsedResponse) {
        for line in lines {
            guard let bytes = hexBytes(line), bytes.count >= 4 else { continue }
            if kwp {
                // Octet de format : bits 7-6 = mode d'adressage, bits 5-0 = longueur (0 → octet de longueur séparé).
                let format = bytes[0]
                var index = 1
                if format & 0xC0 != 0 { index += 2 } // cible + source
                var length = Int(format & 0x3F)
                if length == 0 {
                    guard index < bytes.count else { continue }
                    length = Int(bytes[index])
                    index += 1
                }
                guard index < bytes.count else { continue }
                let end = min(index + length, bytes.count)
                if end - index < length { result.incomplete = true }
                result.messages.append(ECUMessage(header: hex(bytes[0..<index]), bytes: Array(bytes[index..<end])))
            } else {
                // ISO 9141 / J1850 : 3 octets d'en-tête, données, puis 1 octet de somme de contrôle.
                guard bytes.count >= 5 else { continue }
                result.messages.append(ECUMessage(header: hex(bytes[0..<3]), bytes: Array(bytes[3..<(bytes.count - 1)])))
            }
        }
    }

    // MARK: - Sans en-têtes (mode de secours)

    private static func parseWithoutHeaders(_ lines: [String], can: Bool, into result: inout ParsedResponse) {
        // Format multi-trames de l'ELM sans en-têtes : « 00E » puis « 0:4170… », « 1:… »
        var expectedLength: Int?
        var segments: [UInt8] = []
        var sawSegments = false

        for line in lines {
            if can, line.count == 3, let length = Int(line, radix: 16) {
                expectedLength = length
                continue
            }
            if let colon = line.firstIndex(of: ":") {
                sawSegments = true
                if let bytes = hexBytes(String(line[line.index(after: colon)...])) {
                    segments.append(contentsOf: bytes)
                }
                continue
            }
            if let bytes = hexBytes(line), !bytes.isEmpty {
                result.messages.append(ECUMessage(header: "", bytes: bytes))
            }
        }

        if sawSegments {
            if let expected = expectedLength {
                if segments.count < expected { result.incomplete = true }
                segments = Array(segments.prefix(expected))
            }
            result.messages.append(ECUMessage(header: "", bytes: segments))
        }
    }

    // MARK: - Utilitaires

    public static func hexBytes(_ string: String) -> [UInt8]? {
        let chars = Array(string.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let hi = nibble(chars[index]), let lo = nibble(chars[index + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48        // 0-9
        case 65...70: return c - 55        // A-F
        case 97...102: return c - 87       // a-f
        default: return nil
        }
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}

/// Décodage des réponses du service 01.
public enum Service01 {
    /// Découpe une réponse « 41 0C 1A F8 0B 8C » en paires PID → données.
    /// Retourne nil si ce n'est pas une réponse positive au service 01.
    public static func split(_ bytes: [UInt8]) -> [(pid: UInt8, data: [UInt8])]? {
        guard bytes.first == 0x41 else { return nil }
        var out: [(pid: UInt8, data: [UInt8])] = []
        var index = 1
        while index < bytes.count {
            let pid = bytes[index]
            guard let length = PIDTable.dataLength(pid), index + 1 + length <= bytes.count else { break }
            out.append((pid, Array(bytes[(index + 1)..<(index + 1 + length)])))
            index += 1 + length
        }
        return out
    }

    /// Construit la requête : « 01 » + PID… + éventuellement le nombre de réponses attendues (optimisation ELM327 ≥ 1.3).
    public static func request(_ pids: [UInt8], responseCount: Int? = nil) -> String {
        var command = "01" + pids.map { String(format: "%02X", $0) }.joined()
        if let count = responseCount, (1...15).contains(count) {
            command += String(count, radix: 16).uppercased()
        }
        return command
    }

    /// Taille de la réponse (0x41 + PID + données) pour une liste de PID.
    public static func payloadLength(_ pids: [UInt8]) -> Int {
        1 + pids.reduce(0) { $0 + 1 + (PIDTable.dataLength($1) ?? 0) }
    }

    /// Nombre de trames CAN (ISO-TP) pour une charge utile donnée.
    public static func canFrameCount(payloadLength length: Int) -> Int {
        if length <= 7 { return 1 }
        return 1 + Int((Double(length - 6) / 7).rounded(.up))
    }
}
