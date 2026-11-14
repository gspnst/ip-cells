import Foundation
import Network
import Observation

/// Which interface currently carries traffic (Wi-Fi vs cellular), via `NWPathMonitor`.
@MainActor
@Observable
final class PathMonitor {
    enum Interface: String {
        case cellular = "Cellular", wifi = "Wi-Fi", wired = "Wired", other = "Other", none = "Offline"

        var systemImage: String {
            switch self {
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .wifi: return "wifi"
            case .wired: return "cable.connector"
            case .other: return "network"
            case .none: return "wifi.slash"
            }
        }
    }

    private(set) var interface: Interface = .none
    private(set) var isExpensive = false
    private(set) var isConstrained = false
    private(set) var cellularAvailable = false

    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let interface: Interface
            if path.status != .satisfied {
                interface = .none
            } else if path.usesInterfaceType(.wifi) {
                interface = .wifi
            } else if path.usesInterfaceType(.cellular) {
                interface = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                interface = .wired
            } else {
                interface = .other
            }
            let expensive = path.isExpensive, constrained = path.isConstrained
            let cellular = path.availableInterfaces.contains { $0.type == .cellular }
            Task { @MainActor in
                self?.interface = interface
                self?.isExpensive = expensive
                self?.isConstrained = constrained
                self?.cellularAvailable = cellular
            }
        }
        monitor.start(queue: DispatchQueue(label: "PathMonitor"))
    }
}
