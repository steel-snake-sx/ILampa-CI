import Foundation

// Independent watch history engine tracking progress across source providers.
final class WatchHistoryManager {
    static let shared = WatchHistoryManager()

    private let storageKey = "ilampa_watch_history_v1"
    private let preferencesKey = "ilampa_playback_preferences_v1"
    private let defaults = UserDefaults.standard
    private let queue = DispatchQueue(label: "online.lampa.ilampa.history", attributes: .concurrent)

    private var inMemoryRecords: [String: WatchHistoryRecord] = [:]
    private var inMemoryPreferences: [String: UserPlaybackPreferences] = [:]

    private init() {
        loadFromStorage()
    }

    private func recordKey(canonicalId: String, season: Int, episode: Int) -> String {
        return "\(canonicalId)|s\(season)|e\(episode)"
    }

    private func loadFromStorage() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: WatchHistoryRecord].self, from: data) {
            inMemoryRecords = decoded
            purgeDiagnosticRecords()
        }
        if let data = defaults.data(forKey: preferencesKey),
           let decoded = try? JSONDecoder().decode([String: UserPlaybackPreferences].self, from: data) {
            inMemoryPreferences = decoded
        }
    }

    // Automatically removes any diagnostic test playback records from ordinary watch history.
    func purgeDiagnosticRecords() {
        let dirtyKeys = inMemoryRecords.keys.filter { key in
            let lower = key.lowercased()
            let rec = inMemoryRecords[key]
            let urlLower = rec?.url?.lowercased() ?? ""
            return lower.contains("diagnostic") || lower.contains("test-hls") || lower.contains("bipbop") ||
                   urlLower.contains("bipbop") || urlLower.contains("devstreaming")
        }
        if !dirtyKeys.isEmpty {
            for k in dirtyKeys {
                inMemoryRecords.removeValue(forKey: k)
            }
            persist()
        }
    }

    private func persist() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if let encoded = try? JSONEncoder().encode(self.inMemoryRecords) {
                self.defaults.set(encoded, forKey: self.storageKey)
            }
            if let encoded = try? JSONEncoder().encode(self.inMemoryPreferences) {
                self.defaults.set(encoded, forKey: self.preferencesKey)
            }
        }
    }

    func saveTimecode(
        canonicalId: String,
        season: Int,
        episode: Int,
        time: Double,
        duration: Double,
        title: String? = nil,
        url: String? = nil,
        studio: String? = nil,
        quality: String? = nil,
        source: String? = nil
    ) {
        guard !canonicalId.isEmpty, duration > 0, time >= 0 else { return }

        // Strictly exclude diagnostic streams from user watch history
        let canLower = canonicalId.lowercased()
        let urlLower = url?.lowercased() ?? ""
        if canLower.contains("diagnostic") || canLower.contains("test-hls") || canLower.contains("bipbop") ||
           urlLower.contains("bipbop") || urlLower.contains("devstreaming") {
            return
        }
        let key = recordKey(canonicalId: canonicalId, season: season, episode: episode)
        let percent = Int(min(100.0, max(0.0, (time / duration) * 100.0)))

        let record = WatchHistoryRecord(
            canonicalId: canonicalId,
            title: title,
            url: url,
            season: season,
            episode: episode,
            timecode: time,
            duration: duration,
            percent: percent,
            studio: studio,
            quality: quality,
            sourceId: source,
            updatedAt: Date()
        )

        queue.async(flags: .barrier) {
            self.inMemoryRecords[key] = record
            self.persist()
        }
    }

    func getAllRecords() -> [WatchHistoryRecord] {
        queue.sync {
            return self.inMemoryRecords.values
                .sorted(by: { $0.updatedAt > $1.updatedAt })
        }
    }

    func clearHistory() {
        queue.async(flags: .barrier) {
            self.inMemoryRecords.removeAll()
            self.defaults.removeObject(forKey: self.storageKey)
        }
    }

    func deleteRecord(canonicalId: String, season: Int, episode: Int) {
        let key = recordKey(canonicalId: canonicalId, season: season, episode: episode)
        queue.async(flags: .barrier) {
            self.inMemoryRecords.removeValue(forKey: key)
            self.persist()
        }
    }

    func getResumePosition(
        canonicalId: String,
        season: Int,
        episode: Int,
        newStreamDuration: Double? = nil
    ) -> (time: Double, percent: Int, hasDiscrepancy: Bool) {
        let key = recordKey(canonicalId: canonicalId, season: season, episode: episode)

        var record: WatchHistoryRecord?
        queue.sync {
            record = self.inMemoryRecords[key]
        }

        guard let rec = record, rec.timecode > 10 else {
            return (time: 0.0, percent: 0, hasDiscrepancy: false)
        }

        // Near end of stream (>92%), restart from beginning.
        if rec.percent >= 92 {
            return (time: 0.0, percent: rec.percent, hasDiscrepancy: false)
        }

        // When cut durations differ by over 60 seconds, scale position by percentage.
        if let newDur = newStreamDuration, newDur > 60, abs(newDur - rec.duration) > 60.0 {
            let mappedTime = (Double(rec.percent) / 100.0) * newDur
            return (time: mappedTime, percent: rec.percent, hasDiscrepancy: true)
        }

        return (time: rec.timecode, percent: rec.percent, hasDiscrepancy: false)
    }

    func getPreferences(for canonicalId: String) -> UserPlaybackPreferences? {
        queue.sync {
            return self.inMemoryPreferences[canonicalId]
        }
    }

    func savePreferences(for canonicalId: String, studio: String?, quality: String?) {
        queue.async(flags: .barrier) {
            let existing = self.inMemoryPreferences[canonicalId]
            let updated = UserPlaybackPreferences(
                preferredStudio: studio ?? existing?.preferredStudio,
                preferredQuality: quality ?? existing?.preferredQuality,
                autoNextEpisode: existing?.autoNextEpisode ?? true,
                preferNativePlayer: existing?.preferNativePlayer ?? true,
                externalTorrServerHost: existing?.externalTorrServerHost
            )
            self.inMemoryPreferences[canonicalId] = updated
            self.persist()
        }
    }
}
