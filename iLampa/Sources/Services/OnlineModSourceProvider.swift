import Foundation

/// Capability state for Online Mod, reflecting the realistic limitation analysis.
/// Online Mod backends use anti-bot session tokens, obfuscated host resolution,
/// and balancer-specific APIs.
enum OnlineModCapabilityState: Equatable {
    /// Plugin is not installed or not enabled.
    case notInstalled
    /// The JS runtime is still initializing.
    case initializing
    /// Headless JS runtime is available with supported balance backends.
    case headlessBridgeAvailable(currentBalancer: String, availableBalancers: [String])
    /// A specific backend has returned direct stream URLs.
    case streamResolved(balancer: String, quality: String)
    /// A specific backend returned no matches for the requested media.
    case noMatches(balancer: String, reason: String)
    /// The plugin failed to initialize.
    case failed(reason: String)

    var userFacingDescription: String {
        switch self {
        case .notInstalled:
            return "Онлайн-мод не установлен. Добавьте его в разделе «Плагины»."
        case .initializing:
            return "Онлайн-мод инициализируется в JS-среде…"
        case .headlessBridgeAvailable(let current, let available):
            return "Онлайн-мод подключён через нативный headless-мост. Активный балансер: \(current). Доступно: \(available.joined(separator: ", "))"
        case .streamResolved(let balancer, let quality):
            return "\(balancer): поток разрешен (\(quality))."
        case .noMatches(let balancer, let reason):
            return "\(balancer): \(reason)"
        case .failed(let reason):
            return "Онлайн-мод: ошибка инициализации — \(reason)"
        }
    }

    var operationalStatus: ProviderOperationalStatus {
        switch self {
        case .notInstalled: return .unconfigured
        case .initializing: return .initialized
        case .headlessBridgeAvailable: return .searchAvailable
        case .streamResolved: return .streamResolved
        case .noMatches: return .noMatchingTitles
        case .failed: return .connectionFailed
        }
    }
}

/// Structured native provider adapter for Online Mod.
/// Communicates with the headless Lampa JavaScript runtime via typed bridge calls.
/// All user interaction occurs in native SwiftUI — no WKWebView is presented for media playback.
@MainActor
final class OnlineModSourceProvider: SourceProviderProtocol {
    var providerId: String { "online_mod" }
    var displayName: String { "Онлайн-балансеры (Online Mod)" }
    var supportedContentDescription: String { "Балансеры контента (HDRezka, Filmix, Collaps, CDNVideoHub)" }
    var operationalStatus: ProviderOperationalStatus = .registered

    /// Can resolve directly when the plugin is installed and enabled.
    var canResolveDirectly: Bool {
        isConfigured
    }

    var isConfigured: Bool {
        return PluginManager.shared.installedPlugins.contains { plugin in
            (plugin.urlString == "bundled://plugins/online_mod.js" ||
             plugin.urlString.contains("online_mod") ||
             plugin.urlString.contains("online.js")) &&
            plugin.isEligibleForAutomaticRuntime
        }
    }

    /// Current capability state assessed from plugin manager and runtime state.
    private(set) var capabilityState: OnlineModCapabilityState = .notInstalled

    /// Supported and tested balance backends (we do not advertise untested backends).
    static let supportedBalancers = ["cdnvideohub", "rezka2", "collaps", "filmix"]

    func refreshConfigurationStatus() {
        capabilityState = assessCapabilityState()
        operationalStatus = capabilityState.operationalStatus
    }

    func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
        refreshConfigurationStatus()
        guard isConfigured else {
            DiagnosticsLogManager.shared.log(
                category: "[OnlineMod]",
                message: "Провайдер не готов к поиску: \(capabilityState.userFacingDescription)",
                level: .info
            )
            return []
        }

        let host = LampaHeadlessHost.shared
        if !host.isAppReady {
            var waitElapsed: Double = 0
            while !host.isAppReady && waitElapsed < 12.0 {
                try await Task.sleep(nanoseconds: 100_000_000)
                try Task.checkCancellation()
                waitElapsed += 0.1
            }
        }
        guard host.isAppReady else {
            DiagnosticsLogManager.shared.log(
                category: "[OnlineMod]",
                message: "Headless-хост не готов к поиску (таймаут инициализации)",
                level: .warning
            )
            return []
        }

        guard let plugin = PluginManager.shared.installedPlugins.first(where: {
            ($0.urlString == "bundled://plugins/online_mod.js" ||
             $0.urlString.contains("online_mod") ||
             $0.urlString.contains("online.js")) && $0.isEligibleForAutomaticRuntime
        }) else { return [] }

        // The Core ready flag precedes optional JavaScript plugin restoration.
        // Do not start discovery until the enabled Online Mod was loaded into WebKit.
        var pluginWait = 0
        while !host.runningPlugins.contains(plugin.urlString) && pluginWait < 120 {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            pluginWait += 1
        }
        guard host.runningPlugins.contains(plugin.urlString) else {
            operationalStatus = .initialized
            DiagnosticsLogManager.shared.log(
                category: "[OnlineMod]",
                message: "Online Mod ещё не загружен в WebKit. Проверьте его включение и журнал плагинов.",
                level: .warning
            )
            return []
        }
        let currentBalancer = host.currentOnlineModBalancer ?? "CDNVideoHub"
        let actionId = ActionCorrelationTracker.shared.startAction(
            name: "OnlineModSearch",
            metadata: ["canonicalId": item.canonicalId, "balancer": currentBalancer]
        )

        let reqId = UUID()
        let resolutionContext = MediaResolutionContext(
            requestId: reqId,
            actionId: actionId,
            canonicalId: item.canonicalId,
            title: item.displayTitle,
            mediaType: item.canonicalType,
            season: season,
            episode: episode,
            balancer: currentBalancer,
            generation: host.currentGeneration,
            revision: 1,
            originalTitle: item.originalTitle ?? item.originalName
        )

        DiagnosticsLogManager.shared.log(
            category: "[OnlineMod]",
            message: "Запуск нативного поиска «\(item.displayTitle)» через \(currentBalancer) (reqId=\(reqId.uuidString.prefix(8)))...",
            level: .info
        )

        // Dispatch headless search in the hidden WebKit environment
        host.triggerMovieSearch(context: resolutionContext)

        // Bounded wait for discovered candidates via continuation
        // Network-backed balancers may take several seconds after WebKit core readiness.
        let discovered = await host.waitForSources(requestId: reqId.uuidString, timeout: 15.0)
        try Task.checkCancellation()
        guard host.isAppReady, host.currentGeneration == resolutionContext.generation,
              host.activeResolutionContext == resolutionContext else { throw CancellationError() }
        DiagnosticsLogManager.shared.log(category: "[PlaybackStage]", message: "Source discovery completed", level: .info,
            actionId: actionId, metadata: ["stage": "discovery", "count": String(discovered.count), "discoveryId": reqId.uuidString])

        // Check if an empty state was detected by the headless bridge
        if let emptyReason = host.lastOnlineModEmptyReason, !emptyReason.isEmpty, discovered.isEmpty {
            let reason = "\(currentBalancer): \(emptyReason)"
            capabilityState = .noMatches(balancer: currentBalancer, reason: emptyReason)
            operationalStatus = .noMatchingTitles
            DiagnosticsLogManager.shared.log(
                category: "[OnlineMod]",
                message: "\(reason) для «\(item.displayTitle)»",
                level: .info
            )
            return []
        }

        if discovered.isEmpty {
            let reason = "\(currentBalancer): совпадений не найдено для «\(item.displayTitle)»"
            capabilityState = .noMatches(balancer: currentBalancer, reason: "Совпадений не найдено")
            operationalStatus = .noMatchingTitles
            DiagnosticsLogManager.shared.log(
                category: "[OnlineMod]",
                message: reason,
                level: .info
            )
            return []
        }

        DiagnosticsLogManager.shared.log(
            category: "[OnlineMod]",
            message: "\(currentBalancer): обнаружено \(discovered.count) вариантов источников.",
            level: .info
        )

        let candidates = Self.mapDiscoveredSources(discovered, item: item, season: season, episode: episode, balancer: currentBalancer, requestId: reqId)
        guard !candidates.isEmpty else {
            capabilityState = .noMatches(balancer: currentBalancer, reason: "Найдены только разделы, доступные в интерфейсе плагина")
            operationalStatus = .noMatchingTitles
            return []
        }
        operationalStatus = .resultsFound
        capabilityState = .headlessBridgeAvailable(currentBalancer: currentBalancer, availableBalancers: Self.supportedBalancers)
        return candidates
    }

    static func mapDiscoveredSources(_ discovered: [DiscoveredLampaSource], item: MediaItem, season: Int?, episode: Int?, balancer: String, requestId: UUID) -> [ResolvedMediaSource] {
        discovered.filter { !$0.rowToken.isEmpty }.map { disc in
            return ResolvedMediaSource(
                id: "online_mod_\(requestId.uuidString)_\(disc.rowToken)",
                providerName: "Online Mod (\(balancer))",
                title: disc.title.isEmpty ? "\(item.displayTitle) - Вариант \(disc.index + 1)" : disc.title,
                quality: disc.quality,
                studioId: disc.voice.lowercased(),
                studioName: disc.voice,
                streamUrl: "", // On-demand stream resolution when user selects to play
                isHls: false,
                container: "",
                season: season,
                episode: episode,
                isDiagnostic: false,
                providerId: "online_mod",
                canonicalMediaId: item.canonicalId,
                discoveryRequestId: requestId,
                discoveryRowToken: disc.rowToken,
                discoveryRowIndex: disc.index,
                isNavigationFolder: disc.isFolder,
                isAlternativeTitle: disc.isAlternative
            )
        }
    }

    /// Resolves the concrete playback payload on demand when the user explicitly triggers playback.
    func resolveStream(for source: ResolvedMediaSource, context: MediaResolutionContext) async throws -> PlayPayload {
        guard let index = source.discoveryRowIndex, let searchId = source.discoveryRequestId,
              let rowToken = source.discoveryRowToken, !rowToken.isEmpty else {
            throw NSError(domain: "OnlineMod", code: 400, userInfo: [NSLocalizedDescriptionKey: "Недопустимый индекс источника"])
        }

        let host = LampaHeadlessHost.shared
        guard let active = host.activeResolutionContext, active.requestId == searchId,
              active.generation == host.currentGeneration, context.generation == active.generation,
              active.canonicalId == context.canonicalId, active.mediaType == context.mediaType,
              active.season == context.season, active.episode == context.episode else {
            DiagnosticsLogManager.shared.log(category: "[PlaybackStage]", message: "Discovery context expired", level: .warning,
                actionId: context.actionId, metadata: ["stage": "selection_rejected", "sourceIndex": String(index), "discoveryId": searchId.uuidString])
            throw NSError(domain: "OnlineMod", code: 409, userInfo: [NSLocalizedDescriptionKey: "Список источников изменился. Обновите поиск."])
        }
        host.lastInterceptedPayload = nil
        host.authorizePlayback(context: context)
        defer { host.cancelHeadlessSelection(requestId: context.requestId) }

        let currentBalancer = host.currentOnlineModBalancer ?? "CDNVideoHub"
        DiagnosticsLogManager.shared.log(
            category: "[OnlineMod]",
            message: "\(currentBalancer): явное разрешение потока для варианта #\(index)...",
            level: .info
        )

        DiagnosticsLogManager.shared.log(category: "[PlaybackStage]", message: "Source selected", level: .info,
            actionId: context.actionId, metadata: ["stage": "selection", "sourceIndex": String(index), "discoveryId": searchId.uuidString])
        let selected = await host.selectDiscoveredSource(index: index, requestId: context.requestId, searchId: searchId, rowToken: rowToken)
        try Task.checkCancellation()
        guard host.isAppReady, host.currentGeneration == active.generation,
              host.activeResolutionContext == active else { throw CancellationError() }
        guard selected else {
            DiagnosticsLogManager.shared.log(category: "[PlaybackStage]", message: "Source selection rejected", level: .warning,
                actionId: context.actionId, metadata: ["stage": "selection_rejected", "sourceIndex": String(index), "discoveryId": searchId.uuidString])
            throw NSError(domain: "OnlineMod", code: 409, userInfo: [NSLocalizedDescriptionKey: "Вариант изменился или недоступен. Обновите поиск или выберите другой источник."])
        }
        DiagnosticsLogManager.shared.log(category: "[PlaybackStage]", message: "WebKit action dispatched", level: .info,
            actionId: context.actionId, metadata: ["stage": "webkit_action", "discoveryId": searchId.uuidString])

        // Wait up to 4 seconds for intercepted PlayPayload
        var resolveElapsed: Double = 0
        while host.lastInterceptedPayload?.requestId != context.requestId.uuidString && resolveElapsed < 10.0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard host.isAppReady, host.currentGeneration == active.generation,
                  host.activeResolutionContext == active else { throw CancellationError() }
            resolveElapsed += 0.1
        }

        try Task.checkCancellation()
        guard host.isAppReady, host.currentGeneration == active.generation,
              host.activeResolutionContext == active,
              let payload = host.lastInterceptedPayload,
              payload.requestId == context.requestId.uuidString,
              host.activeResolutionContext?.requestId == searchId,
              payload.canonicalId == context.canonicalId, payload.mediaType == context.mediaType,
              payload.season == context.season, payload.episode == context.episode,
              let streamUrl = URL(string: payload.url),
              ["http", "https"].contains(streamUrl.scheme?.lowercased() ?? ""),
              streamUrl.host != nil else {
            let reason = "\(currentBalancer): поток не может быть разрешен напрямую (требуется сессия балансера или авторизация)"
            capabilityState = .noMatches(balancer: currentBalancer, reason: "Поток недоступен напрямую")
            operationalStatus = .noMatchingTitles
            DiagnosticsLogManager.shared.log(category: "[OnlineMod]", message: reason, level: .warning)
            DiagnosticsLogManager.shared.log(category: "[PlaybackStage]", message: "No stream handoff", level: .warning,
                actionId: context.actionId, metadata: ["stage": "timeout", "sourceIndex": String(index), "discoveryId": searchId.uuidString])
            throw NSError(domain: "OnlineMod", code: 404, userInfo: [NSLocalizedDescriptionKey: reason])
        }

        let resolvedQuality = payload.currentQuality ?? source.quality
        capabilityState = .streamResolved(balancer: currentBalancer, quality: resolvedQuality)
        operationalStatus = .streamResolved
        DiagnosticsLogManager.shared.log(category: "[PlaybackStage]", message: "Stream handoff received", level: .info,
            actionId: context.actionId, metadata: ["stage": "handoff", "sourceIndex": String(index), "discoveryId": searchId.uuidString])

        DiagnosticsLogManager.shared.log(
            category: "[OnlineMod]",
            message: "\(currentBalancer): поток успешно получен (\(resolvedQuality)) для «\(source.title)»",
            level: .success
        )

        var correlatedPayload = payload
        correlatedPayload.diagnosticActionId = context.actionId
        return correlatedPayload
    }

    func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?) {
        refreshConfigurationStatus()
        switch capabilityState {
        case .notInstalled:
            return (false, "Онлайн-мод не установлен. Добавьте его в разделе «Плагины».", nil)
        case .initializing:
            return (false, "Рантайм Lampa еще инициализируется.", nil)
        case .failed(let reason):
            return (false, "Онлайн-мод: сбой инициализации — \(reason)", nil)
        case .headlessBridgeAvailable(let current, let available):
            let msg = "Headless-мост готов. Активный балансер: \(current). Доступные: \(available.joined(separator: ", ")). Выбор осуществляется в нативном интерфейсе."
            return (true, msg, nil)
        case .streamResolved(let balancer, let quality):
            return (true, "\(balancer): поток разрешен (\(quality)).", nil)
        case .noMatches(let balancer, let reason):
            return (false, "\(balancer): \(reason)", nil)
        }
    }

    // MARK: - Private

    private func assessCapabilityState() -> OnlineModCapabilityState {
        let pluginManager = PluginManager.shared

        let installedPlugin = pluginManager.installedPlugins.first {
            ($0.urlString == "bundled://plugins/online_mod.js" ||
             $0.urlString.contains("online_mod") ||
             $0.urlString.contains("online.js")) && $0.isEligibleForAutomaticRuntime
        }
        guard let plugin = installedPlugin else { return .notInstalled }
        if let error = plugin.errorDescription, !error.isEmpty {
            return .failed(reason: error)
        }

        guard LampaHeadlessHost.shared.isAppReady else {
            return .initializing
        }

        let currentBalancer = LampaHeadlessHost.shared.currentOnlineModBalancer ?? "CDNVideoHub"
        return .headlessBridgeAvailable(currentBalancer: currentBalancer, availableBalancers: Self.supportedBalancers)
    }
}
