import Foundation
import Combine

enum SourcePriority {
    static let storageKey = "ilampa_source_priority_v1"

    static func decode(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        return keys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func encode(_ keys: [String]) -> String {
        guard let data = try? JSONEncoder().encode(keys), let value = String(data: data, encoding: .utf8) else { return "[]" }
        return value
    }

    static func order(saved: [String], available: [String]) -> [String] {
        var seen = Set<String>()
        return (saved + available).filter { seen.insert($0).inserted }
    }
}

// A typed, validated media stream resolved from an active source provider.
struct ResolvedMediaSource: Identifiable, Hashable, Sendable {
    let id: String
    let providerName: String
    let title: String
    let quality: String // "1080p", "720p", "480p", "Auto"
    let studioId: String
    let studioName: String
    let streamUrl: String
    let isHls: Bool
    let container: String // "m3u8", "mp4", "mkv"
    let season: Int?
    let episode: Int?
    var isDiagnostic: Bool = false
    var providerId: String = ""
    var canonicalMediaId: String = ""
    var discoveryRequestId: UUID? = nil
    var discoveryRowToken: String? = nil
    var discoveryRowIndex: Int? = nil
    var isNavigationFolder: Bool = false
    var isAlternativeTitle: Bool = false

    var sourceKey: String {
        switch providerId {
        case "anilibria": return "anilibria_native"
        case "torrserver": return "torrserver_default"
        default: return providerId
        }
    }

    var isAVPlayerCompatible: Bool {
        container.lowercased() == "m3u8" || container.lowercased() == "mp4" || isHls
    }
}

// Contract for all content providers in the iLampa ecosystem.
@MainActor
protocol SourceProviderProtocol: AnyObject {
    var providerId: String { get }
    var displayName: String { get }
    var supportedContentDescription: String { get }
    var operationalStatus: ProviderOperationalStatus { get set }
    var canResolveDirectly: Bool { get }
    var isConfigured: Bool { get }
    func refreshConfigurationStatus()
    func supports(_ item: MediaItem) -> Bool

    func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource]
    func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?)
}

extension SourceProviderProtocol {
    var canResolveDirectly: Bool { true }
    var isConfigured: Bool { true }
    func refreshConfigurationStatus() {}
    func supports(_ item: MediaItem) -> Bool { ["movie", "tv"].contains(item.canonicalType) }
}

// Central coordinator resolving streams across configured native adapters with bounded HTTP requests,
// in-flight deduplication, short-lived caching, detailed diagnostics logging, and honest unavailable reporting.
@MainActor
final class SourceProviderEngine: ObservableObject {
    static let shared = SourceProviderEngine()

    @Published private(set) var providers: [SourceProviderProtocol] = []

    private var inFlightTasks: [String: (id: UUID, task: Task<ResolutionResult, Never>)] = [:]
    private var resolutionConsumers: [UUID: Set<UUID>] = [:]
    private var resolutionCache: [String: (timestamp: Date, results: [ResolvedMediaSource])] = [:]
    private var configuration: [String] = []
    private var generation = 0
    private var resolutionRevisions: [String: UUID] = [:]

    private struct ResolutionResult: Sendable {
        var sources: [ResolvedMediaSource]
        var hadFailure: Bool
    }

    let anilibriaProvider = AniLibriaSourceProvider()
    let kodikAnimeProvider = KodikAnimeSourceProvider()
    let onlineModProvider = OnlineModSourceProvider()
    let torrServerProvider = TorrServerSourceProvider()
    let jellyfinProvider = JellyfinSourceProvider()
    let plexProvider = PlexSourceProvider()
    let embyProvider = EmbySourceProvider()
    let pluginProvider = PluginSourceProvider()

    init(providers: [SourceProviderProtocol]? = nil) {
        if let providers {
            self.providers = providers
            return
        }
        register(provider: anilibriaProvider)
        register(provider: kodikAnimeProvider)
        register(provider: onlineModProvider)
        register(provider: torrServerProvider)
        register(provider: jellyfinProvider)
        register(provider: plexProvider)
        register(provider: embyProvider)
        register(provider: pluginProvider)
    }

    func register(provider: SourceProviderProtocol) {
        providers.removeAll(where: { $0.providerId == provider.providerId })
        providers.append(provider)
        invalidateCache()
    }

    /// Called by configuration and plugin lifecycle owners. Old work may finish, but cannot repopulate the cache.
    func invalidateCache() {
        generation += 1
        inFlightTasks.values.forEach { $0.task.cancel() }
        inFlightTasks.removeAll()
        resolutionConsumers.removeAll()
        resolutionCache.removeAll()
        resolutionRevisions.removeAll()
        objectWillChange.send()
    }

    func configurationDidChange() {
        invalidateCache()
        providers.forEach { $0.refreshConfigurationStatus() }
    }

    private func configurationSnapshot() -> [String] {
        let keys = ["torrserver_host", "torrserver_port", "torrserver_auth_enabled", "torrserver_username", "torrserver_password",
                    "jellyfin_host", "jellyfin_port", "jellyfin_api_key", "jellyfin_user_id",
                    "plex_host", "plex_port", "plex_token", "emby_host", "emby_port", "emby_api_key",
                     "kodik_api_token", "preferred_studio", "preferred_quality", SourcePriority.storageKey]
        return keys.map { String(describing: UserDefaults.standard.object(forKey: $0) ?? "") }
    }

    // Resolves available media streams for a catalog item with in-flight deduplication,
    // caching, and detailed diagnostic logging.
    func resolveSources(for item: MediaItem, season: Int? = nil, episode: Int? = nil, forceRefresh: Bool = false) async -> [ResolvedMediaSource] {
        guard !Task.isCancelled else { return [] }
        let snapshot = configurationSnapshot()
        if snapshot != configuration {
            invalidateCache()
            configuration = snapshot
        }
        let title = item.displayTitle
        let year = item.displayYear
        let mediaId = item.canonicalId
        let s = season.map(String.init) ?? "none"
        let e = episode.map(String.init) ?? "none"
        let cacheKey = "\(item.canonicalType)_\(mediaId)_s\(s)_e\(e)_\(title)_\(item.originalTitle ?? item.originalName ?? "")_\(year)"

        if forceRefresh {
            inFlightTasks.removeValue(forKey: cacheKey)?.task.cancel()
            resolutionCache.removeValue(forKey: cacheKey)
            resolutionRevisions.removeValue(forKey: cacheKey)
        }
        if let cached = resolutionCache[cacheKey], Date().timeIntervalSince(cached.timestamp) < 60.0 {
            DiagnosticsLogManager.shared.log(
                category: "[Resolution]",
                message: "Использован кэш источников для «\(title)» (\(cached.results.count) вариантов)",
                level: .info
            )
            return cached.results
        }

        let requestGeneration = generation
        if let existingTask = inFlightTasks[cacheKey] {
            DiagnosticsLogManager.shared.log(
                category: "[Resolution]",
                message: "Подключение к выполняющемуся поиску для «\(title)» (дедупликация)",
                level: .info
            )
            let result = await consume(existingTask.task, id: existingTask.id, cacheKey: cacheKey)
            guard generation == requestGeneration, configurationSnapshot() == snapshot,
                  resolutionRevisions[cacheKey] == existingTask.id, !Task.isCancelled else { return [] }
            return result.sources
        }

        let taskID = UUID()
        providers.forEach { $0.refreshConfigurationStatus() }
        let eligible = providers.filter { $0.canResolveDirectly && $0.isConfigured && $0.supports(item) }
        let priority = SourcePriority.order(
            saved: SourcePriority.decode(UserDefaults.standard.string(forKey: SourcePriority.storageKey) ?? ""),
            available: providers.filter { $0.canResolveDirectly }.map(\.providerId))
        let ranks = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($0.element, $0.offset) })
        let task = Task<ResolutionResult, Never> {
            DiagnosticsLogManager.shared.log(
                category: "[Resolution]",
                message: "Запуск поиска источников для «\(title)» (\(year)), ID=\(mediaId), season=\(s), episode=\(e)",
                level: .info
            )

            var allSources: [ResolvedMediaSource] = []
            var hadFailure = false

            await withTaskGroup(of: ResolutionResult.self) { group in
                for provider in eligible {
                    group.addTask { @MainActor in
                        do {
                            try Task.checkCancellation()
                            let raw = try await provider.resolveSources(for: item, season: season, episode: episode)
                            try Task.checkCancellation()
                            let res = raw.compactMap { candidate -> ResolvedMediaSource? in
                                // Diagnostic/sample URLs are never search results. They must only enter
                                // playback through the explicit diagnostic action, not a provider adapter.
                                guard !candidate.isDiagnostic,
                                      candidate.season == season && candidate.episode == episode,
                                      candidate.canonicalMediaId == mediaId else { return nil }

                                if !candidate.streamUrl.isEmpty {
                                    guard candidate.isAVPlayerCompatible,
                                          let url = URL(string: candidate.streamUrl),
                                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                                          url.host != nil else { return nil }
                                }
                                var source = candidate
                                source.providerId = provider.providerId
                                source.canonicalMediaId = mediaId
                                return source
                            }
                            if res.isEmpty {
                                if raw.isEmpty && provider.operationalStatus != .resultsFound {
                                    provider.operationalStatus = .noMatchingTitles
                                }
                                DiagnosticsLogManager.shared.log(
                                    category: "[Provider]",
                                    message: "\(provider.displayName): Не разрешено прямых URL потока для «\(title)»; \(provider.operationalStatus.rawValue)",
                                    level: .info
                                )
                            } else {
                                DiagnosticsLogManager.shared.log(
                                    category: "[Provider]",
                                    message: "\(provider.displayName): Получено \(res.count) ссылок для «\(title)» (воспроизведение ещё не проверено)",
                                    level: .success
                                )
                            }
                            return ResolutionResult(sources: res, hadFailure: false)
                        } catch {
                            if !(error is CancellationError) {
                                provider.operationalStatus = ProviderRequestError.status(for: error)
                            }
                            DiagnosticsLogManager.shared.log(
                                category: "[Provider]",
                                message: "\(provider.displayName): Ошибка поиска: \(ProviderRequestError.diagnostic(error))",
                                level: .error
                            )
                            return ResolutionResult(sources: [], hadFailure: true)
                        }
                    }
                }

                for await results in group {
                    allSources.append(contentsOf: results.sources)
                    hadFailure = hadFailure || results.hadFailure
                }
            }

            let prefStudio = UserDefaults.standard.string(forKey: "preferred_studio") ?? "dubbing"
            let prefQuality = UserDefaults.standard.string(forKey: "preferred_quality") ?? "1080p"

            let voiceAndQuality = VoiceoverNormalizer.prioritize(
                items: allSources,
                preferredStudio: prefStudio,
                preferredQuality: prefQuality,
                studioExtractor: { $0.studioId },
                qualityExtractor: { $0.quality }
            )
            // Keep voice/quality ordering within each provider. A failed or empty preferred
            // provider simply contributes no candidates; other providers remain available.
            let prioritized = voiceAndQuality.enumerated().sorted { left, right in
                let l = ranks[left.element.providerId] ?? Int.max
                let r = ranks[right.element.providerId] ?? Int.max
                return l == r ? left.offset < right.offset : l < r
            }.map(\.element)

            if prioritized.isEmpty {
                DiagnosticsLogManager.shared.log(
                    category: "[Resolution]",
                    message: "Для «\(title)» прямые потоки не найдены (проверено провайдеров: \(eligible.count)). Интерактивные источники доступны отдельно в Lampa.",
                    level: .warning
                )
            } else {
                DiagnosticsLogManager.shared.log(
                    category: "[Resolution]",
                    message: "Итого разрешено \(prioritized.count) вариантов потока. Главный выбор: \(prioritized.first?.title ?? "") [\(prioritized.first?.quality ?? "")]",
                    level: .success
                )
            }

            return ResolutionResult(sources: prioritized, hadFailure: hadFailure)
        }

        inFlightTasks[cacheKey] = (taskID, task)
        resolutionRevisions[cacheKey] = taskID

        let results = await consume(task, id: taskID, cacheKey: cacheKey)

        guard generation == requestGeneration, configurationSnapshot() == snapshot,
              inFlightTasks[cacheKey]?.id == taskID else { return [] }
        inFlightTasks.removeValue(forKey: cacheKey)
        // Never cache absence or transient failures. A user can retry immediately after recovery.
        if !results.sources.isEmpty && !results.hadFailure && !results.sources.contains(where: { $0.discoveryRequestId != nil }) {
            resolutionCache = resolutionCache.filter { Date().timeIntervalSince($0.value.timestamp) < 60 }
            resolutionCache[cacheKey] = (timestamp: Date(), results: results.sources)
        }
        objectWillChange.send()
        for provider in eligible {
            let key = provider.providerId == "anilibria" ? "anilibria_native" : provider.providerId
            SourceManager.shared.updateOperationalStatus(sourceKey: key, status: provider.operationalStatus)
        }

        return Task.isCancelled ? [] : results.sources
    }

    /// A cancelled view releases its subscription, not another view's search.
    /// When the final consumer leaves on MainActor, cancel the shared task rather
    /// than merely dropping its result. Providers still must honor cancellation;
    /// this does not interrupt arbitrary in-progress network/external effects.
    private func consume(_ task: Task<ResolutionResult, Never>, id: UUID, cacheKey: String) async -> ResolutionResult {
        let consumer = UUID()
        resolutionConsumers[id, default: []].insert(consumer)
        defer { releaseConsumer(consumer, id: id, cacheKey: cacheKey, cancelled: false) }
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled { releaseConsumer(consumer, id: id, cacheKey: cacheKey, cancelled: true) }
            return await task.value
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseConsumer(consumer, id: id, cacheKey: cacheKey, cancelled: true)
            }
        })
    }

    private func releaseConsumer(_ consumer: UUID, id: UUID, cacheKey: String, cancelled: Bool) {
        guard resolutionConsumers[id]?.remove(consumer) != nil else { return }
        guard resolutionConsumers[id]?.isEmpty == true else { return }
        resolutionConsumers.removeValue(forKey: id)
        if cancelled, inFlightTasks[cacheKey]?.id == id {
            inFlightTasks.removeValue(forKey: cacheKey)?.task.cancel()
            resolutionRevisions.removeValue(forKey: cacheKey)
        }
    }
}

// MARK: - Title Matching and Verification Engine
struct TitleMatcher {
    static func isRelevantMatch(query: String, candidateTitle: String, minWordOverlapRatio: Double = 0.5) -> Bool {
        let qTokens = tokenize(query)
        let cTokens = tokenize(candidateTitle)

        guard !qTokens.isEmpty && !cTokens.isEmpty else { return false }

        let qNorm = normalize(query)
        let cNorm = normalize(candidateTitle)

        if qNorm == cNorm { return true }

        let qSet = Set(qTokens)
        let cSet = Set(cTokens)
        let intersection = qSet.intersection(cSet)

        // For short queries (<= 2 words like "Квест Вижна"):
        // Every meaningful word MUST be present in candidate title!
        if qTokens.count <= 2 {
            let missingWords = qSet.subtracting(cSet)
            return missingWords.isEmpty
        }

        let overlap = Double(intersection.count) / Double(qSet.count)
        return overlap >= minWordOverlapRatio
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    static func tokenize(_ text: String) -> [String] {
        let stopWords: Set<String> = [
            "в", "на", "и", "с", "по", "о", "к", "у", "из", "за", "от", "для", "не",
            "the", "a", "an", "of", "in", "to", "on", "at", "for", "with", "by", "and"
        ]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }
}

// MARK: - AniLibria Real Open API Source Provider (API v1)
@MainActor
final class AniLibriaSourceProvider: SourceProviderProtocol {
    var providerId: String { "anilibria" }
    var displayName: String { "AniLibria (Официальный API v1)" }
    var supportedContentDescription: String { "Аниме-релизы (каталог и поиск)" }
    var operationalStatus: ProviderOperationalStatus = .searchAvailable

    func supports(_ item: MediaItem) -> Bool {
        guard ["movie", "tv"].contains(item.canonicalType) else { return false }
        if let g = item.genreIds, !g.isEmpty {
            return g.contains(16)
        }
        return true
    }

    private let session: URLSession

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8.0
        self.session = session ?? URLSession(configuration: config)
    }

    func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
        do {
            return try await resolveAnime(for: item, season: season, episode: episode)
        } catch {
            operationalStatus = ProviderRequestError.status(for: error)
            throw error
        }
    }

    private func resolveAnime(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
        guard supports(item), (season ?? 1) > 0, (episode ?? 1) > 0,
              item.canonicalType != "tv" || (season != nil && episode != nil),
              item.canonicalType != "movie" || (season == nil && episode == nil) else { return [] }
        operationalStatus = .searchAvailable
        let s = season ?? 1
        var rawQueries = [
            item.title ?? "",
            item.name ?? "",
            item.originalTitle ?? "",
            item.originalName ?? ""
        ]
        if s > 1 {
            let base = rawQueries.filter { !$0.isEmpty }
            for b in base {
                rawQueries.append("\(b) \(s)")
                rawQueries.append("\(b) \(MediaIdentityMatcher.romanNumeral(s))")
            }
        }
        var seenQueries = Set<String>()
        let searchQueries = rawQueries.compactMap { raw -> String? in
            let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return nil }
            return seenQueries.insert(query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted ? query : nil
        }

        guard !searchQueries.isEmpty else { return [] }

        var matchedReleaseId: Int? = nil
        var matchedTitleName: String? = nil

        for query in searchQueries {
            var parts = URLComponents(string: "https://anilibria.top/api/v1/app/search/releases")!
            parts.queryItems = [URLQueryItem(name: "query", value: query)]
            guard let searchUrl = parts.url else {
                continue
            }

            var request = URLRequest(url: searchUrl)
            request.httpMethod = "GET"
            request.addValue("application/json", forHTTPHeaderField: "Accept")

            let data = try await ProviderHTTP.data(for: request, session: session)
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw ProviderRequestError.invalidResponse
            }

            // Evaluate all candidates returned by search instead of blindly taking .first
            var bestCandidate: [String: Any]? = nil
            var rejectedDescriptions: [String] = []
            for candidate in jsonArray {
                var candidateNames: [String] = []
                if let names = candidate["name"] as? [String: Any] {
                    if let main = names["main"] as? String { candidateNames.append(main) }
                    if let eng = names["english"] as? String { candidateNames.append(eng) }
                    if let alt = names["alternative"] as? String { candidateNames.append(alt) }
                }

                let releaseType = (candidate["type"] as? [String: Any])?["value"] as? String ?? ""
                let type = releaseType.uppercased() == "MOVIE" ? "movie" : (["TV", "ONA", "OVA", "OAD"].contains(releaseType.uppercased()) ? "tv" : "unknown")
                let matches = MediaIdentityMatcher.matches(item, titles: candidateNames,
                                                         year: candidate["year"] as? Int, type: type, season: season)

                if matches {
                    bestCandidate = candidate
                    break
                }
                rejectedDescriptions.append("id=\(candidate["id"] ?? "?") type=\(type) year=\(candidate["year"] ?? "?") titles=\(candidateNames.count)")
            }

            guard let matched = bestCandidate, let rId = matched["id"] as? Int else {
                DiagnosticsLogManager.shared.log(
                    category: "[Provider]",
                    message: "AniLibria: Поиск «\(query)» не прошёл строгую проверку identity expectedType=\(item.canonicalType) expectedYear=\(item.displayYear), candidates=\(rejectedDescriptions.prefix(5).joined(separator: "; "))",
                    level: .warning
                )
                continue
            }

            matchedReleaseId = rId
            operationalStatus = .resultsFound
            if let names = matched["name"] as? [String: Any], let mainName = names["main"] as? String {
                matchedTitleName = mainName
            } else {
                matchedTitleName = query
            }
            break
        }

        guard let releaseId = matchedReleaseId,
              let episodesUrl = URL(string: "https://anilibria.top/api/v1/anime/releases/\(releaseId)?include=episodes") else {
            return []
        }

        var epRequest = URLRequest(url: episodesUrl)
        epRequest.httpMethod = "GET"
        epRequest.addValue("application/json", forHTTPHeaderField: "Accept")

        let epData = try await ProviderHTTP.data(for: epRequest, session: session)
        guard let jsonDict = try JSONSerialization.jsonObject(with: epData) as? [String: Any],
              releaseResponseMatches(jsonDict, releaseId: releaseId),
              let episodesList = jsonDict["episodes"] as? [[String: Any]], !episodesList.isEmpty else {
            return []
        }

        let targetEp = episode ?? 1
        guard item.canonicalType != "movie" || episodesList.count == 1 else { return [] }
        guard let selectedEp = episodesList.first(where: { episodeOrdinal($0) == targetEp }) else {
            let available = episodesList.compactMap(episodeOrdinal).prefix(16).map(String.init).joined(separator: ",")
            DiagnosticsLogManager.shared.log(category: "[Provider]",
                message: "AniLibria: release=\(releaseId) does not contain requested episode=\(targetEp); available=\(available)",
                level: .info)
            return []
        }
        guard episodeReleaseMatches(selectedEp, releaseId: releaseId) else {
            DiagnosticsLogManager.shared.log(category: "[Provider]",
                message: "AniLibria: selected episode=\(targetEp) carries a mismatched release identity for release=\(releaseId)",
                level: .warning)
            return []
        }

        let epOrdinal = episodeOrdinal(selectedEp) ?? targetEp
        let displayTitle = matchedTitleName ?? item.displayTitle

        var resolved: [ResolvedMediaSource] = []

        if let fhd = selectedEp["hls_1080"] as? String, !fhd.isEmpty {
            resolved.append(ResolvedMediaSource(
                id: "anilibria_\(releaseId)_ep\(epOrdinal)_1080p",
                providerName: "AniLibria",
                title: "\(displayTitle) — Серия \(epOrdinal)",
                quality: "1080p",
                studioId: "anilibria",
                studioName: "AniLibria (Официальный)",
                streamUrl: fhd,
                isHls: true,
                container: "m3u8",
                season: season,
                episode: episode == nil ? nil : epOrdinal,
                isDiagnostic: false,
                providerId: providerId,
                canonicalMediaId: item.canonicalId
            ))
        }

        if let hd = selectedEp["hls_720"] as? String, !hd.isEmpty {
            resolved.append(ResolvedMediaSource(
                id: "anilibria_\(releaseId)_ep\(epOrdinal)_720p",
                providerName: "AniLibria",
                title: "\(displayTitle) — Серия \(epOrdinal)",
                quality: "720p",
                studioId: "anilibria",
                studioName: "AniLibria (Официальный)",
                streamUrl: hd,
                isHls: true,
                container: "m3u8",
                season: season,
                episode: episode == nil ? nil : epOrdinal,
                isDiagnostic: false,
                providerId: providerId,
                canonicalMediaId: item.canonicalId
            ))
        }

        if let sd = selectedEp["hls_480"] as? String, !sd.isEmpty {
            resolved.append(ResolvedMediaSource(
                id: "anilibria_\(releaseId)_ep\(epOrdinal)_480p",
                providerName: "AniLibria",
                title: "\(displayTitle) — Серия \(epOrdinal)",
                quality: "480p",
                studioId: "anilibria",
                studioName: "AniLibria (Официальный)",
                streamUrl: sd,
                isHls: true,
                container: "m3u8",
                season: season,
                episode: episode == nil ? nil : epOrdinal,
                isDiagnostic: false,
                providerId: providerId,
                canonicalMediaId: item.canonicalId
            ))
        }

        if !resolved.isEmpty {
            operationalStatus = .streamResolved
        }

        return resolved
    }

    /// The release endpoint currently returns an episodes-only document. If an endpoint does
    /// include a release identifier, reject a mismatch; do not require an optional field.
    private func releaseResponseMatches(_ response: [String: Any], releaseId: Int) -> Bool {
        guard let supplied = response["id"] else { return true }
        if let integer = supplied as? Int { return integer == releaseId }
        if let string = supplied as? String, let integer = Int(string) { return integer == releaseId }
        return false
    }

    private func episodeOrdinal(_ episode: [String: Any]) -> Int? {
        if let integer = episode["ordinal"] as? Int { return integer }
        if let number = episode["ordinal"] as? NSNumber { return number.intValue }
        if let string = episode["ordinal"] as? String { return Int(string) }
        return nil
    }

    private func episodeReleaseMatches(_ episode: [String: Any], releaseId: Int) -> Bool {
        guard let supplied = episode["release_id"] else { return true }
        if let integer = supplied as? Int { return integer == releaseId }
        if let number = supplied as? NSNumber { return number.intValue == releaseId }
        if let string = supplied as? String, let integer = Int(string) { return integer == releaseId }
        return false
    }

    func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?) {
        DiagnosticsLogManager.shared.log(
            category: "[Provider]",
            message: "AniLibria: Запуск теста верификации API v1...",
            level: .info
        )

        // Known authorized release in AniLibria v1: Romelia Senki (release 10337)
        guard let testUrl = URL(string: "https://anilibria.top/api/v1/anime/releases/10337?include=episodes") else {
            operationalStatus = .connectionFailed
            return (false, "Некорректный адрес тестового запроса", nil)
        }

        var req = URLRequest(url: testUrl)
        req.timeoutInterval = 6.0
        req.httpMethod = "GET"

        do {
            let data = try await ProviderHTTP.data(for: req, session: session)
            guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eps = dict["episodes"] as? [[String: Any]],
                  let firstEp = eps.first,
                  let hls1080 = firstEp["hls_1080"] as? String,
                  !hls1080.isEmpty else {
                operationalStatus = .connectionFailed
                let msg = "AniLibria API вернул некорректный ответ"
                DiagnosticsLogManager.shared.log(category: "[Provider]", message: msg, level: .error)
                return (false, msg, nil)
            }

            // Verify stream head reachability
            if let streamUrl = URL(string: hls1080) {
                var headReq = URLRequest(url: streamUrl)
                headReq.httpMethod = "HEAD"
                headReq.timeoutInterval = 5.0
                let (_, streamResp) = try await session.data(for: headReq)
                if let streamHttp = streamResp as? HTTPURLResponse, (200...399).contains(streamHttp.statusCode) {
                    operationalStatus = .streamResolved
                    let msg = "AniLibria API v1 онлайн: HLS поток 1080p подтвержден (HTTP \(streamHttp.statusCode))"
                    DiagnosticsLogManager.shared.log(category: "[Provider]", message: msg, level: .success)
                    return (true, msg, hls1080)
                }
            }

            operationalStatus = .resultsFound
            return (false, "AniLibria API доступен, но тестовый поток не подтвержден", nil)
        } catch {
            operationalStatus = ProviderRequestError.status(for: error)
            let msg = "Ошибка соединения с AniLibria: \(ProviderRequestError.diagnostic(error))"
            DiagnosticsLogManager.shared.log(category: "[Provider]", message: msg, level: .error)
            return (false, msg, nil)
        }
    }
}

// MARK: - TorrServer Source Provider
@MainActor
final class TorrServerSourceProvider: SourceProviderProtocol {
    var providerId: String { "torrserver" }
    var displayName: String { "TorrServer (Торрент-движок)" }
    var supportedContentDescription: String { "Фильмы и сериалы из торрент-раздач" }
    var operationalStatus: ProviderOperationalStatus = .unconfigured
    // Echo/list do not identify the selected media file. Keep this interactive until a file-index adapter exists.
    var canResolveDirectly: Bool { false }
    var isConfigured: Bool { !(UserDefaults.standard.string(forKey: "torrserver_host") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func refreshConfigurationStatus() {
        if !isConfigured { operationalStatus = .unconfigured }
    }

    func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
        if !isConfigured { operationalStatus = .unconfigured }
        return []
    }

    func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?) {
        let host = UserDefaults.standard.string(forKey: "torrserver_host") ?? ""
        let port = UserDefaults.standard.string(forKey: "torrserver_port") ?? "8090"

        guard !host.isEmpty else {
            operationalStatus = .unconfigured
            return (false, "TorrServer не настроен. Укажите IP-адрес сервера в настройках.", nil)
        }

        guard let base = ProviderHTTP.serverURL(host: host, port: port),
              let url = ProviderHTTP.url(base: base, path: "echo") else {
            operationalStatus = .unconfigured
            return (false, "Некорректный IP или порт TorrServer", nil)
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.httpMethod = "GET"
        if UserDefaults.standard.bool(forKey: "torrserver_auth_enabled") {
            let user = UserDefaults.standard.string(forKey: "torrserver_username") ?? ""
            let password = UserDefaults.standard.string(forKey: "torrserver_password") ?? ""
            guard !user.isEmpty, !password.isEmpty else {
                operationalStatus = .authRequired
                return (false, "Укажите логин и пароль TorrServer", nil)
            }
            req.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }

        do {
            _ = try await ProviderHTTP.data(for: req, session: .shared)
                operationalStatus = .initialized
                let msg = "TorrServer доступен. Выберите раздачу и конкретный файл в интерфейсе Lampa."
                DiagnosticsLogManager.shared.log(category: "[Provider]", message: msg, level: .success)
                return (true, msg, nil)
        } catch {
            operationalStatus = ProviderRequestError.status(for: error)
            let msg = "TorrServer: \(ProviderRequestError.diagnostic(error))"
            DiagnosticsLogManager.shared.log(category: "[Provider]", message: msg, level: .error)
            return (false, msg, nil)
        }
    }
}

// MARK: - Plugin Source Provider
@MainActor
final class PluginSourceProvider: SourceProviderProtocol {
    var providerId: String { "plugins" }
    var displayName: String { "Плагины и балансеры (JS)" }
    var supportedContentDescription: String { "Источники, зарегистрированные JS-плагинами" }
    var operationalStatus: ProviderOperationalStatus = .registered
    var canResolveDirectly: Bool { false }

    func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
        // Capability metadata is not a callable native adapter. Diagnostic playback is launched explicitly.
        return []
    }

    func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?) {
        let registry = PluginCapabilityRegistry.shared
        let activeSources = registry.registeredSources.filter { $0.isEnabled }

        if activeSources.isEmpty {
            operationalStatus = .unconfigured
            return (false, "Нет установленных или активных плагинов источников", nil)
        }

        let withResolver = activeSources.filter { $0.hasExecutableResolver }
        if withResolver.isEmpty {
            operationalStatus = .registered
            let msg = "Плагины установлены, но регистрируют только UI-компоненты. Реальные резолверы потоков отсутствуют."
            DiagnosticsLogManager.shared.log(category: "[Plugin]", message: msg, level: .warning)
            return (false, msg, nil)
        }

        operationalStatus = .registered
        return (false, "Плагины доступны в Lampa; адаптер прямого поиска для карточек не зарегистрирован", nil)
    }
}

// Shared validation used by the real adapters (also injectable through URLProtocol in unit tests).
enum ProviderRequestError: LocalizedError {
    case authenticationRequired
    case http(Int)
    case invalidResponse
    case secureConnection(host: String, underlyingDomain: String, underlyingCode: Int)

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "Проверьте авторизацию провайдера"
        case .http(let status): return "Провайдер ответил HTTP \(status)"
        case .invalidResponse: return "Провайдер вернул некорректный ответ"
        case .secureConnection(let host, _, _):
            return "Не удалось установить защищённое соединение с \(host). Проверьте дату устройства, сертификат сервера и сеть/VPN/прокси; проверка TLS не отключалась."
        }
    }

    static func status(for error: Error) -> ProviderOperationalStatus {
        if case ProviderRequestError.authenticationRequired = error { return .authRequired }
        if case ProviderRequestError.http(let code) = error, [401, 403].contains(code) { return .authRequired }
        return .connectionFailed
    }

    static func diagnostic(_ error: Error) -> String {
        let underlying = error as NSError
        if let providerError = error as? ProviderRequestError,
           case .secureConnection(let host, let domain, let code) = providerError {
            return "TLS host=\(host), underlying=\(domain) code=\(code)"
        }
        return "\(underlying.domain) code=\(underlying.code): \(error.localizedDescription)"
    }
}

enum ProviderHTTP {
    static func serverURL(host: String, port: String) -> URL? {
        let raw = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, var parts = URLComponents(string: raw.contains("://") ? raw : "http://" + raw),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host != nil,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        if parts.port == nil, !port.isEmpty {
            guard let number = Int(port), (1...65535).contains(number) else { return nil }
            parts.port = number
        }
        return parts.url
    }

    static func url(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        let target = path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
        guard var parts = URLComponents(url: target, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = query.isEmpty ? nil : query
        return parts.url
    }

    static func data(for request: URLRequest, session: URLSession) async throws -> Data {
        var bounded = request
        bounded.timeoutInterval = min(request.timeoutInterval, 8)
        let requestedHost = safeHost(bounded.url)
        DiagnosticsLogManager.shared.log(category: "[Network]", message: "Provider request host=\(requestedHost), dns=URLSession-managed", level: .info)
        do {
            let (data, response) = try await session.data(for: bounded)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ProviderRequestError.invalidResponse }
            let finalHost = safeHost(response.url)
            DiagnosticsLogManager.shared.log(category: "[Network]",
                message: "Provider response requestedHost=\(requestedHost), finalHost=\(finalHost), redirected=\(requestedHost != finalHost), HTTP=\(http.statusCode)",
                level: (200...299).contains(http.statusCode) ? .info : .warning)
            guard (200...299).contains(http.statusCode) else { throw ProviderRequestError.http(http.statusCode) }
            return data
        } catch {
            if error is CancellationError { throw error }
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            let underlyingDomain = underlying?.domain ?? nsError.domain
            let underlyingCode = underlying?.code ?? nsError.code
            let dnsOutcome: String
            switch nsError.code {
            case -1003, -1006: dnsOutcome = "failed"
            default: dnsOutcome = "unavailable"
            }
            let tlsFailure = nsError.domain == NSURLErrorDomain && nsError.code == -1200
            DiagnosticsLogManager.shared.log(category: "[Network]",
                message: "Provider transport failure host=\(requestedHost), dns=\(dnsOutcome), tls=\(tlsFailure ? "secure-connection-failed" : "not-reported"), domain=\(nsError.domain), code=\(nsError.code), underlying=\(underlyingDomain) code=\(underlyingCode), networkPath=proxy-or-VPN-not-observable",
                level: .error)
            if tlsFailure {
                throw ProviderRequestError.secureConnection(host: requestedHost, underlyingDomain: underlyingDomain, underlyingCode: underlyingCode)
            }
            throw error
        }
    }

    private static func safeHost(_ url: URL?) -> String {
        guard let host = url?.host, !host.isEmpty else { return "unknown" }
        return host.lowercased()
    }

    static func json(for request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let bytes = try await data(for: request, session: session)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ProviderRequestError.invalidResponse
        }
        return object
    }
}

enum MediaIdentityMatcher {
    static func romanNumeral(_ n: Int) -> String {
        switch n {
        case 1: return "I"
        case 2: return "II"
        case 3: return "III"
        case 4: return "IV"
        case 5: return "V"
        case 6: return "VI"
        default: return String(n)
        }
    }

    static func matches(_ item: MediaItem, titles: [String], year: Int?, type: String, tmdbId: String? = nil, season: Int? = nil) -> Bool {
        guard type == item.canonicalType else { return false }
        let s = season ?? 1
        guard s > 0 else { return false }
        // A canonical ID does not excuse conflicting metadata for a first-season/movie lookup.
        if s == 1, let expectedYear = Int(item.displayYear), let year, year != expectedYear { return false }
        if let tmdbId { return tmdbId == String(item.id) }
        let aliases = [item.title, item.name, item.originalTitle, item.originalName].compactMap { $0 }
            .map(TitleMatcher.normalize).filter { !$0.isEmpty }
        guard let expectedYear = Int(item.displayYear), let year else { return false }
        let expectedAliases: [String]
        if s > 1 {
            // Separate releases need an explicit season marker; the base title alone
            // would otherwise select season one and label it as the requested season.
            guard year >= expectedYear else { return false }
            expectedAliases = aliases.map { "\($0)\(s)" } + aliases.map { "\($0)\(romanNumeral(s).lowercased())" }
        } else {
            guard year == expectedYear else { return false }
            expectedAliases = aliases
        }
        return titles.map(TitleMatcher.normalize).contains { !$0.isEmpty && expectedAliases.contains($0) }
    }
}

/// Jellyfin/Emby movie-only recovery path. Series/episode mapping is intentionally unavailable until implemented.
@MainActor enum PersonalLibraryResolver {
    static func resolve(item: MediaItem, base: URL, token: String, provider: String, name: String,
                        userId: String = "", session: URLSession, onTitleMatch: (() -> Void)? = nil) async throws -> [ResolvedMediaSource] {
        guard item.canonicalType == "movie", !token.isEmpty else { return [] }
        let auth = URLQueryItem(name: "api_key", value: token)
        let query = [auth, URLQueryItem(name: "searchTerm", value: item.displayTitle),
                     URLQueryItem(name: "IncludeItemTypes", value: "Movie"), URLQueryItem(name: "Recursive", value: "true"),
                     URLQueryItem(name: "Fields", value: "ProviderIds,OriginalTitle,ProductionYear")]
        let prefix = userId.isEmpty ? "" : "Users/\(userId)/"
        guard let url = ProviderHTTP.url(base: base, path: prefix + "Items", query: query) else { return [] }
        let json = try await ProviderHTTP.json(for: URLRequest(url: url), session: session)
        guard let items = json["Items"] as? [[String: Any]] else { throw ProviderRequestError.invalidResponse }
        var sources: [ResolvedMediaSource] = []
        for candidate in items {
            let ids = candidate["ProviderIds"] as? [String: Any]
            let tmdbId = (ids?["Tmdb"] ?? ids?["tmdb"]).map { String(describing: $0) }
            guard candidate["Type"] as? String == "Movie",
                  let id = candidate["Id"] as? String, !id.isEmpty,
                  MediaIdentityMatcher.matches(item, titles: [candidate["Name"] as? String ?? "", candidate["OriginalTitle"] as? String ?? ""],
                                               year: candidate["ProductionYear"] as? Int, type: "movie", tmdbId: tmdbId),
                   let infoURL = ProviderHTTP.url(base: base, path: "Items/\(id)/PlaybackInfo", query: [auth]) else { continue }
            onTitleMatch?()
            let info = try await ProviderHTTP.json(for: URLRequest(url: infoURL), session: session)
            guard let media = info["MediaSources"] as? [[String: Any]] else { throw ProviderRequestError.invalidResponse }
            for source in media {
                // Static streaming does not convert MKV into MP4. Do not invent compatibility or resolution.
                guard (source["Container"] as? String)?.lowercased() == "mp4",
                      source["SupportsDirectPlay"] as? Bool != false,
                      let sourceId = source["Id"] as? String, !sourceId.isEmpty,
                      let stream = ProviderHTTP.url(base: base, path: "Videos/\(id)/stream.mp4", query: [auth,
                          URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "MediaSourceId", value: sourceId)]) else { continue }
                let tracks = source["MediaStreams"] as? [[String: Any]] ?? []
                let height = tracks.first(where: { $0["Type"] as? String == "Video" })?["Height"] as? Int
                sources.append(ResolvedMediaSource(id: "\(provider)_\(id)_\(sourceId)", providerName: name,
                    title: candidate["Name"] as? String ?? item.displayTitle, quality: height.map { "\($0)p" } ?? "Auto",
                    studioId: "\(provider)_\(sourceId)", studioName: name, streamUrl: stream.absoluteString,
                    isHls: false, container: "mp4", season: nil, episode: nil,
                    providerId: provider, canonicalMediaId: item.canonicalId))
            }
        }
        return sources
    }
}
