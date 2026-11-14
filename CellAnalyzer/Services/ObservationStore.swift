import Foundation
import Observation
import CellAnalyzerCore

/// On-device persistence for observations and tower lookups (JSON in Application Support).
@MainActor
@Observable
final class ObservationStore {
    private(set) var observations: [CellObservation] = []
    private(set) var towerLookups: [CellKey: TowerLookupOutcome] = [:]
    private(set) var lastError: String?

    /// Called after every mutation so derived analysis can be refreshed.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.fileURL = dir.appendingPathComponent("cell-analyzer-store.json")
        }
        load()
    }

    // MARK: Mutations

    func add(_ observation: CellObservation) { add(contentsOf: [observation]) }

    func add(contentsOf new: [CellObservation]) {
        guard !new.isEmpty else { return }
        let existing = Set(observations.map(\.id))
        observations.append(contentsOf: new.filter { !existing.contains($0.id) })
        observations.sort { $0.timestamp < $1.timestamp }
        changed()
    }

    func update(_ observation: CellObservation) {
        guard let index = observations.firstIndex(where: { $0.id == observation.id }) else { return }
        observations[index] = observation
        observations.sort { $0.timestamp < $1.timestamp }
        changed()
    }

    func delete(ids: Set<UUID>) {
        observations.removeAll { ids.contains($0.id) }
        changed()
    }

    func deleteAll() {
        observations.removeAll()
        towerLookups.removeAll()
        changed()
    }

    func setLookup(_ outcome: TowerLookupOutcome, for key: CellKey) {
        towerLookups[key] = outcome
        changed()
    }

    func observation(id: UUID) -> CellObservation? { observations.first { $0.id == id } }

    /// Closest known position to a moment in time (used to geotag screenshots).
    func location(near date: Date, within tolerance: TimeInterval = 600) -> GeoPoint? {
        observations
            .filter { $0.location != nil && abs($0.timestamp.timeIntervalSince(date)) <= tolerance }
            .min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }?
            .location
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var version = 1
        var observations: [CellObservation]
        var lookups: [LookupRecord]
    }

    private struct LookupRecord: Codable {
        var key: CellKey
        var outcome: TowerLookupOutcome
    }

    private func changed() {
        onChange?()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let snapshot = Snapshot(observations: observations,
                                lookups: towerLookups.map { LookupRecord(key: $0.key, outcome: $0.value) })
        let url = fileURL
        do {
            let encoder = Exporters.makeEncoder()
            encoder.outputFormatting = []
            let data = try encoder.encode(snapshot)
            Task.detached(priority: .utility) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let snapshot = try Exporters.makeDecoder().decode(Snapshot.self, from: data)
            observations = snapshot.observations.sorted { $0.timestamp < $1.timestamp }
            towerLookups = Dictionary(snapshot.lookups.map { ($0.key, $0.outcome) }, uniquingKeysWith: { _, new in new })
        } catch {
            lastError = "Could not read saved data: \(error.localizedDescription)"
        }
    }
}
