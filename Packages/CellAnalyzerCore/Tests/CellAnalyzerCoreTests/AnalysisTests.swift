import XCTest
@testable import CellAnalyzerCore

final class AnalysisTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let here = GeoPoint(latitude: 50.08, longitude: 14.42, horizontalAccuracy: 5)

    func obs(_ dt: TimeInterval, _ radio: RadioTechnology = .lte, cell: Int? = nil, pci: Int? = nil,
             channel: Int? = nil, area: Int? = nil, rsrp: Double? = nil, mcc: Int? = 230, mnc: Int? = 3,
             source: ObservationSource = .fieldTestScreenshot, location: GeoPoint? = nil, capture: UUID? = nil) -> CellObservation {
        CellObservation(timestamp: t0.addingTimeInterval(dt), source: source, radio: radio, captureID: capture,
                        mcc: mcc, mnc: mnc, areaCode: area, cellId: cell, pci: pci, channel: channel,
                        rsrp: rsrp, location: location ?? here)
    }

    // MARK: Aggregation

    func testAggregationMergesPhysicalIdentity() {
        let list = [
            obs(0, cell: 1000, pci: 10, channel: 1300, area: 1, rsrp: -90),
            obs(10, pci: 10, channel: 1300, rsrp: -80),            // physical only → same cell
            obs(20, cell: 1000, pci: 10, channel: 1300, mcc: nil, mnc: nil), // no PLMN → same cell
            obs(30, cell: 2000, pci: 11, channel: 6300, area: 1, rsrp: -100),
            obs(40, pci: 99, channel: 1300),                     // unknown physical cell
            obs(50, .lte, source: .system),                     // no identity → ignored
        ]
        let cells = CellAggregator.aggregate(list)
        XCTAssertEqual(cells.count, 3)
        let main = cells.first { $0.cellId == 1000 }!
        XCTAssertEqual(main.observationCount, 3)
        XCTAssertEqual(main.rsrp?.max, -80)
        XCTAssertEqual(main.rsrp?.mean, -85)
        XCTAssertEqual(main.bandLabel, "B3")
        XCTAssertEqual(main.title(), "eNB 3 · 232")
        XCTAssertEqual(main.operatorDescription, "Vodafone CZ (Czechia)")
        XCTAssertNotNil(main.estimatedLocation)
        XCTAssertTrue(cells.contains { $0.cellId == nil && $0.pci == 99 })
        XCTAssertEqual(cells.first { $0.pci == 99 }?.title(), "PCI 99 @ 1300")
    }

    // MARK: Session

    func testSessionSummaryAndEvents() {
        let capture = UUID()
        let list = [
            obs(0, .lte, source: .system),
            obs(60, .nrNSA, source: .system),
            obs(120, .nrNSA, source: .system),
            obs(180, .lte, source: .system),
            obs(5000, .lte, source: .system),   // after a gap
            obs(61, .lte, cell: 1000, pci: 1, channel: 1300, area: 7, capture: capture),
            obs(61, .nrNSA, pci: 400, channel: 632628, capture: capture),
            obs(200, .lte, cell: 2000, pci: 2, channel: 1300, area: 8),
        ]
        let summary = SessionAnalyzer.summarize(list)
        XCTAssertEqual(summary.observationCount, 8)
        XCTAssertEqual(summary.radioChanges, 2, "only iOS samples drive radio changes")
        XCTAssertEqual(summary.handovers, 1)
        XCTAssertEqual(summary.timeByRadio[.lte], 60)
        XCTAssertEqual(summary.timeByRadio[.nrNSA], 120)
        XCTAssertEqual(summary.fiveGShare, 120.0 / 180.0, accuracy: 0.0001)
        XCTAssertEqual(summary.bandUsage["B3"], 2)
        XCTAssertEqual(summary.bandUsage["n78"], 1)
        XCTAssertEqual(summary.uniqueCells, 3)
        XCTAssertTrue(summary.events.contains { if case .areaChange(7, 8) = $0.kind { return true } else { return false } })
    }

    func testRadioTimelineWithoutSystemSamples() {
        let capture = UUID()
        let list = [
            obs(0, .lte, cell: 1, pci: 1, channel: 1300, capture: capture),
            obs(0, .nrNSA, pci: 2, channel: 632628, capture: capture),
            obs(10, .lte, cell: 1, pci: 1, channel: 1300),
        ]
        let timeline = SessionAnalyzer.radioTimeline(list)
        XCTAssertEqual(timeline.map(\.radio), [.nrNSA, .lte])
    }

    // MARK: Anomalies

    func testDetectsTestNetworkAndDowngrade() {
        let list = [
            obs(0, .lte, source: .system),
            obs(30, .edge, source: .system),
            obs(40, .gsm, cell: 1234, mcc: 1, mnc: 1),
        ]
        let anomalies = AnomalyDetector().detect(list)
        XCTAssertEqual(anomalies.first?.kind, .testNetwork)
        XCTAssertTrue(anomalies.contains { $0.kind == .downgradeTo2G })
    }

    func testDetectsIdentityConflictsAndTransientArea() {
        let list = [
            obs(0, cell: 5000, pci: 10, channel: 1300, area: 100),
            obs(60, cell: 5000, pci: 11, channel: 1300, area: 100),   // same ECI, new PCI
            obs(120, cell: 6000, pci: 20, channel: 1300, area: 100),
            obs(180, cell: 7000, pci: 30, channel: 1300, area: 666),  // brief foreign TAC
            obs(240, cell: 6000, pci: 20, channel: 1300, area: 100),
        ]
        let kinds = Set(AnomalyDetector().detect(list).map(\.kind))
        XCTAssertTrue(kinds.contains(.identityConflict))
        XCTAssertTrue(kinds.contains(.transientAreaCode))
        XCTAssertFalse(kinds.contains(.areaCodeConflict))
    }

    func testDetectsPCICollisionStrongSignalAndDatabaseIssues() {
        let near = Geodesy.destination(from: here, bearing: 45, distance: 500)
        let list = [
            obs(0, cell: 100, pci: 7, channel: 1300, rsrp: -45),
            obs(10, cell: 200, pci: 7, channel: 1300, location: near),
            obs(20, cell: 300, pci: 8, channel: 1300),
        ]
        let farTower = Geodesy.destination(from: here, bearing: 0, distance: 80_000)
        let keyFar = list[0].cellKey!, keyMissing = list[2].cellKey!
        let anomalies = AnomalyDetector().detect(list, databaseLocations: [keyFar: farTower], notFoundInDatabase: [keyMissing])
        let kinds = Set(anomalies.map(\.kind))
        XCTAssertTrue(kinds.contains(.pciCollision))
        XCTAssertTrue(kinds.contains(.unusuallyStrongSignal))
        XCTAssertTrue(kinds.contains(.towerTooFar))
        XCTAssertTrue(kinds.contains(.notInDatabase))
        // Sorted by severity, high first.
        XCTAssertEqual(anomalies.map(\.severity), anomalies.map(\.severity).sorted(by: >))
    }

    func testCleanDataHasNoAnomalies() {
        let list = [
            obs(0, .lte, source: .system),
            obs(5, cell: 100, pci: 7, channel: 1300, area: 1, rsrp: -90),
            obs(60, .nrNSA, source: .system),
            obs(65, cell: 100, pci: 7, channel: 1300, area: 1, rsrp: -92),
        ]
        XCTAssertTrue(AnomalyDetector().detect(list).isEmpty)
    }

    // MARK: Export / import

    func testCSVExport() {
        var o = obs(0, cell: 26_838_293, pci: 301, channel: 66786, area: 12345, rsrp: -95.5, mcc: 310, mnc: 260)
        o.notes = "near \"the\" park, north side"
        let csv = Exporters.csv([o])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(String(lines[0]), Exporters.csvColumns.joined(separator: ","))
        XCTAssertTrue(lines[1].contains("310,260,T-Mobile US (United States),12345,26838293,104837,21,301,66786,66,2145"))
        XCTAssertTrue(lines[1].contains("-95.5"))
        XCTAssertTrue(lines[1].hasSuffix("\"near \"\"the\"\" park, north side\""))
    }

    func testJSONRoundTrip() throws {
        let list = [obs(0, cell: 1, pci: 2, channel: 1300, rsrp: -90), obs(1, .nrSA, source: .system)]
        let data = try Exporters.json(list)
        let decoded = try Exporters.importJSON(data)
        XCTAssertEqual(decoded, list)
        // Bare arrays are accepted too.
        let bare = try Exporters.makeEncoder().encode(list)
        XCTAssertEqual(try Exporters.importJSON(bare), list)
    }

    func testKML() {
        let list = [obs(0, cell: 1, pci: 2, channel: 1300, rsrp: -70)]
        let kml = Exporters.kml(observations: list, aggregates: CellAggregator.aggregate(list))
        XCTAssertTrue(kml.contains("<styleUrl>#excellent</styleUrl>"))
        XCTAssertTrue(kml.contains("<styleUrl>#tower</styleUrl>"))
        XCTAssertTrue(kml.contains("14.42,50.08,0"))
    }

    // MARK: OpenCellID

    func testOpenCellIDRequest() throws {
        let request = try OpenCellID.request(apiKey: " pk.abc ", mcc: 230, mnc: 3, areaCode: 100, cellId: 5000, family: .lte)
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://opencellid.org/cell/get?"))
        for part in ["key=pk.abc", "mcc=230", "mnc=3", "lac=100", "cellid=5000", "radio=LTE", "format=json"] {
            XCTAssertTrue(url.contains(part), part)
        }
        XCTAssertThrowsError(try OpenCellID.request(apiKey: "", mcc: 1, mnc: 1, areaCode: 1, cellId: 1, family: .lte))
        XCTAssertThrowsError(try OpenCellID.request(apiKey: "k", mcc: 1, mnc: 1, areaCode: 1, cellId: 1, family: .unknown))
    }

    func testOpenCellIDParsing() throws {
        let found = try OpenCellID.parse(Data(#"{"lat":50.1,"lon":14.4,"range":1200,"samples":42,"radio":"LTE"}"#.utf8))
        guard case let .found(tower) = found else { return XCTFail("expected found") }
        XCTAssertEqual(tower.location.latitude, 50.1)
        XCTAssertEqual(tower.rangeMeters, 1200)
        XCTAssertEqual(tower.samples, 42)

        let missing = try OpenCellID.parse(Data(#"{"error":"Cell not found","code":1}"#.utf8))
        guard case .notFound = missing else { return XCTFail("expected notFound") }

        XCTAssertThrowsError(try OpenCellID.parse(Data(#"{"error":"Invalid token","code":2}"#.utf8))) { error in
            XCTAssertEqual(error as? TowerLookupError, .service("Invalid token"))
        }
        XCTAssertThrowsError(try OpenCellID.parse(Data("<html>".utf8)))
    }
}
