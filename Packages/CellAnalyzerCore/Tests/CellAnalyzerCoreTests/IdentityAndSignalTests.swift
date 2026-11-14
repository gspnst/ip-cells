import XCTest
@testable import CellAnalyzerCore

final class IdentityAndSignalTests: XCTestCase {
    func testLTEDecode() {
        let eci = CellIdentityDecoder.composeECI(enb: 104_837, localCell: 21)
        XCTAssertEqual(eci, 26_838_293)
        let d = CellIdentityDecoder.decodeLTE(eci: eci, plmn: PLMN(mcc: 310, mnc: 260))
        XCTAssertEqual(d.siteId, 104_837)
        XCTAssertEqual(d.localCellId, 21)
        XCTAssertEqual(d.globalIdentifier, "310-260-104837-21")
        XCTAssertEqual(d.hexCellId, "0x1998515")
        XCTAssertTrue(d.warnings.isEmpty)
        XCTAssertFalse(CellIdentityDecoder.decodeLTE(eci: 1 << 29).warnings.isEmpty)
        XCTAssertEqual(CellIdentityDecoder.lteSectorHint(localCellId: 21), "sector 1, carrier group 2")
    }

    func testNRDecode() {
        let nci = (0x123456 << 12) | 0x789
        let d = CellIdentityDecoder.decodeNR(nci: nci, gnbIdBits: 24)
        XCTAssertEqual(d.siteId, 0x123456)
        XCTAssertEqual(d.localCellId, 0x789)
        let d22 = CellIdentityDecoder.decodeNR(nci: nci, gnbIdBits: 22)
        XCTAssertEqual(d22.siteId, nci >> 14)
        XCTAssertEqual(d22.localCellId, nci & 0x3FFF)
        // Out-of-range bit lengths are clamped.
        XCTAssertEqual(CellIdentityDecoder.decodeNR(nci: nci, gnbIdBits: 40).siteIdBits, 32)
        XCTAssertEqual(CellIdentityDecoder.nrInterpretations(nci: nci).count, 11)
    }

    func testUMTSDecode() {
        let d = CellIdentityDecoder.decodeUMTS(cellId: (0x0A3 << 16) | 0x1C2D)
        XCTAssertEqual(d.siteId, 0x0A3)
        XCTAssertEqual(d.localCellId, 0x1C2D)
        let short = CellIdentityDecoder.decodeUMTS(cellId: 4711)
        XCTAssertNil(short.siteId)
        XCTAssertEqual(short.localCellId, 4711)
    }

    func testPLMN() {
        XCTAssertEqual(PLMN(mcc: 310, mnc: 260).description, "310-260")
        XCTAssertEqual(PLMN(mcc: 230, mnc: 3).description, "230-03")
        XCTAssertEqual(PLMN(mcc: 310, mnc: 4).description, "310-004")
        XCTAssertEqual(PLMN(string: "23003")?.mnc, 3)
        XCTAssertEqual(PLMN(string: "23003")?.mncDigits, 2)
        XCTAssertEqual(PLMN(string: "310-260")?.mcc, 310)
        XCTAssertEqual(PLMN(string: "310 410")?.mnc, 410)
        XCTAssertNil(PLMN(string: "12"))
        XCTAssertTrue(PLMN(mcc: 1, mnc: 1).isTestNetwork)
        XCTAssertFalse(PLMN(mcc: 262, mnc: 1).isTestNetwork)
        XCTAssertEqual(7.zeroPadded(to: 3), "007")
    }

    func testOperatorDirectory() {
        XCTAssertEqual(OperatorDirectory.country(mcc: 230)?.name, "Czechia")
        XCTAssertEqual(OperatorDirectory.country(mcc: 230)?.flag, "🇨🇿")
        XCTAssertEqual(OperatorDirectory.operatorName(mcc: 310, mnc: 260), "T-Mobile US")
        XCTAssertEqual(OperatorDirectory.describe(mcc: 262, mnc: 1), "Telekom (Germany)")
        XCTAssertEqual(OperatorDirectory.describe(mcc: 262, mnc: 99), "262-99 (Germany)")
        XCTAssertTrue(OperatorDirectory.usesThreeDigitMNC(mcc: 311))
        XCTAssertFalse(OperatorDirectory.usesThreeDigitMNC(mcc: 262))
        XCTAssertFalse(OperatorDirectory.isKnownMCC(123))
    }

    func testSignalGrades() {
        XCTAssertEqual(SignalQuality.grade(.rsrp, -75), .excellent)
        XCTAssertEqual(SignalQuality.grade(.rsrp, -85), .good)
        XCTAssertEqual(SignalQuality.grade(.rsrp, -95), .fair)
        XCTAssertEqual(SignalQuality.grade(.rsrp, -105), .poor)
        XCTAssertEqual(SignalQuality.grade(.rsrp, -118), .noSignal)
        XCTAssertEqual(SignalQuality.grade(.sinr, 25), .excellent)
        XCTAssertEqual(SignalQuality.grade(.sinr, -2), .poor)
        XCTAssertEqual(SignalQuality.grade(.rsrq, -12), .good)

        XCTAssertEqual(SignalQuality.score(rsrp: -60, rsrq: -3, sinr: 30), 100)
        XCTAssertEqual(SignalQuality.score(rsrp: -140, rsrq: -20, sinr: -10), 0)
        XCTAssertEqual(SignalQuality.score(rsrp: -100, rsrq: nil, sinr: nil), 50)
        XCTAssertNil(SignalQuality.score(rsrp: nil, rsrq: nil, sinr: nil))

        let o = CellObservation(source: .manual, radio: .lte, rsrp: -85, sinr: 2)
        XCTAssertEqual(SignalQuality.overallGrade(for: o), .fair)

        XCTAssertEqual(SignalQuality.spectralEfficiency(sinr: 40), 7.4)
        XCTAssertGreaterThan(SignalQuality.estimatedThroughputMbps(sinr: 20, bandwidthMHz: 20), 100)
    }

    func testGeodesy() {
        let a = GeoPoint(latitude: 50, longitude: 14)
        let north = GeoPoint(latitude: 51, longitude: 14)
        XCTAssertEqual(Geodesy.distance(a, north), 111_195, accuracy: 100)
        XCTAssertEqual(Geodesy.bearing(from: a, to: north), 0, accuracy: 0.01)
        XCTAssertEqual(Geodesy.bearing(from: a, to: GeoPoint(latitude: 50, longitude: 15)), 89.6, accuracy: 0.5)
        XCTAssertEqual(Geodesy.compassDirection(350), "N")
        XCTAssertEqual(Geodesy.compassDirection(135), "SE")

        let dest = Geodesy.destination(from: a, bearing: 90, distance: 10_000)
        XCTAssertEqual(Geodesy.distance(a, dest), 10_000, accuracy: 1)

        XCTAssertEqual(Geodesy.distance(timingAdvance: 10, family: .lte)?.lowerBound ?? 0, 781.2, accuracy: 0.01)
        XCTAssertNil(Geodesy.distance(timingAdvance: 3, family: .cdma))

        // Strong sample dominates the centroid.
        let strong = GeoPoint(latitude: 50.0, longitude: 14.0)
        let weak = GeoPoint(latitude: 50.01, longitude: 14.0)
        let c = Geodesy.weightedCentroid([(strong, -70), (weak, -100)])!
        XCTAssertLessThan(Geodesy.distance(c, strong), 10)
        let equal = Geodesy.weightedCentroid([(strong, -90), (weak, -90)])!
        XCTAssertEqual(equal.latitude, 50.005, accuracy: 0.0001)
        XCTAssertNil(Geodesy.weightedCentroid([]))

        let fspl = Geodesy.freeSpaceDistance(rsrpDBm: -100, frequencyMHz: 1800)
        XCTAssertGreaterThan(fspl, 1000)
    }
}
