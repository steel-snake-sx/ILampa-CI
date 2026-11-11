import Foundation

enum OnlineModOriginPreference: String, Codable, CaseIterable {
    case bundled = "bundled"
    case remote = "remote"

    var displayName: String {
        switch self {
        case .bundled: return "Встроенный Online Mod (bundled)"
        case .remote: return "Удаленный Online Mod (сообщество)"
        }
    }
}

/// Manages explicit user choice between bundled and remote Online Mod implementations.
/// Persists choice across launches and avoids silent reactivation of bundled code.
@MainActor
final class OnlineModPreferenceManager: ObservableObject {
    static let shared = OnlineModPreferenceManager()

    static let staticStorageKey = "ilampa_preferred_online_mod_origin"

    nonisolated static var currentPreference: OnlineModOriginPreference {
        if let raw = UserDefaults.standard.string(forKey: staticStorageKey),
           let saved = OnlineModOriginPreference(rawValue: raw) {
            return saved
        }
        return .bundled
    }

    private let storageKey = OnlineModPreferenceManager.staticStorageKey

    @Published var preference: OnlineModOriginPreference {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: storageKey)
            ActionCorrelationTracker.shared.startAction(
                name: "SwitchOnlineModPreference",
                metadata: ["preferred": preference.rawValue]
            )
            LampaHeadlessHost.shared.clearActiveMediaContext()
            SourceProviderEngine.shared.invalidateCache()
            PluginManager.shared.resolveAndApplyCollisions()
            PluginManager.shared.synchronizeRuntime(reason: "switch_online_mod_preference")
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let saved = OnlineModOriginPreference(rawValue: raw) {
            self.preference = saved
        } else {
            self.preference = .bundled
        }
    }

    func setPreference(_ newPref: OnlineModOriginPreference) {
        guard newPref != preference else { return }
        preference = newPref
    }
}
