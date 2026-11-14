import XCTest
@testable import CellAnalyzerCore

final class SpectrumTests: XCTestCase {
    func testCoreTelephonyMapping() {
        XCTAssertEqual(RadioTechnology(coreTelephonyIdentifier: "CTRadioAccessTechnologyLTE"), .lte)
        XCTAssertEqual(RadioTechnology(coreTelephonyIdentifier: "CTRadioAccessTechnologyNRNSA"), .nrNSA)
        XCTAssertEqual(RadioTechnology(coreTelephonyIdentifier: "CTRadioAccessTechnologyNR"), .nrSA)
        XCTAssertEqual(RadioTechnology(coreTelephonyIdentifier: "CTRadioAccessTechnologyEdge"), .edge)
        XCTAssertEqual(RadioTechnology(coreTelephonyIdentifier: "CTRadioAccessTechnologyHSDPA").generation, .g3)
        XCTAssertEqual(RadioTechnology(coreTelephonyIdentifier: "garbage"), .unknown)
        XCTAssertEqual(RadioTechnology.nrNSA.family, .nr)
    }

    func testLTEBandTableIsConsistent() {
        for band in LTEBands.all {
            XCTAssertLessThan(band.dlRange.lowerBound, band.dlRange.upperBound, "B\(band.number)")
            if let ul = band.ulRange, band.duplex == .fdd {
                XCTAssertLessThanOrEqual(ul.count, band.dlRange.count, "B\(band.number)")
            }
        }
        // No overlapping downlink EARFCN ranges.
        let sorted = LTEBands.all.sorted { $0.dlRange.lowerBound < $1.dlRange.lowerBound }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThan(a.dlRange.upperBound, b.dlRange.lowerBound, "B\(a.number) overlaps B\(b.number)")
        }
    }

    func testLTEEARFCN() throws {
        let b3 = try XCTUnwrap(Spectrum.lte(earfcn: 1300))
        XCTAssertEqual(b3.band, 3)
        XCTAssertEqual(try XCTUnwrap(b3.downlinkMHz), 1815.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(b3.uplinkMHz), 1720.0, accuracy: 0.001)
        XCTAssertEqual(b3.uplinkChannel, 19300)
        XCTAssertEqual(b3.bandLabel, "B3")

        let b20 = try XCTUnwrap(Spectrum.lte(earfcn: 6300))
        XCTAssertEqual(b20.band, 20)
        XCTAssertEqual(try XCTUnwrap(b20.downlinkMHz), 806.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(b20.uplinkMHz), 847.0, accuracy: 0.001)

        let b66 = try XCTUnwrap(Spectrum.lte(earfcn: 66786))
        XCTAssertEqual(b66.band, 66)
        XCTAssertEqual(try XCTUnwrap(b66.downlinkMHz), 2145.0, accuracy: 0.001)
        XCTAssertEqual(b66.uplinkChannel, 132322)

        // Top of B66 downlink has no paired uplink.
        let b66top = try XCTUnwrap(Spectrum.lte(earfcn: 67300))
        XCTAssertNil(b66top.uplinkChannel)
        XCTAssertNil(b66top.uplinkMHz)

        let b41 = try XCTUnwrap(Spectrum.lte(earfcn: 40072))
        XCTAssertEqual(b41.band, 41)
        XCTAssertEqual(b41.duplex, .tdd)
        XCTAssertEqual(b41.downlinkMHz, b41.uplinkMHz)

        // Uplink EARFCN entered by mistake is mapped back to the downlink channel.
        let fromUL = try XCTUnwrap(Spectrum.lte(earfcn: 19300))
        XCTAssertEqual(fromUL.channel, 1300)
        XCTAssertEqual(fromUL.band, 3)

        XCTAssertNil(Spectrum.lte(earfcn: 10400))
    }

    func testNRARFCN() throws {
        XCTAssertEqual(try XCTUnwrap(NRBands.frequencyMHz(arfcn: 632628)), 3489.42, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(NRBands.frequencyMHz(arfcn: 123400)), 617.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(NRBands.frequencyMHz(arfcn: 2079167)), 28000.08, accuracy: 0.0001)
        XCTAssertNil(NRBands.frequencyMHz(arfcn: 4_000_000))
        for arfcn in [123400, 632628, 2079167, 520110] {
            let f = try XCTUnwrap(NRBands.frequencyMHz(arfcn: arfcn))
            XCTAssertEqual(NRBands.arfcn(frequencyMHz: f), arfcn)
        }

        let eu = try XCTUnwrap(Spectrum.nr(arfcn: 632628, mcc: 230))
        XCTAssertEqual(eu.band, 78)
        XCTAssertTrue(eu.alternativeBands.contains(77))
        XCTAssertEqual(eu.bandLabel, "n78")

        let us = try XCTUnwrap(Spectrum.nr(arfcn: 632628, mcc: 310))
        XCTAssertEqual(us.band, 77)

        let reported = try XCTUnwrap(Spectrum.nr(arfcn: 632628, mcc: 310, reportedBand: 78))
        XCTAssertEqual(reported.band, 78)

        XCTAssertEqual(Spectrum.nr(arfcn: 520110, mcc: 310)?.band, 41)
        XCTAssertEqual(Spectrum.nr(arfcn: 2079167, mcc: 310)?.band, 261)
        XCTAssertEqual(Spectrum.nr(arfcn: 126900, mcc: 310)?.band, 71)
    }

    func testUMTSAndGSM() throws {
        let u1 = try XCTUnwrap(UMTSBands.info(uarfcn: 10700))
        XCTAssertEqual(u1.band, 1)
        XCTAssertEqual(try XCTUnwrap(u1.downlinkMHz), 2140.0, accuracy: 0.001)
        XCTAssertEqual(u1.bandLabel, "Band I")
        XCTAssertEqual(try XCTUnwrap(UMTSBands.info(uarfcn: 3011)?.downlinkMHz), 942.2, accuracy: 0.001)
        XCTAssertEqual(UMTSBands.info(uarfcn: 3011)?.bandLabel, "Band VIII")

        let g900 = try XCTUnwrap(GSMBands.info(arfcn: 62))
        XCTAssertEqual(try XCTUnwrap(g900.downlinkMHz), 947.4, accuracy: 0.001)
        let dcs = try XCTUnwrap(GSMBands.info(arfcn: 600, mcc: 230))
        XCTAssertEqual(dcs.bandName, "DCS 1800")
        XCTAssertEqual(try XCTUnwrap(dcs.downlinkMHz), 1822.8, accuracy: 0.001)
        let pcs = try XCTUnwrap(GSMBands.info(arfcn: 600, mcc: 310))
        XCTAssertEqual(pcs.bandName, "PCS 1900")
        XCTAssertEqual(try XCTUnwrap(pcs.downlinkMHz), 1947.8, accuracy: 0.001)
    }

    func testFormatting() {
        XCTAssertEqual(Spectrum.formatFrequency(1815), "1815 MHz")
        XCTAssertEqual(Spectrum.formatFrequency(3489.42), "3489.42 MHz")
        XCTAssertEqual(Spectrum.formatFrequency(28000.08), "28 GHz")
        XCTAssertEqual(Spectrum.roman(19), "XIX")
    }
}
