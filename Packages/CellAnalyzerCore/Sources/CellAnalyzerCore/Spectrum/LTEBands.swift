import Foundation

public enum DuplexMode: String, Codable, Sendable {
    case fdd = "FDD"
    case tdd = "TDD"
    /// Supplemental downlink (downlink-only carrier aggregated with another band).
    case sdl = "SDL"
    /// Supplemental uplink.
    case sul = "SUL"
}

/// One E-UTRA operating band per 3GPP TS 36.101, Table 5.7.3-1.
public struct LTEBand: Sendable, Hashable {
    public let number: Int
    public let duplex: DuplexMode
    /// Lowest downlink frequency (MHz) and its EARFCN offset.
    public let dlLowMHz: Double
    public let dlOffset: Int
    public let dlRange: ClosedRange<Int>
    /// Uplink parameters (nil for SDL bands; TDD bands share the downlink numbering).
    public let ulLowMHz: Double?
    public let ulOffset: Int?
    public let ulRange: ClosedRange<Int>?
    /// Common name of the band, e.g. "1800 MHz".
    public let name: String

    public var dlHighMHz: Double { dlLowMHz + 0.1 * Double(dlRange.upperBound - dlOffset) + 0.1 }

    /// Downlink centre frequency in MHz for an EARFCN in this band.
    public func downlinkMHz(earfcn: Int) -> Double {
        dlLowMHz + 0.1 * Double(earfcn - dlOffset)
    }

    /// Paired uplink frequency (FDD) or the same frequency (TDD).
    public func uplinkMHz(dlEarfcn: Int) -> Double? {
        switch duplex {
        case .tdd: return downlinkMHz(earfcn: dlEarfcn)
        case .sdl, .sul: return nil
        case .fdd:
            guard let ulLowMHz, uplinkEARFCN(dlEarfcn: dlEarfcn) != nil else { return nil }
            return ulLowMHz + 0.1 * Double(dlEarfcn - dlOffset)
        }
    }

    /// The uplink EARFCN paired with a downlink EARFCN.
    public func uplinkEARFCN(dlEarfcn: Int) -> Int? {
        switch duplex {
        case .tdd: return dlEarfcn
        case .sdl, .sul: return nil
        case .fdd:
            guard let ulOffset else { return nil }
            let ul = ulOffset + (dlEarfcn - dlOffset)
            // Some bands have a narrower uplink than downlink (e.g. B66); the top of the DL is unpaired.
            guard ulRange?.contains(ul) ?? false else { return nil }
            return ul
        }
    }
}

public enum LTEBands {
    private static func fdd(_ n: Int, _ name: String, dl: Double, _ dlOff: Int, _ dlHi: Int,
                            ul: Double, _ ulOff: Int) -> LTEBand {
        let width = dlHi - dlOff
        return LTEBand(number: n, duplex: .fdd, dlLowMHz: dl, dlOffset: dlOff, dlRange: dlOff...dlHi,
                       ulLowMHz: ul, ulOffset: ulOff, ulRange: ulOff...(ulOff + width), name: name)
    }

    private static func tdd(_ n: Int, _ name: String, _ low: Double, _ off: Int, _ hi: Int) -> LTEBand {
        LTEBand(number: n, duplex: .tdd, dlLowMHz: low, dlOffset: off, dlRange: off...hi,
                ulLowMHz: low, ulOffset: off, ulRange: off...hi, name: name)
    }

    private static func sdl(_ n: Int, _ name: String, _ low: Double, _ off: Int, _ hi: Int) -> LTEBand {
        LTEBand(number: n, duplex: .sdl, dlLowMHz: low, dlOffset: off, dlRange: off...hi,
                ulLowMHz: nil, ulOffset: nil, ulRange: nil, name: name)
    }

    /// FDD uplink ranges can be narrower than downlink (e.g. band 66); this variant takes the UL upper bound.
    private static func fddAsym(_ n: Int, _ name: String, dl: Double, _ dlOff: Int, _ dlHi: Int,
                                ul: Double, _ ulOff: Int, _ ulHi: Int) -> LTEBand {
        LTEBand(number: n, duplex: .fdd, dlLowMHz: dl, dlOffset: dlOff, dlRange: dlOff...dlHi,
                ulLowMHz: ul, ulOffset: ulOff, ulRange: ulOff...ulHi, name: name)
    }

    public static let all: [LTEBand] = [
        fdd(1, "2100 MHz IMT", dl: 2110, 0, 599, ul: 1920, 18000),
        fdd(2, "1900 MHz PCS", dl: 1930, 600, 1199, ul: 1850, 18600),
        fdd(3, "1800 MHz DCS", dl: 1805, 1200, 1949, ul: 1710, 19200),
        fdd(4, "1700/2100 MHz AWS-1", dl: 2110, 1950, 2399, ul: 1710, 19950),
        fdd(5, "850 MHz CLR", dl: 869, 2400, 2649, ul: 824, 20400),
        fdd(6, "850 MHz Japan", dl: 875, 2650, 2749, ul: 830, 20650),
        fdd(7, "2600 MHz IMT-E", dl: 2620, 2750, 3449, ul: 2500, 20750),
        fdd(8, "900 MHz E-GSM", dl: 925, 3450, 3799, ul: 880, 21450),
        fdd(9, "1800 MHz Japan", dl: 1844.9, 3800, 4149, ul: 1749.9, 21800),
        fdd(10, "1700/2100 MHz Ext. AWS", dl: 2110, 4150, 4749, ul: 1710, 22150),
        fdd(11, "1500 MHz Lower", dl: 1475.9, 4750, 4949, ul: 1427.9, 22750),
        fdd(12, "700 MHz Lower A/B/C", dl: 729, 5010, 5179, ul: 699, 23010),
        fdd(13, "700 MHz Upper C", dl: 746, 5180, 5279, ul: 777, 23180),
        fdd(14, "700 MHz FirstNet", dl: 758, 5280, 5379, ul: 788, 23280),
        fdd(17, "700 MHz Lower B/C", dl: 734, 5730, 5849, ul: 704, 23730),
        fdd(18, "800 MHz Japan Lower", dl: 860, 5850, 5999, ul: 815, 23850),
        fdd(19, "800 MHz Japan Upper", dl: 875, 6000, 6149, ul: 830, 24000),
        fdd(20, "800 MHz Digital Dividend", dl: 791, 6150, 6449, ul: 832, 24150),
        fdd(21, "1500 MHz Upper", dl: 1495.9, 6450, 6599, ul: 1447.9, 24450),
        fdd(22, "3500 MHz", dl: 3510, 6600, 7399, ul: 3410, 24600),
        fdd(23, "2000 MHz S-Band", dl: 2180, 7500, 7699, ul: 2000, 25500),
        fdd(24, "1600 MHz L-Band", dl: 1525, 7700, 8039, ul: 1626.5, 25700),
        fdd(25, "1900 MHz Ext. PCS", dl: 1930, 8040, 8689, ul: 1850, 26040),
        fdd(26, "850 MHz Ext. CLR", dl: 859, 8690, 9039, ul: 814, 26690),
        fdd(27, "800 MHz SMR", dl: 852, 9040, 9209, ul: 807, 27040),
        fdd(28, "700 MHz APT", dl: 758, 9210, 9659, ul: 703, 27210),
        sdl(29, "700 MHz Lower D/E (SDL)", 717, 9660, 9769),
        fdd(30, "2300 MHz WCS", dl: 2350, 9770, 9869, ul: 2305, 27660),
        fdd(31, "450 MHz", dl: 462.5, 9870, 9919, ul: 452.5, 27760),
        sdl(32, "1500 MHz L-Band (SDL)", 1452, 9920, 10359),
        tdd(33, "TD 1900", 1900, 36000, 36199),
        tdd(34, "TD 2000", 2010, 36200, 36349),
        tdd(35, "TD PCS Lower", 1850, 36350, 36949),
        tdd(36, "TD PCS Upper", 1930, 36950, 37549),
        tdd(37, "TD PCS Center", 1910, 37550, 37749),
        tdd(38, "TD 2600", 2570, 37750, 38249),
        tdd(39, "TD 1900+", 1880, 38250, 38649),
        tdd(40, "TD 2300", 2300, 38650, 39649),
        tdd(41, "TD 2500 BRS", 2496, 39650, 41589),
        tdd(42, "TD 3500", 3400, 41590, 43589),
        tdd(43, "TD 3700", 3600, 43590, 45589),
        tdd(44, "TD 700 APT", 703, 45590, 46589),
        tdd(45, "TD 1500", 1447, 46590, 46789),
        tdd(46, "TD 5200 LAA", 5150, 46790, 54539),
        tdd(47, "TD 5900 V2X", 5855, 54540, 55239),
        tdd(48, "TD 3600 CBRS", 3550, 55240, 56739),
        tdd(49, "TD 3600 CBRS-LAA", 3550, 56740, 58239),
        tdd(50, "TD 1500+", 1432, 58240, 59089),
        tdd(51, "TD 1500-", 1427, 59090, 59139),
        tdd(52, "TD 3300", 3300, 59140, 60139),
        tdd(53, "TD 2400 S-Band", 2483.5, 60140, 60254),
        fdd(65, "2100 MHz Ext. IMT", dl: 2110, 65536, 66435, ul: 1920, 131072),
        fddAsym(66, "1700/2100 MHz AWS-3", dl: 2110, 66436, 67335, ul: 1710, 131972, 132671),
        sdl(67, "700 MHz EU (SDL)", 738, 67336, 67535),
        fdd(68, "700 MHz ME", dl: 753, 67536, 67835, ul: 698, 132672),
        sdl(69, "2600 MHz (SDL)", 2570, 67836, 68335),
        fddAsym(70, "1700/2000 MHz AWS-4", dl: 1995, 68336, 68585, ul: 1695, 132972, 133121),
        fdd(71, "600 MHz", dl: 617, 68586, 68935, ul: 663, 133122),
        fdd(72, "450 MHz PMR/PAMR", dl: 461, 68936, 68985, ul: 451, 133472),
        fdd(73, "450 MHz APAC", dl: 460, 68986, 69035, ul: 450, 133522),
        fdd(74, "1500 MHz L-Band", dl: 1475, 69036, 69465, ul: 1427, 133572),
        sdl(75, "1500 MHz (SDL)", 1432, 69466, 70315),
        sdl(76, "1500 MHz Lower (SDL)", 1427, 70316, 70365),
        fdd(85, "700 MHz Ext. Lower", dl: 728, 70366, 70545, ul: 698, 134002),
        fdd(87, "410 MHz", dl: 420, 70546, 70595, ul: 410, 134182),
        fdd(88, "410 MHz Ext.", dl: 422, 70596, 70645, ul: 412, 134232),
    ]

    public static func band(number: Int) -> LTEBand? { all.first { $0.number == number } }

    /// Band whose downlink EARFCN range contains `earfcn`.
    public static func band(forDownlinkEARFCN earfcn: Int) -> LTEBand? {
        all.first { $0.dlRange.contains(earfcn) }
    }

    /// Band whose uplink EARFCN range contains `earfcn` (FDD only; TDD bands share numbering).
    public static func band(forUplinkEARFCN earfcn: Int) -> LTEBand? {
        all.first { $0.duplex == .fdd && ($0.ulRange?.contains(earfcn) ?? false) }
    }
}
