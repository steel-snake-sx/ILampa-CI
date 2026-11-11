import Foundation

// MARK: - Scalable Management Layer Data Contracts
// Defines formal contracts for Plugin & Source lifecycles, 1:M relationships,
// capability tracking, deduplication, and strict media identity.

/// Origin of a registered plugin.
enum PluginOrigin: String, Codable, CaseIterable {
    case bundled = "bundled"
    case communityRemote = "community_remote"
    case userCustom = "user_custom"
}

/// Lifecycle states for an installed plugin.
enum LampaPluginLifecycleState: Codable, Equatable, Hashable {
    case inactive
    case inactiveAlternate(reason: String)
    case loading
    case active
    case failed(reason: String)

    var isOperational: Bool {
        if case .active = self { return true }
        return false
    }

    var displayLabel: String {
        switch self {
        case .inactive: return "Отключен"
        case .inactiveAlternate: return "Неактивен (вторичный)"
        case .loading: return "Загрузка..."
        case .active: return "Активен"
        case .failed(let reason): return "Сбой: \(reason)"
        }
    }
}

/// Classification of source providers.
enum SourceProviderType: String, Codable, CaseIterable {
    case pluginComponent = "plugin_component"
    case nativeAPI = "native_api"
    case torrServer = "torrserver"
    case directFeed = "direct_feed"
}

/// Media categories supported by providers.
enum ContractMediaCategory: String, Codable, CaseIterable {
    case movie = "movie"
    case tvSeries = "tv_series"
    case anime = "anime"
    case cartoon = "cartoon"
}

/// Feature flags exposed by source resolvers.
enum SourceFeature: String, Codable, CaseIterable {
    case multiQuality = "multi_quality"
    case multiVoice = "multi_voice"
    case subtitles = "subtitles"
    case playlist = "playlist"
    case customHeaders = "custom_headers"
}

// MARK: - Persistent Plugin Record
/// Canonical descriptor for an installed Lampa JavaScript plugin.
struct LampaPluginRecord: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let url: URL
    var name: String
    var version: String
    var author: String?
    var license: String?
    var origin: PluginOrigin
    var lifecycleState: LampaPluginLifecycleState
    var registeredComponents: Set<String>
    var providedSourceKeys: [String]
    let installedAt: Date
    var lastValidatedAt: Date?
    // Enable intent is distinct from the last execution result. Optional for Build 14 migration.
    var desiredEnabled: Bool?
    // A deterministic invalid remote response is not retried during unrelated runtime rebuilds.
    // User intent remains enabled and an explicit disable/re-enable can retry it.
    var automaticRetryBlocked: Bool?
    // Consent is bound to exact UTF-8 script bytes, never to a URL or origin.
    var approvedScriptSHA256: String?

    init(
        id: UUID = UUID(),
        url: URL,
        name: String,
        version: String = "1.0.0",
        author: String? = nil,
        license: String? = nil,
        origin: PluginOrigin = .userCustom,
        lifecycleState: LampaPluginLifecycleState = .inactive,
        registeredComponents: Set<String> = [],
        providedSourceKeys: [String] = [],
        installedAt: Date = Date(),
        lastValidatedAt: Date? = nil,
        automaticRetryBlocked: Bool? = false
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.version = version
        self.author = author
        self.license = license
        self.origin = origin
        self.lifecycleState = lifecycleState
        self.registeredComponents = registeredComponents
        self.providedSourceKeys = providedSourceKeys
        self.installedAt = installedAt
        self.lastValidatedAt = lastValidatedAt
        self.desiredEnabled = lifecycleState != .inactive
        self.automaticRetryBlocked = automaticRetryBlocked
    }
}

// MARK: - Persistent Source Record
/// Canonical descriptor for a video source provider (e.g. Rezka, AniLibria, Collaps).
/// A single plugin may register multiple sources (1:M relationship).
struct LampaSourceRecord: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let canonicalKey: String
    var displayName: String
    let parentPluginId: UUID?
    let providerType: SourceProviderType
    var operationalStatus: ProviderOperationalStatus
    var supportedMediaTypes: Set<ContractMediaCategory>
    var supportedFeatures: Set<SourceFeature>
    var consecutiveFailureCount: Int
    var lastResolvedAt: Date?
    var customEndpointUrl: String?
    var isEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id, canonicalKey, displayName, parentPluginId, providerType
        case operationalStatus, supportedMediaTypes, supportedFeatures
        case consecutiveFailureCount, lastResolvedAt, customEndpointUrl, isEnabled
    }

    init(
        id: UUID = UUID(),
        canonicalKey: String,
        displayName: String,
        parentPluginId: UUID? = nil,
        providerType: SourceProviderType = .pluginComponent,
        operationalStatus: ProviderOperationalStatus = .notInstalled,
        supportedMediaTypes: Set<ContractMediaCategory> = [.movie, .tvSeries],
        supportedFeatures: Set<SourceFeature> = [.multiQuality],
        consecutiveFailureCount: Int = 0,
        lastResolvedAt: Date? = nil,
        isEnabled: Bool = true,
        customEndpointUrl: String? = nil
    ) {
        self.id = id
        self.canonicalKey = canonicalKey
        self.displayName = displayName
        self.parentPluginId = parentPluginId
        self.providerType = providerType
        self.operationalStatus = operationalStatus
        self.supportedMediaTypes = supportedMediaTypes
        self.supportedFeatures = supportedFeatures
        self.consecutiveFailureCount = consecutiveFailureCount
        self.lastResolvedAt = lastResolvedAt
        self.isEnabled = isEnabled
        self.customEndpointUrl = customEndpointUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.canonicalKey = try container.decode(String.self, forKey: .canonicalKey)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.parentPluginId = try container.decodeIfPresent(UUID.self, forKey: .parentPluginId)
        self.providerType = try container.decode(SourceProviderType.self, forKey: .providerType)
        self.operationalStatus = try container.decode(ProviderOperationalStatus.self, forKey: .operationalStatus)
        self.supportedMediaTypes = try container.decode(Set<ContractMediaCategory>.self, forKey: .supportedMediaTypes)
        self.supportedFeatures = try container.decode(Set<SourceFeature>.self, forKey: .supportedFeatures)
        self.consecutiveFailureCount = try container.decode(Int.self, forKey: .consecutiveFailureCount)
        self.lastResolvedAt = try container.decodeIfPresent(Date.self, forKey: .lastResolvedAt)
        self.customEndpointUrl = try container.decodeIfPresent(String.self, forKey: .customEndpointUrl)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

// MARK: - Media Playback Descriptor
/// Encapsulates strict media identity from search to native AVPlayer handoff.
/// Prevents cross-title collisions (e.g. 'Vision Quest' matching unrelated anime).
struct MediaPlaybackDescriptor: Identifiable, Codable, Equatable {
    let id: UUID
    let canonicalMediaId: String
    let mediaTitle: String
    let selectedSourceId: UUID
    let sourceKey: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let selectedQuality: String
    let selectedAudioVariant: String?
    let streamUrl: String
    let headers: [String: String]?
    let subtitles: [SubtitleOption]?
    let playlist: [PlaylistItem]?

    init(
        id: UUID = UUID(),
        canonicalMediaId: String,
        mediaTitle: String,
        selectedSourceId: UUID,
        sourceKey: String,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        selectedQuality: String = "auto",
        selectedAudioVariant: String? = nil,
        streamUrl: String,
        headers: [String: String]? = nil,
        subtitles: [SubtitleOption]? = nil,
        playlist: [PlaylistItem]? = nil
    ) {
        self.id = id
        self.canonicalMediaId = canonicalMediaId
        self.mediaTitle = mediaTitle
        self.selectedSourceId = selectedSourceId
        self.sourceKey = sourceKey
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.selectedQuality = selectedQuality
        self.selectedAudioVariant = selectedAudioVariant
        self.streamUrl = streamUrl
        self.headers = headers
        self.subtitles = subtitles
        self.playlist = playlist
    }
}

// MARK: - Scalable Management Layer Protocols

/// Lifecycle operations for plugins in the hybrid architecture.
@MainActor protocol PluginLifecycleManagerProtocol: AnyObject {
    var installedPlugins: [LampaPluginRecord] { get }
    func installPlugin(url: URL, origin: PluginOrigin) async throws -> LampaPluginRecord
    func togglePlugin(id: UUID, enabled: Bool) async throws
    func removePlugin(id: UUID) async throws
    func validatePluginCompatibility(url: URL) async -> Result<Set<String>, Error>
}

/// Registry operations for source providers.
@MainActor protocol SourceRegistryProtocol: AnyObject {
    var registeredSources: [LampaSourceRecord] { get }
    func registerSource(_ source: LampaSourceRecord)
    func unregisterSources(forPluginId pluginId: UUID)
    func updateOperationalStatus(sourceKey: String, status: ProviderOperationalStatus)
    func sources(forMediaCategory category: ContractMediaCategory) -> [LampaSourceRecord]
}

// MARK: - Convenience Helpers
extension LampaPluginRecord {
    var isEnabled: Bool {
        get { desiredEnabled ?? (lifecycleState == .active) }
        set {
            desiredEnabled = newValue
            lifecycleState = newValue ? .loading : .inactive
        }
    }

    var urlString: String {
        url.absoluteString
    }

    var isEligibleForAutomaticRuntime: Bool {
        isEnabled && automaticRetryBlocked != true
    }

    var errorDescription: String? {
        if case .failed(let reason) = lifecycleState {
            return reason
        }
        return nil
    }
}
