import Foundation

@MainActor
final class PlexSourceProvider: SourceProviderProtocol {
    var providerId: String { "plex" }
    var displayName: String { "Plex (Домашний сервер)" }
    var supportedContentDescription: String { "Фильмы из Plex; прямые MP4 Media Part. Сериалы пока недоступны." }
    var operationalStatus: ProviderOperationalStatus = .unconfigured
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }
    var serverHost: String { UserDefaults.standard.string(forKey: "plex_host") ?? "" }
    var serverPort: String { UserDefaults.standard.string(forKey: "plex_port") ?? "32400" }
    var plexToken: String { UserDefaults.standard.string(forKey: "plex_token") ?? "" }
    private var baseURL: URL? { ProviderHTTP.serverURL(host: serverHost, port: serverPort) }
    var isConfigured: Bool { baseURL != nil && !plexToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func supports(_ item: MediaItem) -> Bool { item.canonicalType == "movie" }
    func refreshConfigurationStatus() {
        if baseURL == nil { operationalStatus = .unconfigured }
        else if !isConfigured { operationalStatus = .authRequired }
        else if [.unconfigured, .authRequired].contains(operationalStatus) { operationalStatus = .initialized }
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(plexToken, forHTTPHeaderField: "X-Plex-Token")
        return request
    }

    private func matches(_ item: MediaItem, candidate: [String: Any]) -> Bool {
        var guids = (candidate["Guid"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        if let guid = candidate["guid"] as? String { guids.append(guid) }
        let tmdb = guids.first(where: { $0.hasPrefix("tmdb://") }).map { String($0.dropFirst("tmdb://".count)) }
        return MediaIdentityMatcher.matches(item,
            titles: [candidate["title"] as? String ?? "", candidate["originalTitle"] as? String ?? ""],
            year: candidate["year"] as? Int, type: candidate["type"] as? String ?? "unknown", tmdbId: tmdb)
    }

    func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
        guard supports(item), season == nil, episode == nil else { return [] }
        guard let base = baseURL else { operationalStatus = .unconfigured; return [] }
        guard isConfigured else { operationalStatus = .authRequired; return [] }
        guard let url = ProviderHTTP.url(base: base, path: "search", query: [URLQueryItem(name: "query", value: item.displayTitle)]) else { return [] }
        do {
            let json = try await ProviderHTTP.json(for: request(url), session: session)
            guard let container = json["MediaContainer"] as? [String: Any] else { throw ProviderRequestError.invalidResponse }
            let metadata = container["Metadata"] as? [[String: Any]] ?? []
            var sources: [ResolvedMediaSource] = []
            for candidate in metadata where matches(item, candidate: candidate) {
                guard let key = candidate["ratingKey"] as? String, !key.isEmpty,
                      key.allSatisfy({ $0.isNumber }),
                      let detailsURL = ProviderHTTP.url(base: base, path: "library/metadata/\(key)", query: [URLQueryItem(name: "includeGuids", value: "1")]) else { continue }
                let details = try await ProviderHTTP.json(for: request(detailsURL), session: session)
                guard let body = details["MediaContainer"] as? [String: Any],
                      let records = body["Metadata"] as? [[String: Any]] else { throw ProviderRequestError.invalidResponse }
                for record in records where matches(item, candidate: record) && record["ratingKey"] as? String == key {
                    for media in record["Media"] as? [[String: Any]] ?? [] {
                        guard let parts = media["Part"] as? [[String: Any]], parts.count == 1,
                              let part = parts.first,
                              (part["container"] as? String ?? media["container"] as? String)?.lowercased() == "mp4",
                              let partKey = part["key"] as? String, partKey.hasPrefix("/library/parts/"),
                              !partKey.contains(".."), !partKey.contains("?"), !partKey.contains("#"),
                              let stream = ProviderHTTP.url(base: base, path: partKey,
                                  query: [URLQueryItem(name: "X-Plex-Token", value: plexToken)]) else { continue }
                        let height = media["height"] as? Int
                        sources.append(ResolvedMediaSource(id: "plex_\(key)_\(part["id"] ?? partKey)", providerName: "Plex",
                            title: record["title"] as? String ?? item.displayTitle, quality: height.map { "\($0)p" } ?? "Auto",
                            studioId: "plex_\(key)", studioName: "Plex", streamUrl: stream.absoluteString,
                            isHls: false, container: "mp4", season: nil, episode: nil,
                            providerId: providerId, canonicalMediaId: item.canonicalId))
                    }
                }
            }
            operationalStatus = sources.isEmpty ? .searchAvailable : .streamResolved
            return sources
        } catch {
            operationalStatus = ProviderRequestError.status(for: error)
            throw error
        }
    }

    func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?) {
        guard let base = baseURL else { operationalStatus = .unconfigured; return (false, "Укажите адрес Plex", nil) }
        guard isConfigured else { operationalStatus = .authRequired; return (false, "Укажите X-Plex-Token", nil) }
        guard let url = ProviderHTTP.url(base: base, path: "library/sections") else { return (false, "Некорректный адрес Plex", nil) }
        do {
            let json = try await ProviderHTTP.json(for: request(url), session: session)
            guard json["MediaContainer"] is [String: Any] else { throw ProviderRequestError.invalidResponse }
            operationalStatus = .searchAvailable
            return (true, "Plex: авторизованный доступ к медиатеке подтвержден", nil)
        } catch {
            operationalStatus = ProviderRequestError.status(for: error)
            return (false, ProviderRequestError.diagnostic(error), nil)
        }
    }
}
