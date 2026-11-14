import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of looking up a cell's registered position.
public struct TowerLocation: Codable, Hashable, Sendable {
    public enum Provider: String, Codable, Sendable {
        case openCellID
        case estimated
    }

    public var provider: Provider
    public var location: GeoPoint
    /// Approximate coverage radius reported by the database (metres).
    public var rangeMeters: Double?
    public var samples: Int?
    public var fetchedAt: Date

    public init(provider: Provider, location: GeoPoint, rangeMeters: Double? = nil, samples: Int? = nil, fetchedAt: Date = Date()) {
        self.provider = provider
        self.location = location
        self.rangeMeters = rangeMeters
        self.samples = samples
        self.fetchedAt = fetchedAt
    }
}

public enum TowerLookupOutcome: Codable, Hashable, Sendable {
    case found(TowerLocation)
    case notFound(Date)
}

public enum TowerLookupError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case insufficientIdentity
    case unsupportedRadio
    case service(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add an OpenCellID API key in Settings to look up registered tower positions."
        case .insufficientIdentity: return "Lookup needs MCC, MNC, area code (TAC/LAC) and cell ID."
        case .unsupportedRadio: return "This radio technology can't be looked up."
        case .service(let message): return "OpenCellID: \(message)"
        case .invalidResponse: return "Unexpected response from OpenCellID."
        }
    }
}

/// Request builder / response parser for the OpenCellID `cell/get` API
/// (https://wiki.opencellid.org/wiki/API). Networking is left to the caller.
public enum OpenCellID {
    public static let endpoint = URL(string: "https://opencellid.org/cell/get")!

    public static func request(apiKey: String, mcc: Int, mnc: Int, areaCode: Int, cellId: Int,
                               family: RadioFamily) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TowerLookupError.missingAPIKey }
        guard let radio = family.openCellIDRadio else { throw TowerLookupError.unsupportedRadio }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "mcc", value: String(mcc)),
            URLQueryItem(name: "mnc", value: String(mnc)),
            URLQueryItem(name: "lac", value: String(areaCode)),
            URLQueryItem(name: "cellid", value: String(cellId)),
            URLQueryItem(name: "radio", value: radio),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func request(apiKey: String, for aggregate: CellAggregate) throws -> URLRequest {
        guard let mcc = aggregate.mcc, let mnc = aggregate.mnc, let area = aggregate.areaCode,
              let cellId = aggregate.cellId else { throw TowerLookupError.insufficientIdentity }
        return try request(apiKey: apiKey, mcc: mcc, mnc: mnc, areaCode: area, cellId: cellId, family: aggregate.family)
    }

    struct Response: Decodable {
        var lat: Double?
        var lon: Double?
        var range: Double?
        var samples: Int?
        var error: String?
        var code: Int?
    }

    /// Parses a `cell/get` JSON body. "Cell not found" maps to `.notFound`; other errors throw.
    public static func parse(_ data: Data, now: Date = Date()) throws -> TowerLookupOutcome {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            if let text = String(data: data, encoding: .utf8), text.lowercased().contains("not found") {
                return .notFound(now)
            }
            throw TowerLookupError.invalidResponse
        }
        if let error = response.error {
            if error.lowercased().contains("not found") || response.code == 1 { return .notFound(now) }
            throw TowerLookupError.service(error)
        }
        guard let lat = response.lat, let lon = response.lon else { throw TowerLookupError.invalidResponse }
        let point = GeoPoint(latitude: lat, longitude: lon)
        guard point.isValid else { return .notFound(now) }
        return .found(TowerLocation(provider: .openCellID, location: point, rangeMeters: response.range,
                                    samples: response.samples, fetchedAt: now))
    }
}
