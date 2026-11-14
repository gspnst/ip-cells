import Foundation
import Observation
import CellAnalyzerCore

/// Fetches registered cell positions from OpenCellID and caches them in the store.
/// Only the cell identity (MCC, MNC, area code, cell ID) and your API key are sent.
@MainActor
@Observable
final class TowerLookupService {
    private(set) var inFlight: Set<CellKey> = []
    private(set) var errors: [CellKey: String] = [:]

    @ObservationIgnored private let store: ObservationStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let session: URLSession

    init(store: ObservationStore, settings: AppSettings, session: URLSession = .shared) {
        self.store = store
        self.settings = settings
        self.session = session
    }

    func outcome(for key: CellKey) -> TowerLookupOutcome? { store.towerLookups[key] }

    func tower(for key: CellKey) -> TowerLocation? {
        if case let .found(tower)? = store.towerLookups[key] { return tower }
        return nil
    }

    func isNotFound(_ key: CellKey) -> Bool {
        if case .notFound? = store.towerLookups[key] { return true }
        return false
    }

    func canLookUp(_ cell: CellAggregate) -> Bool {
        cell.mcc != nil && cell.mnc != nil && cell.areaCode != nil && cell.cellId != nil && cell.family.openCellIDRadio != nil
    }

    func lookUp(_ cell: CellAggregate) async {
        guard !inFlight.contains(cell.key) else { return }
        inFlight.insert(cell.key)
        errors[cell.key] = nil
        defer { inFlight.remove(cell.key) }
        do {
            let request = try OpenCellID.request(apiKey: settings.openCellIDKey, for: cell)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 404 {
                throw TowerLookupError.service("HTTP \(http.statusCode)")
            }
            store.setLookup(try OpenCellID.parse(data), for: cell.key)
        } catch {
            errors[cell.key] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Looks up cells that have never been looked up (used when auto-lookup is on).
    func lookUpMissing(_ cells: [CellAggregate]) async {
        guard settings.hasOpenCellIDKey else { return }
        for cell in cells where canLookUp(cell) && store.towerLookups[cell.key] == nil && errors[cell.key] == nil {
            await lookUp(cell)
        }
    }
}
