import Foundation

public enum AnomalySeverity: Int, Comparable, Sendable, CaseIterable {
    case info = 0, low, medium, high

    public var label: String {
        switch self {
        case .info: return "Info"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    public static func < (lhs: AnomalySeverity, rhs: AnomalySeverity) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A pattern worth a closer look. None of these prove anything on their own – networks get
/// re-planned, databases are incomplete – but several together near the same place and time are
/// the classic fingerprint of a cell-site simulator ("IMSI catcher") or a misconfigured cell.
public struct Anomaly: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable {
        case testNetwork, unknownCountry, downgradeTo2G, identityConflict, pciCollision
        case areaCodeConflict, transientAreaCode, unusuallyStrongSignal, towerTooFar, notInDatabase
    }

    public var id: String
    public var kind: Kind
    public var severity: AnomalySeverity
    public var title: String
    public var detail: String
    public var timestamp: Date
    public var cellKey: CellKey?
    public var observationIDs: [UUID]
}

public struct AnomalyDetector {
    public struct Configuration: Sendable {
        /// RSRP above this is flagged as unusually strong.
        public var strongSignalDBm: Double = -50
        /// Same channel+PCI with different cell IDs closer than this is suspicious.
        public var pciCollisionRadiusMeters: Double = 2_000
        /// An area code seen only within this window between two identical ones is "transient".
        public var transientAreaWindow: TimeInterval = 15 * 60
        /// Database tower position further than this from where it was measured.
        public var maxPlausibleRangeMeters: Double = 35_000

        public init() {}
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// - Parameters:
    ///   - databaseLocations: Tower positions from a cell database (e.g. OpenCellID), keyed by cell.
    ///   - notFoundInDatabase: Cells that were looked up but are unknown to the database.
    public func detect(_ observations: [CellObservation],
                       databaseLocations: [CellKey: GeoPoint] = [:],
                       notFoundInDatabase: Set<CellKey> = []) -> [Anomaly] {
        let sorted = observations.sorted { $0.timestamp < $1.timestamp }
        var result: [Anomaly] = []
        result += testAndUnknownNetworks(sorted)
        result += downgrades(sorted)
        result += identityConflicts(sorted)
        result += pciCollisions(sorted)
        result += transientAreaCodes(sorted)
        result += strongSignals(sorted)
        result += databaseChecks(sorted, databaseLocations: databaseLocations, notFound: notFoundInDatabase)
        return result.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.timestamp > $1.timestamp
        }
    }

    // MARK: Rules

    func testAndUnknownNetworks(_ list: [CellObservation]) -> [Anomaly] {
        var seen = Set<String>()
        var out: [Anomaly] = []
        for o in list {
            guard let mcc = o.mcc, let mnc = o.mnc else { continue }
            let plmn = PLMN(mcc: mcc, mnc: mnc, mncDigits: o.mncDigits)
            guard !seen.contains(plmn.description) else { continue }
            if plmn.isTestNetwork {
                seen.insert(plmn.description)
                out.append(Anomaly(id: "test-\(plmn)", kind: .testNetwork, severity: .high,
                                   title: "Test network \(plmn)",
                                   detail: "PLMN \(plmn) is reserved for lab equipment. Commercial networks never broadcast it, but cheap cell-site simulators often do.",
                                   timestamp: o.timestamp, cellKey: o.cellKey,
                                   observationIDs: list.filter { $0.mcc == mcc && $0.mnc == mnc }.map(\.id)))
            } else if !OperatorDirectory.isKnownMCC(mcc) {
                seen.insert(plmn.description)
                out.append(Anomaly(id: "mcc-\(plmn)", kind: .unknownCountry, severity: .medium,
                                   title: "Unallocated country code \(mcc)",
                                   detail: "MCC \(mcc) is not assigned to any country. Check the capture for OCR errors; if it is correct the cell is misconfigured or not a real network.",
                                   timestamp: o.timestamp, cellKey: o.cellKey, observationIDs: [o.id]))
            }
        }
        return out
    }

    func downgrades(_ list: [CellObservation]) -> [Anomaly] {
        var out: [Anomaly] = []
        for (_, sim) in Dictionary(grouping: list, by: { $0.simSlot ?? "" }) {
            let timeline = SessionAnalyzer.radioTimeline(sim)
            for (a, b) in zip(timeline, timeline.dropFirst())
            where a.radio.generation >= .g4 && b.radio.generation == .g2 {
                out.append(Anomaly(id: "2g-\(b.id)", kind: .downgradeTo2G, severity: .medium,
                                   title: "Dropped from \(a.radio.displayName) to \(b.radio.displayName)",
                                   detail: "2G has no network authentication and weak encryption, so forcing phones onto 2G is a common interception technique. It can also simply be poor coverage – see whether it repeats in the same place. Lockdown Mode (iOS 17+) disables 2G entirely.",
                                   timestamp: b.timestamp, cellKey: b.cellKey, observationIDs: [a.id, b.id]))
            }
        }
        return out
    }

    /// The same global cell identity broadcast with different physical parameters or area codes.
    func identityConflicts(_ list: [CellObservation]) -> [Anomaly] {
        var out: [Anomaly] = []
        let global = Dictionary(grouping: list.filter { $0.cellKey?.isGlobal == true }, by: { $0.cellKey! })
        for (key, obs) in global {
            let pcis = Set(obs.compactMap(\.pci)), channels = Set(obs.compactMap(\.channel))
            if pcis.count > 1 || channels.count > 1 {
                var what: [String] = []
                if pcis.count > 1 { what.append("PCIs \(pcis.sorted().map(String.init).joined(separator: ", "))") }
                if channels.count > 1 { what.append("channels \(channels.sorted().map(String.init).joined(separator: ", "))") }
                out.append(Anomaly(id: "conflict-\(key)", kind: .identityConflict, severity: .high,
                                   title: "Cell identity reused with different radio parameters",
                                   detail: "\(key) was seen with \(what.joined(separator: " and ")). A real cell keeps its PCI and frequency; a spoofed cell copying a real identity usually doesn't. Network re-planning or an OCR mistake are innocent explanations.",
                                   timestamp: obs.last?.timestamp ?? Date(), cellKey: key, observationIDs: obs.map(\.id)))
            }
            let areas = Set(obs.compactMap(\.areaCode))
            if areas.count > 1 {
                out.append(Anomaly(id: "area-conflict-\(key)", kind: .areaCodeConflict, severity: .high,
                                   title: "Cell changed its area code",
                                   detail: "\(key) was seen in area codes \(areas.sorted().map(String.init).joined(separator: ", ")). Area codes are rarely changed by operators; a cell advertising a different TAC/LAC forces phones to re-register, which simulators exploit.",
                                   timestamp: obs.last?.timestamp ?? Date(), cellKey: key, observationIDs: obs.map(\.id)))
            }
        }
        return out
    }

    /// Different cells on the same channel and PCI measured close together.
    func pciCollisions(_ list: [CellObservation]) -> [Anomaly] {
        var out: [Anomaly] = []
        let candidates = list.filter { $0.cellId != nil && $0.channel != nil && $0.pci != nil && $0.location != nil }
        let groups = Dictionary(grouping: candidates) { "\($0.radio.family.rawValue)/\($0.mcc ?? -1)/\($0.mnc ?? -1)/\($0.channel!)/\($0.pci!)" }
        for (group, obs) in groups {
            let byCell = Dictionary(grouping: obs, by: { $0.cellId! })
            guard byCell.count > 1 else { continue }
            let cells = Array(byCell)
            var reported = false
            for i in 0..<cells.count where !reported {
                for j in (i + 1)..<cells.count where !reported {
                    guard let a = cells[i].value.last, let b = cells[j].value.last,
                          let la = a.location, let lb = b.location else { continue }
                    let distance = Geodesy.distance(la, lb)
                    if distance <= configuration.pciCollisionRadiusMeters {
                        reported = true
                        out.append(Anomaly(id: "pci-\(group)", kind: .pciCollision, severity: .medium,
                                           title: "PCI \(a.pci!) used by two cells \(Int(distance)) m apart",
                                           detail: "Cells \(a.cellId!) and \(b.cellId!) share channel \(a.channel!) and PCI \(a.pci!). Operators avoid this because phones can't tell the cells apart; it is either a planning error or one of them is not a real network cell.",
                                           timestamp: max(a.timestamp, b.timestamp), cellKey: b.cellKey,
                                           observationIDs: obs.map(\.id)))
                    }
                }
            }
        }
        return out
    }

    /// A → B → A area-code sequence where B lasted only briefly.
    func transientAreaCodes(_ list: [CellObservation]) -> [Anomaly] {
        var out: [Anomaly] = []
        let withArea = list.filter { $0.areaCode != nil && $0.mcc != nil }
        let groups = Dictionary(grouping: withArea) { "\($0.simSlot ?? "")/\($0.radio.family.rawValue)/\($0.mcc!)/\($0.mnc ?? -1)" }
        for (_, obs) in groups {
            // Collapse into runs of identical area codes.
            var runs: [(area: Int, items: [CellObservation])] = []
            for o in obs {
                if let last = runs.last, last.area == o.areaCode { runs[runs.count - 1].items.append(o) }
                else { runs.append((o.areaCode!, [o])) }
            }
            guard runs.count >= 3 else { continue }
            for i in 1..<(runs.count - 1) {
                let before = runs[i - 1], mid = runs[i], after = runs[i + 1]
                guard before.area == after.area,
                      let start = before.items.last?.timestamp, let end = after.items.first?.timestamp,
                      end.timeIntervalSince(start) <= configuration.transientAreaWindow else { continue }
                out.append(Anomaly(id: "transient-\(mid.items[0].id)", kind: .transientAreaCode, severity: .medium,
                                   title: "Brief switch to area code \(mid.area)",
                                   detail: "The phone left area \(before.area) for area \(mid.area) and came back within \(Int(end.timeIntervalSince(start) / 60) + 1) min. A short-lived area code is a typical sign of a cell luring phones into a location update.",
                                   timestamp: mid.items[0].timestamp, cellKey: mid.items[0].cellKey,
                                   observationIDs: mid.items.map(\.id)))
            }
        }
        return out
    }

    func strongSignals(_ list: [CellObservation]) -> [Anomaly] {
        var out: [Anomaly] = []
        var seen = Set<CellKey>()
        for o in list {
            guard let rsrp = o.rsrp, rsrp > configuration.strongSignalDBm, let key = o.cellKey, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(Anomaly(id: "strong-\(key)", kind: .unusuallyStrongSignal, severity: .low,
                               title: "Very strong signal (\(Int(rsrp)) dBm)",
                               detail: "RSRP above \(Int(configuration.strongSignalDBm)) dBm means the transmitter is very close – typical for small cells and indoor systems, but also for portable base stations.",
                               timestamp: o.timestamp, cellKey: key, observationIDs: [o.id]))
        }
        return out
    }

    func databaseChecks(_ list: [CellObservation], databaseLocations: [CellKey: GeoPoint], notFound: Set<CellKey>) -> [Anomaly] {
        var out: [Anomaly] = []
        let byKey = Dictionary(grouping: list.filter { $0.cellKey != nil }, by: { $0.cellKey! })
        for (key, tower) in databaseLocations {
            guard let obs = byKey[key] else { continue }
            let distances = obs.compactMap { o in o.location.map { Geodesy.distance($0, tower) } }
            guard let nearest = distances.min(), nearest > configuration.maxPlausibleRangeMeters else { continue }
            out.append(Anomaly(id: "far-\(key)", kind: .towerTooFar, severity: .medium,
                               title: "Cell measured \(Int(nearest / 1000)) km from its registered site",
                               detail: "The database places \(key) far beyond normal cell range from where you measured it. Either the database entry is wrong, or the identity is being broadcast somewhere else.",
                               timestamp: obs.last?.timestamp ?? Date(), cellKey: key, observationIDs: obs.map(\.id)))
        }
        for key in notFound {
            guard let obs = byKey[key] else { continue }
            out.append(Anomaly(id: "unknown-\(key)", kind: .notInDatabase, severity: .low,
                               title: "Cell not in database",
                               detail: "\(key) is unknown to the cell database. New and rural cells are often missing, so this matters mainly together with other findings.",
                               timestamp: obs.last?.timestamp ?? Date(), cellKey: key, observationIDs: obs.map(\.id)))
        }
        return out
    }
}
