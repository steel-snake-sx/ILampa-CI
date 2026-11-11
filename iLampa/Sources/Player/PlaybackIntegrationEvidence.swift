import Foundation

/// Readiness is not proof of playback. Require an advancing clock while actively playing.
struct PlaybackProgressEvidence {
    private var previousTime: Double?
    private(set) var verified = false

    mutating func observe(time: Double, isPlaying: Bool) -> Bool {
        guard time.isFinite else { return false }
        defer { previousTime = time }
        guard !verified, isPlaying, let previousTime, time > previousTime else { return false }
        verified = true
        return true
    }
}

enum PlaybackAssetMetadata {
    static func headers(for payload: PlayPayload, url: URL) -> [String: String] {
        var headers = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1"]
        if url.host?.contains("libria.fun") == true || payload.url.contains("anilibria") {
            headers["Referer"] = "https://anilibria.top/"
            headers["Origin"] = "https://anilibria.top"
        }
        // Provider-selected metadata takes precedence over compatibility defaults.
        for (key, value) in payload.customHeaders ?? [:] {
            headers.keys.filter { $0.caseInsensitiveCompare(key) == .orderedSame }.forEach { headers.removeValue(forKey: $0) }
            headers[key] = value
        }
        return headers
    }
}
