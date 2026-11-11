import Foundation

/// Kodik search links identify an embedded player, not a native-playable HLS stream.
@MainActor
final class KodikAnimeSourceProvider: SourceProviderProtocol {
    var providerId: String { "kodik_anime" }
    var displayName: String { "Kodik (Аниме и Дорамы)" }
    var supportedContentDescription: String { "Поиск Kodik; выбор и разрешение потока через интерфейс Lampa" }
    var operationalStatus: ProviderOperationalStatus = .initialized
    var canResolveDirectly: Bool { false }

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    private var apiToken: String? {
        let token = (UserDefaults.standard.string(forKey: "kodik_api_token") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    var isConfigured: Bool { apiToken != nil }

    func refreshConfigurationStatus() {
        if !isConfigured { operationalStatus = .unconfigured }
    }

    func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
        // Never pass an HTML embed page to AVPlayer, nor relabel it with the requested episode/quality.
        return []
    }

    func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?) {
        guard let apiToken else {
            operationalStatus = .unconfigured
            return (false, "Kodik требует ваш API токен. Добавьте его в настройках источников; проверка TLS не отключается.", nil)
        }
        var parts = URLComponents(string: "https://kodikapi.com/search")!
        parts.queryItems = [URLQueryItem(name: "token", value: apiToken), URLQueryItem(name: "title", value: "Naruto"), URLQueryItem(name: "limit", value: "1")]
        do {
            let json = try await ProviderHTTP.json(for: URLRequest(url: parts.url!), session: session)
            guard json["error"] == nil, json["results"] is [[String: Any]] else { throw ProviderRequestError.invalidResponse }
            operationalStatus = .searchAvailable
            return (true, "Kodik: поиск доступен. Прямой поток не проверен; выберите источник в Lampa.", nil)
        } catch {
            operationalStatus = ProviderRequestError.status(for: error)
            return (false, "Kodik (kodikapi.com): \(ProviderRequestError.diagnostic(error))", nil)
        }
    }
}
