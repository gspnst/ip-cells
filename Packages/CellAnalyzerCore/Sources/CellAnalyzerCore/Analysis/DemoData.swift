import Foundation

/// Generates a plausible synthetic drive (about 40 minutes, a dozen cells) so the app can be explored
/// in the Simulator or on a device without captures. All values are made up.
public enum DemoData {
    public static let note = "Demo data"

    private struct Site {
        let enb: Int
        let gnb: Int?
        let position: GeoPoint
        let earfcn: Int
        let pciBase: Int
    }

    public static func session(start: Date = Date().addingTimeInterval(-45 * 60),
                               origin: GeoPoint = GeoPoint(latitude: 52.5163, longitude: 13.3777),
                               mcc: Int = 262, mnc: Int = 1) -> [CellObservation] {
        var rng = SeededGenerator(seed: 42)
        let duration: TimeInterval = 40 * 60
        let heading = 95.0
        let routeLength = 14_000.0

        // Sites placed alternately left and right of the route.
        let sites: [Site] = (0..<6).map { i in
            let along = Geodesy.destination(from: origin, bearing: heading, distance: Double(i) * 2_600 + 300)
            let side = Geodesy.destination(from: along, bearing: heading + (i.isMultiple(of: 2) ? 90 : -90), distance: 450)
            return Site(enb: 100_200 + i * 37, gnb: i == 3 ? nil : 2_300_000 + i * 11, position: side,
                        earfcn: i.isMultiple(of: 3) ? 6300 : 1300, pciBase: 30 + i * 9)
        }

        func position(at t: TimeInterval) -> GeoPoint {
            let base = Geodesy.destination(from: origin, bearing: heading, distance: routeLength * t / duration)
            return GeoPoint(latitude: base.latitude, longitude: base.longitude, horizontalAccuracy: 5)
        }

        func rsrp(distance: Double, earfcn: Int) -> Double {
            let lowBandBonus = earfcn == 6300 ? 6.0 : 0
            let value = -62 - 33 * log10(max(distance, 50) / 100) + lowBandBonus + rng.gaussian() * 2
            return (value * 10).rounded() / 10
        }

        var result: [CellObservation] = []

        // iOS-level samples every 20 s: mostly 5G NSA, LTE in the gap without NR, a brief EDGE drop.
        var t: TimeInterval = 0
        while t <= duration {
            let minute = t / 60
            let radio: RadioTechnology
            if (24.5..<25.2).contains(minute) { radio = .edge }
            else if (17..<22).contains(minute) { radio = .lte }
            else { radio = .nrNSA }
            result.append(CellObservation(timestamp: start.addingTimeInterval(t), source: .system, radio: radio,
                                          simSlot: "SIM 1", location: position(at: t), notes: note))
            t += 20
        }

        // Field Test captures every 90 s: serving LTE anchor (+ NR leg when available).
        t = 30
        while t <= duration {
            let here = position(at: t)
            let serving = sites.min { Geodesy.distance($0.position, here) < Geodesy.distance($1.position, here) }!
            let distance = Geodesy.distance(serving.position, here)
            let bearingFromSite = Geodesy.bearing(from: serving.position, to: here)
            let sector = Int(bearingFromSite / 120) % 3 + 1
            let captureID = UUID()
            let lteRSRP = rsrp(distance: distance, earfcn: serving.earfcn)
            let sinr = max(-3, min(28, (lteRSRP + 118) * 0.55 + rng.gaussian() * 2))
            let minute = t / 60
            let timestamp = start.addingTimeInterval(t)

            result.append(CellObservation(
                timestamp: timestamp, source: .fieldTestScreenshot, radio: .lte, captureID: captureID, simSlot: "SIM 1",
                mcc: mcc, mnc: mnc, areaCode: 41_200 + (serving.enb > 100_300 ? 1 : 0),
                cellId: CellIdentityDecoder.composeECI(enb: serving.enb, localCell: sector),
                pci: serving.pciBase + sector - 1, channel: serving.earfcn, band: serving.earfcn == 6300 ? 20 : 3,
                bandwidthMHz: serving.earfcn == 6300 ? 10 : 20,
                rsrp: lteRSRP, rsrq: ((-8 - (lteRSRP < -100 ? 5 : 0) + rng.gaussian()) * 10).rounded() / 10,
                sinr: (sinr * 10).rounded() / 10, timingAdvance: Int(distance / Geodesy.lteTimingAdvanceStepMeters),
                location: here, notes: note))

            if let gnb = serving.gnb, !(17..<22).contains(minute), !(24.5..<25.2).contains(minute) {
                let nrRSRP = lteRSRP - 9 + rng.gaussian() * 2
                result.append(CellObservation(
                    timestamp: timestamp, source: .fieldTestScreenshot, radio: .nrNSA, captureID: captureID, simSlot: "SIM 1",
                    mcc: mcc, mnc: mnc, cellId: (gnb << 12) | sector, pci: 300 + serving.pciBase + sector,
                    channel: 636_666, band: 78, bandwidthMHz: 100,
                    rsrp: (nrRSRP * 10).rounded() / 10, rsrq: -11, sinr: ((sinr - 4) * 10).rounded() / 10,
                    location: here, notes: note))
            }
            t += 90
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }
}

/// Small deterministic PRNG (SplitMix64) so demo data is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Standard normal sample (Box–Muller).
    mutating func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &self), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &self)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
