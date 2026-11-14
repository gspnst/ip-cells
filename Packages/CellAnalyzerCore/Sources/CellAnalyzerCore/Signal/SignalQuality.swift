import Foundation

public enum SignalGrade: Int, Codable, CaseIterable, Sendable, Comparable {
    case noSignal = 0, poor, fair, good, excellent

    public var label: String {
        switch self {
        case .excellent: return "Excellent"
        case .good: return "Good"
        case .fair: return "Fair"
        case .poor: return "Poor"
        case .noSignal: return "Very poor"
        }
    }

    /// Number of bars (0…4) to render.
    public var bars: Int { rawValue }

    public static func < (lhs: SignalGrade, rhs: SignalGrade) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SignalMetric: String, CaseIterable, Sendable {
    case rsrp, rsrq, sinr, rssi

    public var unit: String {
        switch self {
        case .rsrp, .rssi: return "dBm"
        case .rsrq, .sinr: return "dB"
        }
    }

    public var displayName: String {
        switch self {
        case .rsrp: return "RSRP"
        case .rsrq: return "RSRQ"
        case .sinr: return "SINR"
        case .rssi: return "RSSI"
        }
    }

    public var explanation: String {
        switch self {
        case .rsrp: return "Reference Signal Received Power – how strong the cell is. Higher (closer to 0) is better."
        case .rsrq: return "Reference Signal Received Quality – strength relative to total received power incl. interference and load."
        case .sinr: return "Signal to Interference & Noise Ratio – the main driver of achievable throughput."
        case .rssi: return "Received Signal Strength Indicator – total wideband power incl. noise and neighbours."
        }
    }

    /// Plausible range used to reject OCR garbage.
    public var plausibleRange: ClosedRange<Double> {
        switch self {
        case .rsrp: return -156 ... -31
        case .rsrq: return -43 ... 20
        case .sinr: return -23 ... 40
        case .rssi: return -125 ... -10
        }
    }

    /// Range used to normalize values into a 0…1 gauge.
    public var gaugeRange: ClosedRange<Double> {
        switch self {
        case .rsrp: return -140 ... -60
        case .rsrq: return -20 ... -3
        case .sinr: return -10 ... 30
        case .rssi: return -110 ... -50
        }
    }
}

public enum SignalQuality {
    /// Grades a metric using widely used field-engineering thresholds (LTE/NR).
    public static func grade(_ metric: SignalMetric, _ value: Double, family: RadioFamily = .lte) -> SignalGrade {
        let t: (Double, Double, Double, Double) // excellent, good, fair, poor lower bounds
        switch (metric, family) {
        case (.rsrp, _): t = (-80, -90, -100, -110)
        case (.rsrq, _): t = (-10, -15, -20, -25)
        case (.sinr, _): t = (20, 13, 0, -5)
        case (.rssi, .gsm): t = (-70, -85, -100, -110)
        case (.rssi, .umts): t = (-75, -85, -95, -105) // RSCP-like scale
        case (.rssi, _): t = (-65, -75, -85, -95)
        }
        if value >= t.0 { return .excellent }
        if value >= t.1 { return .good }
        if value >= t.2 { return .fair }
        if value >= t.3 { return .poor }
        return .noSignal
    }

    /// 0…1 position of a value within the metric's gauge range.
    public static func normalized(_ metric: SignalMetric, _ value: Double) -> Double {
        let r = metric.gaugeRange
        return min(max((value - r.lowerBound) / (r.upperBound - r.lowerBound), 0), 1)
    }

    /// Composite 0…100 score weighting RSRP (coverage), SINR (throughput) and RSRQ (load).
    /// Returns nil when no metric is available.
    public static func score(rsrp: Double?, rsrq: Double?, sinr: Double?, rssi: Double? = nil) -> Int? {
        var total = 0.0, weight = 0.0
        if let rsrp { total += 0.5 * normalized(.rsrp, rsrp); weight += 0.5 }
        if let sinr { total += 0.3 * normalized(.sinr, sinr); weight += 0.3 }
        if let rsrq { total += 0.2 * normalized(.rsrq, rsrq); weight += 0.2 }
        if weight == 0, let rssi { total = normalized(.rssi, rssi); weight = 1 }
        guard weight > 0 else { return nil }
        return Int((100 * total / weight).rounded())
    }

    /// Overall grade for an observation (worst of RSRP and SINR, which dominate user experience).
    public static func overallGrade(for o: CellObservation) -> SignalGrade? {
        let family = o.radio.family
        var grades: [SignalGrade] = []
        if let rsrp = o.rsrp { grades.append(grade(.rsrp, rsrp, family: family)) }
        if let sinr = o.sinr { grades.append(grade(.sinr, sinr, family: family)) }
        if grades.isEmpty, let rsrq = o.rsrq { grades.append(grade(.rsrq, rsrq, family: family)) }
        if grades.isEmpty, let rssi = o.rssi { grades.append(grade(.rssi, rssi, family: family)) }
        return grades.min()
    }

    /// Rough downlink spectral-efficiency estimate from SINR using an attenuated Shannon bound
    /// (0.75 × log2(1+SINR), capped at 256-QAM ≈ 7.4 b/s/Hz). Useful for relative comparisons only.
    public static func spectralEfficiency(sinr: Double) -> Double {
        let linear = pow(10, sinr / 10)
        return min(0.75 * log2(1 + linear), 7.4)
    }

    /// Very rough single-layer peak throughput (Mbit/s) for a given bandwidth and SINR.
    public static func estimatedThroughputMbps(sinr: Double, bandwidthMHz: Double, mimoLayers: Int = 2) -> Double {
        // ~10 % overhead for reference signals and control channels.
        spectralEfficiency(sinr: sinr) * bandwidthMHz * 0.9 * Double(mimoLayers)
    }

    /// Converts a dBm value to milliwatts.
    public static func milliwatts(dBm: Double) -> Double { pow(10, dBm / 10) }
}
