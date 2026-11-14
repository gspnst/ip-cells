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
    /// Carrier details are only available before iOS 16; newer systems return placeholders.
    var carrierName: String?
    var mcc: Int?
    var mnc: Int?
    var isoCountryCode: String?
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
        let rats = networkInfo.serviceCurrentRadioAccessTechnology ?? [:]
        let carriers = Self.carriers(networkInfo)
        let ids = Set(rats.keys).union(carriers.keys).sorted()

        let previous = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0.radio) })
        var updated: [CellularService] = []
        for (index, id) in ids.enumerated() {
            let raw = rats[id]
            let carrier = carriers[id]
            updated.append(CellularService(
                id: id,
                radio: raw.map(RadioTechnology.init(coreTelephonyIdentifier:)) ?? .unknown,
                rawRadio: raw,
                carrierName: carrier?.name,
                mcc: carrier?.mcc,
                mnc: carrier?.mnc,
                isoCountryCode: carrier?.iso,
                isDataService: id == dataServiceIdentifier,
                index: index))
        }
        // Services that lost radio (airplane mode / no coverage) are kept with .unknown above.
        services = updated

        for service in updated where previous[service.id] != service.radio {
            lastChange = Date()
            onRadioChange?(service, previous[service.id])
        }
    }

    private struct CarrierInfo { var name: String?; var mcc: Int?; var mnc: Int?; var iso: String? }

    /// `CTCarrier` is deprecated since iOS 16 and returns "--"/65535 placeholders there;
    /// placeholder values are filtered out so the UI never shows bogus PLMNs.
    @available(iOS, deprecated: 16.0)
    private static func carriers(_ info: CTTelephonyNetworkInfo) -> [String: CarrierInfo] {
        var result: [String: CarrierInfo] = [:]
        for (id, carrier) in info.serviceSubscriberCellularProviders ?? [:] {
            func clean(_ s: String?) -> String? {
                guard let s, !s.isEmpty, s != "--", s != "65535" else { return nil }
                return s
            }
            result[id] = CarrierInfo(name: clean(carrier.carrierName),
                                     mcc: clean(carrier.mobileCountryCode).flatMap(Int.init),
                                     mnc: clean(carrier.mobileNetworkCode).flatMap(Int.init),
                                     iso: clean(carrier.isoCountryCode)?.uppercased())
        }
        return result
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
