import Foundation

/// Structured breakdown of a global cell identifier.
public struct DecodedCellIdentity: Sendable, Hashable {
    public var family: RadioFamily
    public var rawCellId: Int
    /// eNodeB ID (LTE), gNodeB ID (NR), RNC ID (UMTS). Nil for GSM.
    public var siteId: Int?
    /// Local cell ID within the site (LTE: 0…255, often sector/carrier), NR cell, UMTS CID.
    public var localCellId: Int?
    /// Bit length of the site ID (NR gNB ID length is operator-configured: 22…32).
    public var siteIdBits: Int?
    public var siteLabel: String
    public var localLabel: String
    /// Globally unique string, e.g. ECGI "310-260-123456-1".
    public var globalIdentifier: String?
    public var warnings: [String] = []

    public var hexCellId: String { "0x" + String(rawCellId, radix: 16, uppercase: true) }
}

public enum CellIdentityDecoder {
    public static let lteCellIdMax = (1 << 28) - 1
    public static let nrCellIdMax = (1 << 36) - 1
    /// Most operators configure a 24-bit gNB ID, but 22…32 are all legal.
    public static let defaultGNBIdBits = 24

    /// Decodes a cell identity for the given family.
    /// - Parameter gnbIdBits: NR gNB ID length (22…32). Ignored for other families.
    public static func decode(family: RadioFamily, cellId: Int, plmn: PLMN? = nil,
                              gnbIdBits: Int = defaultGNBIdBits) -> DecodedCellIdentity {
        switch family {
        case .lte: return decodeLTE(eci: cellId, plmn: plmn)
        case .nr: return decodeNR(nci: cellId, plmn: plmn, gnbIdBits: gnbIdBits)
        case .umts: return decodeUMTS(cellId: cellId, plmn: plmn)
        case .gsm, .cdma, .unknown:
            var d = DecodedCellIdentity(family: family, rawCellId: cellId, siteId: nil, localCellId: cellId,
                                        siteIdBits: nil, siteLabel: "Site", localLabel: "Cell ID",
                                        globalIdentifier: plmn.map { "\($0)-\(cellId)" })
            if family == .gsm && cellId > 0xFFFF { d.warnings.append("GSM CI should fit in 16 bits.") }
            return d
        }
    }

    /// LTE ECI = 20-bit eNB ID + 8-bit local cell ID (TS 36.413 §9.2.1.38).
    public static func decodeLTE(eci: Int, plmn: PLMN? = nil) -> DecodedCellIdentity {
        var d = DecodedCellIdentity(family: .lte, rawCellId: eci, siteId: eci >> 8, localCellId: eci & 0xFF,
                                    siteIdBits: 20, siteLabel: "eNB ID", localLabel: "Cell (sector)",
                                    globalIdentifier: nil)
        if let plmn { d.globalIdentifier = "\(plmn)-\(eci >> 8)-\(eci & 0xFF)" }
        if eci > lteCellIdMax || eci < 0 { d.warnings.append("ECI exceeds 28 bits; value may include the PLMN or be misread.") }
        return d
    }

    /// NR NCI = gNB ID (22…32 bits) + local cell ID (remaining bits of 36), TS 38.413 §9.3.1.7.
    public static func decodeNR(nci: Int, plmn: PLMN? = nil, gnbIdBits: Int = defaultGNBIdBits) -> DecodedCellIdentity {
        let bits = min(max(gnbIdBits, 22), 32)
        let cellBits = 36 - bits
        let gnb = nci >> cellBits
        let local = nci & ((1 << cellBits) - 1)
        var d = DecodedCellIdentity(family: .nr, rawCellId: nci, siteId: gnb, localCellId: local,
                                    siteIdBits: bits, siteLabel: "gNB ID", localLabel: "Cell",
                                    globalIdentifier: plmn.map { "\($0)-\(gnb)-\(local)" })
        if nci > nrCellIdMax || nci < 0 { d.warnings.append("NCI exceeds 36 bits.") }
        return d
    }

    /// UTRAN Cell ID (28 bit) = 12-bit RNC ID + 16-bit C-ID. Short (16-bit) IDs are returned as-is.
    public static func decodeUMTS(cellId: Int, plmn: PLMN? = nil) -> DecodedCellIdentity {
        if cellId > 0xFFFF {
            let rnc = cellId >> 16, cid = cellId & 0xFFFF
            return DecodedCellIdentity(family: .umts, rawCellId: cellId, siteId: rnc, localCellId: cid,
                                       siteIdBits: 12, siteLabel: "RNC ID", localLabel: "C-ID",
                                       globalIdentifier: plmn.map { "\($0)-\(rnc)-\(cid)" })
        }
        return DecodedCellIdentity(family: .umts, rawCellId: cellId, siteId: nil, localCellId: cellId,
                                   siteIdBits: nil, siteLabel: "RNC ID", localLabel: "C-ID",
                                   globalIdentifier: plmn.map { "\($0)-\(cellId)" })
    }

    /// Composes an ECI from an eNB ID and local cell ID.
    public static func composeECI(enb: Int, localCell: Int) -> Int { (enb << 8) | (localCell & 0xFF) }

    /// Decodes an NCI under every legal gNB-ID length, for when the operator's length is unknown.
    public static func nrInterpretations(nci: Int) -> [(bits: Int, gnb: Int, cell: Int)] {
        (22...32).map { bits in
            let d = decodeNR(nci: nci, gnbIdBits: bits)
            return (bits, d.siteId ?? 0, d.localCellId ?? 0)
        }
    }

    /// Common vendor convention for LTE local cell IDs: the last decimal digit (or low nibble) is the
    /// sector, higher digits identify the carrier. This is a heuristic, not a standard.
    public static func lteSectorHint(localCellId: Int) -> String {
        let sector = localCellId % 10
        let carrier = localCellId / 10
        return carrier == 0 ? "sector \(sector)" : "sector \(sector), carrier group \(carrier)"
    }

    /// LTE PCI = 3 × SSS group + PSS ID (0…503). NR uses 0…1007.
    public static func pciComponents(_ pci: Int, family: RadioFamily) -> (group: Int, id: Int)? {
        let limit = family == .nr ? 1007 : 503
        guard (0...limit).contains(pci) else { return nil }
        return (pci / 3, pci % 3)
    }
}
