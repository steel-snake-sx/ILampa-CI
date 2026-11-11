import Foundation
import WebKit
import SwiftUI
import Combine

enum WebKitAttachmentMode: String, CaseIterable, Identifiable {
    case attachedUnobtrusive = "Прикреплен (1x1 pt, Скрытый)"
    case attachedVisible = "Прикреплен (Видимый)"
    case detached = "Отсоединен (window == nil)"

    var id: String { rawValue }
}

@MainActor private final class WeakRuntimeMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

enum WebKitSchedulingPolicy: String, CaseIterable, Identifiable {
    case nonePolicy = "none (.none - Без троттлинга)"
    case throttlePolicy = "throttle (.throttle - Троттлинг)"
    case suspendPolicy = "suspend (.suspend - Приостановка)"

    var id: String { rawValue }
}

struct LampaBootstrapStatus: Equatable {
    var isInitialized: Bool = false
    var hasLampaGlobal: Bool = false
    var hasJQuery: Bool = false
    var hasPluginsModule: Bool = false
    var hasPlayerModule: Bool = false
    var bootstrapError: String? = nil
    var bootstrapTimestamp: Date? = nil
}

struct DiscoveredLampaSource: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    let title: String
    let quality: String
    let isFolder: Bool
    var rowToken: String = ""
    var voice: String = ""
    var isAlternative: Bool = false
}

// Host managing the WebKit execution runtime for real Lampa JavaScript plugins.
// Evaluates WKPreferences.inactiveSchedulingPolicy, manages attachment modes,
// and bridges Lampa.Player playback events to native AVPlayer.
@MainActor final class LampaHeadlessHost: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, RuntimeExecutionBoundary {
    static let shared = LampaHeadlessHost()

    @Published private(set) var bootstrapStatus = LampaBootstrapStatus()
    @Published private(set) var isAppReady: Bool = false
    @Published var lastLifecycleMessage: String = "Ожидание инициализации"
    @Published var heartbeatCount: Int = 0
    @Published var heartbeatFrequencyHz: Double = 0.0
    @Published var lastInterceptedPayload: PlayPayload? = nil
    @Published var currentAttachmentMode: WebKitAttachmentMode = .attachedUnobtrusive
    @Published var currentSchedulingPolicy: WebKitSchedulingPolicy = .nonePolicy
    @Published private(set) var runningPlugins: [String] = []
    @Published private(set) var metadataSections: [PluginMetadataSection] = []
    @Published private(set) var legacySettings: [LegacyPluginSetting] = []
    private var metadataCapabilities: [PluginNativeCapability] = []
    private var metadataRequest: [String: String]?

    // Plugin & Source Discovery State
    @Published var lastRegisteredComponent: String? = nil
    @Published var discoveredSources: [DiscoveredLampaSource] = []
    @Published var currentOnlineModBalancer: String? = nil
    @Published var lastOnlineModEmptyReason: String? = nil
    @Published var isSearchingSources: Bool = false
    @Published private(set) var compatibilityError: String?
    @Published private(set) var activeResolutionContext: MediaResolutionContext?
    private var authorizedPlaybackContext: MediaResolutionContext?
    private var headlessSelectionRequestId: UUID?

    var onPlayRequest: ((PlayPayload) -> Void)? = nil
    var onPlaylistUpdate: ((String, [PlaylistItem]) -> Void)? = nil

    var currentGeneration: Int {
        lifecycle.generation
    }

    private(set) var webView: WKWebView?
    private var lastHeartbeatTime: TimeInterval = 0
    private var timerCompletions: [String: (Bool, Double) -> Void] = [:]
    private var activeNavigation: WKNavigation?
    private var authorizedNavigationPending = false
    private var documentToken = ""
    private var legacySnapshotClock = LegacySettingsSnapshotClock()
    private lazy var executor = RuntimeJavaScriptExecutor { [weak self] script, completion in
        guard let webView = self?.webView else { completion(nil, CancellationError()); return }
        webView.evaluateJavaScript(script, completionHandler: completion)
    }
    private var bootDeadline: DispatchWorkItem?
    private var pendingMediaRequest: [String: Any]?
    private var playbackGate = PlaybackSelectionGate()
    private let sourceDiscoveryWaiters = SourceDiscoveryWaiters<DiscoveredLampaSource>()
    private lazy var lifecycle: RuntimeLifecycleController = {
        let controller = RuntimeLifecycleController(boundary: self)
        controller.onLog = { message in
            DiagnosticsLogManager.shared.log(category: "[RuntimeLifecycle]", message: message, level: .info)
        }
        controller.onChange = { [weak self] in
            guard let self else { return }
            self.isAppReady = self.lifecycle.state == .ready
            self.runningPlugins = self.lifecycle.runningPluginIDs
            self.lastLifecycleMessage = "\(self.lifecycle.state.rawValue) generation=\(self.lifecycle.generation)"
            if self.lifecycle.state == .ready || self.lifecycle.state == .failed {
                self.bootDeadline?.cancel()
            }
            if self.lifecycle.state == .ready {
                self.updateBridgePresentation()
                self.dispatchPendingMediaRequest()
                self.dispatchMetadataRequest()
            }
        }
        controller.onInvalidate = { [weak self] in
            guard let self else { return }
            self.executor.invalidate()
            self.legacySnapshotClock.reset()
            self.isAppReady = false
            self.bootstrapStatus = LampaBootstrapStatus()
            self.discoveredSources = []
            self.isSearchingSources = false
            self.activeResolutionContext = nil
            self.authorizedPlaybackContext = nil
            self.headlessSelectionRequestId = nil
            self.lastOnlineModEmptyReason = nil
            self.sourceDiscoveryWaiters.cancelAll()
            self.lastRegisteredComponent = nil
            self.lastInterceptedPayload = nil
            self.compatibilityError = nil
            self.pendingMediaRequest = nil
            self.metadataCapabilities = []
            self.metadataSections = []
            self.legacySettings = []
            self.playbackGate.clear()
            self.authorizedNavigationPending = false
            self.activeNavigation = nil
            self.bootDeadline?.cancel()
            let completions = Array(self.timerCompletions.values)
            self.timerCompletions.removeAll()
            for completion in completions { completion(false, 0) }
            PluginManager.shared.invalidateRuntimeCapabilities()
        }
        controller.onPluginResult = { [weak self] plugin, result in
            switch result {
            case .success: PluginManager.shared.markPluginActive(urlString: plugin.id)
            case .failure(let error):
                self?.metadataCapabilities.removeAll { $0.owner == plugin.id }
                self?.metadataSections.removeAll { $0.capability.owner == plugin.id }
                self?.legacySettings.removeAll { $0.owner == plugin.id }
                let blocksAutomaticRetry = (error as? PluginScriptFetchError)?.blocksAutomaticRetry ?? false
                PluginManager.shared.markPluginFailed(urlString: plugin.id, reason: error.localizedDescription,
                                                       blockAutomaticRetry: blocksAutomaticRetry)
                if blocksAutomaticRetry {
                    // The failed record remains visible with its user enable intent, but it is
                    // excluded from subsequent unrelated reconstructions until explicitly retried.
                    PluginManager.shared.synchronizeRuntime(reason: "block invalid plugin response \(plugin.id)")
                }
            }
        }
        return controller
    }()

    private override init() {
        super.init()
        setupWebView()
        Task { PluginManager.shared.synchronizeRuntime(reason: "application launch") }
    }

    // Configures the WKWebView with iOS 18 inactive scheduling policies and security limits
    private func setupWebView() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        if #available(iOS 17.0, *) {
            switch currentSchedulingPolicy {
            case .nonePolicy:
                config.preferences.inactiveSchedulingPolicy = .none
            case .throttlePolicy:
                config.preferences.inactiveSchedulingPolicy = .throttle
            case .suspendPolicy:
                config.preferences.inactiveSchedulingPolicy = .suspend
            }
        }

        let userContentController = WKUserContentController()
        for name in ["lampaNative", "lampaSelection", "lampaLog", "lampaError", "lampaMetrics", "lampaPluginsList", "lampaLifecycle", "lampaHeartbeat", "lampaComponentRegistered", "lampaSourcesDiscovered", "lampaMetadata", "lampaSettings", "lampaPlaylist"] {
            userContentController.add(WeakRuntimeMessageHandler(self), name: name)
        }

        config.userContentController = userContentController

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.accessibilityIdentifier = "sharedLampaRuntime-\(UUID().uuidString)"
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.bounces = false
        self.webView = wv

    }

    // Bootstraps the local Lampa runtime from bundled assets
    func bootstrap() {
        lifecycle.restart(reason: "explicit refresh")
    }

    func configurePlugins(_ plugins: [RuntimePlugin], reason: String) {
        lifecycle.configure(plugins, reason: reason)
    }

    func loadCore(generation: Int) {
        guard let wv = webView else { return }
        wv.stopLoading()
        bootDeadline?.cancel()
        documentToken = UUID().uuidString
        let scripts = wv.configuration.userContentController
        scripts.removeAllUserScripts()
        let ownershipScript = """
        window.__ilampaGeneration = \(generation);
        window.__ilampaDocumentToken = '\(documentToken)';
        window.__ilampaNativeManaged = true;
        """
        scripts.addUserScript(WKUserScript(source: ownershipScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let bridgePath = Bundle.main.path(forResource: "lampa_bridge", ofType: "js"),
           let bridgeCode = try? String(contentsOfFile: bridgePath, encoding: .utf8) {
            scripts.addUserScript(WKUserScript(source: bridgeCode, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        } else {
            lifecycle.fail(generation: generation, reason: "Bridge resource missing")
            return
        }
        // Finite watchdog, not a readiness delay or an automatic retry.
        let deadline = DispatchWorkItem { [weak self] in
            self?.lifecycle.fail(generation: generation, reason: "Core/plugin initialization deadline exceeded")
        }
        bootDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: deadline)

        if let localUrl = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            authorizedNavigationPending = true
            activeNavigation = wv.loadFileURL(localUrl, allowingReadAccessTo: localUrl.deletingLastPathComponent())
        } else {
            let err = "Локальный файл www/index.html не найден в бандле"
            bootstrapStatus.bootstrapError = err
            lastLifecycleMessage = err
            DiagnosticsLogManager.shared.log(category: "[HeadlessHost]", message: err, level: .error)
            lifecycle.fail(generation: generation, reason: err)
        }
    }

    // Loads bundled plugin from local resources (Task 2)
    func loadBundledPlugin(named name: String) {
        if let path = Bundle.main.path(forResource: name, ofType: "js", inDirectory: "plugins"),
           let code = try? String(contentsOfFile: path, encoding: .utf8) {
            evaluatePluginScript(code: code, name: name, url: "bundled://plugins/\(name).js")
        } else if let path = Bundle.main.path(forResource: name, ofType: "js"),
                  let code = try? String(contentsOfFile: path, encoding: .utf8) {
            evaluatePluginScript(code: code, name: name, url: "bundled://plugins/\(name).js")
        } else {
            DiagnosticsLogManager.shared.log(category: "[HeadlessHost]", message: "Файл плагина \(name).js не найден в бандле", level: .error)
        }
    }

    // Evaluates a plugin script inside the WebKit runtime with strict error observation and stack capture
    func evaluatePluginScript(code: String, name: String, url: String) {
        PluginManager.shared.installPreparedScript(code, url: url, name: name)
    }

    func script(for plugin: RuntimePlugin) async throws -> String {
        try await PluginManager.shared.script(for: plugin)
    }

    func evaluate(script code: String, plugin: RuntimePlugin, generation: Int) async throws {
        guard lifecycle.acceptsCoreWork(generation: generation), webView != nil else { throw CancellationError() }
        guard PluginManager.shared.isApproved(script: code, for: plugin.id) else { throw PluginTrustError.approvalRequired }
        let token = documentToken
        let pluginIDLiteral = String(data: (try? JSONEncoder().encode(plugin.id)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        let wrappedCode = """
        (function() {
            if (window.__ilampaDocumentToken !== '\(token)' || window.__ilampaGeneration !== \(generation) ||
                window.appready !== true || typeof Lampa === 'undefined' || !Lampa.Player || !Lampa.Plugins) {
                return { success: false, error: 'Current core is not ready' };
            }
            var __ilampaPreviousPluginURL = window.__ilampaExecutingPluginURL;
            window.__ilampaExecutingPluginURL = \(pluginIDLiteral);
            window.__ilampaLastPluginURL = \(pluginIDLiteral);
            try {
                \(code)
                return { success: true };
            } catch (ex) {
                return {
                    success: false,
                    error: (ex && ex.message) ? ex.message : String(ex),
                    stack: (ex && ex.stack) ? ex.stack : ""
                };
            } finally {
                window.__ilampaExecutingPluginURL = __ilampaPreviousPluginURL;
            }
        })();
        """

        let result = try await executor.execute(body: "return \(wrappedCode)", generation: generation, documentToken: token) { [weak self] in
            guard let self else { return false }
            return self.documentToken == token && self.lifecycle.acceptsPluginSideEffect(plugin.id, generation: generation) &&
                PluginManager.shared.isEligibleForRuntime(urlString: plugin.id)
        }
        try Task.checkCancellation()
        guard lifecycle.acceptsCoreWork(generation: generation), token == documentToken else { throw CancellationError() }
        guard let dict = result as? [String: Any], dict["success"] as? Bool == true else {
            let reason = (result as? [String: Any])?["error"] as? String ?? "Plugin evaluation returned no result"
            throw NSError(domain: "RuntimePlugin", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
        }
    }

    // Dynamic plugin installation (downloads script via Swift URLSession to bypass CORS, then injects)
    func installPlugin(url: String, name: String) {
        PluginManager.shared.addCustom(url: url)
    }

    // Dynamic plugin toggle
    func togglePlugin(url: String, enabled: Bool) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "undefined", trimmed != "null" else {
            DiagnosticsLogManager.shared.log(category: "[HeadlessHost]", message: "Пропущено переключение некорректного URL плагина: '\(url)'", level: .warning)
            return
        }
        if let plugin = PluginManager.shared.installedPlugins.first(where: { $0.urlString == trimmed }), plugin.isEnabled != enabled {
            PluginManager.shared.toggle(plugin: plugin)
        }
    }

    // Controlled runtime restart: re-evaluates the runtime with only active plugins
    func controlledRestart(activePluginUrls: [String]) {
        // Diagnostic callers cannot override canonical persisted intent with a stale runtime list.
        lifecycle.restart(reason: "explicit controlled restart")
    }

    func refreshPluginsList() {
        runningPlugins = lifecycle.runningPluginIDs
    }

    private func replaceLegacySettings(owner: String, payload: Any, revision: Int) -> Bool {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload), data.count <= 512_000,
              let decoded = try? JSONDecoder().decode([LegacyPluginSetting].self, from: data),
              decoded.count <= 500, decoded.allSatisfy({ $0.owner == owner && $0.generation == lifecycle.generation &&
                  ["trigger", "select", "input", "title"].contains($0.type) }) else { return false }
        // Publish one replacement, not an intermediate empty owner snapshot. A transient
        // removal can destroy the active SwiftUI control while its action is in flight.
        guard legacySnapshotClock.accept(owner: owner, revision: revision) else { return false }
        legacySettings = legacySettings.filter { $0.owner != owner } + decoded
        return true
    }

    func changeLegacySetting(_ setting: LegacyPluginSetting, value: String) async throws {
        let generation = lifecycle.generation
        let token = documentToken
        guard setting.generation == generation, isAppReady, lifecycle.acceptsPluginSideEffect(setting.owner, generation: generation),
              PluginManager.shared.isEligibleForRuntime(urlString: setting.owner),
              legacySettings.contains(where: { $0.id == setting.id && $0.owner == setting.owner }),
               webView != nil else { throw LegacySettingsError.unavailable }
        let arguments: [Any] = [setting.owner, setting.id, value, generation, token]
        guard let data = try? JSONSerialization.data(withJSONObject: arguments),
              let json = String(data: data, encoding: .utf8) else { throw LegacySettingsError.unavailable }
        let result = try await executor.execute(body: "return window.LampaNativeBridge.changeLegacySetting.apply(null, \(json));",
            generation: generation, documentToken: token) { [weak self] in
                guard let self else { return false }
                return self.documentToken == token && self.isAppReady &&
                    self.lifecycle.acceptsPluginSideEffect(setting.owner, generation: generation) &&
                    PluginManager.shared.isEligibleForRuntime(urlString: setting.owner) &&
                    self.legacySettings.contains { $0.owner == setting.owner && $0.id == setting.id }
            }
        try Task.checkCancellation()
        guard lifecycle.generation == generation, documentToken == token, isAppReady,
              lifecycle.acceptsPluginSideEffect(setting.owner, generation: generation),
              PluginManager.shared.isEligibleForRuntime(urlString: setting.owner) else { throw LegacySettingsError.unavailable }
        guard let response = result as? [String: Any] else { throw LegacySettingsError.unavailable }
        if let settings = response["settings"], let revision = response["revision"] as? Int {
            _ = replaceLegacySettings(owner: setting.owner, payload: settings, revision: revision)
        }
        guard response["success"] as? Bool == true else {
            throw LegacySettingsError.failed(response["error"] as? String ?? "Неизвестная ошибка")
        }
    }

    /// Shared admission/execution protocol for ready-runtime operations. Capture
    /// request identity in `eligible`; it is rechecked at the synchronous JS turn.
    func executeRuntimeAction(_ body: String, eligible: @escaping () -> Bool = { true }) async throws -> Any? {
        let generation = lifecycle.generation
        let token = documentToken
        guard isAppReady else { throw CancellationError() }
        let result = try await executor.execute(body: body, generation: generation, documentToken: token) { [weak self] in
            guard let self else { return false }
            return self.isAppReady && self.documentToken == token &&
                self.lifecycle.acceptsCoreWork(generation: generation) && eligible()
        }
        try Task.checkCancellation()
        guard isAppReady, lifecycle.generation == generation, documentToken == token, eligible() else { throw CancellationError() }
        return result
    }

    @discardableResult
    func beginMetadata(for item: MediaItem) -> String {
        let requestId = UUID().uuidString
        metadataSections = []
        metadataRequest = ["requestId": requestId, "canonicalId": item.canonicalId,
                           "mediaType": item.canonicalType, "title": item.displayTitle,
                           "originalTitle": item.originalTitle ?? item.originalName ?? "",
                           "year": item.displayYear]
        dispatchMetadataRequest()
        return requestId
    }

    func endMetadata(requestId: String) {
        guard metadataRequest?["requestId"] == requestId else { return }
        metadataRequest = nil
        metadataSections = []
        // Request IDs are generated UUIDs, not plugin-supplied JavaScript.
        webView?.evaluateJavaScript("window.LampaNativeBridge.clearMetadata('\(requestId)');", completionHandler: nil)
    }

    private func dispatchMetadataRequest() {
        guard isAppReady, var request = metadataRequest else { return }
        // A provider may be reinvoked for the same screen when another provider
        // registers. Reject messages already queued by the superseded invocation.
        request["dispatchId"] = UUID().uuidString
        metadataRequest = request
        let allowed = metadataCapabilities.filter {
            lifecycle.acceptsPluginSideEffect($0.owner, generation: lifecycle.generation) &&
            PluginManager.shared.isEligibleForRuntime(urlString: $0.owner)
        }.map { ["owner": $0.owner, "id": $0.id] }
        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              let allowedData = try? JSONSerialization.data(withJSONObject: allowed),
              let requestJSON = String(data: requestData, encoding: .utf8),
              let allowedJSON = String(data: allowedData, encoding: .utf8) else { return }
        let dispatchID = request["dispatchId"]
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.executeRuntimeAction("window.LampaNativeBridge.requestMetadata(\(requestJSON), \(allowedJSON)); return true;") { [weak self] in
                self?.metadataRequest?["dispatchId"] == dispatchID
            }
        }
    }

    // Triggers search for a movie in Lampa (Test D / Task 3)
    func triggerMovieSearch(id: Int, title: String) {
        let actionId = ActionCorrelationTracker.shared.currentActionId
        let context = MediaResolutionContext(
            requestId: UUID(),
            actionId: actionId,
            canonicalId: "urn:media:tmdb:movie:\(id)",
            title: title,
            mediaType: "movie",
            season: nil,
            episode: nil,
            balancer: nil,
            generation: lifecycle.generation,
            revision: 1
        )
        triggerMovieSearch(context: context)
    }

    func triggerMovieSearch(item: MediaItem, season: Int?, episode: Int?, component: String? = nil) {
        let actionId = ActionCorrelationTracker.shared.currentActionId
        let context = MediaResolutionContext(
            requestId: UUID(),
            actionId: actionId,
            canonicalId: item.canonicalId,
            title: item.displayTitle,
            mediaType: item.canonicalType,
            season: season,
            episode: episode,
            balancer: component,
            generation: lifecycle.generation,
            revision: 1,
            originalTitle: item.originalTitle ?? item.originalName
        )
        triggerMovieSearch(context: context)
    }

    func triggerMovieSearch(context: MediaResolutionContext) {
        guard context.generation == currentGeneration else { return }
        sourceDiscoveryWaiters.cancelAll()
        self.activeResolutionContext = context
        self.authorizedPlaybackContext = nil
        self.headlessSelectionRequestId = nil
        self.discoveredSources.removeAll()
        self.lastInterceptedPayload = nil
        self.lastOnlineModEmptyReason = nil
        self.compatibilityError = nil
        self.isSearchingSources = true
        self.playbackGate.invalidatePending()

        var params: [String: Any] = [
            "id": Int(context.canonicalId.split(separator: ":").last ?? "0") ?? 0,
            "title": context.title,
            "mediaType": context.mediaType,
            "canonicalId": context.canonicalId,
            "requestId": context.requestId.uuidString,
            "actionId": context.actionId.uuidString,
            "component": "online_mod"
        ]
        params["season"] = context.season
        params["episode"] = context.episode
        params["original_title"] = context.originalTitle
        if let balancer = context.balancer, !balancer.isEmpty {
            params["balancer"] = balancer
        }
        queueMediaRequest(params)
    }

    func authorizePlayback(context: MediaResolutionContext) {
        self.authorizedPlaybackContext = context
        self.headlessSelectionRequestId = context.requestId
        DiagnosticsLogManager.shared.log(
            category: "[BridgeHandoff]",
            message: "Explicit playback authorized for context: \(context.contextKey)",
            level: .info
        )
    }

    /// Resolve a playlist callback only inside its original WebKit document and playback session.
    /// WKWebView's async JS API waits for the plugin callback without blocking the main actor.
    func resolvePlaylistItem(_ item: PlaylistItem, for payload: PlayPayload) async throws -> String {
        guard let requestId = payload.requestId, let itemId = item.itemId, item.deferred,
              let view = webView, let active = lastInterceptedPayload,
              active.requestId == requestId, active.playlistId == payload.playlistId,
              isAppReady else { throw CancellationError() }
        let generation = currentGeneration
        let token = documentToken
        let value = try await view.callAsyncJavaScript("""
            const bridge = window.LampaNativeBridge;
            if (!bridge || typeof bridge.resolvePlaylistItem !== 'function')
                return { success: false, error: 'resolver-unavailable' };
            return await bridge.resolvePlaylistItem(requestId, itemId);
            """, arguments: ["requestId": requestId, "itemId": itemId],
            in: nil, contentWorld: .page)
        try Task.checkCancellation()
        guard currentGeneration == generation, documentToken == token, isAppReady,
              lastInterceptedPayload?.requestId == requestId,
              let response = value as? [String: Any],
              response["success"] as? Bool == true,
              let url = response["url"] as? String else {
            throw NSError(domain: "ILampaDeferredPlaylist", code: 409,
                          userInfo: [NSLocalizedDescriptionKey: "Исходный плагин не разрешил поток серии"])
        }
        return try SourceManager.shared.sanitizeStreamUrl(url).absoluteString
    }

    func clearActiveMediaContext() {
        let generation = currentGeneration
        self.pendingMediaRequest = nil
        self.activeResolutionContext = nil
        self.authorizedPlaybackContext = nil
        self.headlessSelectionRequestId = nil
        self.lastInterceptedPayload = nil
        self.discoveredSources.removeAll()
        self.lastOnlineModEmptyReason = nil
        self.playbackGate.invalidatePending()
        self.isSearchingSources = false
        sourceDiscoveryWaiters.cancelAll()
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.executeRuntimeAction("window.LampaNativeBridge.clearActiveSearchContext(); return true;") { [weak self] in
                self?.currentGeneration == generation && self?.activeResolutionContext == nil && self?.pendingMediaRequest == nil
            }
        }
        DiagnosticsLogManager.shared.log(
            category: "[HeadlessHost]",
            message: "Active media context cleared; pending playback revoked",
            level: .info
        )
    }

    /// Asynchronously awaits discovered sources for a specific search request with bounded timeout.
    func waitForSources(requestId: String, timeout: TimeInterval = 6.0) async -> [DiscoveredLampaSource] {
        guard !Task.isCancelled, activeResolutionContext?.requestId.uuidString == requestId else { return [] }
        if !discoveredSources.isEmpty && activeResolutionContext?.requestId.uuidString == requestId {
            return discoveredSources
        }
        if lastOnlineModEmptyReason != nil && activeResolutionContext?.requestId.uuidString == requestId {
            return []
        }

        let ticket = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, activeResolutionContext?.requestId.uuidString == requestId else {
                    continuation.resume(returning: [])
                    return
                }
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let current = self.activeResolutionContext?.requestId.uuidString == requestId
                    let finished = self.sourceDiscoveryWaiters.finish(requestId: requestId, ticket: ticket,
                        values: current ? self.discoveredSources : [])
                    if finished && current && !self.sourceDiscoveryWaiters.contains(requestId: requestId) {
                        self.isSearchingSources = false
                    }
                }
                sourceDiscoveryWaiters.insert(requestId: requestId, ticket: ticket, deadline: deadline) {
                    continuation.resume(returning: $0)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.sourceDiscoveryWaiters.finish(requestId: requestId, ticket: ticket, values: [])
            }
        })
    }

    private func queueMediaRequest(_ params: [String: Any]) {
        compatibilityError = nil
        pendingMediaRequest = params
        isSearchingSources = true
        discoveredSources.removeAll()
        dispatchPendingMediaRequest()
    }

    private func dispatchPendingMediaRequest() {
        guard isAppReady, let params = pendingMediaRequest,
              let data = try? JSONSerialization.data(withJSONObject: params),
              let json = String(data: data, encoding: .utf8) else { return }
        pendingMediaRequest = nil
        guard let context = activeResolutionContext, params["requestId"] as? String == context.requestId.uuidString else { return }
        Task { [weak self] in
            guard let self else { return }
            let result = try? await self.executeRuntimeAction("return window.LampaNativeBridge.triggerMovieSearch(\(json));") { [weak self] in
                self?.activeResolutionContext == context
            }
            guard self.activeResolutionContext == context, self.currentGeneration == context.generation else { return }
            if (result as? [String: Any])?["success"] as? Bool != true {
                self.isSearchingSources = false
                self.compatibilityError = "Интерактивный источник для этой карточки недоступен. Включите совместимый онлайн-плагин в «Плагинах»."
                self.sourceDiscoveryWaiters.finish(requestId: context.requestId.uuidString, values: [])
                DiagnosticsLogManager.shared.log(category: "[CompatibilityUI]", message: "Provider UI unavailable: \(String(describing: result))", level: .warning)
            }
        }
    }

    // Activates a discovered source item via headless bridge
    // Folder navigation never creates a playback selection; callers must wait for
    // a new snapshot and separately authorize a final media row.
    func navigateDiscoveredFolder(index: Int, searchId: UUID, rowToken: String) async -> Bool {
        let result = await navigateFolderSnapshot(index: index, searchId: searchId, rowToken: rowToken)
        if case .success = result { return true }
        return false
    }

    enum FolderSnapshot {
        case success([DiscoveredLampaSource])
        case failure(String)
    }

    func navigateFolderSnapshot(index: Int, searchId: UUID, rowToken: String) async -> FolderSnapshot {
        guard isAppReady, let root = activeResolutionContext, root.requestId == searchId,
              root.generation == currentGeneration,
              rowToken.range(of: #"^[0-9]{1,18}$"#, options: .regularExpression) != nil else { return .failure("Список устарел. Начните поиск заново.") }
        let generation = lifecycle.generation
        let owner = PluginCapabilityRegistry.shared.registeredSources.first {
            $0.name == "online_mod" && $0.isEnabled && runningPlugins.contains($0.pluginUrl) &&
            PluginManager.shared.isEligibleForRuntime(urlString: $0.pluginUrl) &&
            isBundledOnlineModScript(owner: $0.pluginUrl)
        }?.pluginUrl
        let ownerLiteral = String(data: (try? JSONEncoder().encode(owner)) ?? Data("null".utf8), encoding: .utf8) ?? "null"
        let operation = UUID().uuidString
        var completed = false
        defer {
            if !completed {
                Task { [weak self] in
                    guard let self else { return }
                    _ = try? await self.executeRuntimeAction("window.LampaNativeBridge.cancelFolderOperation('\(operation)'); return true;") { [weak self] in
                        self?.activeResolutionContext == root
                    }
                }
            }
        }
        func isCurrent() -> Bool {
            !Task.isCancelled && isAppReady && lifecycle.generation == generation &&
            activeResolutionContext == root &&
            (owner == nil || (runningPlugins.contains(owner!) && PluginManager.shared.isEligibleForRuntime(urlString: owner!)))
        }
        guard let first = try? await executeRuntimeAction("return window.LampaNativeBridge.navigateHeadlessFolder(\(index), '\(searchId.uuidString)', '\(rowToken)', '\(operation)', \(ownerLiteral));", eligible: isCurrent) as? [String: Any], isCurrent() else {
            return .failure("Плагин или запрос изменился. Начните поиск заново.")
        }
        var result = first
        if result["pending"] as? Bool == true {
            for _ in 0..<120 {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return .failure("Навигация отменена.") }
                guard isCurrent(), let snapshot = try? await executeRuntimeAction("return window.LampaNativeBridge.folderOperationSnapshot('\(operation)');", eligible: isCurrent) as? [String: Any], isCurrent() else {
                    return .failure("Плагин или запрос изменился. Начните поиск заново.")
                }
                result = snapshot
                if snapshot["pending"] as? Bool != true { break }
            }
        }
        guard isCurrent(), result["success"] as? Bool == true, let rows = result["sources"] as? [[String: Any]],
              result["operationId"] == nil || (result["operationId"] as? String == operation && result["owner"] as? String == owner) else {
            let reason = result["error"] as? String
            return .failure(reason == "alternative-unverified"
                ? "Выбрана другая карточка. Плагин не подтвердил её идентификатор; вернитесь к поиску исходного произведения."
                : reason == "identity-changed" || reason == "operation-invalid"
                ? "Название или серия изменились. Проверьте выбранное произведение и начните поиск заново."
                : "Плагин не подтвердил следующие результаты. Начните поиск заново.")
        }
        let sources = rows.map { row in
            DiscoveredLampaSource(index: row["index"] as? Int ?? 0, title: row["title"] as? String ?? "",
                quality: row["quality"] as? String ?? "", isFolder: row["isFolder"] as? Bool ?? false,
                rowToken: row["rowToken"] as? String ?? "", voice: row["voice"] as? String ?? "",
                isAlternative: row["isAlternative"] as? Bool ?? false)
        }
        completed = true
        return .success(sources)
    }

    // The pagination adapter is tied to the inspected bundled source contract,
    // not to arbitrary plugins that happen to register the same component name.
    private func isBundledOnlineModScript(owner: String) -> Bool {
        let bundle = Bundle.main
        guard let bundled = bundle.url(forResource: "online_mod", withExtension: "js", subdirectory: "plugins")
                ?? bundle.url(forResource: "online_mod", withExtension: "js"),
              let expected = try? Data(contentsOf: bundled),
              let actual = try? Data(contentsOf: PluginManager.shared.scriptURL(for: owner)) else { return false }
        return !expected.isEmpty && expected == actual
    }

    func selectDiscoveredSource(index: Int, requestId: UUID, searchId: UUID, rowToken: String) async -> Bool {
        guard isAppReady, let root = activeResolutionContext, root.requestId == searchId,
              root.generation == currentGeneration, headlessSelectionRequestId == requestId,
              rowToken.range(of: #"^[0-9]{1,18}$"#, options: .regularExpression) != nil else { return false }
        let result = try? await executeRuntimeAction("return window.LampaNativeBridge.selectHeadlessSource(\(index), '\(requestId.uuidString)', '\(searchId.uuidString)', '\(rowToken)');") { [weak self] in
            self?.activeResolutionContext == root && self?.headlessSelectionRequestId == requestId
        }
        return (result as? [String: Any])?["success"] as? Bool == true
    }

    func cancelHeadlessSelection(requestId: UUID) {
        if playbackGate.pending?.requestID == requestId.uuidString { playbackGate.invalidatePending() }
        if authorizedPlaybackContext?.requestId == requestId { authorizedPlaybackContext = nil }
        if headlessSelectionRequestId == requestId { headlessSelectionRequestId = nil }
        let root = activeResolutionContext
        let generation = currentGeneration
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.executeRuntimeAction("window.LampaNativeBridge.cancelHeadlessSelection('\(requestId.uuidString)'); return true;") { [weak self] in
                self?.currentGeneration == generation && self?.activeResolutionContext == root && self?.headlessSelectionRequestId != requestId
            }
        }
    }

    // Switches the active balancer in Online Mod headlessly
    func switchOnlineModBalancer(name: String, completion: ((Bool) -> Void)? = nil) {
        guard isAppReady else { completion?(false); return }
        guard let data = try? JSONEncoder().encode(name), let literal = String(data: data, encoding: .utf8) else { completion?(false); return }
        let root = activeResolutionContext
        let generation = currentGeneration
        Task { [weak self] in
            guard let self else { completion?(false); return }
            let result = try? await self.executeRuntimeAction("return window.LampaNativeBridge.switchBalancer(\(literal));") { [weak self] in
                self?.currentGeneration == generation && self?.activeResolutionContext == root
            }
            let success = (result as? [String: Any])?["success"] as? Bool == true
            completion?(success)
        }
    }

    // Simulates plugin stream resolution to test the handoff to native AVPlayer (Test E)
    func simulateResolveAndPlay(url: String, title: String) {
        // Explicit diagnostic button only; never a resolution failure fallback.
        guard (try? SourceManager.shared.sanitizeStreamUrl(url)) != nil else { return }
        let payload = PlayPayload(action: "play", url: url, title: title, subtitle: "Diagnostic stream",
                                  time: 0, duration: 0, hash: nil, canonicalId: "diagnostic:explicit",
                                  mediaType: "movie", season: nil, episode: nil, currentQuality: nil,
                                  currentStudio: nil, availableQualities: nil, availableStudios: nil,
                                  availableSubtitles: nil, playlist: nil, isDiagnostic: true)
        lastInterceptedPayload = payload
        onPlayRequest?(payload)
    }

    // Stops any residual HTML5 audio/video playing in WebKit
    func stopAllMedia() {
        webView?.evaluateJavaScript("window.LampaNativeBridge.stopAllMedia();", completionHandler: nil)
    }

    // Tests delayed execution (timer) under current scheduling policy and attachment mode
    func testDelayedTimer(delaySeconds: Double, completion: @escaping (Bool, Double) -> Void) {
        guard lifecycle.acceptsCoreWork(generation: lifecycle.generation) else { completion(false, 0); return }
        let callbackId = UUID().uuidString
        self.timerCompletions[callbackId] = completion
        let ms = Int(delaySeconds * 1000)
        let js = "window.LampaNativeBridge.testTimer(\(ms), '\(callbackId)');"
        webView?.evaluateJavaScript(js) { [weak self] _, error in
            if error != nil, let completion = self?.timerCompletions.removeValue(forKey: callbackId) {
                completion(false, 0)
            }
        }
    }

    // Updates scheduling policy dynamically to prove iOS 18 behavior
    func updateSchedulingPolicy(_ policy: WebKitSchedulingPolicy) {
        self.currentSchedulingPolicy = policy
        if #available(iOS 17.0, *) {
            switch policy {
            case .nonePolicy: webView?.configuration.preferences.inactiveSchedulingPolicy = .none
            case .throttlePolicy: webView?.configuration.preferences.inactiveSchedulingPolicy = .throttle
            case .suspendPolicy: webView?.configuration.preferences.inactiveSchedulingPolicy = .suspend
            }
        }
    }

    // Updates attachment mode
    func setAttachmentMode(_ mode: WebKitAttachmentMode) {
        self.currentAttachmentMode = mode
        if mode == .detached { playbackGate.clear(); pendingMediaRequest = nil }
        updateBridgePresentation()
        dispatchPendingMediaRequest()
    }

    private func updateBridgePresentation() {
        guard lifecycle.acceptsCoreWork(generation: lifecycle.generation) else { return }
        let visible = currentAttachmentMode == .attachedVisible && isAppReady
        webView?.evaluateJavaScript("window.LampaNativeBridge.setPresentation(\(visible));", completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard prompt == RuntimeJavaScriptExecutor.prompt, webView === self.webView, frame.isMainFrame,
              let data = defaultText?.data(using: .utf8),
              let ticket = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = ticket["id"] as? String, let generation = ticket["generation"] as? Int,
              let token = ticket["documentToken"] as? String, token == documentToken,
              executor.authorize(id: id, generation: generation, documentToken: token) else {
            completionHandler(nil); return
        }
        completionHandler(id)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === activeNavigation else { return }
        let generation = lifecycle.generation
        lifecycle.navigationFinished(generation: generation)
        DiagnosticsLogManager.shared.log(category: "[HeadlessHost]", message: "Navigation completed generation=\(generation)", level: .info)
        // Document completion is not bridge/core readiness. Only the current bridge's
        // explicit handshake may start restoration, after its player/request hooks are installed.
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, navigation === activeNavigation,
              (error as NSError).code != NSURLErrorCancelled else { return }
        lifecycle.fail(generation: lifecycle.generation, reason: error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        guard navigationAction.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        let target = navigationAction.request.url
        let local = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www")
        if authorizedNavigationPending, target == local {
            authorizedNavigationPending = false
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, let target, ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(target)
        } else {
            lifecycle.restart(reason: "unexpected main-document navigation type=\(navigationAction.navigationType.rawValue)", automatic: true)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        lifecycle.restart(reason: "WebKit content process terminated", automatic: true)
    }

    private func acceptCoreReady(_ dict: [String: Any]) {
        guard dict["hasLampa"] as? Bool == true, dict["hasJQuery"] as? Bool == true,
              dict["hasPlugins"] as? Bool == true, dict["hasPlayer"] as? Bool == true else { return }
        bootstrapStatus = LampaBootstrapStatus(isInitialized: true, hasLampaGlobal: true, hasJQuery: true,
                                               hasPluginsModule: true, hasPlayerModule: true,
                                               bootstrapError: nil, bootstrapTimestamp: Date())
        lifecycle.coreReady(generation: lifecycle.generation)
        updateBridgePresentation()
    }

    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let envelope = message.body as? [String: Any],
              envelope["generation"] as? Int == lifecycle.generation,
              envelope["documentToken"] as? String == documentToken else { return }
        if message.name == "lampaSettings" {
            guard let owner = envelope["owner"] as? String,
                  lifecycle.acceptsPluginSideEffect(owner, generation: lifecycle.generation),
                  PluginManager.shared.isEligibleForRuntime(urlString: owner),
                  let settings = envelope["settings"], let revision = envelope["revision"] as? Int else { return }
            _ = replaceLegacySettings(owner: owner, payload: settings, revision: revision)
            return
        }
        if message.name == "lampaMetadata" {
            guard let owner = envelope["owner"] as? String, let id = envelope["id"] as? String,
                  id.range(of: "^[a-zA-Z0-9_.-]{1,80}$", options: .regularExpression) != nil,
                  lifecycle.acceptsPluginSideEffect(owner, generation: lifecycle.generation),
                  PluginManager.shared.isEligibleForRuntime(urlString: owner) else { return }
            if envelope["action"] as? String == "register", envelope["type"] as? String == "mediaDetail" {
                let capability = PluginNativeCapability(owner: owner, generation: lifecycle.generation, id: id,
                                                        kind: .mediaDetail, contract: .structuredMetadata)
                if !metadataCapabilities.contains(capability) { metadataCapabilities.append(capability) }
                if isAppReady { dispatchMetadataRequest() }
                return
            }
            guard isAppReady, let capability = metadataCapabilities.first(where: { $0.id == id && $0.owner == owner && $0.generation == lifecycle.generation }),
                  let request = metadataRequest, envelope["requestId"] as? String == request["requestId"],
                  let dispatchId = request["dispatchId"], envelope["dispatchId"] as? String == dispatchId,
                  let canonicalId = request["canonicalId"], envelope["canonicalId"] as? String == canonicalId else { return }
            if envelope["action"] as? String == "remove" {
                metadataSections.removeAll { $0.capability == capability }
            } else if envelope["action"] as? String == "update", let section = PluginMetadataSection.decode(envelope, capability: capability, canonicalId: canonicalId) {
                var next = metadataSections.filter { $0.capability != capability }
                next.append(section)
                next.sort { $0.id < $1.id }
                metadataSections = next
            }
            return
        }
        if message.name == "lampaLifecycle", let dict = message.body as? [String: Any] {
            if let status = dict["status"] as? String, status == "timerCompleted" {
                let elapsed = dict["elapsed"] as? Double ?? 0.0
                let callbackId = dict["callbackId"] as? String ?? ""
                if let completion = self.timerCompletions.removeValue(forKey: callbackId) {
                    completion(true, elapsed)
                }
                return
            }

            if dict["status"] as? String == "ready" { acceptCoreReady(dict) }
            return
        }

        if message.name == "lampaHeartbeat", let dict = message.body as? [String: Any] {
            let ticks = dict["ticks"] as? Int ?? 0
            let now = Date().timeIntervalSince1970

                self.heartbeatCount = ticks
                if self.lastHeartbeatTime > 0 {
                    let delta = now - self.lastHeartbeatTime
                    if delta > 0 {
                        let hz = 1.0 / delta
                        self.heartbeatFrequencyHz = (self.heartbeatFrequencyHz * 0.7) + (hz * 0.3)
                    }
                }
                self.lastHeartbeatTime = now
            return
        }

        if message.name == "lampaComponentRegistered", let dict = message.body as? [String: Any] {
            let isPlatform = dict["isPlatform"] as? Bool ?? false
            let name = dict["name"] as? String ?? ""
            let pluginURL = dict["pluginUrl"] as? String

            // Strict Platform-level component isolation (CUB Sport, Shots feed, Lampa core)
            if isPlatform || name.hasPrefix("cub_") || name.hasPrefix("shots_") || name == "main" || name == "settings" {
                DiagnosticsLogManager.shared.log(category: "[HeadlessHost]",
                    message: "Зарегистрирован платформенный компонент Lampa: «\(name)» (не привязан к плагинам)",
                    level: .info)
                self.lastRegisteredComponent = name
                return
            }

            guard let resolvedURL = pluginURL,
                  lifecycle.acceptsPluginSideEffect(resolvedURL, generation: lifecycle.generation),
                  PluginManager.shared.isEligibleForRuntime(urlString: resolvedURL) else {
                DiagnosticsLogManager.shared.log(category: "[HeadlessHost]",
                    message: "Зарегистрирован компонент без подтверждённого активного владельца: \(name)",
                    level: .info)
                return
            }
            self.lastRegisteredComponent = name
            self.lastLifecycleMessage = "Компонент Lampa зарегистрирован: «" + name + "»"
            DiagnosticsLogManager.shared.log(category: "[HeadlessHost]", message: "Плагин зарегистрировал компонент: «" + name + "»", level: .success)
            PluginManager.shared.markComponentRegistered(urlString: resolvedURL, name: name)

            if name == "somafm" {
                SourceManager.shared.updateOperationalStatus(sourceKey: "somafm_radio", status: .initialized)
                PluginCapabilityRegistry.shared.updateOperationalStatus(id: "somafm_radio", status: .initialized)
            }
            return
        }

        if message.name == "lampaSourcesDiscovered", let dict = message.body as? [String: Any] {
            guard isAppReady else { return }

            // Strict resolution context match: drop stale or mismatched discovery
            if let activeContext = activeResolutionContext,
               activeContext.generation == currentGeneration,
               let discoveryCanonicalId = dict["canonicalId"] as? String,
               let discoveryRequestId = dict["requestId"] as? String {
                guard discoveryCanonicalId == activeContext.canonicalId else {
                    DiagnosticsLogManager.shared.log(
                        category: "[HeadlessHost]",
                        message: "Rejected stale source discovery: candidate=\(discoveryCanonicalId) vs active=\(activeContext.canonicalId)",
                        level: .warning
                    )
                    return
                }
                if discoveryRequestId != activeContext.requestId.uuidString ||
                    dict["mediaType"] as? String != activeContext.mediaType ||
                    dict["season"] as? Int != activeContext.season || dict["episode"] as? Int != activeContext.episode {
                    DiagnosticsLogManager.shared.log(
                        category: "[HeadlessHost]",
                        message: "Rejected superseded source discovery request",
                        level: .warning
                    )
                    return
                }
            } else { return }

            if let balancer = dict["balancer"] as? String, !balancer.isEmpty {
                self.currentOnlineModBalancer = balancer
            }
            if let empty = dict["emptyReason"] as? String, !empty.isEmpty {
                self.lastOnlineModEmptyReason = empty
            } else if dict["count"] as? Int ?? 0 > 0 {
                self.lastOnlineModEmptyReason = nil
            }
            if let sources = dict["sources"] as? [[String: Any]] {
                self.discoveredSources = sources.compactMap { d in
                    DiscoveredLampaSource(
                        index: d["index"] as? Int ?? 0,
                        title: d["title"] as? String ?? "",
                        quality: d["quality"] as? String ?? "",
                        isFolder: d["isFolder"] as? Bool ?? false,
                        rowToken: d["rowToken"] as? String ?? "",
                        voice: d["voice"] as? String ?? "",
                        isAlternative: d["isAlternative"] as? Bool ?? false
                    )
                }
                DiagnosticsLogManager.shared.log(
                    category: "[HeadlessHost]",
                    message: "Headless sources discovered count=\(self.discoveredSources.count) balancer=\(self.currentOnlineModBalancer ?? "none") emptyReason=\(self.lastOnlineModEmptyReason ?? "none")",
                    level: .info
                )
            }
            if !self.discoveredSources.isEmpty || self.lastOnlineModEmptyReason != nil {
                self.isSearchingSources = false
                if let activeReq = self.activeResolutionContext?.requestId.uuidString {
                    self.sourceDiscoveryWaiters.finish(requestId: activeReq, values: self.discoveredSources)
                }
            }
            return
        }

        if message.name == "lampaLog", let dict = message.body as? [String: Any] {
            let level = dict["level"] as? String ?? "info"
            let msg = dict["message"] as? String ?? ""
            let diagLevel: DiagnosticLogEntry.LogLevel = (level == "error") ? .error : ((level == "warn") ? .warning : .info)
            DiagnosticsLogManager.shared.log(category: "[LampaJS]", message: msg, level: diagLevel)
            return
        }

        if message.name == "lampaError", let dict = message.body as? [String: Any] {
            let msg = dict["message"] as? String ?? ""
            let source = dict["source"] as? String ?? ""
            let line = dict["line"] as? Int ?? 0
            let col = dict["col"] as? Int ?? 0
            DiagnosticsLogManager.shared.log(category: "[JSException]", message: "\(msg) (\(source):\(line):\(col))", level: .error)
            return
        }

        if message.name == "lampaPluginsList" {
            // Upstream metadata is not execution acknowledgment and cannot own native plugin state.
            return
        }

        if message.name == "lampaSelection" {
            guard isAppReady,
                  let requestID = envelope["requestId"] as? String,
                  let canonicalID = envelope["canonicalId"] as? String,
                  let mediaType = envelope["mediaType"] as? String,
                  let pluginID = envelope["pluginId"] as? String,
                  let context = envelope["selectionContext"] as? String else { return }
            if context == "headless_native_bridge" {
                guard let authorized = authorizedPlaybackContext,
                      requestID == authorized.requestId.uuidString,
                      canonicalID == authorized.canonicalId, mediaType == authorized.mediaType,
                      (envelope["season"] as? Int) == authorized.season,
                      (envelope["episode"] as? Int) == authorized.episode else { return }
            }
            playbackGate.select(.init(requestID: requestID, canonicalID: canonicalID, mediaType: mediaType,
                                      pluginID: pluginID, context: context, generation: lifecycle.generation,
                                      createdAt: Date(), season: envelope["season"] as? Int,
                                      episode: envelope["episode"] as? Int, audio: envelope["audio"] as? String),
                                isVisible: currentAttachmentMode == .attachedVisible)
            return
        }

        if message.name == "lampaPlaylist", let body = message.body as? [String: Any],
           let requestId = body["requestId"] as? String,
           let playlistId = body["playlistId"] as? String,
           let items = body["playlist"],
           var active = lastInterceptedPayload,
           active.requestId == requestId, active.playlistId == playlistId,
           let data = try? JSONSerialization.data(withJSONObject: items),
           let playlist = try? JSONDecoder().decode([PlaylistItem].self, from: data) {
            active.playlist = playlist
            lastInterceptedPayload = active
            onPlaylistUpdate?(requestId, playlist)
            return
        }

        if message.name == "lampaNative", let body = message.body as? [String: Any] {
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: body, options: [])
                var payload = try JSONDecoder().decode(PlayPayload.self, from: jsonData)
                guard isAppReady,
                      let selection = playbackGate.consumeSelection(payload, generation: lifecycle.generation, isVisible: currentAttachmentMode == .attachedVisible) else {
                    DiagnosticsLogManager.shared.log(category: "[BridgeHandoff]", message: "Rejected unsolicited, stale or mismatched playback", level: .warning)
                    return
                }

                // Only these bridge contexts source audio from the selected Online Mod row's
                // explicit voice fields. Do not treat an arbitrary currentStudio ID as a label.
                payload.currentStudioName = selection.selectedVoiceName

                // Strict resolution context match
                if let activeContext = activeResolutionContext {
                    guard activeContext.matches(canonicalId: payload.canonicalId, season: payload.season, episode: payload.episode) else {
                        let reason = activeContext.rejectionReason(canonicalId: payload.canonicalId, season: payload.season, episode: payload.episode) ?? "Context mismatch"
                        DiagnosticsLogManager.shared.log(category: "[BridgeHandoff]", message: "Rejected stream: \(reason)", level: .warning)
                        return
                    }
                }

                _ = try SourceManager.shared.sanitizeStreamUrl(payload.url)

                // Defense-in-depth: Reject any Apple Aerial screensaver video resource
                let urlLower = payload.url.lowercased()
                if urlLower.contains("sylvan.apple.com") || urlLower.contains("orangejedi/aerial") || urlLower.contains("/videos/aerial") {
                    DiagnosticsLogManager.shared.log(
                        category: "[BridgeHandoff]",
                        message: "Rejected screensaver playback",
                        level: .warning
                    )
                    return
                }

                DiagnosticsLogManager.shared.log(
                    category: "[BridgeHandoff]",
                    message: "Selected stream handoff plugin=\(payload.pluginId ?? "none") request=\(payload.requestId ?? "none") generation=\(lifecycle.generation)",
                    level: .success
                )

                self.lastInterceptedPayload = payload

                // Only start native playback if explicit user playback authorization was granted!
                if payload.selectionContext == "headless_native_bridge" {
                    // The waiting native selection task owns the one playback handoff.
                    // Do not also present the player from this callback.
                    authorizedPlaybackContext = nil
                } else if let authContext = authorizedPlaybackContext,
                   authContext.matches(canonicalId: payload.canonicalId, season: payload.season, episode: payload.episode) {
                    self.authorizedPlaybackContext = nil
                    self.onPlayRequest?(payload)
                } else {
                    DiagnosticsLogManager.shared.log(
                        category: "[BridgeHandoff]",
                        message: "Stream payload stored for on-demand resolution (no auto-playback during discovery)",
                        level: .info
                    )
                }

                if payload.url.contains("somafm") {
                    PluginCapabilityRegistry.shared.updateOperationalStatus(id: "somafm_radio", status: .streamResolved)
                }
            } catch let decodingError as DecodingError {
                let errorDetails: String
                switch decodingError {
                case .keyNotFound(let key, let context):
                    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                    errorDetails = "Отсутствует ключ '\(key.stringValue)' по пути '\(path)': \(context.debugDescription)"
                case .typeMismatch(let type, let context):
                    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                    errorDetails = "Несовпадение типа для '\(type)' по пути '\(path)': \(context.debugDescription)"
                case .valueNotFound(let type, let context):
                    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                    errorDetails = "Значение null для '\(type)' по пути '\(path)': \(context.debugDescription)"
                case .dataCorrupted(let context):
                    let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                    errorDetails = "Данные повреждены по пути '\(path)': \(context.debugDescription)"
                @unknown default:
                    errorDetails = decodingError.localizedDescription
                }
                DiagnosticsLogManager.shared.log(category: "[BridgeHandoff]", message: "Ошибка декодирования PlayPayload: \(errorDetails)", level: .error)
            } catch {
                DiagnosticsLogManager.shared.log(category: "[BridgeHandoff]", message: "Ошибка сериализации PlayPayload: \(error.localizedDescription)", level: .error)
            }
        }
    }
}

// SwiftUI view embedding the WebKit container according to the chosen attachment mode
struct LampaHostContainerView: UIViewRepresentable {
    @ObservedObject var host = LampaHeadlessHost.shared
    var isInteractive: Bool = false

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        updateHierarchy(container: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        updateHierarchy(container: uiView)
    }

    private func updateHierarchy(container: UIView) {
        guard let wv = host.webView else { return }
        switch host.currentAttachmentMode {
        case .detached:
            if wv.superview != nil {
                wv.removeFromSuperview()
            }
            container.isUserInteractionEnabled = false
        case .attachedUnobtrusive:
            guard !isInteractive else { container.isUserInteractionEnabled = false; return }
            if wv.superview != container {
                wv.removeFromSuperview()
                wv.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(wv)
                NSLayoutConstraint.activate([
                    wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    wv.topAnchor.constraint(equalTo: container.topAnchor),
                    wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])
            }
            container.isUserInteractionEnabled = false
            wv.isUserInteractionEnabled = false

        case .attachedVisible:
            guard isInteractive else { container.isUserInteractionEnabled = false; return }
            if wv.superview != container {
                wv.removeFromSuperview()
                wv.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(wv)
                NSLayoutConstraint.activate([
                    wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    wv.topAnchor.constraint(equalTo: container.topAnchor),
                    wv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])
            }
            container.isUserInteractionEnabled = host.isAppReady
            wv.isUserInteractionEnabled = host.isAppReady
        }
    }
}
