import Foundation

@MainActor
final class EmbySourceProvider: SourceProviderProtocol {
    var providerId: String { "emby" }
    var displayName: String { "Emby (Домашний сервер)" }
    var supportedContentDescription: String { "Фильмы из личной медиатеки; прямые MP4. Сериалы пока недоступны." }
    var operationalStatus: ProviderOperationalStatus = .unconfigured
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }
    var serverHost: String { UserDefaults.standard.string(forKey: "emby_host") ?? "" }
    var serverPort: String { UserDefaults.standard.string(forKey: "emby_port") ?? "8096" }
    var apiKey: String { UserDefaults.standard.string(forKey: "emby_api_key") ?? "" }
    private var baseURL: URL? { ProviderHTTP.serverURL(host: serverHost, port: serverPort) }
    var isConfigured: Bool { baseURL != nil && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func supports(_ item: MediaItem) -> Bool { item.canonicalType == "movie" }
    func refreshConfigurationStatus() {
        if baseURL == nil { operationalStatus = .unconfigured }
        else if !isConfigured { operationalStatus = .authRequired }
        else if [.unconfigured, .authRequired].contains(operationalStatus) { operationalStatus = .initialized }
    }

    func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
        guard supports(item), season == nil, episode == nil else { return [] }
        guard let base = baseURL else { operationalStatus = .unconfigured; return [] }
        guard isConfigured else { operationalStatus = .authRequired; return [] }
        operationalStatus = .searchAvailable
        do {
            let sources = try await PersonalLibraryResolver.resolve(item: item, base: base, token: apiKey,
                provider: providerId, name: "Emby", session: session,
                onTitleMatch: { self.operationalStatus = .resultsFound })
            if !sources.isEmpty { operationalStatus = .streamResolved }
            return sources
        } catch {
            operationalStatus = ProviderRequestError.status(for: error)
            throw error
        }
    }

    func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?) {
        guard let base = baseURL else { operationalStatus = .unconfigured; return (false, "Укажите адрес Emby", nil) }
        guard isConfigured else { operationalStatus = .authRequired; return (false, "Укажите API-ключ Emby", nil) }
        guard let url = ProviderHTTP.url(base: base, path: "Items", query: [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "Limit", value: "1")]) else {
            return (false, "Некорректный адрес Emby", nil)
        }
        do {
            let json = try await ProviderHTTP.json(for: URLRequest(url: url), session: session)
            guard json["Items"] is [[String: Any]] else { throw ProviderRequestError.invalidResponse }
            operationalStatus = .searchAvailable
            return (true, "Emby: авторизованный доступ к медиатеке подтвержден", nil)
        } catch {
            operationalStatus = ProviderRequestError.status(for: error)
            return (false, ProviderRequestError.diagnostic(error), nil)
        }
    }
}
