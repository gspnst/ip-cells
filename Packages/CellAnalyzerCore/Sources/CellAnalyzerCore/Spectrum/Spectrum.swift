import Foundation

/// Decoded meaning of a channel number.
public struct ChannelInfo: Sendable, Hashable {
    public var family: RadioFamily
    public var channel: Int
    /// Band number ("n78" for NR is represented as 78; use `bandLabel`).
    public var band: Int?
    public var bandName: String?
    public var duplex: DuplexMode?
    public var downlinkMHz: Double?
    public var uplinkMHz: Double?
    public var uplinkChannel: Int?
    /// Other bands that contain the same frequency (NR overlaps).
    public var alternativeBands: [Int] = []

    public var bandLabel: String? {
        guard let band else { return nil }
        switch family {
        case .nr: return "n\(band)"
        case .lte: return "B\(band)"
        case .umts: return "Band \(Spectrum.roman(band))"
        default: return bandName ?? "\(band)"
        }
    }
}

public enum Spectrum {
    /// Decodes a downlink channel number for any radio family.
    public static func channelInfo(family: RadioFamily, channel: Int, mcc: Int? = nil,
                                   reportedBand: Int? = nil) -> ChannelInfo? {
        switch family {
        case .lte: return lte(earfcn: channel)
        case .nr: return nr(arfcn: channel, mcc: mcc, reportedBand: reportedBand)
        case .umts: return UMTSBands.info(uarfcn: channel)
        case .gsm: return GSMBands.info(arfcn: channel, mcc: mcc)
        case .cdma, .unknown: return nil
        }
    }

    public static func lte(earfcn: Int) -> ChannelInfo? {
        if let band = LTEBands.band(forDownlinkEARFCN: earfcn) {
            return ChannelInfo(family: .lte, channel: earfcn, band: band.number, bandName: band.name,
                               duplex: band.duplex, downlinkMHz: band.downlinkMHz(earfcn: earfcn),
                               uplinkMHz: band.uplinkMHz(dlEarfcn: earfcn),
                               uplinkChannel: band.uplinkEARFCN(dlEarfcn: earfcn))
        }
        // Users sometimes enter the uplink EARFCN by mistake.
        if let band = LTEBands.band(forUplinkEARFCN: earfcn), let ulOff = band.ulOffset, let ulLow = band.ulLowMHz {
            let dl = band.dlOffset + (earfcn - ulOff)
            return ChannelInfo(family: .lte, channel: dl, band: band.number, bandName: band.name,
                               duplex: band.duplex, downlinkMHz: band.downlinkMHz(earfcn: dl),
                               uplinkMHz: ulLow + 0.1 * Double(earfcn - ulOff), uplinkChannel: earfcn)
        }
        return nil
    }

    public static func nr(arfcn: Int, mcc: Int? = nil, reportedBand: Int? = nil) -> ChannelInfo? {
        guard let f = NRBands.frequencyMHz(arfcn: arfcn) else { return nil }
        let candidates = NRBands.candidateBands(arfcn: arfcn)
        let chosen: NRBand?
        if let reportedBand, let match = candidates.first(where: { $0.number == reportedBand }) ?? NRBands.band(number: reportedBand) {
            chosen = match
        } else {
            chosen = NRBands.likelyBand(arfcn: arfcn, mcc: mcc)
        }
        return ChannelInfo(family: .nr, channel: arfcn, band: chosen?.number, bandName: chosen?.name,
                           duplex: chosen?.duplex, downlinkMHz: f,
                           uplinkMHz: chosen?.duplex == .tdd ? f : nil, uplinkChannel: nil,
                           alternativeBands: candidates.map(\.number).filter { $0 != chosen?.number })
    }

    /// Roman numerals for UMTS band naming (I…XXXII).
    public static func roman(_ value: Int) -> String {
        guard value > 0 && value < 40 else { return "\(value)" }
        let table: [(Int, String)] = [(10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = value, out = ""
        for (v, s) in table { while n >= v { out += s; n -= v } }
        return out
    }

    /// Formats a frequency in MHz, switching to GHz above 6 GHz.
    public static func formatFrequency(_ mhz: Double) -> String {
        if mhz >= 6000 {
            return trimmed(mhz / 1000, decimals: 3) + " GHz"
        }
        return trimmed(mhz, decimals: 3) + " MHz"
    }

    static func trimmed(_ value: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}

/// UMTS (WCDMA) bands per TS 25.101 – general UARFCN numbering only.
public enum UMTSBands {
    struct Entry { let band: Int; let dlOffsetMHz: Double; let range: ClosedRange<Int>; let duplexMHz: Double; let name: String }

    static let table: [Entry] = [
        Entry(band: 1, dlOffsetMHz: 0, range: 10562...10838, duplexMHz: 190, name: "2100 MHz IMT"),
        Entry(band: 2, dlOffsetMHz: 0, range: 9662...9938, duplexMHz: 80, name: "1900 MHz PCS"),
        Entry(band: 3, dlOffsetMHz: 1575, range: 1162...1513, duplexMHz: 95, name: "1800 MHz DCS"),
        Entry(band: 4, dlOffsetMHz: 1805, range: 1537...1738, duplexMHz: 400, name: "1700/2100 MHz AWS"),
        Entry(band: 5, dlOffsetMHz: 0, range: 4357...4458, duplexMHz: 45, name: "850 MHz CLR"),
        Entry(band: 6, dlOffsetMHz: 0, range: 4387...4413, duplexMHz: 45, name: "800 MHz Japan"),
        Entry(band: 7, dlOffsetMHz: 2175, range: 2237...2563, duplexMHz: 120, name: "2600 MHz"),
        Entry(band: 8, dlOffsetMHz: 340, range: 2937...3088, duplexMHz: 45, name: "900 MHz"),
        Entry(band: 9, dlOffsetMHz: 0, range: 9237...9387, duplexMHz: 95, name: "1700 MHz Japan"),
        Entry(band: 10, dlOffsetMHz: 1490, range: 3112...3388, duplexMHz: 400, name: "1700/2100 MHz Ext."),
        Entry(band: 11, dlOffsetMHz: 736, range: 3712...3787, duplexMHz: 48, name: "1500 MHz"),
        Entry(band: 19, dlOffsetMHz: 735, range: 712...763, duplexMHz: 45, name: "800 MHz Japan"),
    ]

    public static func info(uarfcn: Int) -> ChannelInfo? {
        // Band V and VI overlap; prefer V (much more common).
        guard let e = table.first(where: { $0.range.contains(uarfcn) }) else { return nil }
        let dl = e.dlOffsetMHz + 0.2 * Double(uarfcn)
        return ChannelInfo(family: .umts, channel: uarfcn, band: e.band, bandName: e.name, duplex: .fdd,
                           downlinkMHz: dl, uplinkMHz: dl - e.duplexMHz, uplinkChannel: nil)
    }
}

/// GSM ARFCN decoding per TS 45.005.
public enum GSMBands {
    public static func info(arfcn n: Int, mcc: Int? = nil) -> ChannelInfo? {
        let americas = mcc.map(Regions.isAmericas(mcc:)) ?? false
        var ul: Double
        let dl: Double
        let name: String
        let band: Int
        switch n {
        case 0...124:
            ul = 890 + 0.2 * Double(n); dl = ul + 45; name = n == 0 ? "E-GSM 900" : "P-GSM 900"; band = 900
        case 128...251:
            ul = 824.2 + 0.2 * Double(n - 128); dl = ul + 45; name = "GSM 850"; band = 850
        case 512...810 where americas:
            ul = 1850.2 + 0.2 * Double(n - 512); dl = ul + 80; name = "PCS 1900"; band = 1900
        case 512...885:
            ul = 1710.2 + 0.2 * Double(n - 512); dl = ul + 95; name = "DCS 1800"; band = 1800
        case 955...974:
            ul = 890 + 0.2 * Double(n - 1024); dl = ul + 45; name = "R-GSM 900"; band = 900
        case 975...1023:
            ul = 890 + 0.2 * Double(n - 1024); dl = ul + 45; name = "E-GSM 900"; band = 900
        default:
            return nil
        }
        ul = (ul * 10).rounded() / 10
        return ChannelInfo(family: .gsm, channel: n, band: band, bandName: name, duplex: .fdd,
                           downlinkMHz: (dl * 10).rounded() / 10, uplinkMHz: ul, uplinkChannel: n)
    }
}
