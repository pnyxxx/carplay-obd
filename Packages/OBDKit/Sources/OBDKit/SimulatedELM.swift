import Foundation

/// Voiture virtuelle : un 320d qui enchaîne des accélérations, pour le mode démo et les tests.
public struct SimulatedCar: Sendable {
    public struct State: Sendable {
        public var rpm: Double
        public var boostKPa: Double        // pression relative
        public var boostTargetKPa: Double  // consigne relative
        public var coolantC: Double
        public var intakeAirC: Double
        public var speedKmh: Double
        public var throttlePct: Double
        /// Couple réel en % du couple de référence (400 Nm).
        public var torquePct: Double
    }

    public var baroKPa: Double = 101
    public var supportsPID70 = true

    public init(supportsPID70: Bool = true) {
        self.supportsPID70 = supportsPID70
    }

    public func state(at t: Double) -> State {
        let cycle = t.truncatingRemainder(dividingBy: 26)
        var rpm = 850.0
        var throttle = 0.0
        var gearFactor = 120.0

        switch cycle {
        case ..<4: // ralenti
            rpm = 850 + 12 * sin(t * 7)
        case ..<17: // trois rapports à fond
            let inGear = (cycle - 4).truncatingRemainder(dividingBy: 4.33) / 4.33
            let gear = Int((cycle - 4) / 4.33)
            let startRPM = gear == 0 ? 1100.0 : 2500.0
            rpm = startRPM + (4400 - startRPM) * ease(inGear)
            throttle = 100
            gearFactor = [120.0, 72, 50][min(gear, 2)]
        case ..<21: // lever de pied
            let k = (cycle - 17) / 4
            rpm = 4300 - 2500 * ease(k)
            gearFactor = 50
        default: // croisière
            rpm = 1850 + 25 * sin(t * 2)
            throttle = 22
            gearFactor = 50
        }

        // Turbo : consigne qui monte avec le régime à pleine charge, pression réelle en retard (inertie).
        let target = throttle > 50 ? 155 * smoothstep((rpm - 1300) / 1100) - 25 * smoothstep((rpm - 3600) / 800) : throttle * 0.6
        let lag = smoothstep((cycle.truncatingRemainder(dividingBy: 4.33) + 0.2) / 1.0)
        let boost = max(0, (throttle > 50 ? target * lag : target) + 2 * sin(t * 13))

        return State(
            rpm: max(0, rpm),
            boostKPa: boost,
            boostTargetKPa: target,
            coolantC: 62 + 28 * min(1, t / 90),
            intakeAirC: 27 + boost / 12,
            speedKmh: rpm / gearFactor,
            throttlePct: throttle,
            torquePct: throttle > 50 ? min(88, 45 + boost / 4) * (rpm > 3200 ? 1 - (rpm - 3200) / 4000 : 1) : throttle * 0.4
        )
    }

    private func ease(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return 1 - (1 - c) * (1 - c)
    }

    private func smoothstep(_ x: Double) -> Double {
        let c = min(max(x, 0), 1)
        return c * c * (3 - 2 * c)
    }

    var engineSupported: Set<UInt8> {
        var set: Set<UInt8> = [0x01, 0x04, 0x05, 0x0B, 0x0C, 0x0D, 0x0F, 0x11, 0x1C, 0x20, 0x21, 0x33, 0x40, 0x42]
        if supportsPID70 { set.formUnion([0x60, 0x62, 0x63, 0x70]) }
        return set
    }

    /// Données brutes d'un PID (nil = non supporté).
    func data(for pid: UInt8, at t: Double) -> [UInt8]? {
        if pid % 0x20 == 0 {
            guard pid == 0 || engineSupported.contains(pid) else { return nil }
            return bitmap(base: pid, supported: engineSupported)
        }
        guard engineSupported.contains(pid) else { return nil }
        let s = state(at: t)
        func byte(_ v: Double) -> UInt8 { UInt8(clamping: Int(v.rounded())) }
        func word(_ v: Double) -> [UInt8] {
            let w = UInt16(clamping: Int(v.rounded()))
            return [UInt8(w >> 8), UInt8(w & 0xFF)]
        }
        switch pid {
        case 0x04: return [byte(s.throttlePct * 2.55)]
        case 0x05: return [byte(s.coolantC + 40)]
        case 0x0B: return [byte(baroKPa + s.boostKPa)]
        case 0x0C: return word(s.rpm * 4)
        case 0x0D: return [byte(s.speedKmh)]
        case 0x0F: return [byte(s.intakeAirC + 40)]
        case 0x11: return [byte(s.throttlePct * 2.55)]
        case 0x1C: return [0x06] // EOBD
        case 0x21: return [0, 0]
        case 0x33: return [byte(baroKPa)]
        case 0x42: return word(13800)
        case 0x62: return [byte(s.torquePct + 125)]
        case 0x63: return word(400)
        case 0x70:
            return [0x03] + word((baroKPa + s.boostTargetKPa) * 32) + word((baroKPa + s.boostKPa) * 32) + [0, 0, 0, 0, 0]
        default: return nil
        }
    }

    func bitmap(base: UInt8, supported: Set<UInt8>) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        for offset in 1...32 {
            let pid = Int(base) + offset
            guard pid <= 0xFF, supported.contains(UInt8(pid)) else { continue }
            bytes[(offset - 1) / 8] |= 0x80 >> UInt8((offset - 1) % 8)
        }
        return bytes
    }
}

/// Faux adaptateur ELM327 (CAN 11 bits, comme une E90 récente) : répond comme un vrai,
/// avec en-têtes, trames multiples ISO-TP et un deuxième calculateur (boîte de vitesses).
public final class SimulatedELM: ELMTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var echo = true
    private var headers = false
    private var spaces = true
    private var requestHeader = "7DF"
    private let startDate = Date()
    private let latency: Duration
    private let stn: Bool
    private let proto: OBDProtocol
    public let car: SimulatedCar

    /// - Parameter proto: `.can11_500` (E90 récente, D-CAN) ou `.kwpFast` (E90 ancienne, K-line).
    public init(car: SimulatedCar = SimulatedCar(), latency: Duration = .milliseconds(30), stn: Bool = true, proto: OBDProtocol = .can11_500) {
        self.car = car
        self.latency = latency
        self.stn = stn
        self.proto = proto
    }

    public func send(_ command: String, timeout: Duration) async throws -> String {
        try await Task.sleep(for: latency)
        return respondLocked(to: command)
    }

    private func respondLocked(to command: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return respond(to: command)
    }

    private func respond(to rawCommand: String) -> String {
        let command = rawCommand.uppercased().replacingOccurrences(of: " ", with: "")
        var lines: [String]

        if command.hasPrefix("AT") {
            lines = handleAT(String(command.dropFirst(2)))
        } else if command == "STI" {
            lines = [stn ? "STN2120 v5.10.3" : "?"]
        } else if command.hasPrefix("01") {
            lines = handleService01(String(command.dropFirst(2)))
        } else {
            lines = ["?"]
        }

        var out = echo ? rawCommand + "\r" : ""
        out += lines.map { $0 + "\r" }.joined()
        return out + "\r>"
    }

    private func handleAT(_ cmd: String) -> [String] {
        switch cmd {
        case "Z":
            echo = true; headers = false; spaces = true; requestHeader = "7DF"
            return ["", "ELM327 v1.5"]
        case "E0": echo = false
        case "E1": echo = true
        case "H0": headers = false
        case "H1": headers = true
        case "S0": spaces = false
        case "S1": spaces = true
        case "I": return ["ELM327 v1.5"]
        case "DPN": return ["A" + String(proto.rawValue, radix: 16).uppercased()]
        case "RV": return ["13.9V"]
        default:
            if cmd.hasPrefix("SH") { requestHeader = String(cmd.dropFirst(2)) }
        }
        return ["OK"]
    }

    private func handleService01(_ body: String) -> [String] {
        var hex = body
        var maxFrames: Int?
        if hex.count % 2 == 1, let last = hex.last, let n = Int(String(last), radix: 16) {
            maxFrames = n
            hex.removeLast()
        }
        guard let pids = ELMParser.hexBytes(hex), !pids.isEmpty, pids.count <= 6 else { return ["?"] }

        let t = Date().timeIntervalSince(startDate)
        var payload: [UInt8] = [0x41]
        for pid in pids {
            if let data = car.data(for: pid, at: t) { payload += [pid] + data }
        }

        let engineID = proto.isCAN ? "7E8" : "10"
        let gearboxID = proto.isCAN ? "7E9" : "18"
        var messages: [(header: String, payload: [UInt8])] = []
        if payload.count > 1 { messages.append((engineID, payload)) }
        // La boîte de vitesses répond aussi aux requêtes « PID supportés » envoyées à tous (7DF).
        if requestHeader == "7DF", pids.count == 1, pids[0] == 0x00 {
            messages.append((gearboxID, [0x41, 0x00] + car.bitmap(base: 0, supported: [0x01, 0x0D, 0x1C])))
        }
        guard !messages.isEmpty else { return ["NO DATA"] }

        var frames: [String] = []
        for message in messages {
            frames += format(message.payload, header: message.header)
        }
        if let maxFrames, maxFrames < frames.count { frames = Array(frames.prefix(maxFrames)) }
        return frames
    }

    private func format(_ payload: [UInt8], header: String) -> [String] {
        let sep = spaces ? " " : ""
        func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: sep) }

        if !proto.isCAN {
            // KWP2000 : octet de format (adresses + longueur), cible F1, source, données, somme de contrôle.
            guard headers else { return [hex(payload)] }
            let source = UInt8(header, radix: 16) ?? 0x10
            var frame: [UInt8] = [0x80 | UInt8(payload.count), 0xF1, source] + payload
            frame.append(UInt8(truncatingIfNeeded: frame.reduce(0) { $0 + Int($1) }))
            return [hex(frame)]
        }

        if !headers {
            if payload.count <= 7 { return [hex(payload)] }
            var lines = [String(format: "%03X", payload.count)]
            var rest = payload
            var index = 0
            let first = Array(rest.prefix(6)); rest.removeFirst(min(6, rest.count))
            lines.append("\(index):" + sep + hex(first))
            while !rest.isEmpty {
                index += 1
                let chunk = Array(rest.prefix(7)); rest.removeFirst(min(7, rest.count))
                lines.append("\(index % 16):" + sep + hex(chunk))
            }
            return lines
        }

        if payload.count <= 7 {
            return [header + sep + hex([UInt8(payload.count)] + payload)]
        }
        var lines: [String] = []
        var rest = payload
        let first = [0x10 | UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + rest.prefix(6)
        rest.removeFirst(min(6, rest.count))
        lines.append(header + sep + hex(first))
        var sequence: UInt8 = 1
        while !rest.isEmpty {
            let chunk = Array(rest.prefix(7)); rest.removeFirst(min(7, rest.count))
            lines.append(header + sep + hex([0x20 | (sequence & 0x0F)] + chunk))
            sequence &+= 1
        }
        return lines
    }
}
