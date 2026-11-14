import Foundation

/// One NR operating band per 3GPP TS 38.101-1 (FR1) / 38.101-2 (FR2), downlink range only.
public struct NRBand: Sendable, Hashable {
    public let number: Int
    public let duplex: DuplexMode
    public let dlLowMHz: Double
    public let dlHighMHz: Double
    public let name: String

    public var widthMHz: Double { dlHighMHz - dlLowMHz }
    /// FR2 = millimetre wave (above 24 GHz).
    public var isMillimeterWave: Bool { dlLowMHz >= 24_000 }

    public func contains(mhz: Double) -> Bool { mhz >= dlLowMHz && mhz <= dlHighMHz }
}

public enum NRBands {
    private static func b(_ n: Int, _ d: DuplexMode, _ lo: Double, _ hi: Double, _ name: String) -> NRBand {
        NRBand(number: n, duplex: d, dlLowMHz: lo, dlHighMHz: hi, name: name)
    }

    public static let all: [NRBand] = [
        b(1, .fdd, 2110, 2170, "2100 MHz"),
        b(2, .fdd, 1930, 1990, "1900 MHz PCS"),
        b(3, .fdd, 1805, 1880, "1800 MHz"),
        b(5, .fdd, 869, 894, "850 MHz"),
        b(7, .fdd, 2620, 2690, "2600 MHz"),
        b(8, .fdd, 925, 960, "900 MHz"),
        b(12, .fdd, 729, 746, "700 MHz Lower"),
        b(13, .fdd, 746, 756, "700 MHz Upper C"),
        b(14, .fdd, 758, 768, "700 MHz FirstNet"),
        b(18, .fdd, 860, 875, "800 MHz Japan"),
        b(20, .fdd, 791, 821, "800 MHz DD"),
        b(24, .fdd, 1525, 1559, "1600 MHz L-Band"),
        b(25, .fdd, 1930, 1995, "1900 MHz Ext. PCS"),
        b(26, .fdd, 859, 894, "850 MHz Ext."),
        b(28, .fdd, 758, 803, "700 MHz APT"),
        b(29, .sdl, 717, 728, "700 MHz (SDL)"),
        b(30, .fdd, 2350, 2360, "2300 MHz WCS"),
        b(34, .tdd, 2010, 2025, "TD 2000"),
        b(38, .tdd, 2570, 2620, "TD 2600"),
        b(39, .tdd, 1880, 1920, "TD 1900+"),
        b(40, .tdd, 2300, 2400, "TD 2300"),
        b(41, .tdd, 2496, 2690, "TD 2500"),
        b(46, .tdd, 5150, 5925, "TD 5 GHz unlicensed"),
        b(47, .tdd, 5855, 5925, "TD 5.9 GHz V2X"),
        b(48, .tdd, 3550, 3700, "TD 3600 CBRS"),
        b(50, .tdd, 1432, 1517, "TD 1500"),
        b(51, .tdd, 1427, 1432, "TD 1500-"),
        b(53, .tdd, 2483.5, 2495, "TD 2400 S-Band"),
        b(65, .fdd, 2110, 2200, "2100 MHz Ext."),
        b(66, .fdd, 2110, 2200, "AWS-3"),
        b(67, .sdl, 738, 758, "700 MHz EU (SDL)"),
        b(70, .fdd, 1995, 2020, "AWS-4"),
        b(71, .fdd, 617, 652, "600 MHz"),
        b(74, .fdd, 1475, 1518, "1500 MHz L-Band"),
        b(75, .sdl, 1432, 1517, "1500 MHz (SDL)"),
        b(76, .sdl, 1427, 1432, "1500 MHz Lower (SDL)"),
        b(77, .tdd, 3300, 4200, "TD 3700 C-Band"),
        b(78, .tdd, 3300, 3800, "TD 3500"),
        b(79, .tdd, 4400, 5000, "TD 4700"),
        b(85, .fdd, 728, 746, "700 MHz Ext. Lower"),
        b(90, .tdd, 2496, 2690, "TD 2500 (alt raster)"),
        b(96, .tdd, 5925, 7125, "TD 6 GHz unlicensed"),
        b(100, .fdd, 919.4, 925, "900 MHz Railway"),
        b(101, .tdd, 1900, 1910, "TD 1900 Railway"),
        b(104, .tdd, 6425, 7125, "TD 6.4 GHz"),
        b(105, .fdd, 617, 652, "600 MHz Ext."),
        b(257, .tdd, 26_500, 29_500, "28 GHz"),
        b(258, .tdd, 24_250, 27_500, "26 GHz"),
        b(259, .tdd, 39_500, 43_500, "41 GHz"),
        b(260, .tdd, 37_000, 40_000, "39 GHz"),
        b(261, .tdd, 27_500, 28_350, "28 GHz US"),
        b(262, .tdd, 47_200, 48_200, "47 GHz"),
    ]

    public static func band(number: Int) -> NRBand? { all.first { $0.number == number } }

    /// Converts an NR-ARFCN to the reference frequency in MHz (TS 38.104 §5.4.2.1).
    public static func frequencyMHz(arfcn n: Int) -> Double? {
        switch n {
        case 0..<600_000:
            return 0.005 * Double(n)
        case 600_000..<2_016_667:
            return 3000 + 0.015 * Double(n - 600_000)
        case 2_016_667...3_279_165:
            return 24_250.08 + 0.06 * Double(n - 2_016_667)
        default:
            return nil
        }
    }

    /// Inverse of `frequencyMHz(arfcn:)`.
    public static func arfcn(frequencyMHz f: Double) -> Int? {
        switch f {
        case 0..<3000:
            return Int((f / 0.005).rounded())
        case 3000..<24_250.08:
            return 600_000 + Int(((f - 3000) / 0.015).rounded())
        case 24_250.08...100_000:
            return 2_016_667 + Int(((f - 24_250.08) / 0.06).rounded())
        default:
            return nil
        }
    }

    /// Bands whose downlink range contains the ARFCN's frequency, most specific (narrowest) first.
    /// Bands overlap (n77/n78, n1/n65/n66, n41/n90…), so the modem-reported band should win when known.
    public static func candidateBands(arfcn: Int) -> [NRBand] {
        guard let f = frequencyMHz(arfcn: arfcn) else { return [] }
        return all.filter { $0.contains(mhz: f) }
            .sorted { ($0.widthMHz, $0.number) < ($1.widthMHz, $1.number) }
    }

    /// Picks the most likely band, using regional conventions when bands overlap.
    public static func likelyBand(arfcn: Int, mcc: Int? = nil) -> NRBand? {
        let candidates = candidateBands(arfcn: arfcn)
        guard !candidates.isEmpty else { return nil }
        let preferred: [Int]
        if let mcc, Regions.isNorthAmerica(mcc: mcc) {
            // US/Canada deploy n66/n25/n77/n41/n71 rather than n1/n2/n78/n90.
            preferred = [77, 66, 25, 41, 71, 5, 2, 260, 261]
        } else {
            preferred = [78, 1, 3, 7, 8, 28, 20, 41, 258, 257]
        }
        for number in preferred {
            if let match = candidates.first(where: { $0.number == number }) { return match }
        }
        return candidates.first
    }
}

/// Coarse regional helpers derived from the MCC.
public enum Regions {
    /// MCCs in the North American numbering zone (US, Canada, territories) – they use PCS-style band plans.
    public static func isNorthAmerica(mcc: Int) -> Bool {
        (310...316).contains(mcc) || mcc == 302
    }

    /// Americas (ITU zone 3 and 7): GSM there uses 850/1900 MHz.
    public static func isAmericas(mcc: Int) -> Bool {
        (300...399).contains(mcc) || (700...799).contains(mcc)
    }
}
