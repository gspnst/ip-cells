import Foundation
import Observation
import CellAnalyzerCore

/// Root object graph shared with all views through the environment.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let store: ObservationStore
    let telephony: TelephonyMonitor
    let location: LocationService
    let path: PathMonitor
    let recorder: Recorder
    let towers: TowerLookupService

    /// Derived analysis, recomputed whenever the store changes.
    private(set) var cells: [CellAggregate] = []
    private(set) var summary: SessionSummary
    private(set) var anomalies: [Anomaly] = []

    @ObservationIgnored private var recomputeTask: Task<Void, Never>?

    /// Launched with `-demoData` (UI tests, screenshots), the app uses a throwaway store filled with demo data.
    init() {
        let demo = ProcessInfo.processInfo.arguments.contains("-demoData")
        let settings = AppSettings()
        let store = demo
            ? ObservationStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("demo-store.json"))
            : ObservationStore()
        let telephony = TelephonyMonitor()
        let location = LocationService()
        self.settings = settings
        self.store = store
        self.telephony = telephony
        self.location = location
        self.path = PathMonitor()
        self.recorder = Recorder(telephony: telephony, location: location, store: store, settings: settings)
        self.towers = TowerLookupService(store: store, settings: settings)
        self.summary = SessionAnalyzer.summarize([])

        store.onChange = { [weak self] in self?.scheduleRecompute() }
        telephony.onRadioChange = { [weak self] _, _ in self?.recorder.handleRadioChange() }
        location.onLocation = { [weak self] fix in self?.recorder.handleLocation(fix) }
        if demo {
            settings.hasCompletedOnboarding = true
            store.deleteAll()
            store.add(contentsOf: DemoData.session())
        }
        recompute()
    }

    // MARK: Derived data

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    func recompute() {
        let observations = store.observations
        let cells = CellAggregator.aggregate(observations)
        self.cells = cells
        self.summary = SessionAnalyzer.summarize(observations, aggregates: cells)

        var towerPositions: [CellKey: GeoPoint] = [:]
        var notFound = Set<CellKey>()
        for (key, outcome) in store.towerLookups {
            switch outcome {
            case let .found(tower): towerPositions[key] = tower.location
            case .notFound: notFound.insert(key)
            }
        }
        self.anomalies = AnomalyDetector().detect(observations, databaseLocations: towerPositions,
                                                  notFoundInDatabase: notFound)

        if settings.autoLookup {
            Task { await self.towers.lookUpMissing(cells) }
        }
    }

    // MARK: Demo data

    var hasDemoData: Bool { store.observations.contains { $0.notes == DemoData.note } }

    func loadDemoData() {
        store.add(contentsOf: DemoData.session())
    }

    func removeDemoData() {
        store.delete(ids: Set(store.observations.filter { $0.notes == DemoData.note }.map(\.id)))
    }

    // MARK: Queries

    var latestMeasured: CellObservation? {
        store.observations.last { $0.identifiesCell || $0.hasSignal }
    }

    func cell(for key: CellKey) -> CellAggregate? { cells.first { $0.key == key } }

    func cell(containing observation: CellObservation) -> CellAggregate? {
        cells.first { $0.observationIDs.contains(observation.id) }
    }

    func observations(for cell: CellAggregate) -> [CellObservation] {
        let ids = Set(cell.observationIDs)
        return store.observations.filter { ids.contains($0.id) }
    }

    func anomalies(for key: CellKey) -> [Anomaly] { anomalies.filter { $0.cellKey == key } }

    /// Best position for a measurement taken at `date`: recorded track first, then the last fix.
    func bestLocation(for date: Date) -> GeoPoint? {
        location.location(near: date) ?? store.location(near: date)
            ?? (abs(date.timeIntervalSinceNow) < 600 ? location.currentPoint : nil)
    }
}
