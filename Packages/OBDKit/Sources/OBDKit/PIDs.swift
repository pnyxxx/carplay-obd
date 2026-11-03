import Foundation

/// Grandeurs physiques produites par le décodage OBD.
public enum Channel: String, Sendable, Codable, CaseIterable {
    case rpm                  // tr/min
    case intakePressureKPa    // pression absolue d'admission / de suralimentation (kPa)
    case boostTargetKPa       // pression de suralimentation demandée par le calculateur (kPa, absolue)
    case baroKPa              // pression atmosphérique (kPa)
    case coolantC             // température d'eau (°C)
    case intakeAirC           // température d'air d'admission (°C)
    case oilC                 // température d'huile (°C)
    case speedKmh             // vitesse véhicule (km/h)
    case throttlePct          // position papillon / pédale (%)
    case engineLoadPct        // charge moteur calculée (%)
    case batteryV             // tension mesurée par l'adaptateur (V)
    case maxMAPKPa            // échelle max du capteur MAP annoncée par le PID 0x4F (kPa)
}

public struct Reading: Sendable, Equatable {
    public var channel: Channel
    public var value: Double

    public init(_ channel: Channel, _ value: Double) {
        self.channel = channel
        self.value = value
    }
}

/// D'où vient la pression de turbo.
public enum BoostSource: String, Sendable, Codable, CaseIterable {
    /// PID 0x70 « Boost pressure control » : capteur de suralimentation, résolution 1/32 kPa, jusqu'à 2048 kPa.
    case pid70
    /// PID 0x87 « Intake manifold absolute pressure » étendu : résolution 1/32 kPa, jusqu'à 2048 kPa.
    case pid87
    /// PID 0x0B « MAP » classique : 1 kPa, plafonné à 255 kPa (≈ 1,54 bar relatif au niveau de la mer).
    case pid0B

    public var pid: UInt8 {
        switch self {
        case .pid70: return 0x70
        case .pid87: return 0x87
        case .pid0B: return 0x0B
        }
    }

    public var label: String {
        switch self {
        case .pid70: return "PID 0x70 (capteur turbo, 1/32 kPa)"
        case .pid87: return "PID 0x87 (MAP étendu, 1/32 kPa)"
        case .pid0B: return "PID 0x0B (MAP, max 255 kPa)"
        }
    }
}

/// Table des PID du service 01 que l'app sait décoder (longueur des données + formule).
/// Formules : SAE J1979 / https://en.wikipedia.org/wiki/OBD-II_PIDs
public enum PIDTable {
    /// Nombre d'octets de données renvoyés par le PID (hors octet de PID).
    public static func dataLength(_ pid: UInt8) -> Int? {
        switch pid {
        case 0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0: return 4  // bitmaps « PID supportés »
        case 0x04, 0x05, 0x0B, 0x0D, 0x0F, 0x11, 0x33, 0x5C: return 1
        case 0x0C: return 2
        case 0x4F: return 4
        case 0x70: return 10
        case 0x87: return 5
        default: return nil
        }
    }

    public static func name(_ pid: UInt8) -> String {
        switch pid {
        case 0x04: return "Charge moteur"
        case 0x05: return "Température d'eau"
        case 0x0B: return "Pression admission (MAP)"
        case 0x0C: return "Régime moteur"
        case 0x0D: return "Vitesse"
        case 0x0F: return "Température d'air admission"
        case 0x11: return "Papillon / pédale"
        case 0x33: return "Pression atmosphérique"
        case 0x4F: return "Valeurs max (MAP…)"
        case 0x5C: return "Température d'huile"
        case 0x70: return "Contrôle suralimentation"
        case 0x87: return "MAP étendu"
        default: return String(format: "PID 0x%02X", pid)
        }
    }

    /// Décode les octets de données d'un PID en grandeurs physiques.
    public static func decode(pid: UInt8, data d: [UInt8]) -> [Reading] {
        guard let len = dataLength(pid), d.count >= len else { return [] }
        let a = Double(d[0])
        switch pid {
        case 0x04: return [Reading(.engineLoadPct, a * 100 / 255)]
        case 0x05: return [Reading(.coolantC, a - 40)]
        case 0x0B: return [Reading(.intakePressureKPa, a)]
        case 0x0C: return [Reading(.rpm, (a * 256 + Double(d[1])) / 4)]
        case 0x0D: return [Reading(.speedKmh, a)]
        case 0x0F: return [Reading(.intakeAirC, a - 40)]
        case 0x11: return [Reading(.throttlePct, a * 100 / 255)]
        case 0x33: return [Reading(.baroKPa, a)]
        case 0x4F:
            let maxMAP = Double(d[3]) * 10
            return maxMAP > 0 ? [Reading(.maxMAPKPa, maxMAP)] : []
        case 0x5C: return [Reading(.oilC, a - 40)]
        case 0x70:
            // A = bits de support : b0 consigne A, b1 capteur A, b2 consigne B, b3 capteur B.
            // B-C = consigne A, D-E = capteur A (1/32 kPa).
            let support = d[0]
            let commanded = word(d[1], d[2]) / 32
            let actual = word(d[3], d[4]) / 32
            var out: [Reading] = []
            // Certains calculateurs laissent les bits de support à 0 : on accepte alors une valeur plausible.
            if support & 0x02 != 0 || (support == 0 && actual > 20) { out.append(Reading(.intakePressureKPa, actual)) }
            if support & 0x01 != 0 || (support == 0 && commanded > 20) { out.append(Reading(.boostTargetKPa, commanded)) }
            return out
        case 0x87:
            // A = bits de support : b0 capteur A, b1 capteur B. B-C = capteur A (1/32 kPa).
            let support = d[0]
            let sensorA = word(d[1], d[2]) / 32
            if support & 0x01 != 0 || (support == 0 && sensorA > 20) { return [Reading(.intakePressureKPa, sensorA)] }
            return []
        default:
            return []
        }
    }

    /// Décode un bitmap « PID supportés » (réponse à 0x00, 0x20, 0x40…).
    /// Le bit de poids fort du premier octet correspond à base+1.
    public static func supportedPIDs(base: UInt8, bitmap: [UInt8]) -> Set<UInt8> {
        guard bitmap.count >= 4 else { return [] }
        var result = Set<UInt8>()
        for byteIndex in 0..<4 {
            for bit in 0..<8 where bitmap[byteIndex] & (0x80 >> UInt8(bit)) != 0 {
                let pid = Int(base) + byteIndex * 8 + bit + 1
                if pid <= 0xFF { result.insert(UInt8(pid)) }
            }
        }
        return result
    }

    private static func word(_ hi: UInt8, _ lo: UInt8) -> Double {
        Double(UInt16(hi) << 8 | UInt16(lo))
    }
}
