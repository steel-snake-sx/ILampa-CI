import Foundation
import Combine

/// A registered third-party capability is not automatically a native media resolver.
/// This classification is deliberately descriptive, not a permission grant.
enum PluginCapabilityKind: String, Codable, CaseIterable {
    case mediaSource
    case interactiveComponent
    case radio
    case metadataExtension
    case settingsExtension
    case unsupported

    var displayName: String {
        switch self {
        case .mediaSource: return "Источник медиа"
        case .interactiveComponent: return "Интерактивный компонент"
        case .radio: return "Радио"
        case .metadataExtension: return "Метаданные"
        case .settingsExtension: return "Настройки"
        case .unsupported: return "Без нативной поддержки"
        }
    }

    var iconName: String {
        switch self {
        case .mediaSource: return "play.tv"
        case .interactiveComponent: return "rectangle.and.hand.point.up.left"
        case .radio: return "radio"
        case .metadataExtension: return "text.badge.checkmark"
        case .settingsExtension: return "gearshape"
        case .unsupported: return "exclamationmark.triangle"
        }
    }
}

struct PluginRegisteredSource: Identifiable, Equatable {
    let id: String
    let pluginUrl: String
    let name: String
    let description: String?
    let isEnabled: Bool
    let hasExecutableResolver: Bool
    let capability: PluginCapabilityKind
    var operationalStatus: ProviderOperationalStatus
}

/// Truthful, current-generation plugin counters for product UI. Installed intent, successful
/// WebKit execution, and capability registration are intentionally separate values.
struct PluginRuntimeSnapshot: Equatable {
    let installedCount: Int
    let desiredEnabledCount: Int
    let executedCurrentGenerationCount: Int
    let registeredActiveCapabilityCount: Int
    let failedOrBlockedCount: Int
    private let currentExecutionURLs: Set<String>
    private let enabledURLs: Set<String>

    init(installed: [LampaPluginRecord], runningPluginURLs: [String], capabilities: [PluginRegisteredSource]) {
        let enabledURLs = Set(installed.filter(\.isEnabled).map(\.urlString))
        let executionURLs = Set(runningPluginURLs).intersection(enabledURLs)
        let activeCapabilityCount = capabilities.filter { executionURLs.contains($0.pluginUrl) }.count
        let failedOrBlockedCount = installed.filter { $0.errorDescription != nil || $0.automaticRetryBlocked == true }.count

        installedCount = installed.count
        self.enabledURLs = enabledURLs
        currentExecutionURLs = executionURLs
        desiredEnabledCount = enabledURLs.count
        executedCurrentGenerationCount = executionURLs.count
        registeredActiveCapabilityCount = activeCapabilityCount
        self.failedOrBlockedCount = failedOrBlockedCount
    }

    func isExecutedInCurrentGeneration(_ plugin: LampaPluginRecord) -> Bool {
        currentExecutionURLs.contains(plugin.urlString)
    }

    func isCapabilityActive(_ capability: PluginRegisteredSource) -> Bool {
        currentExecutionURLs.contains(capability.pluginUrl)
    }
}

/// UI publication and registry mutations have one executor; no deferred append can race teardown.
@MainActor
final class PluginCapabilityRegistry: ObservableObject {
    static let shared = PluginCapabilityRegistry()
    @Published private(set) var registeredSources: [PluginRegisteredSource] = []
    @Published private(set) var activeHooks: [String: [String]] = [:]
    @Published private(set) var registeredThemes: [String: String] = [:]
    private var themeOwners: [String: String] = [:]
    private init() {}

    func registerSource(pluginUrl: String, id: String, name: String, description: String?,
                        hasExecutableResolver: Bool = false, capability: PluginCapabilityKind = .unsupported,
                        operationalStatus: ProviderOperationalStatus = .registered) {
        guard !id.isEmpty, !pluginUrl.isEmpty else { return }
        guard !registeredSources.contains(where: { $0.id == id && $0.pluginUrl != pluginUrl }) else {
            DiagnosticsLogManager.shared.log(category: "[PluginRegistry]", message: "Отклонен конфликт владельцев источника \(id)", level: .warning)
            return
        }
        registeredSources.removeAll { $0.id == id && $0.pluginUrl == pluginUrl }
        registeredSources.append(PluginRegisteredSource(id: id, pluginUrl: pluginUrl, name: name,
            description: description, isEnabled: true, hasExecutableResolver: hasExecutableResolver,
            capability: capability, operationalStatus: operationalStatus))
        SourceProviderEngine.shared.invalidateCache()
    }

    func updateOperationalStatus(id: String, status: ProviderOperationalStatus) {
        guard let index = registeredSources.firstIndex(where: { $0.id == id }) else { return }
        registeredSources[index].operationalStatus = status
    }

    func unregisterAll(for pluginUrl: String) {
        registeredSources.removeAll { $0.pluginUrl == pluginUrl }
        for key in Array(activeHooks.keys) {
            activeHooks[key] = activeHooks[key]?.filter { $0 != pluginUrl }
        }
        for name in themeOwners.keys.filter({ themeOwners[$0] == pluginUrl }) {
            themeOwners.removeValue(forKey: name)
            registeredThemes.removeValue(forKey: name)
        }
        SourceProviderEngine.shared.invalidateCache()
    }

    func registerHook(pluginUrl: String, event: String) {
        var owners = activeHooks[event] ?? []
        if !owners.contains(pluginUrl) { owners.append(pluginUrl) }
        activeHooks[event] = owners
    }

    func registerTheme(name: String, data: String, pluginUrl: String? = nil) {
        if let owner = themeOwners[name], owner != pluginUrl { return }
        registeredThemes[name] = data
        themeOwners[name] = pluginUrl
    }

    func isSourceActive(id: String) -> Bool {
        registeredSources.contains { $0.id == id && $0.isEnabled }
    }

    func clear() {
        registeredSources.removeAll()
        activeHooks.removeAll()
        registeredThemes.removeAll()
        themeOwners.removeAll()
        SourceProviderEngine.shared.invalidateCache()
    }
}
