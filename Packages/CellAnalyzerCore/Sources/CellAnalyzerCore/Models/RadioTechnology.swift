import Foundation

/// Broad radio-access family. Cells are only comparable within the same family.
public enum RadioFamily: String, Codable, CaseIterable, Sendable, Comparable {
    case gsm, cdma, umts, lte, nr, unknown

    public var displayName: String {
        switch self {
        case .gsm: return "GSM"
        case .cdma: return "CDMA"
        case .umts: return "UMTS"
        case .lte: return "LTE"
        case .nr: return "5G NR"
        case .unknown: return "Unknown"
        }
    }

    /// Value used by OpenCellID's `radio` parameter.
    public var openCellIDRadio: String? {
        switch self {
        case .gsm: return "GSM"
        case .cdma: return "CDMA"
        case .umts: return "UMTS"
        case .lte: return "LTE"
        case .nr: return "NR"
        case .unknown: return nil
        }
    }

    private var order: Int {
        switch self {
        case .nr: return 0
        case .lte: return 1
        case .umts: return 2
        case .cdma: return 3
        case .gsm: return 4
        case .unknown: return 5
        }
    }

    public static func < (lhs: RadioFamily, rhs: RadioFamily) -> Bool { lhs.order < rhs.order }
}

/// Mobile network generation.
public enum NetworkGeneration: Int, Codable, CaseIterable, Sendable, Comparable {
    case unknown = 0, g2 = 2, g3 = 3, g4 = 4, g5 = 5

    public var displayName: String {
        self == .unknown ? "?" : "\(rawValue)G"
    }

    public static func < (lhs: NetworkGeneration, rhs: NetworkGeneration) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Radio access technology, a superset of what CoreTelephony reports.
public enum RadioTechnology: String, Codable, CaseIterable, Sendable {
    case gprs, edge, gsm
    case cdma1x, evdo, ehrpd
    case umts, hsdpa, hsupa
    case lte
    case nrNSA, nrSA
    case unknown

    /// Maps the string constants exposed by `CTTelephonyNetworkInfo`
    /// (e.g. `CTRadioAccessTechnologyLTE`) to a `RadioTechnology`.
    public init(coreTelephonyIdentifier id: String) {
        let suffix = id.hasPrefix("CTRadioAccessTechnology")
            ? String(id.dropFirst("CTRadioAccessTechnology".count))
            : id
        switch suffix {
        case "GPRS": self = .gprs
        case "Edge": self = .edge
        case "WCDMA": self = .umts
        case "HSDPA": self = .hsdpa
        case "HSUPA": self = .hsupa
        case "CDMA1x": self = .cdma1x
        case "CDMAEVDORev0", "CDMAEVDORevA", "CDMAEVDORevB": self = .evdo
        case "eHRPD": self = .ehrpd
        case "LTE": self = .lte
        case "NRNSA": self = .nrNSA
        case "NR": self = .nrSA
        default: self = .unknown
        }
    }

    public var family: RadioFamily {
        switch self {
        case .gprs, .edge, .gsm: return .gsm
        case .cdma1x, .evdo, .ehrpd: return .cdma
        case .umts, .hsdpa, .hsupa: return .umts
        case .lte: return .lte
        case .nrNSA, .nrSA: return .nr
        case .unknown: return .unknown
        }
    }

    public var generation: NetworkGeneration {
        switch self {
        case .gprs, .edge, .gsm, .cdma1x: return .g2
        case .evdo, .ehrpd, .umts, .hsdpa, .hsupa: return .g3
        case .lte: return .g4
        case .nrNSA, .nrSA: return .g5
        case .unknown: return .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .gprs: return "GPRS"
        case .edge: return "EDGE"
        case .gsm: return "GSM"
        case .cdma1x: return "CDMA 1x"
        case .evdo: return "EV-DO"
        case .ehrpd: return "eHRPD"
        case .umts: return "UMTS"
        case .hsdpa: return "HSDPA"
        case .hsupa: return "HSUPA"
        case .lte: return "LTE"
        case .nrNSA: return "5G NSA"
        case .nrSA: return "5G SA"
        case .unknown: return "Unknown"
        }
    }

    /// One-line explanation suitable for a help popover.
    public var explanation: String {
        switch self {
        case .gprs, .edge, .gsm:
            return "2G GSM. Slow data and no mutual authentication between phone and network."
        case .cdma1x, .evdo, .ehrpd:
            return "Legacy CDMA2000 network."
        case .umts, .hsdpa, .hsupa:
            return "3G UMTS/WCDMA."
        case .lte:
            return "4G LTE."
        case .nrNSA:
            return "5G Non-Standalone: an LTE anchor cell carries signalling, 5G NR adds capacity."
        case .nrSA:
            return "5G Standalone: phone is attached to a 5G core via an NR cell only."
        case .unknown:
            return "Radio technology not reported."
        }
    }
}
