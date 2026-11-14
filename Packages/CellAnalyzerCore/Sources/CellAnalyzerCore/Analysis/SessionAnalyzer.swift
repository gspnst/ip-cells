import Foundation

/// Something that happened on the radio link.
public struct NetworkEvent: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case radioChange(from: RadioTechnology, to: RadioTechnology)
        case handover(from: CellKey?, to: CellKey)
        case areaChange(from: Int, to: Int)
    }

    public var id: String
    public var timestamp: Date
    public var kind: Kind
    public var simSlot: String?

    public var title: String {
        switch kind {
        case let .radioChange(from, to):
            return "\(from.displayName) → \(to.displayName)"
        case let .handover(_, to):
            return "Handover to \(to.description)"
        case let .areaChange(from, to):
            return "Area code \(from) → \(to)"
        }
    }
}

public struct SessionSummary: Sendable {
    public var observationCount: Int
    public var measuredObservationCount: Int
    public var start: Date?
    public var end: Date?
    public var uniqueCells: Int
    public var handovers: Int
    public var radioChanges: Int
    /// Seconds spent on each radio technology (gaps longer than `maxSampleGap` are not counted).
    public var timeByRadio: [RadioTechnology: TimeInterval]
    public var timeByGeneration: [NetworkGeneration: TimeInterval]
    /// Observation counts per band label ("B3", "n78").
    public var bandUsage: [String: Int]
    public var operators: [String: Int]
    public var rsrp: MetricStats?
    public var sinr: MetricStats?
    public var events: [NetworkEvent]

    public var duration: TimeInterval {
        guard let start, let end else { return 0 }
        return end.timeIntervalSince(start)
    }

    /// Share (0…1) of tracked time on 5G.
    public var fiveGShare: Double {
        let total = timeByGeneration.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return (timeByGeneration[.g5] ?? 0) / total
    }
}

public enum SessionAnalyzer {
    /// Samples further apart than this are treated as a gap (app not recording).
    public static let maxSampleGap: TimeInterval = 300

    public static func summarize(_ observations: [CellObservation], aggregates: [CellAggregate]? = nil) -> SessionSummary {
        let sorted = observations.sorted { $0.timestamp < $1.timestamp }
        let cells = aggregates ?? CellAggregator.aggregate(sorted)
        let events = events(from: sorted)

        var timeByRadio: [RadioTechnology: TimeInterval] = [:]
        // Time accounting per SIM to avoid double counting dual-SIM samples.
        let bySim = Dictionary(grouping: sorted.filter { $0.radio != .unknown }, by: { $0.simSlot ?? "" })
        for (_, all) in bySim {
            let list = radioTimeline(all)
            for (a, b) in zip(list, list.dropFirst()) {
                let dt = b.timestamp.timeIntervalSince(a.timestamp)
                guard dt > 0, dt <= maxSampleGap else { continue }
                timeByRadio[a.radio, default: 0] += dt
            }
        }
        var timeByGeneration: [NetworkGeneration: TimeInterval] = [:]
        for (radio, t) in timeByRadio { timeByGeneration[radio.generation, default: 0] += t }

        var bandUsage: [String: Int] = [:]
        for o in sorted {
            guard let band = o.resolvedBand else { continue }
            bandUsage[o.radio.family == .nr ? "n\(band)" : (o.radio.family == .lte ? "B\(band)" : "\(o.radio.family.displayName) \(band)"), default: 0] += 1
        }

        var operators: [String: Int] = [:]
        for o in sorted where o.mcc != nil {
            operators[OperatorDirectory.describe(mcc: o.mcc, mnc: o.mnc), default: 0] += 1
        }

        let measured = sorted.filter { $0.identifiesCell }
        return SessionSummary(
            observationCount: sorted.count,
            measuredObservationCount: measured.count,
            start: sorted.first?.timestamp,
            end: sorted.last?.timestamp,
            uniqueCells: cells.count,
            handovers: events.filter { if case .handover = $0.kind { return true } else { return false } }.count,
            radioChanges: events.filter { if case .radioChange = $0.kind { return true } else { return false } }.count,
            timeByRadio: timeByRadio,
            timeByGeneration: timeByGeneration,
            bandUsage: bandUsage,
            operators: operators,
            rsrp: MetricStats(sorted.compactMap(\.rsrp)),
            sinr: MetricStats(sorted.compactMap(\.sinr)),
            events: events
        )
    }

    /// Derives radio-technology changes, handovers and area-code changes, per SIM.
    public static func events(from observations: [CellObservation]) -> [NetworkEvent] {
        let sorted = observations.sorted { $0.timestamp < $1.timestamp }
        var events: [NetworkEvent] = []
        let bySim = Dictionary(grouping: sorted, by: { $0.simSlot ?? "" })
        for (sim, list) in bySim {
            var lastRadio: RadioTechnology?
            for o in radioTimeline(list) {
                if let lastRadio, lastRadio != o.radio {
                    events.append(NetworkEvent(id: "rat-\(o.id)", timestamp: o.timestamp,
                                               kind: .radioChange(from: lastRadio, to: o.radio), simSlot: sim.isEmpty ? nil : sim))
                }
                lastRadio = o.radio
            }

            var lastCell: [RadioFamily: CellKey] = [:]
            var lastArea: [RadioFamily: Int] = [:]
            for o in list {
                let family = o.radio.family
                if let key = o.cellKey, key.isGlobal {
                    if let previous = lastCell[family], previous != key {
                        events.append(NetworkEvent(id: "ho-\(o.id)", timestamp: o.timestamp,
                                                   kind: .handover(from: previous, to: key), simSlot: sim.isEmpty ? nil : sim))
                    }
                    lastCell[family] = key
                }
                if let area = o.areaCode {
                    if let previous = lastArea[family], previous != area {
                        events.append(NetworkEvent(id: "area-\(o.id)", timestamp: o.timestamp,
                                                   kind: .areaChange(from: previous, to: area), simSlot: sim.isEmpty ? nil : sim))
                    }
                    lastArea[family] = area
                }
            }
        }
        return events.sorted { $0.timestamp < $1.timestamp }
    }

    /// The observations that describe "which radio technology was active".
    /// iOS samples are authoritative when present; Field Test captures describe individual legs
    /// (an NSA capture yields an LTE and an NR row), so only one row per capture is kept.
    static func radioTimeline(_ list: [CellObservation]) -> [CellObservation] {
        let known = list.filter { $0.radio != .unknown }
        let system = known.filter { $0.source == .system }
        if !system.isEmpty { return system }
        var seenCaptures = Set<UUID>()
        var result: [CellObservation] = []
        for o in known {
            guard let capture = o.captureID else { result.append(o); continue }
            guard !seenCaptures.contains(capture) else { continue }
            seenCaptures.insert(capture)
            // Represent the capture by its highest generation leg (NSA → 5G).
            let legs = known.filter { $0.captureID == capture }
            result.append(legs.max { $0.radio.generation < $1.radio.generation } ?? o)
        }
        return result
    }
}
