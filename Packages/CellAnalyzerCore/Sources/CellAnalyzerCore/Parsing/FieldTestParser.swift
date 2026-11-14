import Foundation

/// Fields that can be extracted from iPhone Field Test Mode (`*3001#12345#*`) screens.
public enum FieldTestField: String, CaseIterable, Sendable {
    case rsrp, rsrq, sinr, rssi
    case pci, channel, ulChannel, band, bandwidth
    case tac, lac, cellId, mcc, mnc, mncDigits, plmn
    case timingAdvance, connectionType, rat

    var isSignal: Bool { [.rsrp, .rsrq, .sinr, .rssi].contains(self) }
}

/// Which radio a value belongs to, inferred from section headers and label prefixes.
public enum FieldTestContext: String, Sendable {
    case lte, nr, umts, gsm, unknown

    var family: RadioFamily? {
        switch self {
        case .lte: return .lte
        case .nr: return .nr
        case .umts: return .umts
        case .gsm: return .gsm
        case .unknown: return nil
        }
    }
}

/// A label/value pair the parser understood – shown to the user for verification.
public struct RecognizedPair: Sendable, Hashable {
    public var label: String
    public var value: String
    public var field: FieldTestField
    public var context: FieldTestContext
    public var isNeighbor: Bool
}

/// Serving-cell values parsed for one radio.
public struct ParsedServingCell: Sendable, Hashable {
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
    public var rsrp: Double?
    public var rsrq: Double?
    public var sinr: Double?
    public var rssi: Double?
    public var timingAdvance: Int?
    /// Values whose sign was flipped because OCR dropped a minus sign.
    public var signCorrected: [FieldTestField] = []

    public var populatedFieldCount: Int {
        let values: [Any?] = [mcc, mnc, areaCode, cellId, pci, channel, band, bandwidthMHz,
                              rsrp, rsrq, sinr, rssi, timingAdvance]
        return values.compactMap { $0 }.count
    }

    public func observation(timestamp: Date, location: GeoPoint?, captureID: UUID?,
                            source: ObservationSource = .fieldTestScreenshot) -> CellObservation {
        CellObservation(timestamp: timestamp, source: source, radio: radio, captureID: captureID,
                        mcc: mcc, mnc: mnc, mncDigits: mncDigits, areaCode: areaCode, cellId: cellId,
                        pci: pci, channel: channel, band: band, bandwidthMHz: bandwidthMHz,
                        rsrp: rsrp, rsrq: rsrq, sinr: sinr, rssi: rssi, timingAdvance: timingAdvance,
                        location: location)
    }
}

/// Result of parsing one screenshot (or one block of pasted text).
public struct FieldTestCapture: Sendable {
    public var cells: [ParsedServingCell]
    public var pairs: [RecognizedPair]
    public var unparsedLines: [String]

    public var isEmpty: Bool { cells.allSatisfy { $0.populatedFieldCount == 0 } }

    public func observations(timestamp: Date, location: GeoPoint?, captureID: UUID = UUID()) -> [CellObservation] {
        cells.filter { $0.populatedFieldCount > 0 }
            .map { $0.observation(timestamp: timestamp, location: location, captureID: captureID) }
    }
}

/// Parses text recognized from Field Test Mode screens into serving-cell measurements.
///
/// Labels differ between iOS versions and modem vendors (Qualcomm shows `rsrp0`, `phy_cell_id`,
/// `dl_freq`, `freq_band_ind`…; Intel modems show "Physical cell ID", "Downlink EARFCN"…), so the
/// parser normalizes labels and matches them against an alias table with OCR-typo tolerance.
public enum FieldTestParser {

    // MARK: Public API

    public static func parse(text: String) -> FieldTestCapture {
        parse(lines: text.components(separatedBy: .newlines))
    }

    public static func parse(lines rawLines: [String]) -> FieldTestCapture {
        var section: FieldTestContext = .unknown
        var inNeighborSection = false
        var pendingLabel: String?
        var entries: [Entry] = []
        var pairs: [RecognizedPair] = []
        var unparsed: [String] = []
        var ratHint: FieldTestContext = .unknown

        func consume(label: String, value: String, raw: String) {
            guard let match = matchLabel(label) else {
                unparsed.append(raw)
                return
            }
            let context = match.contextHint != .unknown ? match.contextHint : section
            pairs.append(RecognizedPair(label: label, value: value, field: match.field,
                                        context: context, isNeighbor: inNeighborSection))
            guard !inNeighborSection else { return }
            if match.field == .rat, let hint = contextKeyword(in: value.lowercased()) {
                ratHint = hint
                return
            }
            entries.append(Entry(field: match.field, value: value, context: context,
                                 priority: match.priority, antenna: match.antenna))
        }

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            switch split(line) {
            case let .pair(label, value):
                pendingLabel = nil
                if matchLabel(label) == nil, let header = headerContext(line) {
                    // e.g. "NR 5G" – the trailing "5G" looked like a value.
                    if let context = header.context { section = context }
                    inNeighborSection = header.neighbor
                } else {
                    consume(label: label, value: value, raw: line)
                }
            case let .valueOnly(value):
                if let label = pendingLabel {
                    consume(label: label, value: value, raw: label + " " + value)
                    pendingLabel = nil
                } else {
                    unparsed.append(line)
                }
            case let .labelOnly(label):
                if matchLabel(label) != nil {
                    pendingLabel = label
                } else if let header = headerContext(label) {
                    pendingLabel = nil
                    if let context = header.context { section = context }
                    inNeighborSection = header.neighbor
                } else {
                    pendingLabel = nil
                    unparsed.append(line)
                }
            }
        }

        let cells = buildCells(entries: entries, ratHint: ratHint)
        return FieldTestCapture(cells: cells, pairs: pairs, unparsedLines: unparsed)
    }

    // MARK: Line splitting

    enum SplitResult: Equatable {
        case pair(String, String)
        case labelOnly(String)
        case valueOnly(String)
    }

    static func split(_ line: String) -> SplitResult {
        for separator in ["\t", ":", "="] {
            if let range = line.range(of: separator) {
                let label = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\t:=")))
                if label.isEmpty { return value.isEmpty ? .labelOnly(line) : .valueOnly(value) }
                if value.isEmpty { return .labelOnly(label) }
                return .pair(label, value)
            }
        }
        let tokens = line.split(whereSeparator: { $0 == " " }).map(String.init)
        // Find the first token from which every remaining token is value-like.
        var valueStart = tokens.count
        for index in stride(from: tokens.count - 1, through: 0, by: -1) {
            if isValueLike(tokens[index]) { valueStart = index } else { break }
        }
        // The value must start with something numeric (units alone aren't values).
        while valueStart < tokens.count, !startsNumeric(tokens[valueStart]) { valueStart += 1 }
        if valueStart == tokens.count {
            // Short textual values such as "connection_type SA" or "rat LTE".
            if tokens.count >= 2, let last = tokens.last, textualValues.contains(last.lowercased()),
               matchLabel(tokens.dropLast().joined(separator: " ")) != nil {
                return .pair(tokens.dropLast().joined(separator: " "), last)
            }
            return .labelOnly(line)
        }
        if valueStart == 0 { return .valueOnly(line) }
        let label = tokens[..<valueStart].joined(separator: " ")
        let value = tokens[valueStart...].joined(separator: " ")
        // "rsrp0" style labels end in a digit but are not values.
        return .pair(label, value)
    }

    private static let textualValues: Set<String> = [
        "sa", "nsa", "lte", "nr", "5g", "4g", "3g", "2g", "wcdma", "umts", "gsm", "endc", "nr5g", "hspa",
        "edge", "gprs", "fdd", "tdd", "idle", "connected", "yes", "no", "on", "off", "true", "false",
    ]

    private static let unitWords: Set<String> = ["dbm", "db", "mhz", "khz", "ghz", "rb", "rbs", "ms", "m", "sa", "nsa", "(sa)", "(nsa)"]

    private static func isValueLike(_ token: String) -> Bool {
        let t = token.lowercased()
        if unitWords.contains(t) { return true }
        return startsNumeric(token)
    }

    private static func startsNumeric(_ token: String) -> Bool {
        let cleaned = normalizeNumericText(token)
        guard let first = cleaned.first else { return false }
        if first.isNumber { return true }
        if first == "-" || first == "+", cleaned.dropFirst().first?.isNumber == true { return true }
        if cleaned.lowercased().hasPrefix("0x") { return true }
        // Band values such as "n78" or "B66".
        let lower = cleaned.lowercased()
        if (lower.hasPrefix("n") || lower.hasPrefix("b")), lower.count <= 4, lower.dropFirst().allSatisfy(\.isNumber), lower.count > 1 { return true }
        return false
    }

    // MARK: Label matching

    struct LabelMatch {
        var field: FieldTestField
        var contextHint: FieldTestContext
        /// 2 = explicitly "serving/measured", 1 = plain, 0 = per-antenna.
        var priority: Int
        var antenna: Int?
    }

    static let aliases: [String: FieldTestField] = {
        var map: [String: FieldTestField] = [:]
        func add(_ field: FieldTestField, _ labels: [String]) { for l in labels { map[l] = field } }
        add(.rsrp, ["rsrp", "rsrp avg", "avg rsrp", "reference signal received power", "rscp", "rsrp dbm"])
        add(.rsrq, ["rsrq", "reference signal received quality", "ecio", "ec io", "ec no", "ecno"])
        add(.sinr, ["sinr", "snr", "rs sinr", "rssnr", "rs snr", "sinr avg", "signal to noise ratio", "cinr"])
        add(.rssi, ["rssi", "rx power", "received signal strength", "rssi dbm", "rx level", "rxlev dbm"])
        add(.pci, ["pci", "phy cell id", "physical cell id", "phys cell id", "physical cell identity",
                   "phy cellid", "pcid", "physical cell", "psc", "primary scrambling code", "bsic", "phy id"])
        add(.channel, ["earfcn", "dl earfcn", "dl freq", "downlink frequency", "downlink earfcn", "dl frequency",
                       "arfcn", "nrarfcn", "nr arfcn", "ssb arfcn", "dl arfcn", "uarfcn", "dl uarfcn",
                       "channel", "dl channel", "absolute rf channel number", "ssb freq", "earfcn dl",
                       "freq", "frequency", "downlink channel", "serving earfcn", "dl arfcn ssb", "nr freq",
                       "absolute frequency ssb", "arfcn dl"])
        add(.ulChannel, ["ul freq", "uplink frequency", "ul earfcn", "uplink earfcn", "ul arfcn", "ul uarfcn",
                         "ul channel", "uplink channel", "earfcn ul"])
        add(.band, ["band", "freq band ind", "freq band indicator", "frequency band indicator", "band info",
                    "band ind", "band indicator", "lte band", "operating band", "band number", "freq band",
                    "frequency band", "band class", "active band"])
        add(.bandwidth, ["dl bandwidth", "dl bw", "bandwidth", "downlink bandwidth", "bw", "carrier bandwidth",
                         "channel bandwidth", "dl bandwidth mhz", "bandwidth mhz"])
        add(.tac, ["tac", "tracking area code", "tracking area", "5gs tac", "tac code"])
        add(.lac, ["lac", "location area code", "location area"])
        add(.cellId, ["cell identity", "cell id", "cellid", "cid", "eci", "nci", "global cell id", "cell identifier",
                      "e utran cell identifier", "eutran cell identifier", "nr cell identity", "nr cell identifier",
                      "ci", "eutran cell id", "serving cell id", "cell identity eci", "gci", "ecgi cell id", "utran cell id"])
        add(.mcc, ["mcc", "mobile country code"])
        add(.mnc, ["mnc", "mobile network code"])
        add(.mncDigits, ["num mnc digits", "mnc digits", "mnc length", "number of mnc digits"])
        add(.plmn, ["plmn", "plmn id", "serving plmn", "registered plmn", "rplmn", "selected plmn", "plmn identity"])
        add(.timingAdvance, ["ta", "timing advance", "timing adv", "ta value"])
        add(.connectionType, ["connection type", "nr connection type", "nr mode", "nr connection mode", "endc", "en dc", "nr status"])
        add(.rat, ["rat", "radio access technology", "serving rat", "system mode", "technology", "access technology", "radio technology"])
        return map
    }()

    private static let squashedAliases: [String: FieldTestField] = {
        var map: [String: FieldTestField] = [:]
        for (label, field) in aliases { map[label.replacingOccurrences(of: " ", with: "")] = field }
        return map
    }()

    /// Lower-cases, strips punctuation/units and collapses whitespace.
    static func normalizeLabel(_ label: String) -> String {
        var s = label.lowercased()
        for ch in ["_", "-", ".", "/", "(", ")", "[", "]", ":", "#", "|", ","] {
            s = s.replacingOccurrences(of: ch, with: " ")
        }
        var words = s.split(separator: " ").map(String.init)
        words.removeAll { ["dbm", "db", "mhz", "khz", "in", "of", "the"].contains($0) }
        return words.joined(separator: " ")
    }

    static func matchLabel(_ rawLabel: String) -> LabelMatch? {
        var words = normalizeLabel(rawLabel).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }

        var context: FieldTestContext = .unknown
        var priority = 1
        var antenna: Int?

        // Context prefixes ("nr_rsrp", "ssb_rsrp", "lte_rsrp", "5g …").
        let nrPrefixes: Set<String> = ["nr", "5g", "nr5g", "ssb", "ss", "5gnr", "scg"]
        let ltePrefixes: Set<String> = ["lte", "4g", "eutra", "eutran"]
        while let first = words.first, words.count > 1 {
            if nrPrefixes.contains(first) {
                context = .nr
                // "nr arfcn"/"nr band"/"nr cell identity" are aliases themselves; keep the prefix for lookup.
                if aliases[words.joined(separator: " ")] != nil { break }
                words.removeFirst()
            } else if ltePrefixes.contains(first) {
                context = .lte
                if aliases[words.joined(separator: " ")] != nil { break }
                words.removeFirst()
            } else if ["wcdma", "umts", "3g"].contains(first) {
                context = .umts; words.removeFirst()
            } else if ["gsm", "2g"].contains(first) {
                context = .gsm; words.removeFirst()
            } else if ["serving", "measured", "srv", "meas", "current", "pcell"].contains(first) {
                priority = 2
                if aliases[words.joined(separator: " ")] != nil { break }
                words.removeFirst()
            } else {
                break
            }
        }

        // Antenna suffixes: "rsrp0", "rsrp 1", "rsrp ant 0", "rsrp_ant1", "rsrp rx1".
        let antennaWords: Set<String> = ["ant", "rx", "antenna", "port", "branch"]
        if words.count >= 2, let last = words.last, let index = Int(last), (0...7).contains(index) {
            words.removeLast()
            if let ant = words.last, antennaWords.contains(ant), words.count >= 2 { words.removeLast() }
            antenna = index
        } else if words.count >= 2, let last = words.last, let digit = last.last?.wholeNumberValue,
                  antennaWords.contains(String(last.dropLast())) {
            words.removeLast()
            antenna = digit
        } else if let last = words.last, last.count >= 4, let digit = last.last?.wholeNumberValue {
            var base = String(last.dropLast())
            for suffix in ["ant", "rx"] where base.hasSuffix(suffix) && base.count > suffix.count {
                base.removeLast(suffix.count)
            }
            if ["rsrp", "rsrq", "rssi", "sinr", "snr"].contains(base) {
                words[words.count - 1] = base
                antenna = digit
            }
        }
        if antenna != nil { priority = 0 }

        let key = words.joined(separator: " ")
        if key.hasPrefix("nr ") || key == "nci" || key.hasPrefix("ssb ") { context = .nr }
        if let field = aliases[key] ?? squashedAliases[key.replacingOccurrences(of: " ", with: "")] {
            if antenna != nil && !field.isSignal { return nil }
            return LabelMatch(field: field, contextHint: context, priority: priority, antenna: antenna)
        }
        // OCR typo tolerance: edit distance 1 for longer labels, only when unambiguous.
        let squashed = key.replacingOccurrences(of: " ", with: "")
        guard squashed.count >= 6 else { return nil }
        let candidates = Set(squashedAliases.filter { $0.key.count >= 6 && levenshtein($0.key, squashed) <= 1 }.map(\.value))
        guard candidates.count == 1, let field = candidates.first else { return nil }
        return LabelMatch(field: field, contextHint: context, priority: priority, antenna: antenna)
    }

    /// Detects section headers like "LTE", "5G NR", "Serving Cell Info", "Neighbor Cell Meas".
    static func headerContext(_ label: String) -> (context: FieldTestContext?, neighbor: Bool)? {
        let lower = label.lowercased()
        let neighbor = ["neighbor", "neighbour", "ncell", "nbr", "intra freq", "inter freq", "irat"].contains { lower.contains($0) }
        let context = contextKeyword(in: lower)
        let isHeaderish = context != nil || neighbor || lower.contains("serving") || lower.contains("cell info")
            || lower.contains("cell meas") || lower.contains("dashboard")
        guard isHeaderish else { return nil }
        return (context, neighbor)
    }

    static func contextKeyword(in lower: String) -> FieldTestContext? {
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !words.isDisjoint(with: ["nr", "5g", "5gnr", "nr5g", "nrnsa", "nrsa", "endc", "sa", "nsa"]) { return .nr }
        if !words.isDisjoint(with: ["lte", "4g", "eutra", "eutran"]) { return .lte }
        if !words.isDisjoint(with: ["umts", "wcdma", "3g", "hspa", "utra"]) { return .umts }
        if !words.isDisjoint(with: ["gsm", "2g", "edge", "gprs"]) { return .gsm }
        return nil
    }

    // MARK: Value parsing

    /// Replaces typographic minus signs and common OCR confusions inside numeric tokens.
    static func normalizeNumericText(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespaces)
        for dash in ["\u{2212}", "\u{2013}", "\u{2014}", "\u{2012}", "\u{FE63}", "\u{FF0D}", "~"] {
            s = s.replacingOccurrences(of: dash, with: "-")
        }
        // Only fix letters inside tokens that are otherwise numeric (e.g. "-1O5 dBm" → "-105 dBm").
        let tokens = s.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let digitCount = token.filter(\.isNumber).count
            let confusable = token.filter { "OoIl|".contains($0) }.count
            let punctuation = token.filter { "-+.,".contains($0) }.count
            guard digitCount > 0, confusable > 0, digitCount + confusable + punctuation == token.count else {
                return String(token)
            }
            return String(token.map { ch -> Character in
                switch ch {
                case "O", "o": return "0"
                case "I", "l", "|": return "1"
                default: return ch
                }
            })
        }
        return tokens.joined(separator: " ")
    }

    /// First decimal number in the text (handles "-95 dBm", "−95", "B66", "n78", "12,5").
    static func number(in text: String) -> Double? {
        let s = normalizeNumericText(text).replacingOccurrences(of: ",", with: ".")
        var result = ""
        var started = false
        var seenDot = false
        for ch in s {
            if ch.isNumber && ch.isASCII {
                result.append(ch); started = true
            } else if ch == "-" && !started {
                result = "-"
            } else if ch == "." && started && !seenDot {
                result.append(ch); seenDot = true
            } else if started {
                break
            } else if result == "-" && ch != " " {
                result = ""
            }
        }
        if result.hasSuffix(".") { result.removeLast() }
        return Double(result)
    }

    static func integer(in text: String, allowHex: Bool = false) -> Int? {
        let trimmed = normalizeNumericText(text)
        if allowHex {
            let lower = trimmed.lowercased()
            if lower.hasPrefix("0x") {
                return Int(lower.dropFirst(2).prefix { $0.isHexDigit }, radix: 16)
            }
            let token = lower.split(separator: " ").first.map(String.init) ?? lower
            if token.count >= 4, token.allSatisfy(\.isHexDigit), token.contains(where: { $0.isLetter }) {
                return Int(token, radix: 16)
            }
        }
        guard let n = number(in: trimmed), n.rounded() == n, abs(n) < 1e15 else { return nil }
        return Int(n)
    }

    // MARK: Aggregation

    struct Entry {
        var field: FieldTestField
        var value: String
        var context: FieldTestContext
        var priority: Int
        var antenna: Int?
    }

    private static func buildCells(entries: [Entry], ratHint: FieldTestContext) -> [ParsedServingCell] {
        var known = Set(entries.map(\.context).filter { $0 != .unknown })
        let defaultContext: FieldTestContext
        if ratHint != .unknown {
            defaultContext = ratHint
        } else if known.count == 1, let only = known.first {
            defaultContext = only
        } else if known.contains(.lte) {
            defaultContext = .lte
        } else if let first = known.sorted(by: { $0.rawValue < $1.rawValue }).first {
            defaultContext = first
        } else {
            defaultContext = .lte
        }
        let resolved = entries.map { e -> Entry in
            var e = e
            if e.context == .unknown { e.context = defaultContext }
            return e
        }
        known = Set(resolved.map(\.context))

        let connectionType = resolved.first { $0.field == .connectionType }?.value.lowercased()

        var cells: [ParsedServingCell] = []
        for context in [FieldTestContext.lte, .nr, .umts, .gsm] where known.contains(context) {
            let group = resolved.filter { $0.context == context }
            guard let family = context.family else { continue }
            let radio: RadioTechnology
            switch context {
            case .nr:
                if let connectionType, connectionType.contains("nsa") || connectionType.contains("endc") || connectionType.contains("en dc") {
                    radio = .nrNSA
                } else if let connectionType, connectionType.split(whereSeparator: { !$0.isLetter }).contains("sa") {
                    radio = .nrSA
                } else {
                    radio = known.contains(.lte) ? .nrNSA : .nrSA
                }
            case .lte: radio = .lte
            case .umts: radio = .umts
            case .gsm: radio = .gsm
            case .unknown: continue
            }
            var cell = ParsedServingCell(radio: radio)
            fill(&cell, from: group, family: family)
            if cell.populatedFieldCount > 0 { cells.append(cell) }
        }
        // Share PLMN between legs of one capture (NSA screens often show it once).
        if let withPLMN = cells.first(where: { $0.mcc != nil && $0.mnc != nil }) {
            for i in cells.indices where cells[i].mcc == nil {
                cells[i].mcc = withPLMN.mcc
                cells[i].mnc = withPLMN.mnc
                cells[i].mncDigits = withPLMN.mncDigits
            }
        }
        return cells
    }

    private static func fill(_ cell: inout ParsedServingCell, from entries: [Entry], family: RadioFamily) {
        func best(_ field: FieldTestField) -> [Entry] {
            let matching = entries.filter { $0.field == field }
            guard let top = matching.map(\.priority).max() else { return [] }
            return matching.filter { $0.priority == top }
        }

        func signal(_ field: FieldTestField, _ metric: SignalMetric) -> Double? {
            let values = best(field).compactMap { e -> (Double, Bool)? in
                guard var v = number(in: e.value) else { return nil }
                var corrected = false
                // OCR frequently drops the minus sign; RSRP/RSSI are always negative, RSRQ almost always.
                if (metric == .rsrp || metric == .rssi) && v > 0 { v = -v; corrected = true }
                if metric == .rsrq && v > 3 { v = -v; corrected = true }
                // Some basebands report tenths or sixteenths of a dB.
                if !metric.plausibleRange.contains(v), metric.plausibleRange.contains(v / 10) { v /= 10 }
                return metric.plausibleRange.contains(v) ? (v, corrected) : nil
            }
            guard let best = values.max(by: { $0.0 < $1.0 }) else { return nil }
            if best.1, let f = FieldTestField(rawValue: metric.rawValue) { cell.signCorrected.append(f) }
            return best.0
        }

        func int(_ field: FieldTestField, range: ClosedRange<Int>, hex: Bool = false) -> Int? {
            for e in best(field) {
                if let v = integer(in: e.value, allowHex: hex), range.contains(v) { return v }
            }
            return nil
        }

        cell.rsrp = signal(.rsrp, .rsrp)
        cell.rsrq = signal(.rsrq, .rsrq)
        cell.sinr = signal(.sinr, .sinr)
        cell.rssi = signal(.rssi, .rssi)

        cell.pci = int(.pci, range: 0...(family == .nr ? 1007 : (family == .umts ? 511 : 503)))
        let channelRange: ClosedRange<Int>
        switch family {
        case .nr: channelRange = 0...3_279_165
        case .umts: channelRange = 0...16_383
        case .gsm: channelRange = 0...1023
        default: channelRange = 0...262_143
        }
        // Values with a frequency unit are not channel numbers.
        cell.channel = best(.channel)
            .filter { e in !["mhz", "ghz"].contains { e.value.lowercased().contains($0) } }
            .lazy.compactMap { integer(in: $0.value) }.first { channelRange.contains($0) }
        if cell.channel == nil, family == .lte, let ul = int(.ulChannel, range: 18_000...262_143),
           let info = Spectrum.lte(earfcn: ul) {
            cell.channel = info.channel
        }
        cell.band = best(.band).lazy.compactMap { number(in: $0.value) }.map { Int($0) }.first { (1...512).contains($0) }
        cell.bandwidthMHz = bandwidth(best(.bandwidth).first?.value, family: family)

        let areaMax = family == .nr ? 0xFFFFFF : 0xFFFF
        cell.areaCode = int(.tac, range: 0...0xFFFFFF, hex: true) ?? int(.lac, range: 0...areaMax, hex: true)
        let cellMax: Int
        switch family {
        case .nr: cellMax = CellIdentityDecoder.nrCellIdMax
        case .gsm: cellMax = 0xFFFF
        default: cellMax = CellIdentityDecoder.lteCellIdMax
        }
        cell.cellId = int(.cellId, range: 0...cellMax, hex: true)
        cell.timingAdvance = int(.timingAdvance, range: 0...3846)

        cell.mcc = int(.mcc, range: 1...999)
        if let mncEntry = best(.mnc).first, let mnc = integer(in: mncEntry.value), (0...999).contains(mnc) {
            cell.mnc = mnc
            let digits = normalizeNumericText(mncEntry.value).prefix { $0.isNumber }.count
            cell.mncDigits = (2...3).contains(digits) ? digits : nil
        }
        if let d = int(.mncDigits, range: 2...3) { cell.mncDigits = d }
        if cell.mcc == nil || cell.mnc == nil, let raw = best(.plmn).first?.value, let plmn = PLMN(string: normalizeNumericText(raw)) {
            cell.mcc = cell.mcc ?? plmn.mcc
            cell.mnc = cell.mnc ?? plmn.mnc
            cell.mncDigits = cell.mncDigits ?? plmn.mncDigits
        }
    }

    /// Interprets bandwidth values that may be MHz, resource blocks or a modem enum.
    static func bandwidth(_ text: String?, family: RadioFamily) -> Double? {
        guard let text, let v = number(in: text) else { return nil }
        let lower = text.lowercased()
        if lower.contains("mhz") { return v > 0 && v <= 400 ? v : nil }
        if lower.contains("rb") { return resourceBlocksToMHz(Int(v)) }
        if family == .lte {
            if [1.4, 3, 5, 10, 15, 20].contains(v) { return v }
            if let mhz = resourceBlocksToMHz(Int(v)), v.rounded() == v { return mhz }
            // Qualcomm enum: 0=1.4, 1=3, 2=5, 3=10, 4=15, 5=20 MHz (only unambiguous values).
            switch v {
            case 0: return 1.4
            case 1: return 3
            case 2: return 5
            case 4: return 15
            default: return nil
            }
        }
        let nrWidths: Set<Double> = [5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100, 200, 400]
        return nrWidths.contains(v) ? v : nil
    }

    static func resourceBlocksToMHz(_ rb: Int) -> Double? {
        [6: 1.4, 15: 3, 25: 5, 50: 10, 75: 15, 100: 20][rb]
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
