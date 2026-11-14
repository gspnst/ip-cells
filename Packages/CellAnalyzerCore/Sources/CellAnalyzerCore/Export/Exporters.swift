import Foundation

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csv, json, kml

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .csv: return "CSV (spreadsheet)"
        case .json: return "JSON (re-importable)"
        case .kml: return "KML (Google Earth)"
        }
    }
}

public enum Exporters {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func data(_ format: ExportFormat, observations: [CellObservation],
                            aggregates: [CellAggregate] = [], gnbIdBits: Int = CellIdentityDecoder.defaultGNBIdBits) throws -> Data {
        switch format {
        case .csv: return Data(csv(observations, gnbIdBits: gnbIdBits).utf8)
        case .json: return try json(observations)
        case .kml: return Data(kml(observations: observations, aggregates: aggregates, gnbIdBits: gnbIdBits).utf8)
        }
    }

    // MARK: CSV

    public static let csvColumns = [
        "timestamp", "source", "sim", "radio", "mcc", "mnc", "operator", "area_code", "cell_id", "site_id", "local_cell_id",
        "pci", "channel", "band", "dl_mhz", "bandwidth_mhz", "rsrp_dbm", "rsrq_db", "sinr_db", "rssi_dbm",
        "timing_advance", "latitude", "longitude", "accuracy_m", "notes",
    ]

    public static func csv(_ observations: [CellObservation], gnbIdBits: Int = CellIdentityDecoder.defaultGNBIdBits) -> String {
        var lines = [csvColumns.joined(separator: ",")]
        for o in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let plmn = o.mcc.flatMap { mcc in o.mnc.map { PLMN(mcc: mcc, mnc: $0, mncDigits: o.mncDigits) } }
            let decoded = o.cellId.map { CellIdentityDecoder.decode(family: o.radio.family, cellId: $0, plmn: plmn, gnbIdBits: gnbIdBits) }
            let info = o.channel.flatMap { Spectrum.channelInfo(family: o.radio.family, channel: $0, mcc: o.mcc, reportedBand: o.band) }
            let fields: [String?] = [
                iso.string(from: o.timestamp), o.source.rawValue, o.simSlot, o.radio.rawValue,
                o.mcc.map { $0.zeroPadded(to: 3) }, plmn?.formattedMNC,
                o.mcc != nil ? OperatorDirectory.describe(mcc: o.mcc, mnc: o.mnc) : nil,
                o.areaCode.map(String.init), o.cellId.map(String.init),
                decoded?.siteId.map(String.init), decoded?.localCellId.map(String.init),
                o.pci.map(String.init), o.channel.map(String.init), (o.band ?? info?.band).map(String.init),
                info?.downlinkMHz.map { Spectrum.trimmed($0, decimals: 3) },
                o.bandwidthMHz.map { Spectrum.trimmed($0, decimals: 1) },
                o.rsrp.map { Spectrum.trimmed($0, decimals: 1) }, o.rsrq.map { Spectrum.trimmed($0, decimals: 1) },
                o.sinr.map { Spectrum.trimmed($0, decimals: 1) }, o.rssi.map { Spectrum.trimmed($0, decimals: 1) },
                o.timingAdvance.map(String.init),
                o.location.map { Spectrum.trimmed($0.latitude, decimals: 7) },
                o.location.map { Spectrum.trimmed($0.longitude, decimals: 7) },
                o.location?.horizontalAccuracy.map { Spectrum.trimmed($0, decimals: 1) },
                o.notes,
            ]
            lines.append(fields.map { csvEscape($0 ?? "") }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func csvEscape(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: JSON

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(iso.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                if let date = iso.date(from: s) { return date }
                let plain = ISO8601DateFormatter()
                if let date = plain.date(from: s) { return date }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date \(s)")
            }
            return Date(timeIntervalSinceReferenceDate: try c.decode(Double.self))
        }
        return d
    }

    public static func json(_ observations: [CellObservation]) throws -> Data {
        try makeEncoder().encode(ExportEnvelope(observations: observations))
    }

    /// Accepts either an export envelope or a bare array of observations.
    public static func importJSON(_ data: Data) throws -> [CellObservation] {
        let decoder = makeDecoder()
        if let envelope = try? decoder.decode(ExportEnvelope.self, from: data) { return envelope.observations }
        return try decoder.decode([CellObservation].self, from: data)
    }

    public struct ExportEnvelope: Codable {
        public var format = "cell-analyzer"
        public var version = 1
        public var exportedAt = Date()
        public var observations: [CellObservation]
    }

    // MARK: KML

    public static func kml(observations: [CellObservation], aggregates: [CellAggregate],
                           gnbIdBits: Int = CellIdentityDecoder.defaultGNBIdBits) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Cell Analyzer export</name>
        <Style id="excellent"><IconStyle><color>ff00c000</color><scale>0.6</scale></IconStyle></Style>
        <Style id="good"><IconStyle><color>ff00d0a0</color><scale>0.6</scale></IconStyle></Style>
        <Style id="fair"><IconStyle><color>ff00c0ff</color><scale>0.6</scale></IconStyle></Style>
        <Style id="poor"><IconStyle><color>ff0060ff</color><scale>0.6</scale></IconStyle></Style>
        <Style id="none"><IconStyle><color>ff0000c0</color><scale>0.6</scale></IconStyle></Style>
        <Style id="tower"><IconStyle><color>ffff6000</color><scale>1.1</scale></IconStyle></Style>
        <Folder><name>Measurements</name>

        """
        for o in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let p = o.location, p.isValid else { continue }
            let style: String
            switch SignalQuality.overallGrade(for: o) {
            case .excellent?: style = "excellent"
            case .good?: style = "good"
            case .fair?: style = "fair"
            case .poor?: style = "poor"
            default: style = "none"
            }
            var desc = "\(o.radio.displayName)"
            if let key = o.cellKey { desc += " · \(key)" }
            if let rsrp = o.rsrp { desc += " · RSRP \(Int(rsrp)) dBm" }
            out += "<Placemark><name>\(xml(o.radio.displayName))</name><TimeStamp><when>\(iso.string(from: o.timestamp))</when></TimeStamp>"
            out += "<styleUrl>#\(style)</styleUrl><description>\(xml(desc))</description>"
            out += "<Point><coordinates>\(p.longitude),\(p.latitude),0</coordinates></Point></Placemark>\n"
        }
        out += "</Folder><Folder><name>Estimated cell positions</name>\n"
        for a in aggregates {
            guard let p = a.estimatedLocation else { continue }
            let desc = "\(a.key) · \(a.observationCount) samples" + (a.bandLabel.map { " · \($0)" } ?? "")
            out += "<Placemark><name>\(xml(a.title(gnbIdBits: gnbIdBits)))</name><styleUrl>#tower</styleUrl>"
            out += "<description>\(xml(desc))</description><Point><coordinates>\(p.longitude),\(p.latitude),0</coordinates></Point></Placemark>\n"
        }
        out += "</Folder></Document></kml>\n"
        return out
    }

    static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
