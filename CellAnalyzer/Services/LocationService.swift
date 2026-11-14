import Foundation
import CoreLocation
import Observation
import CellAnalyzerCore

@MainActor
@Observable
final class LocationService: NSObject {
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var lastLocation: CLLocation?
    private(set) var isUpdating = false
    private(set) var lastError: String?

    @ObservationIgnored var onLocation: ((CLLocation) -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var backgroundSession: CLBackgroundActivitySession?
    /// Recent fixes, for matching screenshot timestamps to positions.
    @ObservationIgnored private var history: [CLLocation] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    var currentPoint: GeoPoint? { lastLocation.map { GeoPoint($0) } }

    func requestPermission() {
        if authorization == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    /// Starts continuous updates. With `background`, updates continue while the app is in the
    /// background (blue status-bar pill) using a `CLBackgroundActivitySession`.
    func start(background: Bool) {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.allowsBackgroundLocationUpdates = background
        manager.showsBackgroundLocationIndicator = background
        if background, backgroundSession == nil {
            backgroundSession = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
        isUpdating = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        isUpdating = false
    }

    /// Requests a single fix (used when not recording).
    func refreshOnce() {
        guard isAuthorized else { requestPermission(); return }
        manager.requestLocation()
    }

    /// Best known position within `tolerance` of `date`.
    func location(near date: Date, tolerance: TimeInterval = 600) -> GeoPoint? {
        history
            .filter { abs($0.timestamp.timeIntervalSince(date)) <= tolerance }
            .min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }
            .map { GeoPoint($0) }
    }

    fileprivate func handle(_ locations: [CLLocation]) {
        let valid = locations.filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy < 200 }
        guard let latest = valid.last else { return }
        lastLocation = latest
        lastError = nil
        history.append(contentsOf: valid)
        if history.count > 5_000 { history.removeFirst(history.count - 5_000) }
        for location in valid { onLocation?(location) }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.isAuthorized, self.lastLocation == nil { self.manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = error.localizedDescription
        let isUnknown = (error as? CLError)?.code == .locationUnknown
        Task { @MainActor in
            if !isUnknown { self.lastError = message }
        }
    }
}

extension GeoPoint {
    init(_ location: CLLocation) {
        self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                  horizontalAccuracy: location.horizontalAccuracy)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
