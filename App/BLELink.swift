import CoreBluetooth
import Foundation
import OBDKit

/// Adaptateur OBD Bluetooth LE (Veepeak OBDCheck BLE/BLE+, vLinker, etc.) vu comme un port série ELM327.
///
/// Les adaptateurs BLE « ELM327 » exposent un service avec une caractéristique d'écriture et une de notification.
/// Selon les sources, le Veepeak utilise le service FFF0 avec FFF1/FFF2 mais le rôle de chacune varie :
/// on choisit donc d'après les propriétés réelles (notify / write), pas d'après l'UUID.
final class BLELink: NSObject, ELMTransport, @unchecked Sendable {
    struct Device: Identifiable, Hashable, Sendable {
        let id: UUID
        let name: String
        let rssi: Int
        let looksLikeOBD: Bool
    }

    enum LinkError: Error, CustomStringConvertible {
        case bluetoothOff
        case unauthorized
        case notFound
        case noSerialService
        case connectionFailed(String)

        var description: String {
            switch self {
            case .bluetoothOff: return "Bluetooth désactivé"
            case .unauthorized: return "Accès Bluetooth refusé (Réglages > TrackGauge)"
            case .notFound: return "Adaptateur OBD introuvable (contact mis ? adaptateur branché ?)"
            case .noSerialService: return "Cet appareil n'expose pas de port série ELM327"
            case .connectionFailed(let reason): return "Connexion impossible : \(reason)"
            }
        }
    }

    /// Services connus des adaptateurs ELM327 BLE, par ordre de préférence.
    private static let knownServices: [CBUUID] = [
        CBUUID(string: "FFF0"),  // Veepeak, nombreux clones
        CBUUID(string: "FFE0"),  // HM-10 et clones
        CBUUID(string: "18F0"),  // vLinker, OBDLink CX
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),  // Vgate iCar Pro
    ]
    private static let ignoredServices: Set<CBUUID> = [
        CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A"), CBUUID(string: "180F"),
    ]
    private static let nameHints = ["VEEPEAK", "OBD", "VLINK", "V-LINK", "ELM", "IOS-VLINK", "KONNWEI", "VGATE", "ICAR"]

    private let queue = DispatchQueue(label: "fr.plmn.trackgauge.ble", qos: .userInteractive)
    private var central: CBCentralManager!

    // Tout l'état ci-dessous n'est touché que sur `queue`.
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var pendingServiceCount = 0
    private var discovered: [UUID: Device] = [:]
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

    private var stateWaiters: [CheckedContinuation<Void, Error>] = []
    private var connectContinuation: CheckedContinuation<String, Error>?
    private var responseContinuation: CheckedContinuation<String, Error>?
    private var receiveBuffer = ""
    private var commandSerial = 0
    /// Après un délai dépassé, on ignore brièvement ce qui arrive (fin de l'ancienne réponse).
    private var quietUntil = DispatchTime.now()

    /// Appelé (sur une file quelconque) à chaque nouvel appareil vu pendant la recherche.
    var onDevicesChanged: (@Sendable ([Device]) -> Void)?
    /// Appelé quand le lien tombe.
    var onDisconnect: (@Sendable (String) -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: - Connexion

    private func waitUntilPoweredOn() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                switch self.central.state {
                case .poweredOn: continuation.resume()
                case .unauthorized: continuation.resume(throwing: LinkError.unauthorized)
                case .poweredOff, .unsupported: continuation.resume(throwing: LinkError.bluetoothOff)
                default: self.stateWaiters.append(continuation)
                }
            }
        }
    }

    /// Lance une recherche d'appareils (pour l'écran de choix).
    func startScan() async throws {
        try await waitUntilPoweredOn()
        queue.async {
            self.discovered.removeAll()
            self.central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func stopScan() {
        queue.async { self.central.stopScan() }
    }

    /// Se connecte à l'adaptateur mémorisé ou au premier adaptateur OBD trouvé. Renvoie son nom.
    func connect(preferred: UUID?, scanTimeout: Duration = .seconds(12)) async throws -> (id: UUID, name: String) {
        try await waitUntilPoweredOn()

        var target: CBPeripheral?
        if let preferred {
            target = await onQueue { self.central.retrievePeripherals(withIdentifiers: [preferred]).first }
        }
        if target == nil {
            target = try await scanForAdapter(timeout: scanTimeout)
        }
        guard let target else { throw LinkError.notFound }

        let name = try await withTimeout(.seconds(15)) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                self.queue.async {
                    self.connectContinuation?.resume(throwing: LinkError.connectionFailed("nouvelle tentative"))
                    self.connectContinuation = continuation
                    self.peripheral = target
                    target.delegate = self
                    self.central.connect(target, options: nil)
                }
            }
        } onTimeout: {
            self.queue.async {
                self.connectContinuation?.resume(throwing: TransportError.timeout)
                self.connectContinuation = nil
                self.central.cancelPeripheralConnection(target)
            }
        }
        return (target.identifier, name)
    }

    private func scanForAdapter(timeout: Duration) async throws -> CBPeripheral? {
        try await startScan()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(300))
            let match: CBPeripheral? = await onQueue {
                let best = self.discovered.values.filter(\.looksLikeOBD).max(by: { $0.rssi < $1.rssi })
                return best.flatMap { self.discoveredPeripherals[$0.id] }
            }
            if let match {
                stopScan()
                return match
            }
        }
        stopScan()
        return nil
    }

    /// Se connecte à un appareil précis choisi dans la liste.
    func connect(to id: UUID) async throws -> (id: UUID, name: String) {
        stopScan()
        return try await connect(preferred: id, scanTimeout: .seconds(8))
    }

    func disconnect() {
        queue.async {
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.failPending(TransportError.disconnected)
            self.peripheral = nil
            self.writeCharacteristic = nil
            self.notifyCharacteristic = nil
        }
    }

    // MARK: - ELMTransport

    func send(_ command: String, timeout: Duration) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            queue.async {
                let wait = self.quietUntil > DispatchTime.now() ? self.quietUntil : DispatchTime.now()
                self.queue.asyncAfter(deadline: wait) {
                    self.write(command, timeout: timeout, continuation: continuation)
                }
            }
        }
    }

    private func write(_ command: String, timeout: Duration, continuation: CheckedContinuation<String, Error>) {
        guard let peripheral, peripheral.state == .connected, let characteristic = writeCharacteristic else {
            continuation.resume(throwing: TransportError.disconnected)
            return
        }
        guard responseContinuation == nil else {
            continuation.resume(throwing: TransportError.busy)
            return
        }
        commandSerial += 1
        let serial = commandSerial
        receiveBuffer = ""
        responseContinuation = continuation
        peripheral.writeValue(Data((command + "\r").utf8), for: characteristic, type: writeType)

        queue.asyncAfter(deadline: .now() + timeout.inSeconds) {
            guard self.commandSerial == serial, let pending = self.responseContinuation else { return }
            self.responseContinuation = nil
            self.receiveBuffer = ""
            self.quietUntil = .now() + 0.25
            pending.resume(throwing: TransportError.timeout)
        }
    }

    private func failPending(_ error: Error) {
        responseContinuation?.resume(throwing: error)
        responseContinuation = nil
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
    }

    // MARK: - Utilitaires

    private func onQueue<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func publishDevices() {
        let list = discovered.values.sorted { ($0.looksLikeOBD ? 1 : 0, $0.rssi) > ($1.looksLikeOBD ? 1 : 0, $1.rssi) }
        onDevicesChanged?(list)
    }

    private func selectCharacteristics(of peripheral: CBPeripheral) {
        let services = (peripheral.services ?? []).filter { !Self.ignoredServices.contains($0.uuid) }
        let ordered = services.sorted { a, b in
            let ia = Self.knownServices.firstIndex(of: a.uuid) ?? Int.max
            let ib = Self.knownServices.firstIndex(of: b.uuid) ?? Int.max
            return ia < ib
        }

        for service in ordered {
            let characteristics = service.characteristics ?? []
            let notify = characteristics.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            // On préfère une caractéristique d'écriture distincte de la notification quand il y en a une.
            let writable = characteristics.filter { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            let write = writable.first { $0.uuid != notify?.uuid } ?? writable.first
            if let notify, let write {
                notifyCharacteristic = notify
                writeCharacteristic = write
                writeType = write.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                peripheral.setNotifyValue(true, for: notify)
                return
            }
        }
        connectContinuation?.resume(throwing: LinkError.noSerialService)
        connectContinuation = nil
        central.cancelPeripheralConnection(peripheral)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLELink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            stateWaiters.forEach { $0.resume() }
            stateWaiters.removeAll()
        case .unauthorized:
            stateWaiters.forEach { $0.resume(throwing: LinkError.unauthorized) }
            stateWaiters.removeAll()
        case .poweredOff, .unsupported:
            stateWaiters.forEach { $0.resume(throwing: LinkError.bluetoothOff) }
            stateWaiters.removeAll()
            failPending(TransportError.disconnected)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard !name.isEmpty else { return }
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let upper = name.uppercased()
        let looksLikeOBD = Self.nameHints.contains { upper.contains($0) } || services.contains { Self.knownServices.contains($0) }
        discovered[peripheral.identifier] = Device(id: peripheral.identifier, name: name, rssi: RSSI.intValue, looksLikeOBD: looksLikeOBD)
        discoveredPeripherals[peripheral.identifier] = peripheral
        publishDevices()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: LinkError.connectionFailed(error?.localizedDescription ?? "échec"))
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        failPending(TransportError.disconnected)
        writeCharacteristic = nil
        notifyCharacteristic = nil
        onDisconnect?(error?.localizedDescription ?? "Adaptateur déconnecté")
    }
}

// MARK: - CBPeripheralDelegate

extension BLELink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (peripheral.services ?? []).filter { !Self.ignoredServices.contains($0.uuid) }
        guard error == nil, !services.isEmpty else {
            connectContinuation?.resume(throwing: LinkError.noSerialService)
            connectContinuation = nil
            return
        }
        pendingServiceCount = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        pendingServiceCount -= 1
        if pendingServiceCount <= 0 {
            selectCharacteristics(of: peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == notifyCharacteristic?.uuid else { return }
        if let error {
            connectContinuation?.resume(throwing: LinkError.connectionFailed(error.localizedDescription))
        } else {
            connectContinuation?.resume(returning: peripheral.name ?? "Adaptateur OBD")
        }
        connectContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        if DispatchTime.now() < quietUntil { return }
        guard responseContinuation != nil else { return } // données non sollicitées
        receiveBuffer += String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\u{0}", with: "")
        if let prompt = receiveBuffer.firstIndex(of: ">") {
            let response = String(receiveBuffer[..<prompt])
            receiveBuffer = ""
            let continuation = responseContinuation
            responseContinuation = nil
            continuation?.resume(returning: response)
        }
    }
}

/// Exécute `operation` avec un délai maximum.
func withTimeout<T: Sendable>(_ timeout: Duration, operation: @escaping @Sendable () async throws -> T, onTimeout: @escaping @Sendable () -> Void) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        for try await result in group {
            if let result { return result }
            onTimeout()
            throw TransportError.timeout
        }
        throw TransportError.timeout
    }
}
