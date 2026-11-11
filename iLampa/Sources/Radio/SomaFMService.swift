import Foundation

enum SomaFMError: LocalizedError {
    case networkError(Error)
    case invalidChannelsResponse
    case noPlaylistAvailable(stationId: String)
    case plsParseFailure(url: String)
    
    var errorDescription: String? {
        switch self {
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .invalidChannelsResponse: return "SomaFM returned an unexpected response"
        case .noPlaylistAvailable(let id): return "No playlist available for station '\(id)'"
        case .plsParseFailure(let url): return "Could not parse playlist at \(url)"
        }
    }
}

actor SomaFMService {
    static let shared = SomaFMService()
    
    private let channelsURL = URL(string: "https://api.somafm.com/channels.json")!
    private let fallbackChannelsURL = URL(string: "https://somafm.com/channels.json")!
    private var cachedChannels: [RadioStation]?
    private var cacheDate: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes
    
    private var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()
    
    // Returns cached channels if fresh, otherwise fetches from network
    func channels(forceRefresh: Bool = false) async throws -> [RadioStation] {
        if !forceRefresh, let cached = cachedChannels, let date = cacheDate,
           Date().timeIntervalSince(date) < cacheTTL {
            return cached
        }
        
        var rawData: Data
        do {
            let (data, response) = try await session.data(from: channelsURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw SomaFMError.invalidChannelsResponse
            }
            rawData = data
        } catch {
            let (data, response) = try await session.data(from: fallbackChannelsURL)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw SomaFMError.invalidChannelsResponse
            }
            rawData = data
        }
        
        do {
            let decoded = try JSONDecoder().decode(SomaFMChannelsResponse.self, from: rawData)
            let sorted = decoded.channels.sorted { ($0.listeners, $0.title) > ($1.listeners, $1.title) }
            cachedChannels = sorted
            cacheDate = Date()
            DiagnosticsLogManager.shared.log(
                category: "[Radio]",
                message: "Успешно загружено станций SomaFM: \(sorted.count)",
                level: .info
            )
            return sorted
        } catch let decErr as DecodingError {
            let details: String
            switch decErr {
            case .keyNotFound(let k, let c): details = "Ключ \(k.stringValue) не найден: \(c.debugDescription)"
            case .typeMismatch(let t, let c): details = "Тип \(t) не совпал: \(c.debugDescription)"
            case .valueNotFound(let t, let c): details = "Значение \(t) null: \(c.debugDescription)"
            case .dataCorrupted(let c): details = "Данные повреждены: \(c.debugDescription)"
            @unknown default: details = decErr.localizedDescription
            }
            DiagnosticsLogManager.shared.log(
                category: "[Radio]",
                message: "Ошибка парсинга каналов SomaFM: \(details)",
                level: .error
            )
            throw decErr
        }
    }
    
    // Resolves a station's PLS playlist URL to actual stream URLs (File1=, File2=, ...)
    func resolveStreamURLs(for station: RadioStation) async throws -> [URL] {
        guard let playlist = station.preferredPlaylist else {
            throw SomaFMError.noPlaylistAvailable(stationId: station.id)
        }
        guard let plsURL = URL(string: playlist.url) else {
            throw SomaFMError.plsParseFailure(url: playlist.url)
        }
        
        let (data, _) = try await session.data(from: plsURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SomaFMError.plsParseFailure(url: playlist.url)
        }
        
        let urls = parsePLS(text: text)
        guard !urls.isEmpty else {
            throw SomaFMError.plsParseFailure(url: playlist.url)
        }
        return urls
    }
    
    // Parse PLS INI format: extract File1=, File2=, ... lines
    private func parsePLS(text: String) -> [URL] {
        var results: [URL] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match lines like "File1=http://..." or "file1=http://..."
            let lower = trimmed.lowercased()
            if lower.hasPrefix("file") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let urlStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if let url = URL(string: urlStr), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        results.append(url)
                    }
                }
            }
        }
        return results
    }
}
