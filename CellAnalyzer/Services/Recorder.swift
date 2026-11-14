import Foundation
import CoreLocation
import Observation
import CellAnalyzerCore

/// Logs what iOS exposes (radio technology per SIM + position) over time.
///
/// A sample is written when the radio technology changes, when the phone moved more than
/// `minimumDistance`, or at least every `maximumQuietInterval` while stationary.
@MainActor
@Observable
final class Recorder {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var samplesThisSession = 0

    @ObservationIgnored private let telephony: TelephonyMonitor
    @ObservationIgnored private let location: LocationService
    @ObservationIgnored private let store: ObservationStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var lastSample: [String: CellObservation] = [:]

    let minimumDistance: Double = 25
    let maximumQuietInterval: TimeInterval = 60

    init(telephony: TelephonyMonitor, location: LocationService, store: ObservationStore, settings: AppSettings) {
        self.telephony = telephony
        self.location = location
        self.store = store
        self.settings = settings
    }

    func toggle() { isRecording ? stop() : start() }

    func start() {
        guard !isRecording else { return }
        isRecording = true
        startedAt = Date()
        samplesThisSession = 0
        lastSample.removeAll()
        location.start(background: settings.backgroundRecording)
        sample(force: true)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.settings.sampleInterval ?? 10
                try? await Task.sleep(for: .seconds(max(interval, 2)))
                guard !Task.isCancelled else { return }
                self?.sample(force: false)
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        sample(force: true)
        timerTask?.cancel()
        timerTask = nil
        isRecording = false
        location.stop()
    }

    /// Called by the app when a location fix or radio change arrives.
    func handleLocation(_ location: CLLocation) {
        guard isRecording else { return }
        sample(force: false)
    }

    func handleRadioChange() {
        guard isRecording else { return }
        sample(force: false)
    }

    /// Records one iOS-level sample per cellular service.
    func sample(force: Bool) {
        telephony.refresh()
        let now = Date()
        let point = location.currentPoint
        var new: [CellObservation] = []
        for service in telephony.services {
            let observation = CellObservation(
                timestamp: now, source: .system, radio: service.radio, simSlot: service.label,
                location: point)
            if force || shouldRecord(observation, previous: lastSample[service.id]) {
                new.append(observation)
                lastSample[service.id] = observation
            }
        }
        guard !new.isEmpty else { return }
        samplesThisSession += new.count
        store.add(contentsOf: new)
    }

    private func shouldRecord(_ o: CellObservation, previous: CellObservation?) -> Bool {
        guard let previous else { return true }
        if previous.radio != o.radio { return true }
        if o.timestamp.timeIntervalSince(previous.timestamp) >= maximumQuietInterval { return true }
        if let a = previous.location, let b = o.location, Geodesy.distance(a, b) >= minimumDistance { return true }
        if previous.location == nil && o.location != nil { return true }
        return false
    }
}
