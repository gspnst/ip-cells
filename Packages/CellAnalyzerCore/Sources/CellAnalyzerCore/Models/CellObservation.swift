import Foundation

/// A WGS-84 coordinate with optional horizontal accuracy (metres).
public struct GeoPoint: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var horizontalAccuracy: Double?

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
    }

    public var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }
}

/// Where a measurement came from.
public enum ObservationSource: String, Codable, CaseIterable, Sendable {
    /// Periodic sample of what iOS exposes publicly (radio technology + location only).
    case system
    /// Parsed from a Field Test Mode screenshot via OCR.
    case fieldTestScreenshot
    /// Typed in by the user.
    case manual
    /// Imported from a file.
    case imported

    public var displayName: String {
        switch self {
        case .system: return "iOS sample"
        case .fieldTestScreenshot: return "Field Test screenshot"
        case .manual: return "Manual entry"
        case .imported: return "Imported"
        }
    }
}

/// One measurement of the serving cell at a point in time.
///
/// Every radio parameter is optional: iOS only exposes the radio technology publicly,
/// the rest comes from Field Test Mode captures or manual entry.
public struct CellObservation: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var source: ObservationSource
    public var radio: RadioTechnology

    /// Groups observations captured together (e.g. LTE anchor + NR leg of one NSA screenshot).
    public var captureID: UUID?
    /// CoreTelephony service identifier / SIM label.
    public var simSlot: String?

    // Identity
    public var mcc: Int?
    public var mnc: Int?
    /// Number of digits the MNC is written with (2 or 3). `nil` = infer.
    public var mncDigits: Int?
    /// TAC for LTE/NR, LAC for GSM/UMTS.
    public var areaCode: Int?
    /// ECI (LTE, 28 bit), NCI (NR, 36 bit), UTRAN Cell ID (UMTS, 28 bit) or CI (GSM, 16 bit).
    public var cellId: Int?
    /// Physical Cell ID (LTE/NR), Primary Scrambling Code (UMTS) or BSIC (GSM).
    public var pci: Int?

    // Spectrum
    /// Downlink channel number: EARFCN, NR-ARFCN, UARFCN or ARFCN.
    public var channel: Int?
    /// Band number as reported by the modem (overrides the channel-derived band).
    public var band: Int?
    public var bandwidthMHz: Double?

    // Signal
    public var rsrp: Double?
    public var rsrq: Double?
    public var sinr: Double?
    public var rssi: Double?
    /// Timing advance in modem units, when available.
    public var timingAdvance: Int?

    public var location: GeoPoint?
    public var notes: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: ObservationSource,
        radio: RadioTechnology,
        captureID: UUID? = nil,
        simSlot: String? = nil,
        mcc: Int? = nil,
        mnc: Int? = nil,
        mncDigits: Int? = nil,
        areaCode: Int? = nil,
        cellId: Int? = nil,
        pci: Int? = nil,
        channel: Int? = nil,
        band: Int? = nil,
        bandwidthMHz: Double? = nil,
        rsrp: Double? = nil,
        rsrq: Double? = nil,
        sinr: Double? = nil,
        rssi: Double? = nil,
        timingAdvance: Int? = nil,
        location: GeoPoint? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.radio = radio
        self.captureID = captureID
        self.simSlot = simSlot
        self.mcc = mcc
        self.mnc = mnc
        self.mncDigits = mncDigits
        self.areaCode = areaCode
        self.cellId = cellId
        self.pci = pci
        self.channel = channel
        self.band = band
        self.bandwidthMHz = bandwidthMHz
        self.rsrp = rsrp
        self.rsrq = rsrq
        self.sinr = sinr
        self.rssi = rssi
        self.timingAdvance = timingAdvance
        self.location = location
        self.notes = notes
    }

    /// True when the observation identifies a specific cell (not just the radio technology).
    public var identifiesCell: Bool { cellKey != nil }

    /// True when at least one signal metric is present.
    public var hasSignal: Bool { rsrp != nil || rsrq != nil || sinr != nil || rssi != nil }

    /// The key that identifies the serving cell, if enough data is present.
    public var cellKey: CellKey? { CellKey(observation: self) }

    /// PLMN formatted as "MCC-MNC", honouring 3-digit MNCs.
    public var plmn: String? {
        guard let mcc, let mnc else { return nil }
        return PLMN(mcc: mcc, mnc: mnc, mncDigits: mncDigits).description
    }

    /// Band, either as reported or derived from the channel number.
    public var resolvedBand: Int? {
        if let band { return band }
        guard let channel else { return nil }
        return Spectrum.channelInfo(family: radio.family, channel: channel, mcc: mcc)?.band
    }
}

/// Public Land Mobile Network identifier (MCC + MNC).
public struct PLMN: Hashable, Codable, Sendable, CustomStringConvertible {
    public var mcc: Int
    public var mnc: Int
    public var mncDigits: Int?

    public init(mcc: Int, mnc: Int, mncDigits: Int? = nil) {
        self.mcc = mcc
        self.mnc = mnc
        self.mncDigits = mncDigits
    }

    /// Parses "310260", "310-260", "310 26", "23003".
    public init?(string: String) {
        let digits = string.filter(\.isNumber)
        let parts = string.split(whereSeparator: { !$0.isNumber })
        if parts.count == 2, parts[0].count == 3, (2...3).contains(parts[1].count),
           let mcc = Int(parts[0]), let mnc = Int(parts[1]) {
            self.init(mcc: mcc, mnc: mnc, mncDigits: parts[1].count)
        } else if (5...6).contains(digits.count), parts.count == 1,
                  let mcc = Int(digits.prefix(3)), let mnc = Int(digits.dropFirst(3)) {
            self.init(mcc: mcc, mnc: mnc, mncDigits: digits.count - 3)
        } else {
            return nil
        }
        guard (1...999).contains(mcc) else { return nil }
    }

    public var formattedMNC: String {
        let digits = mncDigits ?? (OperatorDirectory.usesThreeDigitMNC(mcc: mcc) || mnc > 99 ? 3 : 2)
        return mnc.zeroPadded(to: digits)
    }

    public var description: String { mcc.zeroPadded(to: 3) + "-" + formattedMNC }

    /// PLMNs reserved for testing; commercial networks never broadcast them.
    public var isTestNetwork: Bool {
        (mcc == 1 && (mnc == 1 || mnc == 10 || mnc == 0)) || (mcc == 999 && (mnc == 99 || mnc == 999)) || mcc == 0
    }
}

/// Stable identity of a cell, used to group observations.
public struct CellKey: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public var id: String { description }

    public var family: RadioFamily
    public var mcc: Int?
    public var mnc: Int?
    public var areaCode: Int?
    public var cellId: Int?
    /// Used when the global cell ID is unknown.
    public var channel: Int?
    public var pci: Int?

    public init(family: RadioFamily, mcc: Int? = nil, mnc: Int? = nil, areaCode: Int? = nil,
                cellId: Int? = nil, channel: Int? = nil, pci: Int? = nil) {
        self.family = family
        self.mcc = mcc
        self.mnc = mnc
        self.areaCode = areaCode
        self.cellId = cellId
        self.channel = channel
        self.pci = pci
    }

    /// Prefers the global identity (PLMN + cell ID). Falls back to channel + PCI
    /// (a "physical" identity that is only locally unique).
    public init?(observation o: CellObservation) {
        let family = o.radio.family
        guard family != .unknown else { return nil }
        if let cellId = o.cellId {
            self.init(family: family, mcc: o.mcc, mnc: o.mnc, areaCode: nil, cellId: cellId)
        } else if let channel = o.channel, let pci = o.pci {
            self.init(family: family, mcc: o.mcc, mnc: o.mnc, channel: channel, pci: pci)
        } else {
            return nil
        }
    }

    /// True when the key is based on the global cell identity.
    public var isGlobal: Bool { cellId != nil }

    public var description: String {
        var parts = [family.displayName]
        if let mcc, let mnc { parts.append(PLMN(mcc: mcc, mnc: mnc).description) }
        if let cellId {
            parts.append("CID \(cellId)")
        } else {
            if let channel { parts.append("CH \(channel)") }
            if let pci { parts.append("PCI \(pci)") }
        }
        return parts.joined(separator: " · ")
    }
}

extension Int {
    /// Decimal representation left-padded with zeros (e.g. `7.zeroPadded(to: 2) == "07"`).
    public func zeroPadded(to width: Int) -> String {
        let digits = String(Swift.abs(self))
        let padded = String(repeating: "0", count: Swift.max(0, width - digits.count)) + digits
        return self < 0 ? "-" + padded : padded
    }
}
