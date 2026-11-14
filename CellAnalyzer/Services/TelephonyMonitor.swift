import Foundation
import CoreTelephony
import Observation
import CellAnalyzerCore

/// What iOS publicly exposes about one cellular service (SIM / eSIM).
struct CellularService: Identifiable, Hashable {
    /// CoreTelephony service identifier (opaque, stable per SIM slot).
    var id: String
    var radio: RadioTechnology
    var rawRadio: String?
    var isDataService: Bool
    /// Position in the list – used to label services "SIM 1", "SIM 2".
    var index: Int

    var label: String { "SIM \(index + 1)" }
}

/// Wraps `CTTelephonyNetworkInfo`: per-SIM radio access technology plus change notifications.
///
/// This is the *only* live cellular information Apple allows third-party apps to read.
/// Cell IDs, PCI, EARFCN and signal levels are not available through public APIs.
@MainActor
@Observable
final class TelephonyMonitor: NSObject {
    private(set) var services: [CellularService] = []
    private(set) var dataServiceIdentifier: String?
    private(set) var cellularDataState: CTCellularDataRestrictedState = .restrictedStateUnknown
    private(set) var lastChange: Date?

    /// Invoked when any service's radio technology changes.
    @ObservationIgnored var onRadioChange: ((CellularService, RadioTechnology?) -> Void)?

    @ObservationIgnored private let networkInfo = CTTelephonyNetworkInfo()
    @ObservationIgnored private let cellularData = CTCellularData()
    @ObservationIgnored private var observer: NSObjectProtocol?

    override init() {
        super.init()
        networkInfo.delegate = self
        observer = NotificationCenter.default.addObserver(
            forName: .CTServiceRadioAccessTechnologyDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        cellularData.cellularDataRestrictionDidUpdateNotifier = { [weak self] state in
            Task { @MainActor in self?.cellularDataState = state }
        }
        cellularDataState = cellularData.restrictedState
        refresh()
    }

    var dataService: CellularService? {
        services.first { $0.isDataService } ?? services.first
    }

    var hasCellularService: Bool { !services.isEmpty }

    func refresh() {
        dataServiceIdentifier = networkInfo.dataServiceIdentifier
        // Carrier name/MCC/MNC (CTCarrier) are not read: since iOS 16 they only return placeholders.
        let rats = networkInfo.serviceCurrentRadioAccessTechnology ?? [:]
        let ids = rats.keys.sorted()

        let previous = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0.radio) })
        var updated: [CellularService] = []
        for (index, id) in ids.enumerated() {
            let raw = rats[id]
            updated.append(CellularService(
                id: id,
                radio: raw.map(RadioTechnology.init(coreTelephonyIdentifier:)) ?? .unknown,
                rawRadio: raw,
                isDataService: id == dataServiceIdentifier,
                index: index))
        }
        services = updated

        for service in updated where previous[service.id] != service.radio {
            lastChange = Date()
            onRadioChange?(service, previous[service.id])
        }
    }
}

extension TelephonyMonitor: CTTelephonyNetworkInfoDelegate {
    nonisolated func dataServiceIdentifierDidChange(_ identifier: String) {
        Task { @MainActor in self.refresh() }
    }
}

extension CTCellularDataRestrictedState {
    var label: String {
        switch self {
        case .notRestricted: return "Allowed"
        case .restricted: return "Restricted for this app"
        case .restrictedStateUnknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}
