import Foundation
import Observation
import Security
import CellAnalyzerCore

/// User preferences, persisted in UserDefaults (and the Keychain for the API key).
@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// NR gNB-ID length used to split NCIs (operator specific, 22…32).
    var gnbIdBits: Int { didSet { defaults.set(gnbIdBits, forKey: Keys.gnbIdBits) } }
    /// Seconds between periodic samples while recording.
    var sampleInterval: Double { didSet { defaults.set(sampleInterval, forKey: Keys.sampleInterval) } }
    /// Keep recording with the screen off (needs background location).
    var backgroundRecording: Bool { didSet { defaults.set(backgroundRecording, forKey: Keys.backgroundRecording) } }
    /// Look up newly seen cells on OpenCellID automatically.
    var autoLookup: Bool { didSet { defaults.set(autoLookup, forKey: Keys.autoLookup) } }
    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }

    /// OpenCellID access token (stored in the Keychain).
    var openCellIDKey: String {
        didSet { Keychain.set(openCellIDKey.trimmingCharacters(in: .whitespacesAndNewlines), for: Keys.openCellIDKey) }
    }

    var hasOpenCellIDKey: Bool { !openCellIDKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.gnbIdBits: CellIdentityDecoder.defaultGNBIdBits,
            Keys.sampleInterval: 10.0,
            Keys.backgroundRecording: true,
            Keys.autoLookup: false,
            Keys.onboarding: false,
        ])
        gnbIdBits = defaults.integer(forKey: Keys.gnbIdBits)
        sampleInterval = defaults.double(forKey: Keys.sampleInterval)
        backgroundRecording = defaults.bool(forKey: Keys.backgroundRecording)
        autoLookup = defaults.bool(forKey: Keys.autoLookup)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        openCellIDKey = Keychain.get(Keys.openCellIDKey) ?? ""
    }

    private enum Keys {
        static let gnbIdBits = "gnbIdBits"
        static let sampleInterval = "sampleInterval"
        static let backgroundRecording = "backgroundRecording"
        static let autoLookup = "autoLookup"
        static let onboarding = "hasCompletedOnboarding"
        static let openCellIDKey = "openCellIDKey"
    }
}

/// Minimal generic-password Keychain wrapper.
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "CellAnalyzer"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
