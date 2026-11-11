import Foundation
import AVKit

// Quality variant description for adaptive or direct streams.
struct QualityOption: Identifiable, Codable, Hashable {
    var id: String { label }
    let label: String
    let url: String
    let bitrate: Int?

    enum CodingKeys: String, CodingKey {
        case label, url, bitrate
    }

    init(label: String, url: String, bitrate: Int? = nil) {
        self.label = label
        self.url = url
        self.bitrate = bitrate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.label = (try? container.decodeIfPresent(String.self, forKey: .label)) ?? "Auto"
        self.url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""
        if let b = try? container.decodeIfPresent(Int.self, forKey: .bitrate) {
            self.bitrate = b
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .bitrate), let b = Int(s) {
            self.bitrate = b
        } else {
            self.bitrate = nil
        }
    }
}

// Audio track or voiceover studio option.
struct AudioTrackOption: Identifiable, Codable, Hashable {
    var id: String
    let name: String
    let url: String
    let isOriginal: Bool
    let language: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, isOriginal, language
    }

    init(id: String, name: String, url: String, isOriginal: Bool = false, language: String? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.isOriginal = isOriginal
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Студия"
        self.url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""
        self.isOriginal = (try? container.decodeIfPresent(Bool.self, forKey: .isOriginal)) ?? false
        self.language = try? container.decodeIfPresent(String.self, forKey: .language)
    }
}

// Subtitle track option.
struct SubtitleOption: Identifiable, Codable, Hashable {
    var id: String
    let name: String
    let language: String
    let url: String?
    let isEmbedded: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, language, url, isEmbedded
    }

    init(id: String, name: String, language: String = "ru", url: String? = nil, isEmbedded: Bool = false) {
        self.id = id
        self.name = name
        self.language = language
        self.url = url
        self.isEmbedded = isEmbedded
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        self.name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? "Субтитры"
        self.language = (try? container.decodeIfPresent(String.self, forKey: .language)) ?? "ru"
        self.url = try? container.decodeIfPresent(String.self, forKey: .url)
        self.isEmbedded = (try? container.decodeIfPresent(Bool.self, forKey: .isEmbedded)) ?? false
    }
}

// Individual episode entry within a serial playlist.
struct PlaylistItem: Identifiable, Codable, Hashable {
    var id: Int { index }
    let index: Int
    let seasonNumber: Int?
    let episodeNumber: Int?
    let title: String
    let url: String
    let duration: Double?
    let timecode: Double?

    enum CodingKeys: String, CodingKey {
        case index, seasonNumber, episodeNumber, title, url, duration, timecode
    }

    init(index: Int, seasonNumber: Int? = nil, episodeNumber: Int? = nil, title: String, url: String, duration: Double? = nil, timecode: Double? = nil) {
        self.index = index
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.title = title
        self.url = url
        self.duration = duration
        self.timecode = timecode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let idx = try? container.decodeIfPresent(Int.self, forKey: .index) {
            self.index = idx
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .index), let idx = Int(s) {
            self.index = idx
        } else {
            self.index = 0
        }

        if let s = try? container.decodeIfPresent(Int.self, forKey: .seasonNumber) {
            self.seasonNumber = s
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .seasonNumber), let s = Int(str) {
            self.seasonNumber = s
        } else {
            self.seasonNumber = nil
        }

        if let e = try? container.decodeIfPresent(Int.self, forKey: .episodeNumber) {
            self.episodeNumber = e
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .episodeNumber), let e = Int(str) {
            self.episodeNumber = e
        } else {
            self.episodeNumber = nil
        }

        self.title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? ""
        self.url = (try? container.decodeIfPresent(String.self, forKey: .url)) ?? ""

        if let d = try? container.decodeIfPresent(Double.self, forKey: .duration) {
            self.duration = d
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .duration), let d = Double(str) {
            self.duration = d
        } else {
            self.duration = nil
        }

        if let t = try? container.decodeIfPresent(Double.self, forKey: .timecode) {
            self.timecode = t
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .timecode), let t = Double(str) {
            self.timecode = t
        } else {
            self.timecode = nil
        }
    }
}


enum EpisodeQueue {
    enum NextEpisode {
        case available(PlaylistItem)
        case lastEpisode
        case unavailable
        case unknown
    }

    /// Source-local only. Never infer that another provider has the next episode.
    /// A finished playlist is normal; only a broken candidate warrants a warning.
    static func resolveNextEpisode(for payload: PlayPayload) -> NextEpisode {
        guard let playlist = payload.playlist, !playlist.isEmpty else { return .unknown }

        let exact = playlist.firstIndex {
            $0.url == payload.url &&
            (payload.episode == nil || $0.episodeNumber == nil || $0.episodeNumber == payload.episode) &&
            (payload.season == nil || $0.seasonNumber == nil || $0.seasonNumber == payload.season)
        }
        let identity = playlist.firstIndex {
            payload.episode != nil && $0.episodeNumber == payload.episode &&
            (payload.season == nil || $0.seasonNumber == nil || $0.seasonNumber == payload.season)
        }
        guard let index = exact ?? identity ?? playlist.firstIndex(where: { $0.url == payload.url }) else {
            return .unknown
        }
        guard index + 1 < playlist.count else { return .lastEpisode }

        let candidate = playlist[index + 1]
        guard let url = URL(string: candidate.url),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return .unavailable }

        if let current = payload.episode, let upcoming = candidate.episodeNumber {
            if let season = payload.season, let upcomingSeason = candidate.seasonNumber {
                if upcomingSeason == season {
                    guard upcoming == current + 1 else { return .unavailable }
                } else {
                    guard upcomingSeason == season + 1, upcoming == 1 else { return .unavailable }
                }
            } else {
                guard upcoming == current + 1 else { return .unavailable }
            }
        }
        return .available(candidate)
    }

    /// Never silently switch to another provider or voice while advancing a serial.
    static func chooseNextSource(
        from candidates: [ResolvedMediaSource], previous: PlayPayload,
        canonicalId: String, season: Int, episode: Int
    ) -> ResolvedMediaSource? {
        let sameProvider = candidates.filter { source in
            guard source.canonicalMediaId == canonicalId,
                  source.season == season, source.episode == episode else { return false }
            if let preferred = previous.plugin {
                let normalized = preferred.lowercased()
                if normalized == source.providerId.lowercased() { return true }
                if normalized.contains("online") && source.providerId == "online_mod" { return true }
            }
            return previous.pluginId == source.sourceKey
        }
        let sameVoice = sameProvider.filter { source in
            let matchesId = previous.currentStudio.map {
                !$0.isEmpty && source.studioId.caseInsensitiveCompare($0) == .orderedSame
            } ?? false
            let matchesName = previous.currentStudioName.map {
                !$0.isEmpty && source.studioName.caseInsensitiveCompare($0) == .orderedSame
            } ?? false
            if previous.currentStudio != nil || previous.currentStudioName != nil {
                return matchesId || matchesName
            }
            return true
        }
        // With no voice identity, only a single unique choice is safe.
        if previous.currentStudio == nil && previous.currentStudioName == nil &&
           Set(sameVoice.map(\.studioId)).count > 1 { return nil }
        return sameVoice.first { $0.quality == previous.currentQuality } ?? sameVoice.first
    }

    static func nextEpisode(for payload: PlayPayload) -> PlaylistItem? {
        if case let .available(item) = resolveNextEpisode(for: payload) { return item }
        return nil
    }

    static func shouldShowNextEpisodeAction(for payload: PlayPayload) -> Bool {
        switch resolveNextEpisode(for: payload) {
        case .available, .unavailable: return true
        case .lastEpisode, .unknown: return false
        }
    }
}

// Core payload communicated across the JavaScript bridge to trigger native playback.
struct PlayPayload: Identifiable, Codable, Equatable {
    // Keep a single fullScreenCover alive when AVPlayer switches episodes or qualities.
    var id: String { "\(action)_\(canonicalId ?? hash ?? url)" }
    var action: String
    var url: String
    var title: String
    var subtitle: String?
    var time: Double?
    var duration: Double?
    var hash: String?

    var canonicalId: String?
    var mediaType: String?
    var season: Int?
    var episode: Int?
    var currentQuality: String?
    var currentStudio: String?
    // Human-readable provider voice for this stream, when supplied by the source.
    var currentStudioName: String?
    var availableQualities: [QualityOption]?
    var availableStudios: [AudioTrackOption]?
    var availableSubtitles: [SubtitleOption]?
    var playlist: [PlaylistItem]?
    // Original catalog identity allows source-local next-episode lookup without a bundled playlist.
    var mediaLookupItem: MediaItem?
    var customHeaders: [String: String]?
    var isDiagnostic: Bool

    // Attribution and plugin source identity
    var plugin: String?
    var pluginId: String?
    var requestId: String?
    var selectionContext: String?
    // Assigned only by native source resolution; never decoded from bridge input.
    var diagnosticActionId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case action, url, title, subtitle, time, duration, hash
        case canonicalId, mediaType, season, episode, currentQuality, currentStudio, currentStudioName
        case availableQualities, availableStudios, availableSubtitles, playlist, mediaLookupItem, customHeaders, isDiagnostic
        case plugin, pluginId, requestId, selectionContext
    }

    init(
        action: String = "play",
        url: String,
        title: String = "Воспроизведение",
        subtitle: String? = nil,
        time: Double? = nil,
        duration: Double? = nil,
        hash: String? = nil,
        canonicalId: String? = nil,
        mediaType: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        currentQuality: String? = nil,
        currentStudio: String? = nil,
        currentStudioName: String? = nil,
        availableQualities: [QualityOption]? = nil,
        availableStudios: [AudioTrackOption]? = nil,
        availableSubtitles: [SubtitleOption]? = nil,
        playlist: [PlaylistItem]? = nil,
        mediaLookupItem: MediaItem? = nil,
        customHeaders: [String: String]? = nil,
        isDiagnostic: Bool = false,
        plugin: String? = nil,
        pluginId: String? = nil,
        requestId: String? = nil,
        selectionContext: String? = nil
    ) {
        self.action = action
        self.url = url
        self.title = title
        self.subtitle = subtitle
        self.time = time
        self.duration = duration
        self.hash = hash
        self.canonicalId = canonicalId
        self.mediaType = mediaType
        self.season = season
        self.episode = episode
        self.currentQuality = currentQuality
        self.currentStudio = currentStudio
        self.currentStudioName = currentStudioName
        self.availableQualities = availableQualities
        self.availableStudios = availableStudios
        self.availableSubtitles = availableSubtitles
        self.playlist = playlist
        self.mediaLookupItem = mediaLookupItem
        self.customHeaders = customHeaders
        self.isDiagnostic = isDiagnostic
        self.plugin = plugin
        self.pluginId = pluginId
        self.requestId = requestId
        self.selectionContext = selectionContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.url = try container.decode(String.self, forKey: .url)
        self.action = (try? container.decodeIfPresent(String.self, forKey: .action)) ?? "play"
        self.title = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? "Воспроизведение"
        self.subtitle = try? container.decodeIfPresent(String.self, forKey: .subtitle)
        self.hash = try? container.decodeIfPresent(String.self, forKey: .hash)
        self.canonicalId = try? container.decodeIfPresent(String.self, forKey: .canonicalId)
        self.mediaType = try? container.decodeIfPresent(String.self, forKey: .mediaType)
        self.currentQuality = try? container.decodeIfPresent(String.self, forKey: .currentQuality)
        self.currentStudio = try? container.decodeIfPresent(String.self, forKey: .currentStudio)
        self.currentStudioName = try? container.decodeIfPresent(String.self, forKey: .currentStudioName)

        // Resilient boolean decode
        if let diag = try? container.decodeIfPresent(Bool.self, forKey: .isDiagnostic) {
            self.isDiagnostic = diag
        } else if let diagStr = try? container.decodeIfPresent(String.self, forKey: .isDiagnostic) {
            self.isDiagnostic = (diagStr.lowercased() == "true" || diagStr == "1")
        } else if let diagInt = try? container.decodeIfPresent(Int.self, forKey: .isDiagnostic) {
            self.isDiagnostic = (diagInt == 1)
        } else {
            self.isDiagnostic = false
        }

        // Resilient time decode (Double, Int, or numeric String)
        if let d = try? container.decodeIfPresent(Double.self, forKey: .time) {
            self.time = d
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .time), let d = Double(s) {
            self.time = d
        } else if let i = try? container.decodeIfPresent(Int.self, forKey: .time) {
            self.time = Double(i)
        } else {
            self.time = nil
        }

        // Resilient duration decode
        if let d = try? container.decodeIfPresent(Double.self, forKey: .duration) {
            self.duration = d
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .duration), let d = Double(s) {
            self.duration = d
        } else if let i = try? container.decodeIfPresent(Int.self, forKey: .duration) {
            self.duration = Double(i)
        } else {
            self.duration = nil
        }

        // Resilient season decode (Int or String)
        if let i = try? container.decodeIfPresent(Int.self, forKey: .season) {
            self.season = i
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .season), let i = Int(s) {
            self.season = i
        } else {
            self.season = nil
        }

        // Resilient episode decode (Int or String)
        if let i = try? container.decodeIfPresent(Int.self, forKey: .episode) {
            self.episode = i
        } else if let s = try? container.decodeIfPresent(String.self, forKey: .episode), let i = Int(s) {
            self.episode = i
        } else {
            self.episode = nil
        }

        self.availableQualities = try? container.decodeIfPresent([QualityOption].self, forKey: .availableQualities)
        self.availableStudios = try? container.decodeIfPresent([AudioTrackOption].self, forKey: .availableStudios)
        self.availableSubtitles = try? container.decodeIfPresent([SubtitleOption].self, forKey: .availableSubtitles)
        self.playlist = try? container.decodeIfPresent([PlaylistItem].self, forKey: .playlist)
        self.mediaLookupItem = try? container.decodeIfPresent(MediaItem.self, forKey: .mediaLookupItem)
        self.customHeaders = try? container.decodeIfPresent([String: String].self, forKey: .customHeaders)

        self.plugin = try? container.decodeIfPresent(String.self, forKey: .plugin)
        self.pluginId = try? container.decodeIfPresent(String.self, forKey: .pluginId)
        self.requestId = try? container.decodeIfPresent(String.self, forKey: .requestId)
        self.selectionContext = try? container.decodeIfPresent(String.self, forKey: .selectionContext)
    }
}

// Persistent watch history entry keyed by canonical media identifiers.
struct WatchHistoryRecord: Codable, Identifiable {
    var id: String { "\(canonicalId)|s\(season)|e\(episode)" }
    let canonicalId: String
    var title: String?
    var url: String?
    let season: Int
    let episode: Int
    let timecode: Double
    let duration: Double
    let percent: Int
    let studio: String?
    let quality: String?
    let sourceId: String?
    let updatedAt: Date
}

// User-defined defaults and playback preferences.
struct UserPlaybackPreferences: Codable {
    let preferredStudio: String?
    let preferredQuality: String?
    let autoNextEpisode: Bool
    let preferNativePlayer: Bool
    let externalTorrServerHost: String?
}

/// A callback must still belong to the same operation after an asynchronous hop.
/// Invalidating an observer alone cannot revoke queued work.
@MainActor
final class PlaybackSessionToken {
    private(set) var current: UUID? = UUID()

    @discardableResult
    func renew() -> UUID {
        let token = UUID()
        current = token
        return token
    }

    func invalidate() { current = nil }

    func accepts(_ token: UUID?) -> Bool {
        guard let current, let token else { return false }
        return current == token
    }
}

// Shared playback lifecycle controller; all ownership mutations are main-actor isolated.
@MainActor
final class PlayerPlaybackController: ObservableObject {
    static let shared = PlayerPlaybackController()

    private(set) weak var activePlayer: AVPlayer?
    private(set) weak var activeController: AVPlayerViewController?
    var onExplicitDismiss: (@MainActor () -> Void)?
    private var activeOwner: UUID?
    private var activeTeardown: (@MainActor () -> Void)?
    private var audioOwners: Set<UUID> = []
    private var pictureInPictureSessions: [UUID: AnyObject] = [:]
    private let deactivateAudio: @MainActor () -> Void

    init(deactivateAudio: @escaping @MainActor () -> Void = {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }) {
        self.deactivateAudio = deactivateAudio
    }

    func register(player: AVPlayer, controller: AVPlayerViewController, owner: UUID, teardown: @escaping @MainActor () -> Void) {
        activePlayer = player
        activeController = controller
        activeOwner = owner
        activeTeardown = teardown
    }

    /// Native Player V2 owns an AVPlayerLayer rather than AVPlayerViewController.
    func registerLayer(player: AVPlayer, owner: UUID, teardown: @escaping @MainActor () -> Void) {
        activePlayer = player
        activeController = nil
        activeOwner = owner
        activeTeardown = teardown
    }

    func isActive(owner: UUID) -> Bool { activeOwner == owner }

    func claimAudioSession(owner: UUID) { audioOwners.insert(owner) }

    func releaseAudioSession(owner: UUID) {
        guard audioOwners.remove(owner) != nil, audioOwners.isEmpty else { return }
        deactivateAudio()
    }

    func unregister(owner: UUID) {
        guard activeOwner == owner else { return }
        activePlayer = nil
        activeController = nil
        activeOwner = nil
        activeTeardown = nil
    }

    func retainPictureInPicture(_ session: AnyObject, owner: UUID) {
        pictureInPictureSessions[owner] = session
    }

    func releasePictureInPicture(owner: UUID) {
        pictureInPictureSessions[owner] = nil
    }

    func pauseAndTeardown() {
        print("[PlayerPlaybackController] Explicit pauseAndTeardown requested")
        let player = activePlayer
        let controller = activeController
        let owner = activeOwner
        // Remove observers while their player is still retained, before detaching it.
        activeTeardown?()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        controller?.player = nil
        if let owner {
            unregister(owner: owner)
            releaseAudioSession(owner: owner)
        }
        // A dismissal callback may start new playback; never deactivate after it.
        onExplicitDismiss?()
    }
}
