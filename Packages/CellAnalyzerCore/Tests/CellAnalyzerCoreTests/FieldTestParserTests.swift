import XCTest
@testable import CellAnalyzerCore

final class FieldTestParserTests: XCTestCase {
    func testQualcommStyleLTEScreen() throws {
        let text = """
        LTE
        Serving Cell Info
        freq_band_ind 66
        dl_freq 66786
        ul_freq 132322
        dl_bandwidth 100
        phy_cell_id 301
        tac 12345
        cell_identity 26838293
        mcc 310
        mnc 260
        Serving Cell Meas
        rsrp0 -95
        rsrp1 -98
        rsrq0 -11
        rsrq1 -13
        sinr0 14.2
        Neighbor Cell Meas
        rsrp -120
        phy_cell_id 99
        """
        let capture = FieldTestParser.parse(text: text)
        XCTAssertEqual(capture.cells.count, 1)
        let cell = try XCTUnwrap(capture.cells.first)
        XCTAssertEqual(cell.radio, .lte)
        XCTAssertEqual(cell.band, 66)
        XCTAssertEqual(cell.channel, 66786)
        XCTAssertEqual(cell.bandwidthMHz, 20)
        XCTAssertEqual(cell.pci, 301)
        XCTAssertEqual(cell.areaCode, 12345)
        XCTAssertEqual(cell.cellId, 26_838_293)
        XCTAssertEqual(cell.mcc, 310)
        XCTAssertEqual(cell.mnc, 260)
        XCTAssertEqual(cell.mncDigits, 3)
        XCTAssertEqual(cell.rsrp, -95, "best antenna wins; neighbour values ignored")
        XCTAssertEqual(cell.rsrq, -11)
        XCTAssertEqual(cell.sinr, 14.2)
        XCTAssertTrue(capture.pairs.contains { $0.isNeighbor && $0.field == .rsrp })

        let obs = capture.observations(timestamp: Date(timeIntervalSince1970: 0), location: nil)
        XCTAssertEqual(obs.count, 1)
        XCTAssertEqual(obs[0].source, .fieldTestScreenshot)
        XCTAssertEqual(obs[0].cellKey?.cellId, 26_838_293)
    }

    func testOCRNoiseAndHumanLabels() throws {
        let lines = [
            "RSRP\t\u{2212}1O2 dBm",
            "RSRQ: 9",
            "SINR 8",
            "Physical cell ID\t12",
            "Downlink EARFCN\t1300",
            "Tracking Area Code",
            "4711",
            "PLMN 23003",
            "Global cell ID 0x199A01",
        ]
        let cell = try XCTUnwrap(FieldTestParser.parse(lines: lines).cells.first)
        XCTAssertEqual(cell.radio, .lte)
        XCTAssertEqual(cell.rsrp, -102)
        XCTAssertEqual(cell.rsrq, -9, "missing minus sign restored")
        XCTAssertEqual(cell.signCorrected, [.rsrq])
        XCTAssertEqual(cell.sinr, 8)
        XCTAssertEqual(cell.pci, 12)
        XCTAssertEqual(cell.channel, 1300)
        XCTAssertEqual(cell.areaCode, 4711)
        XCTAssertEqual(cell.mcc, 230)
        XCTAssertEqual(cell.mnc, 3)
        XCTAssertEqual(cell.mncDigits, 2)
        XCTAssertEqual(cell.cellId, 0x199A01)
    }

    func testNSACaptureProducesTwoLegs() throws {
        let text = """
        LTE Serving Cell
        earfcn 1300
        pci 77
        rsrp -88
        mcc 262
        mnc 01
        tac 0x1A2B
        5G NR
        nr_arfcn 632628
        ss_rsrp -101
        ssb_sinr 7
        pci 455
        band n78
        connection_type NSA
        """
        let capture = FieldTestParser.parse(text: text)
        XCTAssertEqual(capture.cells.map(\.radio), [.lte, .nrNSA])
        XCTAssertTrue(capture.pairs.contains { $0.field == .connectionType && $0.value == "NSA" })
        let lte = capture.cells[0], nr = capture.cells[1]
        XCTAssertEqual(lte.channel, 1300)
        XCTAssertEqual(lte.pci, 77)
        XCTAssertEqual(lte.areaCode, 0x1A2B)
        XCTAssertEqual(nr.channel, 632_628)
        XCTAssertEqual(nr.rsrp, -101)
        XCTAssertEqual(nr.sinr, 7)
        XCTAssertEqual(nr.pci, 455)
        XCTAssertEqual(nr.band, 78)
        XCTAssertEqual(nr.mcc, 262, "PLMN shared from the LTE leg")
        XCTAssertEqual(nr.mnc, 1)

        let captureID = UUID()
        let obs = capture.observations(timestamp: Date(), location: nil, captureID: captureID)
        XCTAssertEqual(obs.count, 2)
        XCTAssertTrue(obs.allSatisfy { $0.captureID == captureID })
    }

    func testStandaloneNR() throws {
        let capture = FieldTestParser.parse(text: """
        NR connection type: SA
        nr_arfcn: 520110
        nr_pci: 300
        nr_rsrp: -92
        nci: 0x123456789
        """)
        let cell = try XCTUnwrap(capture.cells.first)
        XCTAssertEqual(cell.radio, .nrSA)
        XCTAssertEqual(cell.channel, 520_110)
        XCTAssertEqual(cell.pci, 300)
        XCTAssertEqual(cell.cellId, 0x123456789)
    }

    func testTextualValueWithoutSeparator() throws {
        let capture = FieldTestParser.parse(text: "connection_type SA\nnr_rsrp -90")
        XCTAssertEqual(capture.cells.first?.radio, .nrSA)
    }

    func testRatHintAndUnknownContext() throws {
        let capture = FieldTestParser.parse(text: """
        RAT: WCDMA
        UARFCN 10700
        PSC 211
        RSCP -79
        Ec/Io -6
        LAC 1234
        Cell ID 5832114
        """)
        let cell = try XCTUnwrap(capture.cells.first)
        XCTAssertEqual(cell.radio, .umts)
        XCTAssertEqual(cell.channel, 10700)
        XCTAssertEqual(cell.pci, 211)
        XCTAssertEqual(cell.rsrp, -79, "RSCP is treated as the UMTS equivalent of RSRP")
        XCTAssertEqual(cell.rsrq, -6)
        XCTAssertEqual(cell.areaCode, 1234)
        XCTAssertEqual(cell.cellId, 5_832_114)
    }

    func testRejectsImplausibleValuesAndFrequencyUnits() {
        let capture = FieldTestParser.parse(text: """
        rsrp -12
        pci 9999
        dl freq 1815 MHz
        sinr 14
        """)
        let cell = capture.cells.first
        XCTAssertNil(cell?.rsrp)
        XCTAssertNil(cell?.pci)
        XCTAssertNil(cell?.channel)
        XCTAssertEqual(cell?.sinr, 14)
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(FieldTestParser.parse(text: "").isEmpty)
        let capture = FieldTestParser.parse(text: "Hello world\nBattery 87%\n12:41")
        XCTAssertTrue(capture.isEmpty)
        XCTAssertFalse(capture.unparsedLines.isEmpty)
    }

    func testLabelMatching() {
        XCTAssertEqual(FieldTestParser.matchLabel("phy_cell_id")?.field, .pci)
        XCTAssertEqual(FieldTestParser.matchLabel("Phys Cell Id")?.field, .pci)
        XCTAssertEqual(FieldTestParser.matchLabel("phycellid")?.field, .pci)
        XCTAssertEqual(FieldTestParser.matchLabel("freq_band_lnd")?.field, .band, "OCR typo tolerated")
        XCTAssertEqual(FieldTestParser.matchLabel("rsrp_ant1")?.antenna, 1)
        XCTAssertEqual(FieldTestParser.matchLabel("rsrp 0")?.priority, 0)
        XCTAssertEqual(FieldTestParser.matchLabel("measured_rsrp")?.priority, 2)
        XCTAssertEqual(FieldTestParser.matchLabel("nr_rsrp")?.contextHint, .nr)
        XCTAssertEqual(FieldTestParser.matchLabel("ssb_rsrp")?.field, .rsrp)
        XCTAssertEqual(FieldTestParser.matchLabel("NR ARFCN")?.field, .channel)
        XCTAssertEqual(FieldTestParser.matchLabel("lte_rsrq")?.contextHint, .lte)
        XCTAssertEqual(FieldTestParser.matchLabel("ul_freq")?.field, .ulChannel)
        XCTAssertEqual(FieldTestParser.matchLabel("rsrq")?.field, .rsrq)
        XCTAssertEqual(FieldTestParser.matchLabel("rsrp")?.field, .rsrp)
        XCTAssertNil(FieldTestParser.matchLabel("carrier 1"))
        XCTAssertNil(FieldTestParser.matchLabel("battery"))
    }

    func testNumberParsing() {
        XCTAssertEqual(FieldTestParser.number(in: "-95 dBm"), -95)
        XCTAssertEqual(FieldTestParser.number(in: "\u{2212}95"), -95)
        XCTAssertEqual(FieldTestParser.number(in: "- 95"), -95)
        XCTAssertEqual(FieldTestParser.number(in: "n78"), 78)
        XCTAssertEqual(FieldTestParser.number(in: "12,5 dB"), 12.5)
        XCTAssertEqual(FieldTestParser.number(in: "-1O5 dBm"), -105)
        XCTAssertNil(FieldTestParser.number(in: "abc"))
        XCTAssertEqual(FieldTestParser.integer(in: "0x1F", allowHex: true), 31)
        XCTAssertEqual(FieldTestParser.integer(in: "1A2B", allowHex: true), 0x1A2B)
        XCTAssertEqual(FieldTestParser.integer(in: "1234", allowHex: true), 1234)
        XCTAssertNil(FieldTestParser.integer(in: "12.5"))
    }

    func testBandwidthInterpretation() {
        XCTAssertEqual(FieldTestParser.bandwidth("20 MHz", family: .lte), 20)
        XCTAssertEqual(FieldTestParser.bandwidth("100", family: .lte), 20)
        XCTAssertEqual(FieldTestParser.bandwidth("50 RBs", family: .lte), 10)
        XCTAssertEqual(FieldTestParser.bandwidth("4", family: .lte), 15)
        XCTAssertEqual(FieldTestParser.bandwidth("100", family: .nr), 100)
        XCTAssertNil(FieldTestParser.bandwidth("7", family: .nr))
    }

    func testOCRLineAssembler() {
        let tokens = [
            OCRToken(text: "-95", x: 0.80, y: 0.301, width: 0.10, height: 0.02),
            OCRToken(text: "rsrp0", x: 0.05, y: 0.300, width: 0.15, height: 0.02),
            OCRToken(text: "Serving Cell Meas", x: 0.05, y: 0.20, width: 0.5, height: 0.03),
            OCRToken(text: "rsrq0", x: 0.05, y: 0.340, width: 0.15, height: 0.02),
            OCRToken(text: "-11", x: 0.82, y: 0.342, width: 0.08, height: 0.02),
            OCRToken(text: "dB", x: 0.905, y: 0.342, width: 0.04, height: 0.02),
        ]
        let lines = OCRLineAssembler.lines(from: tokens)
        XCTAssertEqual(lines, ["Serving Cell Meas", "rsrp0\t-95", "rsrq0\t-11 dB"])
        let cell = FieldTestParser.parse(lines: lines).cells.first
        XCTAssertEqual(cell?.rsrp, -95)
        XCTAssertEqual(cell?.rsrq, -11)
    }

    func testLevenshtein() {
        XCTAssertEqual(FieldTestParser.levenshtein("kitten", "sitting"), 3)
        XCTAssertEqual(FieldTestParser.levenshtein("", "abc"), 3)
        XCTAssertEqual(FieldTestParser.levenshtein("same", "same"), 0)
    }
}
