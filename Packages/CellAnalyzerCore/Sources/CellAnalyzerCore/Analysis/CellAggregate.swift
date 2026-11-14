import Foundation

/// Summary statistics of a signal metric.
public struct MetricStats: Sendable, Hashable {
    public var count: Int
    public var min: Double
    public var max: Double
    public var mean: Double
    public var latest: Double

    public init?(_ values: [Double]) {
        guard let first = values.first, let last = values.last else { return nil }
        count = values.count
        min = values.min() ?? first
        max = values.max() ?? first
        mean = values.reduce(0, +) / Double(values.count)
        latest = last
    }
}

/// Everything known about one cell, merged from all of its observations.
public struct CellAggregate: Identifiable, Sendable, Hashable {
    public var id: CellKey { key }
    public var key: CellKey
    public var radio: RadioTechnology
    public var mcc: Int?
    public var mnc: Int?
    public var mncDigits: Int?
    public var areaCode: Int?
    public var cellId: Int?
    public var pci: Int?
    public var channel: Int?
    public var band: Int?
    public var bandwidthMHz: Double?
    public var observationCount: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var rsrp: MetricStats?
    public var rsrq: MetricStats?
    public var sinr: MetricStats?
    public var rssi: MetricStats?
    /// Power-weighted centroid of the places the cell was measured from.
    public var estimatedLocation: GeoPoint?
    public var observationIDs: [UUID]
    public var areaCodesSeen: Set<Int>
    public var pcisSeen: Set<Int>
    public var channelsSeen: Set<Int>

    public var family: RadioFamily { key.family }

    public var plmn: PLMN? {
        guard let mcc, let mnc else { return nil }
        return PLMN(mcc: mcc, mnc: mnc, mncDigits: mncDigits)
    }

    public var operatorDescription: String { OperatorDirectory.describe(mcc: mcc, mnc: mnc) }

    public var channelInfo: ChannelInfo? {
        guard let channel else {
            guard let band else { return nil }
            return ChannelInfo(family: family, channel: -1, band: band,
                               bandName: family == .nr ? NRBands.band(number: band)?.name : LTEBands.band(number: band)?.name)
        }
        return Spectrum.channelInfo(family: family, channel: channel, mcc: mcc, reportedBand: band)
    }

    public var bandLabel: String? {
        if let label = channelInfo?.bandLabel { return label }
        guard let band else { return nil }
        return family == .nr ? "n\(band)" : "B\(band)"
    }

    public func decodedIdentity(gnbIdBits: Int = CellIdentityDecoder.defaultGNBIdBits) -> DecodedCellIdentity? {
        guard let cellId else { return nil }
        return CellIdentityDecoder.decode(family: family, cellId: cellId, plmn: plmn, gnbIdBits: gnbIdBits)
    }

    /// Short title such as "eNB 123456 · 3" or "PCI 101 @ 6300".
    public func title(gnbIdBits: Int = CellIdentityDecoder.defaultGNBIdBits) -> String {
        if let d = decodedIdentity(gnbIdBits: gnbIdBits) {
            if let site = d.siteId, let local = d.localCellId {
                let siteName = family == .nr ? "gNB" : (family == .lte ? "eNB" : "RNC")
                return "\(siteName) \(site) · \(local)"
            }
            return "CID \(d.rawCellId)"
        }
        var parts: [String] = []
        if let pci { parts.append("PCI \(pci)") }
        if let channel { parts.append("@ \(channel)") }
        return parts.isEmpty ? key.description : parts.joined(separator: " ")
    }

    public var overallGrade: SignalGrade? {
        var grades: [SignalGrade] = []
        if let rsrp { grades.append(SignalQuality.grade(.rsrp, rsrp.mean, family: family)) }
        if let sinr { grades.append(SignalQuality.grade(.sinr, sinr.mean, family: family)) }
        if grades.isEmpty, let rssi { grades.append(SignalQuality.grade(.rssi, rssi.mean, family: family)) }
        return grades.min()
    }
}

public enum CellAggregator {
    /// Groups observations by cell. Observations that only carry a physical identity (channel + PCI)
    /// are merged into a globally identified cell when the match is unambiguous.
    public static func aggregate(_ observations: [CellObservation]) -> [CellAggregate] {
        let sorted = observations.sorted { $0.timestamp < $1.timestamp }
        var groups: [CellKey: [CellObservation]] = [:]
        var physicalOnly: [CellObservation] = []

        for o in sorted {
            guard let key = o.cellKey else { continue }
            if key.isGlobal { groups[key, default: []].append(o) } else { physicalOnly.append(o) }
        }

        // Merge global keys lacking a PLMN into the single matching key that has one.
        for key in groups.keys where key.mcc == nil {
            let matches = groups.keys.filter { $0.mcc != nil && $0.family == key.family && $0.cellId == key.cellId }
            if matches.count == 1, let target = matches.first, let moved = groups.removeValue(forKey: key) {
                groups[target, default: []].append(contentsOf: moved)
            }
        }

        for o in physicalOnly {
            let family = o.radio.family
            let matches = groups.filter { key, list in
                key.family == family && plmnCompatible(key, o)
                    && list.contains { $0.channel == o.channel && $0.pci == o.pci }
            }
            if matches.count == 1, let key = matches.first?.key {
                groups[key, default: []].append(o)
            } else if let key = o.cellKey {
                groups[key, default: []].append(o)
            }
        }

        return groups.map { key, list in build(key: key, observations: list.sorted { $0.timestamp < $1.timestamp }) }
            .sorted { lhs, rhs in
                if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
                return lhs.key.description < rhs.key.description
            }
    }

    private static func plmnCompatible(_ key: CellKey, _ o: CellObservation) -> Bool {
        (key.mcc == nil || o.mcc == nil || key.mcc == o.mcc) && (key.mnc == nil || o.mnc == nil || key.mnc == o.mnc)
    }

    static func build(key: CellKey, observations list: [CellObservation]) -> CellAggregate {
        func latest<T>(_ path: KeyPath<CellObservation, T?>) -> T? {
            list.reversed().lazy.compactMap { $0[keyPath: path] }.first
        }
        let located = list.compactMap { o in o.location.map { (point: $0, dBm: o.rsrp ?? o.rssi) } }
        return CellAggregate(
            key: key,
            radio: list.last?.radio ?? .unknown,
            mcc: latest(\.mcc), mnc: latest(\.mnc), mncDigits: latest(\.mncDigits),
            areaCode: latest(\.areaCode), cellId: latest(\.cellId), pci: latest(\.pci),
            channel: latest(\.channel), band: latest(\.band), bandwidthMHz: latest(\.bandwidthMHz),
            observationCount: list.count,
            firstSeen: list.first?.timestamp ?? Date(), lastSeen: list.last?.timestamp ?? Date(),
            rsrp: MetricStats(list.compactMap(\.rsrp)),
            rsrq: MetricStats(list.compactMap(\.rsrq)),
            sinr: MetricStats(list.compactMap(\.sinr)),
            rssi: MetricStats(list.compactMap(\.rssi)),
            estimatedLocation: Geodesy.weightedCentroid(located),
            observationIDs: list.map(\.id),
            areaCodesSeen: Set(list.compactMap(\.areaCode)),
            pcisSeen: Set(list.compactMap(\.pci)),
            channelsSeen: Set(list.compactMap(\.channel))
        )
    }
}
