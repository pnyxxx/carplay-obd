import XCTest
@testable import OBDKit

final class ParserTests: XCTestCase {
    func testSingleFrameCAN11WithHeaders() {
        let response = ELMParser.parse("7E8064100BE3EB811\r\r>", protocol: .can11_500, headers: true)
        XCTAssertEqual(response.messages, [ECUMessage(header: "7E8", bytes: [0x41, 0x00, 0xBE, 0x3E, 0xB8, 0x11])])
        XCTAssertFalse(response.incomplete)
    }

    func testSpacesAndPaddingAreHandled() {
        // Certains calculateurs complètent la trame à 8 octets : la longueur PCI fait foi.
        let response = ELMParser.parse("7E8 03 41 0D 32 AA AA AA AA\r\r>", protocol: .can11_500, headers: true)
        XCTAssertEqual(response.messages.first?.bytes, [0x41, 0x0D, 0x32])
    }

    func testMultiFrameCAN11WithHeaders() {
        // 0170 : 12 octets → première trame + 1 trame consécutive
        let raw = "7E8100C417003111111\r7E821111111110000AA\r\r>"
        let response = ELMParser.parse(raw, protocol: .can11_500, headers: true)
        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages[0].bytes.count, 12)
        XCTAssertEqual(Array(response.messages[0].bytes.prefix(3)), [0x41, 0x70, 0x03])
        XCTAssertFalse(response.incomplete)
    }

    func testIncompleteMultiFrame() {
        let response = ELMParser.parse("7E8100C41700311\r\r>", protocol: .can11_500, headers: true)
        XCTAssertTrue(response.incomplete)
    }

    func testTwoECUsAnswer() {
        let raw = "7E8064100BE3EB811\r7E906410080000001\r\r>"
        let response = ELMParser.parse(raw, protocol: .can11_500, headers: true)
        XCTAssertEqual(response.messages.map(\.header), ["7E8", "7E9"])
    }

    func testCAN29Headers() {
        let response = ELMParser.parse("18DAF11004410C1AF8\r\r>", protocol: .can29_500, headers: true)
        XCTAssertEqual(response.messages, [ECUMessage(header: "18DAF110", bytes: [0x41, 0x0C, 0x1A, 0xF8])])
    }

    func testKWPWithHeaders() {
        // E90 avant 03/2007 : K-line KWP2000. Format 0x84 = adresses + 4 octets de données, puis somme de contrôle.
        let response = ELMParser.parse("84F112410C1AF8C3\r\r>", protocol: .kwpFast, headers: true)
        XCTAssertEqual(response.messages, [ECUMessage(header: "F112", bytes: [0x41, 0x0C, 0x1A, 0xF8])])
        // Même calculateur, réponse plus longue : même identifiant.
        let longer = ELMParser.parse("86F1124100BE3EB811AA\r\r>", protocol: .kwpFast, headers: true)
        XCTAssertEqual(longer.messages.first?.header, "F112")
        XCTAssertEqual(longer.messages.first?.bytes, [0x41, 0x00, 0xBE, 0x3E, 0xB8, 0x11])
    }

    func testISO9141WithHeaders() {
        let response = ELMParser.parse("486B10410C1AF8D0\r\r>", protocol: .iso9141, headers: true)
        XCTAssertEqual(response.messages.first?.bytes, [0x41, 0x0C, 0x1A, 0xF8])
    }

    func testHeadersOffMultiFrame() {
        let raw = "00C\r0:417003111111\r1:11111111110000\r\r>"
        let response = ELMParser.parse(raw, protocol: .can11_500, headers: false)
        XCTAssertEqual(response.messages.count, 1)
        XCTAssertEqual(response.messages[0].bytes.count, 12)
    }

    func testErrors() {
        XCTAssertEqual(ELMParser.parse("NO DATA\r\r>", protocol: .can11_500, headers: true).statuses, [.noData])
        let searching = ELMParser.parse("SEARCHING...\rUNABLE TO CONNECT\r\r>", protocol: .automatic, headers: true)
        XCTAssertEqual(searching.statuses, [.unableToConnect])
        XCTAssertEqual(ELMParser.parse("?\r\r>", protocol: .can11_500, headers: true).statuses, [.unknownCommand])
        XCTAssertEqual(ELMParser.parse("7E803410D00<DATA ERROR\r\r>", protocol: .can11_500, headers: true).statuses, [.dataError])
    }

    func testProtocolFromDPN() {
        XCTAssertEqual(OBDProtocol(dpnResponse: "A6"), .can11_500)
        XCTAssertEqual(OBDProtocol(dpnResponse: "5"), .kwpFast)
        XCTAssertEqual(OBDProtocol(dpnResponse: "A7"), .can29_500)
    }
}

final class DecoderTests: XCTestCase {
    func testMultiPIDSplitAndDecode() {
        let pairs = Service01.split([0x41, 0x0C, 0x1A, 0xF8, 0x0B, 0xC8, 0x05, 0x7B])!
        XCTAssertEqual(pairs.map(\.pid), [0x0C, 0x0B, 0x05])
        let readings = pairs.flatMap { PIDTable.decode(pid: $0.pid, data: $0.data) }
        XCTAssertEqual(readings, [Reading(.rpm, 1726), Reading(.intakePressureKPa, 200), Reading(.coolantC, 83)])
    }

    func testPID70() {
        // consigne 230 kPa, réelle 224,5 kPa (×32)
        let data: [UInt8] = [0x03, 0x1C, 0xC0, 0x1C, 0x10, 0, 0, 0, 0, 0]
        let readings = PIDTable.decode(pid: 0x70, data: data)
        XCTAssertEqual(readings, [Reading(.intakePressureKPa, 224.5), Reading(.boostTargetKPa, 230)])
    }

    func testTorquePIDs() {
        XCTAssertEqual(PIDTable.decode(pid: 0x62, data: [0xC8]), [Reading(.actualTorquePct, 75)])
        XCTAssertEqual(PIDTable.decode(pid: 0x63, data: [0x01, 0x90]), [Reading(.referenceTorqueNm, 400)])
    }

    func testPID87() {
        XCTAssertEqual(PIDTable.decode(pid: 0x87, data: [0x01, 0x20, 0x00, 0, 0]), [Reading(.intakePressureKPa, 256)])
    }

    func testSupportedBitmap() {
        // Exemple de Wikipédia : BE1FA813
        let set = PIDTable.supportedPIDs(base: 0, bitmap: [0xBE, 0x1F, 0xA8, 0x13])
        XCTAssertEqual(set, [0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x1C, 0x1F, 0x20])
    }

    func testRequestBuilding() {
        XCTAssertEqual(Service01.request([0x0C]), "010C")
        XCTAssertEqual(Service01.request([0x0C, 0x0B], responseCount: 1), "010C0B1")
        XCTAssertEqual(Service01.payloadLength([0x0C, 0x0B]), 6)
        XCTAssertEqual(Service01.canFrameCount(payloadLength: 6), 1)
        XCTAssertEqual(Service01.canFrameCount(payloadLength: 7), 1)
        XCTAssertEqual(Service01.canFrameCount(payloadLength: 8), 2)
        XCTAssertEqual(Service01.canFrameCount(payloadLength: 13), 2)
        XCTAssertEqual(Service01.canFrameCount(payloadLength: 14), 3)
    }
}

final class SessionTests: XCTestCase {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _readings: [Reading] = []
        private var _stats: [PollStats] = []
        var readings: [Reading] { lock.lock(); defer { lock.unlock() }; return _readings }
        var stats: [PollStats] { lock.lock(); defer { lock.unlock() }; return _stats }
        func handle(_ event: SessionEvent) {
            lock.lock(); defer { lock.unlock() }
            switch event {
            case .readings(let r): _readings += r
            case .stats(let s): _stats.append(s)
            default: break
            }
        }
    }

    func testFullSessionAgainstSimulator() async throws {
        let collector = Collector()
        let session = ELMSession(transport: SimulatedELM(latency: .milliseconds(5))) { collector.handle($0) }
        let info = try await session.initialize()

        XCTAssertEqual(info.proto, .can11_500)
        XCTAssertTrue(info.headersEnabled)
        XCTAssertEqual(info.engineECU, "7E8")
        XCTAssertEqual(info.respondingECUs, ["7E8", "7E9"])
        XCTAssertTrue(info.physicalAddressing)
        XCTAssertEqual(info.boostSource, .pid70)
        XCTAssertTrue(info.multiPID)
        XCTAssertTrue(info.responseCount)
        XCTAssertEqual(info.initialBaroKPa, 101)
        XCTAssertNotNil(info.stnIdentity)
        XCTAssertTrue(info.supportedPIDs.isSuperset(of: [0x05, 0x0B, 0x0C, 0x33, 0x70]))
        XCTAssertEqual(info.referenceTorqueNm, 400)
        XCTAssertEqual(info.powerPID, 0x62)

        let task = Task { try await session.run() }
        try await Task.sleep(for: .milliseconds(1300))
        task.cancel()
        _ = try? await task.value

        let channels = Set(collector.readings.map(\.channel))
        XCTAssertTrue(channels.isSuperset(of: [.rpm, .intakePressureKPa, .boostTargetKPa, .coolantC, .intakeAirC, .speedKmh, .actualTorquePct]), "\(channels)")
        XCTAssertGreaterThan(collector.stats.last?.fastUpdatesPerSecond ?? 0, 20)
        XCTAssertTrue(collector.readings.filter { $0.channel == .rpm }.allSatisfy { $0.value > 500 && $0.value < 5000 })
    }

    func testKLineSession() async throws {
        // E90 d'avant 2007 environ : K-line (KWP2000), pas d'adressage direct, plusieurs calculateurs.
        let collector = Collector()
        let session = ELMSession(transport: SimulatedELM(latency: .milliseconds(3), proto: .kwpFast)) { collector.handle($0) }
        let info = try await session.initialize()
        XCTAssertEqual(info.proto, .kwpFast)
        XCTAssertEqual(info.engineECU, "F110")
        XCTAssertEqual(info.respondingECUs, ["F110", "F118"])
        XCTAssertFalse(info.physicalAddressing)
        XCTAssertFalse(info.responseCount)
        XCTAssertEqual(info.boostSource, .pid70)

        let task = Task { try await session.run() }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        _ = try? await task.value
        let channels = Set(collector.readings.map(\.channel))
        XCTAssertTrue(channels.isSuperset(of: [.rpm, .intakePressureKPa, .coolantC]), "\(channels)")
    }

    func testFallsBackToPID0BWithout70() async throws {
        let session = ELMSession(transport: SimulatedELM(car: SimulatedCar(supportsPID70: false), latency: .milliseconds(2))) { _ in }
        let info = try await session.initialize()
        XCTAssertEqual(info.boostSource, .pid0B)
        // Sans PID 0x62/0x63 : estimation par la charge moteur.
        XCTAssertEqual(info.powerPID, 0x04)
    }

    func testWithoutOptimisations() async throws {
        var config = SessionConfig()
        config.multiPID = false
        config.responseCount = false
        config.physicalAddressing = false
        let collector = Collector()
        let session = ELMSession(transport: SimulatedELM(latency: .milliseconds(2)), config: config) { collector.handle($0) }
        let info = try await session.initialize()
        XCTAssertFalse(info.multiPID)
        XCTAssertFalse(info.physicalAddressing)

        let task = Task { try await session.run() }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        _ = try? await task.value
        XCTAssertTrue(Set(collector.readings.map(\.channel)).isSuperset(of: [.rpm, .intakePressureKPa, .coolantC]))
    }
}
