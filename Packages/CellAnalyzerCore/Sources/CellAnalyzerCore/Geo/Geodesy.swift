import Foundation

public enum Geodesy {
    public static let earthRadiusMeters = 6_371_008.8

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let φ1 = a.latitude.radians, φ2 = b.latitude.radians
        let dφ = (b.latitude - a.latitude).radians
        let dλ = (b.longitude - a.longitude).radians
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north (0…360).
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let φ1 = a.latitude.radians, φ2 = b.latitude.radians
        let dλ = (b.longitude - a.longitude).radians
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let θ = atan2(y, x).degrees
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// 16-point compass label for a bearing.
    public static func compassDirection(_ bearing: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let index = Int(((bearing.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 22.5).rounded()) % 16
        return names[index]
    }

    /// Point at `distance` metres along `bearing` from `origin`.
    public static func destination(from origin: GeoPoint, bearing: Double, distance: Double) -> GeoPoint {
        let δ = distance / earthRadiusMeters
        let θ = bearing.radians
        let φ1 = origin.latitude.radians, λ1 = origin.longitude.radians
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return GeoPoint(latitude: φ2.degrees, longitude: ((λ2.degrees + 540).truncatingRemainder(dividingBy: 360)) - 180)
    }

    /// Distance represented by one LTE timing-advance step (16·Ts·c/2 ≈ 78.12 m).
    public static let lteTimingAdvanceStepMeters = 78.12

    /// Approximate distance to the cell from a timing-advance value.
    /// - Parameter subcarrierSpacingKHz: NR numerology (15, 30, 60, 120 kHz); LTE is 15.
    public static func distance(timingAdvance ta: Int, family: RadioFamily, subcarrierSpacingKHz: Int = 30) -> ClosedRange<Double>? {
        guard ta >= 0 else { return nil }
        let step: Double
        switch family {
        case .lte: step = lteTimingAdvanceStepMeters
        case .nr: step = lteTimingAdvanceStepMeters * 15 / Double(max(subcarrierSpacingKHz, 15))
        case .gsm: step = 553.85 // GSM TA bit period ≈ 3.69 µs → 553 m
        default: return nil
        }
        let d = Double(ta) * step
        return d...(d + step)
    }

    /// Estimates a transmitter position as the power-weighted centroid of measurement points.
    /// Stronger samples (higher RSRP) pull the estimate harder; this is the classic crowd-sourcing
    /// approach used by open cell databases and is typically accurate to a few hundred metres.
    public static func weightedCentroid(_ samples: [(point: GeoPoint, dBm: Double?)]) -> GeoPoint? {
        let valid = samples.filter { $0.point.isValid }
        guard !valid.isEmpty else { return nil }
        // Normalize so the strongest sample has weight 1 to avoid underflow.
        let strongest = valid.compactMap(\.dBm).max() ?? 0
        var sumW = 0.0, x = 0.0, y = 0.0, z = 0.0
        for s in valid {
            let w = s.dBm.map { pow(10, ($0 - strongest) / 10) } ?? 0.01
            let φ = s.point.latitude.radians, λ = s.point.longitude.radians
            x += w * cos(φ) * cos(λ)
            y += w * cos(φ) * sin(λ)
            z += w * sin(φ)
            sumW += w
        }
        guard sumW > 0 else { return nil }
        x /= sumW; y /= sumW; z /= sumW
        let lon = atan2(y, x), hyp = sqrt(x * x + y * y), lat = atan2(z, hyp)
        return GeoPoint(latitude: lat.degrees, longitude: lon.degrees)
    }

    /// Free-space path-loss distance estimate (metres) – an *upper bound* sanity check, since real
    /// propagation loses far more than free space.
    public static func freeSpaceDistance(rsrpDBm: Double, frequencyMHz: Double, eirpPerREdBm: Double = 18) -> Double {
        let pathLoss = eirpPerREdBm - rsrpDBm
        // FSPL(dB) = 20log10(d_km) + 20log10(f_MHz) + 32.44
        let exponent = (pathLoss - 20 * log10(frequencyMHz) - 32.44) / 20
        return pow(10, exponent) * 1000
    }
}

extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
