import Foundation
import Combine
import CryptoKit

enum PluginScriptResponseBodyKind: String, Equatable {
    case empty
    case html
    case xml
    case json
    case nonText
    case scriptOrText
}

struct PluginScriptResponseDiagnostic: Equatable {
    let statusCode: Int?
    let contentType: String?
    let requestedURL: String
    let finalURL: String?
    let bodyKind: PluginScriptResponseBodyKind
    let byteCount: Int

    var sanitizedDescription: String {
        let status = statusCode.map(String.init) ?? "non-HTTP"
        let type = contentType?.isEmpty == false ? contentType! : "unknown"
        let final = finalURL?.isEmpty == false ? finalURL! : "unknown"
        return "HTTP=\(status), type=\(type), requested=\(requestedURL), final=\(final), redirected=\(requestedURL != final), body=\(bodyKind.rawValue), bytes=\(byteCount)"
    }
}

enum PluginScriptFetchError: LocalizedError, Equatable {
    case invalidResponse(PluginScriptResponseDiagnostic)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let diagnostic):
            return "Invalid plugin response (\(diagnostic.sanitizedDescription))"
        }
    }

    var blocksAutomaticRetry: Bool { true }
}

enum PluginTrustError: LocalizedError {
    case approvalRequired
    var errorDescription: String? { "Код плагина не подтверждён или изменился. Подтвердите текущий SHA-256 перед запуском." }
}

// Curated plugin catalogue definition for verified community and internal extensions
struct CuratedPlugin: Identifiable, Hashable {
    var id: String { url }
    let name: String
    let description: String
    let url: String
    let iconName: String
}

// Typed, persistent plugin manager controlling the complete lifecycle of extensions in WebKit runtime:
// download, local disk caching, execution inside LampaHeadlessHost, and dynamic 1:M source registration.
@MainActor final class PluginManager: ObservableObject, PluginLifecycleManagerProtocol {
    static let shared = PluginManager()

    private let storageKey = "ilampa_webkit_plugins_v1"
    private let legacyStorageKey = "ilampa_installed_plugins_v3"
    private let defaults: UserDefaults
    private let session: URLSession

    @Published private(set) var installedPlugins: [LampaPluginRecord] = []
    @Published var installingUrls: Set<String> = []
    @Published var lastError: String? = nil
    private let cacheDirectory: URL?
    private let runtimeConfiguration: ([RuntimePlugin], String) -> Void
    private var installationTokens: [String: UUID] = [:]
    private var installationTasks: [String: URLSessionDataTask] = [:]
    private(set) var installationEpoch = UUID()
    private var storageReadFailed = false

    let curatedPlugins: [CuratedPlugin] = [
        CuratedPlugin(
            name: "SomaFM (Радио & Музыка)",
            description: "51 независимый интернет-радиоканал без рекламы (Groove Salad, Drone Zone и др.)",
            url: "https://tsynik.github.io/lampa/soma.js",
            iconName: "radio.fill"
        ),
        CuratedPlugin(
            name: "e.js (Меню выхода и навигации)",
            description: "Добавляет кнопку выхода и быстрые действия в меню Lampa",
            url: "https://tsynik.github.io/lampa/e.js",
            iconName: "arrow.right.square.fill"
        ),
        CuratedPlugin(
            name: "Онлайн-мод (встроенный)",
            description: "Оригинальный интерактивный выбор источника в Lampa с безопасной передачей выбранного потока",
            url: "bundled://plugins/online_mod.js",
            iconName: "play.tv.fill"
        )
    ]

    private var pluginsDirectory: URL {
        if let cacheDirectory { return cacheDirectory }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("iLampa/Plugins", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    init(defaults: UserDefaults = .standard, cacheDirectory: URL? = nil,
         session: URLSession = URLSession(configuration: .default),
         runtimeConfiguration: (([RuntimePlugin], String) -> Void)? = nil) {
        self.defaults = defaults
        self.cacheDirectory = cacheDirectory
        self.session = session
        self.runtimeConfiguration = runtimeConfiguration ?? { plugins, reason in
            LampaHeadlessHost.shared.configurePlugins(plugins, reason: reason)
        }
        loadPlugins()
        // Do NOT bootstrap active plugins here before WebKit index.html has booted.
        // onRuntimeReady() will be called when WebKit emits appready=true.
    }

    private func loadPlugins() {
        if let data = defaults.data(forKey: storageKey) {
            guard let decoded = try? JSONDecoder().decode([LampaPluginRecord].self, from: data) else {
                // Do not replace damaged user intent with enabled defaults or overwrite recovery data.
                installedPlugins = []
                storageReadFailed = true
                lastError = "Не удалось прочитать сохранённые плагины. Данные сохранены для восстановления."
                return
            }
            self.installedPlugins = decoded.map { record in
                // Preserve the precise deterministic failure across launches. It remains visible
                // and intentionally excluded until the user asks for an explicit retry.
                if record.automaticRetryBlocked == true { return record }
                var next = record
                next.isEnabled = record.isEnabled
                return next
            }
            resolveAndApplyCollisions()
            return
        }

        if let data = defaults.data(forKey: legacyStorageKey) {
            struct LegacyPlugin: Decodable {
                let url: String
                let name: String
                let author: String?
                let status: Int
                let localFileName: String?
            }
            guard let legacy = try? JSONDecoder().decode([LegacyPlugin].self, from: data) else {
                installedPlugins = []
                storageReadFailed = true
                lastError = "Не удалось перенести прежний список плагинов. Исходные данные сохранены."
                return
            }
            installedPlugins = legacy.compactMap { old in
                guard let url = URL(string: old.url), ["http", "https", "ilampa"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                let record = LampaPluginRecord(url: url, name: old.name, author: old.author,
                                              lifecycleState: old.status == 1 ? .loading : .inactive)
                if let fileName = old.localFileName, fileName == URL(fileURLWithPath: fileName).lastPathComponent,
                   let script = try? String(contentsOf: pluginsDirectory.appendingPathComponent(fileName), encoding: .utf8) {
                    _ = saveScriptToDisk(script: script, forUrl: old.url)
                }
                return record
            }
            persist() // Retain the old key for recovery; current key is authoritative from now on.
            return
        }

        // A fresh install must not execute third-party or diagnostic JavaScript without an
        // explicit user choice. The normal Plugins catalogue offers compatible extensions.
        self.installedPlugins = []
        persist()
    }

    private func persist() {
        guard !storageReadFailed else { return }
        if let encoded = try? JSONEncoder().encode(installedPlugins) {
            defaults.set(encoded, forKey: storageKey)
        }
    }

    @discardableResult
    func resolveAndApplyCollisions() -> [PluginCollisionReport] {
        let reports = PluginCollisionPolicy.resolveCollisions(in: installedPlugins)
        var changed = false
        for report in reports {
            if let idx = installedPlugins.firstIndex(where: { $0.id == report.loser.id }),
               installedPlugins[idx].isEnabled {
                installedPlugins[idx].isEnabled = false
                installedPlugins[idx].lifecycleState = .inactiveAlternate(reason: report.userMessage)
                changed = true
                DiagnosticsLogManager.shared.log(
                    category: "[PluginCollision]",
                    message: "Приоритет плагинов применен: \(report.userMessage)",
                    level: .info
                )
            }
        }
        if changed {
            persist()
        }
        return reports
    }

    // Intent only. The host's lifecycle controller exclusively owns restoration and execution.
    func synchronizeRuntime(reason: String = "plugin configuration") {
        resolveAndApplyCollisions()
        let plugins = installedPlugins.filter(\.isEligibleForAutomaticRuntime).map {
            RuntimePlugin(id: $0.urlString, name: $0.name)
        }
        let blocked = installedPlugins.filter { $0.isEnabled && !$0.isEligibleForAutomaticRuntime }.map(\.urlString)
        let intent = installedPlugins.map { plugin in
            "\(safeURLString(plugin.url)){desired=\(plugin.isEnabled),blocked=\(plugin.automaticRetryBlocked == true),state=\(plugin.lifecycleState.displayLabel)}"
        }.joined(separator: ", ")
        DiagnosticsLogManager.shared.log(
            category: "[PluginManager]",
            message: "Runtime intent reason=\(reason), enabled=\(installedPlugins.filter(\.isEnabled).count), executable=\(plugins.count), retryBlocked=\(blocked.count), records=[\(intent)]",
            level: .info
        )
        runtimeConfiguration(plugins, reason)
    }

    func markPluginFailed(urlString: String, reason: String, blockAutomaticRetry: Bool = false) {
            if let idx = self.installedPlugins.firstIndex(where: { $0.url.absoluteString == urlString && $0.isEligibleForAutomaticRuntime }) {
                // A script may register components before throwing. Remove those transient
                // capabilities instead of presenting a partially failed plugin as usable.
                SourceManager.shared.unregisterSources(forPluginId: self.installedPlugins[idx].id)
                PluginCapabilityRegistry.shared.unregisterAll(for: urlString)
                self.installedPlugins[idx].registeredComponents.removeAll()
                self.installedPlugins[idx].lifecycleState = .failed(reason: reason)
                self.installedPlugins[idx].automaticRetryBlocked = blockAutomaticRetry
                self.persist()
                DiagnosticsLogManager.shared.log(
                    category: "[PluginManager]",
                    message: "Сбой плагина «\(self.installedPlugins[idx].name)» retryBlocked=\(blockAutomaticRetry): \(reason)",
                    level: .error
                )
            }
    }

    func markPluginActive(urlString: String) {
            if let idx = self.installedPlugins.firstIndex(where: { $0.url.absoluteString == urlString && $0.isEligibleForAutomaticRuntime }) {
                self.installedPlugins[idx].lifecycleState = .active
                self.installedPlugins[idx].lastValidatedAt = Date()
                self.installedPlugins[idx].automaticRetryBlocked = false
                self.persist()
                DiagnosticsLogManager.shared.log(category: "[PluginManager]",
                    message: "Executed plugin url=\(self.safeURLString(self.installedPlugins[idx].url)) components=\(self.installedPlugins[idx].registeredComponents.sorted())",
                    level: .success)
                self.registerCapabilities(plugin: self.installedPlugins[idx])
            }
    }

    func isInstalled(url: String) -> Bool {
        installedPlugins.contains(where: { $0.url.absoluteString == url })
    }

    func isInstalling(url: String) -> Bool {
        installingUrls.contains(url)
    }

    func isEligibleForRuntime(urlString: String) -> Bool {
        installedPlugins.contains { $0.urlString == urlString && $0.isEligibleForAutomaticRuntime }
    }

    /// Asynchronous ownership attribution matching component names to active plugins
    func resolveOwnerPlugin(forComponentName componentName: String) -> String? {
        let lower = componentName.lowercased()
        let eligible = installedPlugins.filter { $0.isEligibleForAutomaticRuntime }

        for plugin in eligible {
            let urlLower = plugin.urlString.lowercased()
            let nameLower = plugin.name.lowercased()

            if lower.hasPrefix("myshows") && (urlLower.contains("myshows") || nameLower.contains("myshows")) {
                return plugin.urlString
            }
            if lower.hasPrefix("jellyfin") && (urlLower.contains("jellyfin") || nameLower.contains("jellyfin")) {
                return plugin.urlString
            }
            if (lower.hasPrefix("online_fx") || lower.contains("filmix")) && (urlLower.contains("fx") || nameLower.contains("filmix")) {
                return plugin.urlString
            }
            if lower.hasPrefix("cinema") && (urlLower.contains("cinema") || nameLower.contains("cinema")) {
                return plugin.urlString
            }
            if lower.hasPrefix("netfix") && (urlLower.contains("netfix") || nameLower.contains("netfix")) {
                return plugin.urlString
            }
            if lower.hasPrefix("online_kp") && (urlLower.contains("kp") || urlLower.contains("kinopub")) {
                return plugin.urlString
            }
            if (lower.contains("record") || lower == "radiovera") && (urlLower.contains("record") || nameLower.contains("record")) {
                return plugin.urlString
            }
            if lower == "somafm" && urlLower.contains("soma") {
                return plugin.urlString
            }
            if lower == "exit_m" && urlLower.contains("/e.js") {
                return plugin.urlString
            }
            if lower == "timetable" && (urlLower.contains("myshows") || urlLower.contains("timetable")) {
                return plugin.urlString
            }
        }
        return nil
    }

    /// Transactional batch addition for imported plugins.
    /// Newly imported plugins are staged disabled by default, preventing WebKit restart storms.
    func batchAdd(records: [LampaPluginRecord]) {
        guard !storageReadFailed, !records.isEmpty else { return }
        for var record in records {
            guard !installedPlugins.contains(where: { $0.urlString == record.urlString }) else { continue }
            record.approvedScriptSHA256 = nil
            record.isEnabled = false
            installedPlugins.append(record)
        }
        persist()
        DiagnosticsLogManager.shared.log(
            category: "[PluginManager]",
            message: "Пакетно добавлены плагины: \(records.count) записей (по умолчанию отключены)",
            level: .success
        )
    }

    /// Commit one downloaded batch item without changing existing plugin intent or runtime state.
    /// UserDefaults does not expose a durable-write acknowledgement; encoding and cache writes
    /// are checked before publishing the new in-memory record.
    func commitBatchPlugin(_ record: LampaPluginRecord, script: String, expectedEpoch: UUID? = nil) throws {
        if let expectedEpoch, expectedEpoch != installationEpoch { throw CancellationError() }
        guard !storageReadFailed else {
            throw NSError(domain: "BatchImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: lastError ?? "Хранилище плагинов недоступно"])
        }
        func normalized(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.url?.absoluteString ?? url.absoluteString
        }
        let key = normalized(record.url)
        guard !installedPlugins.contains(where: { normalized($0.url) == key }),
              !installingUrls.contains(where: { URL(string: $0).map(normalized) == key }) else {
            throw NSError(domain: "BatchImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "Плагин уже установлен или устанавливается"])
        }
        var disabled = record
        disabled.approvedScriptSHA256 = nil
        disabled.desiredEnabled = false
        disabled.lifecycleState = .inactive
        let updated = installedPlugins + [disabled]
        let encoded = try JSONEncoder().encode(updated)
        try script.write(to: scriptURL(for: key), atomically: true, encoding: .utf8)
        defaults.set(encoded, forKey: storageKey)
        installedPlugins = updated
    }

    // Installs a curated plugin with script retrieval, disk caching, and execution
    func install(curated: CuratedPlugin, operationID: UUID = UUID(), completion: ((Bool, String?) -> Void)? = nil) {
        guard !storageReadFailed else { completion?(false, lastError); return }
        let urlString = curated.url
        guard !installingUrls.contains(urlString) else { completion?(false, "Installation already in progress"); return }
        guard !isInstalled(url: urlString) else {
            completion?(true, nil)
            return
        }

        installingUrls.insert(urlString)
        let installationToken = operationID
        installationTokens[urlString] = installationToken
        lastError = nil

        if urlString.starts(with: "ilampa://") {
            installInternalPlugin(curated: curated, completion: completion)
            return
        }

        guard let url = URL(string: urlString) else {
            installingUrls.remove(urlString)
            let msg = "Некорректный адрес плагина"
            lastError = msg
            completion?(false, msg)
            return
        }

        // Check bundled fallback first
        if let bundledScript = loadBundledFallback(urlString: urlString) {
            installScriptDirectly(script: bundledScript, url: url, name: curated.name, author: "Curated Community", origin: .communityRemote, completion: completion)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        request.httpMethod = "GET"

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.installationTokens[urlString] == installationToken else { completion?(false, "Installation cancelled"); return }
                self.installationTasks[urlString] = nil
                self.installingUrls.remove(urlString)

                if let error = error {
                    // Try bundled fallback on network error
                    if let bundled = self.loadBundledFallback(urlString: urlString) {
                        self.installScriptDirectly(script: bundled, url: url, name: curated.name, author: "Curated (Bundled Fallback)", origin: .communityRemote, completion: completion)
                        return
                    }
                    let msg = "Ошибка сети: \(error.localizedDescription)"
                    self.lastError = msg
                    completion?(false, msg)
                    return
                }

                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    if let bundled = self.loadBundledFallback(urlString: urlString) {
                        self.installScriptDirectly(script: bundled, url: url, name: curated.name, author: "Curated (Bundled Fallback)", origin: .communityRemote, completion: completion)
                        return
                    }
                    let msg = "Сервер вернул ошибку \(http.statusCode)"
                    self.lastError = msg
                    completion?(false, msg)
                    return
                }

                guard let data = data, let script = String(data: data, encoding: .utf8), !script.isEmpty else {
                    let msg = "Получен пустой файл скрипта"
                    self.lastError = msg
                    completion?(false, msg)
                    return
                }

                self.installScriptDirectly(script: script, url: url, name: curated.name, author: "Verified Community", origin: .communityRemote, completion: completion)
            }
        }
        installationTasks[urlString] = task
        task.resume()
    }

    private func installScriptDirectly(
        script: String,
        url: URL,
        name: String,
        author: String?,
        origin: PluginOrigin,
        completion: ((Bool, String?) -> Void)?
    ) {
        let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedScript.hasPrefix("<!DOCTYPE") || trimmedScript.hasPrefix("<html") || trimmedScript.hasPrefix("<?xml") {
            let msg = "Сервер вернул HTML-страницу ошибки вместо скрипта"
            self.lastError = msg
            completion?(false, msg)
            return
        }

        let urlString = url.absoluteString
        installingUrls.remove(urlString)
        installationTokens[urlString] = nil
        guard !isInstalled(url: urlString) else { completion?(true, nil); return }
        do {
            try script.write(to: scriptURL(for: urlString), atomically: true, encoding: .utf8)
        } catch {
            lastError = "Не удалось сохранить код плагина."
            completion?(false, lastError)
            return
        }

        let newId = UUID()
        var components: Set<String> = []
        var sourceKeys: [String] = []

        if isSomaPlugin(urlString) {
            components.insert("somafm")
            sourceKeys.append("somafm_radio")
        } else if ["https://tsynik.github.io/lampa/e.js", "bundled://plugins/e.js"].contains(urlString) {
            components.insert("exit_m")
        }

        let newRecord = LampaPluginRecord(
            id: newId,
            url: url,
            name: name,
            version: "1.0.0",
            author: isOnlineModPlugin(urlString) ? "iLampa (bundled original plugin)" : author,
            origin: isOnlineModPlugin(urlString) ? .bundled : origin,
            lifecycleState: .inactive,
            registeredComponents: components,
            providedSourceKeys: sourceKeys
        )

        installedPlugins.append(newRecord)
        persist()
        synchronizeRuntime(reason: "install \(urlString)")
        completion?(true, nil)
    }

    private func installInternalPlugin(curated: CuratedPlugin, completion: ((Bool, String?) -> Void)?) {
        installingUrls.remove(curated.url)
        installationTokens[curated.url] = nil
        let script = getInternalDiagnosticScript()
        do {
            try script.write(to: scriptURL(for: curated.url), atomically: true, encoding: .utf8)
        } catch {
            lastError = "Не удалось сохранить код плагина."
            completion?(false, lastError)
            return
        }

        let newId = UUID()
        let newRecord = LampaPluginRecord(
            id: newId,
            url: URL(string: curated.url)!,
            name: curated.name,
            version: "1.0.0",
            author: "iLampa Test Suite",
            origin: .bundled,
            lifecycleState: .inactive,
            registeredComponents: ["diagnostic"],
            providedSourceKeys: ["diagnostic_test_source"]
        )

        installedPlugins.append(newRecord)
        persist()
        synchronizeRuntime(reason: "install internal plugin")
        completion?(true, nil)
    }

    // Adds a custom plugin by URL
    func addCustom(url rawUrl: String, operationID: UUID = UUID(), completion: ((Bool, String?) -> Void)? = nil) {
        guard !storageReadFailed else { completion?(false, lastError); return }
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !installingUrls.contains(trimmed) else { completion?(false, "Installation already in progress"); return }
        guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            let msg = "URL должен начинаться с http:// или https://"
            lastError = msg
            completion?(false, msg)
            return
        }

        guard !isInstalled(url: trimmed) else {
            let msg = "Плагин уже установлен"
            lastError = msg
            completion?(false, msg)
            return
        }

        installingUrls.insert(trimmed)
        let installationToken = operationID
        installationTokens[trimmed] = installationToken

        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.installationTokens[trimmed] == installationToken else { completion?(false, "Installation cancelled"); return }
                self.installationTasks[trimmed] = nil
                self.installingUrls.remove(trimmed)

                if let error = error {
                    let msg = "Ошибка соединения: \(error.localizedDescription)"
                    self.lastError = msg
                    completion?(false, msg)
                    return
                }

                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    completion?(false, "Plugin HTTP request failed")
                    return
                }

                guard let data = data, let script = String(data: data, encoding: .utf8), !script.isEmpty else {
                    let msg = "Получен пустой ответ от сервера"
                    self.lastError = msg
                    completion?(false, msg)
                    return
                }

                let hostName = url.host ?? "Custom Plugin"
                self.installScriptDirectly(script: script, url: url, name: hostName, author: "Custom", origin: .userCustom, completion: completion)
            }
        }
        installationTasks[trimmed] = task
        task.resume()
    }

    func toggle(plugin: LampaPluginRecord) {
        if let idx = installedPlugins.firstIndex(where: { $0.id == plugin.id }) {
            let willEnable = !installedPlugins[idx].isEnabled
            installedPlugins[idx].isEnabled = willEnable
            if willEnable { installedPlugins[idx].automaticRetryBlocked = false }
            persist()

            let urlString = plugin.url.absoluteString
            guard !urlString.isEmpty, urlString != "undefined", urlString != "null" else { return }
            if !willEnable {
                // Immediate Dynamic Invalidation of registered sources
                SourceManager.shared.unregisterSources(forPluginId: plugin.id)
                PluginCapabilityRegistry.shared.unregisterAll(for: urlString)
            }
            synchronizeRuntime(reason: "toggle \(urlString) enabled=\(willEnable)")
        }
    }

    /// A component message is evidence only of a visible Lampa component owned by a currently
    /// managed script. It never upgrades arbitrary JavaScript into a direct native resolver.
    func markComponentRegistered(urlString: String, name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let idx = installedPlugins.firstIndex(where: { $0.urlString == urlString && $0.isEligibleForAutomaticRuntime }) else { return }
        installedPlugins[idx].registeredComponents.insert(name)
        persist()

        let capability: PluginCapabilityKind = isSomaPlugin(urlString) || name == "somafm" ? .radio : .interactiveComponent
        let description: String
        if capability == .radio {
            description = "Радиостанции выбираются в исходном интерфейсе SomaFM"
        } else {
            description = "Компонент доступен в видимом интерфейсе Lampa; прямой нативный резолвер не заявлен"
        }
        let id = capability == .radio ? "somafm_radio" : "\(urlString)#component#\(name)"
        PluginCapabilityRegistry.shared.registerSource(pluginUrl: urlString, id: id,
            name: name, description: description, capability: capability, operationalStatus: .registered)
        DiagnosticsLogManager.shared.log(category: "[PluginManager]",
            message: "Component capability registered url=\(safeURLString(installedPlugins[idx].url)), name=\(name), kind=\(capability.rawValue)",
            level: .info)
    }

    /// Explicit user retry for a deterministic remote-response failure. It never runs on a
    /// lifecycle reconstruction, so a retired endpoint cannot churn every generation.
    func retry(plugin: LampaPluginRecord) {
        guard let idx = installedPlugins.firstIndex(where: { $0.id == plugin.id }),
              installedPlugins[idx].isEnabled, installedPlugins[idx].automaticRetryBlocked == true else { return }
        installedPlugins[idx].automaticRetryBlocked = false
        installedPlugins[idx].lifecycleState = .loading
        persist()
        synchronizeRuntime(reason: "explicit retry \(plugin.urlString)")
    }

    func remove(plugin: LampaPluginRecord) {
        let urlString = plugin.url.absoluteString
        if !urlString.isEmpty && urlString != "undefined" && urlString != "null" {
            PluginCapabilityRegistry.shared.unregisterAll(for: urlString)
        }
        SourceManager.shared.unregisterSources(forPluginId: plugin.id)

        let filePath = scriptURL(for: urlString)
        try? FileManager.default.removeItem(at: filePath)

        installedPlugins.removeAll(where: { $0.id == plugin.id })
        persist()
        synchronizeRuntime(reason: "remove \(urlString)")
    }

    func bulkToggleAll(enabled: Bool) {
        for idx in installedPlugins.indices {
            let plugin = installedPlugins[idx]
            installedPlugins[idx].isEnabled = enabled
            if enabled { installedPlugins[idx].automaticRetryBlocked = false }
            let urlString = plugin.url.absoluteString
            if !enabled {
                SourceManager.shared.unregisterSources(forPluginId: plugin.id)
                PluginCapabilityRegistry.shared.unregisterAll(for: urlString)
            }
        }
        persist()
        synchronizeRuntime(reason: "bulk toggle enabled=\(enabled)")
    }

    func bulkRemoveAll() {
        // Revokes batch downloads as well as URLSession callback installations.
        // A response already in flight must not repopulate an explicitly cleared inventory.
        installationEpoch = UUID()
        // This is an explicit user operation, unlike runtime invalidation on startup.
        storageReadFailed = false
        lastError = nil
        installationTokens.removeAll()
        installationTasks.values.forEach { $0.cancel() }
        installationTasks.removeAll()
        installingUrls.removeAll()
        for plugin in installedPlugins {
            let urlString = plugin.url.absoluteString
            if !urlString.isEmpty && urlString != "undefined" && urlString != "null" {
                PluginCapabilityRegistry.shared.unregisterAll(for: urlString)
            }
            SourceManager.shared.unregisterSources(forPluginId: plugin.id)
        }
        installedPlugins.removeAll()
        persist()
        synchronizeRuntime(reason: "bulk removal")
    }

    func resetToDefaults() {
        bulkRemoveAll()
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: legacyStorageKey)
        loadPlugins()
        synchronizeRuntime(reason: "reset plugins to defaults")
    }

    // MARK: - PluginLifecycleManagerProtocol

    func installPlugin(url: URL, origin: PluginOrigin) async throws -> LampaPluginRecord {
        let operationID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LampaPluginRecord, Error>) in
            let rawUrl = url.absoluteString
            if let curated = curatedPlugins.first(where: { $0.url == rawUrl }) {
                self.install(curated: curated, operationID: operationID) { success, error in
                    if success, let record = self.installedPlugins.first(where: { $0.url == url }) {
                        continuation.resume(returning: record)
                    } else {
                        continuation.resume(throwing: NSError(domain: "PluginManager", code: 400, userInfo: [NSLocalizedDescriptionKey: error ?? "Installation failed"]))
                    }
                }
            } else {
                self.addCustom(url: rawUrl, operationID: operationID) { success, error in
                    if success, let record = self.installedPlugins.first(where: { $0.url == url }) {
                        continuation.resume(returning: record)
                    } else {
                        continuation.resume(throwing: NSError(domain: "PluginManager", code: 400, userInfo: [NSLocalizedDescriptionKey: error ?? "Installation failed"]))
                    }
                }
            }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelInstallation(url: url.absoluteString, operationID: operationID) }
        })
    }

    private func cancelInstallation(url: String, operationID: UUID) {
        guard installationTokens[url] == operationID else { return }
        installationTokens[url] = nil
        installationTasks.removeValue(forKey: url)?.cancel()
        installingUrls.remove(url)
    }

    func togglePlugin(id: UUID, enabled: Bool) async throws {
        await MainActor.run {
            if let record = installedPlugins.first(where: { $0.id == id }) {
                if record.isEnabled != enabled {
                    self.toggle(plugin: record)
                }
            }
        }
    }

    func removePlugin(id: UUID) async throws {
        await MainActor.run {
            if let record = installedPlugins.first(where: { $0.id == id }) {
                self.remove(plugin: record)
            }
        }
    }

    func validatePluginCompatibility(url: URL) async -> Result<Set<String>, Error> {
        // A URL substring is not execution or component-registration evidence.
        return .failure(NSError(domain: "PluginCompatibility", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "Проверка требует выполнения плагина в готовом рантайме Lampa."]))
    }

    // MARK: - Private Execution & Storage Helpers

    func script(for runtimePlugin: RuntimePlugin) async throws -> String {
        let urlString = runtimePlugin.id
        guard let plugin = installedPlugins.first(where: { $0.urlString == urlString && $0.isEligibleForAutomaticRuntime }) else {
            throw CancellationError()
        }
        // First-party code comes from the signed application resources, never the writable cache.
        if let bundled = trustedBundledScript(urlString: urlString) { return bundled }
        if let data = try? Data(contentsOf: scriptURL(for: urlString)) {
            guard let cached = String(data: data, encoding: .utf8), !cached.isEmpty,
                  Data(cached.utf8) == data, isApproved(script: cached, for: urlString) else {
                throw PluginTrustError.approvalRequired
            }
            return cached
        }
        if let bundled = loadBundledFallback(urlString: urlString) {
            _ = saveScriptToDisk(script: bundled, forUrl: urlString)
            guard isApproved(script: bundled, for: urlString) else { throw PluginTrustError.approvalRequired }
            return bundled
        }
        var request = URLRequest(url: plugin.url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard installedPlugins.contains(where: { $0.id == plugin.id && $0.isEnabled }) else { throw CancellationError() }
        let diagnostic = pluginResponseDiagnostic(data: data, response: response, requestedURL: plugin.url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let script = String(data: data, encoding: .utf8), isAcceptablePluginScript(script, diagnostic: diagnostic) else {
            DiagnosticsLogManager.shared.log(
                category: "[PluginManager]",
                message: "Rejected plugin response url=\(safeURLString(plugin.url)): \(diagnostic.sanitizedDescription)",
                level: .error
            )
            throw PluginScriptFetchError.invalidResponse(diagnostic)
        }
        _ = saveScriptToDisk(script: script, forUrl: urlString)
        guard Data(script.utf8) == data, isApproved(script: script, for: urlString) else {
            throw PluginTrustError.approvalRequired
        }
        return script
    }

    private func scriptHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func trustedBundledScript(urlString: String) -> String? {
        switch urlString {
        case "bundled://plugins/online_mod.js", "bundled://plugins/sample_source_plugin.js",
             "bundled://plugins/soma.js", "bundled://plugins/e.js",
             "bundled://plugins/diagnostic_plugin.js", "ilampa://internal/diagnostic_plugin.js":
            return loadBundledFallback(urlString: urlString)
        default:
            return nil
        }
    }

    /// Capture this value when presenting consent and pass it back on confirmation.
    func cachedScriptSHA256(for url: String) -> String? {
        guard let data = try? Data(contentsOf: scriptURL(for: url)), !data.isEmpty,
              let script = String(data: data, encoding: .utf8), Data(script.utf8) == data else { return nil }
        return scriptHash(data)
    }

    func isApproved(script: String, for url: String) -> Bool {
        guard let record = installedPlugins.first(where: { $0.urlString == url && $0.isEligibleForAutomaticRuntime }) else { return false }
        if let bundled = trustedBundledScript(urlString: url) {
            return Data(script.utf8) == Data(bundled.utf8)
        }
        guard let approved = record.approvedScriptSHA256 else { return false }
        return scriptHash(Data(script.utf8)) == approved
    }

    func hasTrustedCachedScript(_ plugin: LampaPluginRecord) -> Bool {
        if trustedBundledScript(urlString: plugin.urlString) != nil { return true }
        guard let hash = cachedScriptSHA256(for: plugin.urlString) else { return false }
        return hash == plugin.approvedScriptSHA256
    }

    /// Fetch for a user-requested enable without granting execution or trusting a URL.
    func prepareScriptForApproval(pluginID: UUID) async throws -> String {
        guard !storageReadFailed, let plugin = installedPlugins.first(where: { $0.id == pluginID }) else { throw CancellationError() }
        if let hash = cachedScriptSHA256(for: plugin.urlString) { return hash }
        guard ["http", "https"].contains(plugin.url.scheme?.lowercased() ?? "") else { throw PluginTrustError.approvalRequired }
        var request = URLRequest(url: plugin.url)
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard installedPlugins.contains(where: { $0.id == pluginID && $0.urlString == plugin.urlString }) else { throw CancellationError() }
        let diagnostic = pluginResponseDiagnostic(data: data, response: response, requestedURL: plugin.url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let script = String(data: data, encoding: .utf8), Data(script.utf8) == data,
              isAcceptablePluginScript(script, diagnostic: diagnostic) else {
            throw PluginScriptFetchError.invalidResponse(diagnostic)
        }
        // Do not replace a cache another operation staged while this request was in flight.
        if let hash = cachedScriptSHA256(for: plugin.urlString) { return hash }
        try script.write(to: scriptURL(for: plugin.urlString), atomically: true, encoding: .utf8)
        guard let hash = cachedScriptSHA256(for: plugin.urlString) else { throw PluginTrustError.approvalRequired }
        return hash
    }

    /// Stage a new remote version without trusting or executing it.
    /// The existing approval hash deliberately remains unchanged until explicit consent.
    func stageUpdatedScriptForApproval(pluginID: UUID) async throws -> String {
        guard !storageReadFailed,
              let plugin = installedPlugins.first(where: { $0.id == pluginID }),
              ["http", "https"].contains(plugin.url.scheme?.lowercased() ?? "") else {
            throw PluginTrustError.approvalRequired
        }

        var request = URLRequest(
            url: plugin.url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.setValue("application/javascript, text/javascript, */*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard installedPlugins.contains(where: { $0.id == pluginID && $0.urlString == plugin.urlString }) else {
            throw CancellationError()
        }
        let diagnostic = pluginResponseDiagnostic(data: data, response: response, requestedURL: plugin.url)
        guard data.count > 0, data.count <= 2_000_000,
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let script = String(data: data, encoding: .utf8),
              Data(script.utf8) == data,
              isAcceptablePluginScript(script, diagnostic: diagnostic) else {
            throw PluginScriptFetchError.invalidResponse(diagnostic)
        }
        let hash = scriptHash(data)
        // The live approved cache is left intact until the user accepts this exact hash.
        try data.write(to: pendingScriptURL(for: plugin.urlString), options: .atomic)
        return hash
    }

    private func pendingScriptURL(for urlString: String) -> URL {
        scriptURL(for: urlString).appendingPathExtension("pending")
    }

    func discardStagedUpdate(pluginID: UUID) {
        guard let plugin = installedPlugins.first(where: { $0.id == pluginID }) else { return }
        try? FileManager.default.removeItem(at: pendingScriptURL(for: plugin.urlString))
    }

    @discardableResult
    func approveStagedUpdate(pluginID: UUID, expectedSHA256: String) -> Bool {
        guard !storageReadFailed,
              let plugin = installedPlugins.first(where: { $0.id == pluginID }) else { return false }
        let pending = pendingScriptURL(for: plugin.urlString)
        guard let data = try? Data(contentsOf: pending), !data.isEmpty,
              data.count <= 2_000_000, scriptHash(data) == expectedSHA256,
              let text = String(data: data, encoding: .utf8),
              Data(text.utf8) == data else {
            lastError = "Изменившийся код нельзя подтвердить. Повторите загрузку обновления."
            return false
        }

        let destination = scriptURL(for: plugin.urlString)
        let previous = try? Data(contentsOf: destination)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            lastError = "Не удалось сохранить обновление."
            return false
        }
        guard approveCachedScript(pluginID: pluginID, expectedSHA256: expectedSHA256) else {
            if let previous {
                try? previous.write(to: destination, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: destination)
            }
            return false
        }
        try? FileManager.default.removeItem(at: pending)
        return true
    }

    /// Fails closed if the staged bytes changed while the confirmation was visible.
    @discardableResult
    func approveCachedScript(pluginID: UUID, expectedSHA256: String) -> Bool {
        guard !storageReadFailed, let idx = installedPlugins.firstIndex(where: { $0.id == pluginID }) else { return false }
        guard cachedScriptSHA256(for: installedPlugins[idx].urlString) == expectedSHA256 else {
            lastError = "Код плагина изменился до подтверждения. Проверьте его снова."
            return false
        }
        lastError = nil
        installedPlugins[idx].approvedScriptSHA256 = expectedSHA256
        installedPlugins[idx].isEnabled = true
        installedPlugins[idx].automaticRetryBlocked = false
        persist()
        synchronizeRuntime(reason: "plugin content approved")
        return true
    }

    /// Diagnostic/batch paths install intent too; never evaluate outside the serialized restorer.
    func installPreparedScript(_ script: String, url: String, name: String) {
        guard !storageReadFailed else { return }
        guard let parsed = URL(string: url) else { return }
        if let existing = installedPlugins.first(where: { $0.urlString == url }) {
            DiagnosticsLogManager.shared.log(
                category: "[PluginManager]",
                message: "Ignored prepared script url=\(url); existing desiredEnabled=\(existing.isEnabled), retryBlocked=\(existing.automaticRetryBlocked == true)",
                level: .info
            )
            return
        }
        DiagnosticsLogManager.shared.log(category: "[PluginManager]", message: "Persisting explicit prepared plugin url=\(url)", level: .info)
        installScriptDirectly(script: script, url: parsed, name: name, author: nil, origin: .userCustom, completion: nil)
    }

    func invalidateRuntimeCapabilities() {
        SourceManager.shared.clearDynamicSources()
        for idx in installedPlugins.indices {
            PluginCapabilityRegistry.shared.unregisterAll(for: installedPlugins[idx].urlString)
            if installedPlugins[idx].isEnabled && installedPlugins[idx].automaticRetryBlocked != true {
                installedPlugins[idx].lifecycleState = .loading
            }
        }
        persist()
    }

    private func registerCapabilities(plugin: LampaPluginRecord) {
        let urlString = plugin.url.absoluteString
        if isSomaPlugin(urlString) {
            // SomaFM is a dedicated audio radio service, not a video provider.
            PluginCapabilityRegistry.shared.registerSource(
                pluginUrl: urlString,
                id: "somafm_radio",
                name: "SomaFM Радио (51 канал)",
                description: "51 независимый интернет-радиоканал без рекламы",
                hasExecutableResolver: true,
                capability: .radio,
                operationalStatus: .radioReady
            )
        } else if isDiagnosticPlugin(urlString) {
            PluginCapabilityRegistry.shared.registerSource(
                pluginUrl: urlString,
                id: "diagnostic_test_source",
                name: "Диагностический источник",
                description: "Проверочный источник потока для автоматизированных тестов",
                hasExecutableResolver: true,
                capability: .unsupported,
                operationalStatus: .initialized
            )
        }
    }

    private func loadBundledFallback(urlString: String) -> String? {
        let name: String
        switch urlString {
        case "https://tsynik.github.io/lampa/soma.js", "bundled://plugins/soma.js": name = "soma"
        case "https://tsynik.github.io/lampa/e.js", "bundled://plugins/e.js": name = "e"
        case "ilampa://internal/diagnostic_plugin.js", "bundled://plugins/diagnostic_plugin.js": return getInternalDiagnosticScript()
        case "bundled://plugins/online_mod.js": name = "online_mod"
        case "bundled://plugins/sample_source_plugin.js": name = "sample_source_plugin"
        default: return nil
        }
        guard let path = Bundle.main.path(forResource: name, ofType: "js", inDirectory: "plugins") ?? Bundle.main.path(forResource: name, ofType: "js") else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func isAcceptablePluginScript(_ script: String, diagnostic: PluginScriptResponseDiagnostic) -> Bool {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch diagnostic.bodyKind {
        case .html, .xml, .json, .nonText, .empty: return false
        case .scriptOrText: return true
        }
    }

    private func pluginResponseDiagnostic(data: Data, response: URLResponse, requestedURL: URL) -> PluginScriptResponseDiagnostic {
        let http = response as? HTTPURLResponse
        let contentType = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let bodyKind: PluginScriptResponseBodyKind
        if data.isEmpty {
            bodyKind = .empty
        } else if String(data: data, encoding: .utf8) == nil {
            bodyKind = .nonText
        } else {
            let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if contentType?.contains("html") == true || trimmed.hasPrefix("<!doctype") || trimmed.hasPrefix("<html") {
                bodyKind = .html
            } else if contentType?.contains("xml") == true || trimmed.hasPrefix("<?xml") {
                bodyKind = .xml
            } else if contentType?.contains("json") == true {
                bodyKind = .json
            } else {
                bodyKind = .scriptOrText
            }
        }
        return PluginScriptResponseDiagnostic(statusCode: http?.statusCode, contentType: contentType,
                                              requestedURL: safeURLString(requestedURL),
                                              finalURL: response.url.map { self.safeURLString($0) }, bodyKind: bodyKind,
                                              byteCount: data.count)
    }

    private func safeURLString(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        components.path = url.path
        return components.string ?? "unknown"
    }

    private func isSomaPlugin(_ url: String) -> Bool {
        ["https://tsynik.github.io/lampa/soma.js", "bundled://plugins/soma.js"].contains(url)
    }

    private func isOnlineModPlugin(_ url: String) -> Bool {
        url == "bundled://plugins/online_mod.js"
    }

    private func isDiagnosticPlugin(_ url: String) -> Bool {
        ["ilampa://internal/diagnostic_plugin.js", "bundled://plugins/diagnostic_plugin.js"].contains(url)
    }

    func saveScriptToDisk(script: String, forUrl urlString: String) -> String {
        let fileUrl = scriptURL(for: urlString)
        try? script.write(to: fileUrl, atomically: true, encoding: .utf8)
        return fileUrl.lastPathComponent
    }

    func scriptURL(for urlString: String) -> URL {
        let hash = SHA256.hash(data: Data(urlString.utf8)).map { String(format: "%02x", $0) }.joined()
        return pluginsDirectory.appendingPathComponent("plugin_\(hash).js")
    }

    private func getInternalDiagnosticScript() -> String {
        if let bundleUrl = Bundle.main.url(forResource: "diagnostic_plugin", withExtension: "js", subdirectory: "plugins") ?? Bundle.main.url(forResource: "diagnostic_plugin", withExtension: "js"),
           let bundleContent = try? String(contentsOfFile: bundleUrl.path, encoding: .utf8) {
            return bundleContent
        }

        // Built-in fail-safe embedded diagnostic script
        return """
        (function () {
            'use strict';
            if (typeof Lampa !== 'undefined') {
                if (Lampa.Plugins && Lampa.Plugins.add) {
                    Lampa.Plugins.add({
                        name: "Diagnostic Source Plugin",
                        version: "1.0.0",
                        type: "source"
                    });
                }
                if (Lampa.Sources && Lampa.Sources.add) {
                    Lampa.Sources.add({
                        id: "diagnostic_test_source",
                        name: "Диагностический источник",
                        description: "Проверочный источник потока для автоматизированных тестов"
                    });
                }
            }
        })();
        """
    }
}
