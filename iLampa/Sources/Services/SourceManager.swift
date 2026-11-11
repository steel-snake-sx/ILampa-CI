import Foundation
import UIKit
import Combine

// Coordinates stream discovery, security verification, external player routing,
// and implements SourceRegistryProtocol with dynamic 1:M plugin invalidation.
@MainActor
final class SourceManager: ObservableObject, SourceRegistryProtocol {
    static let shared = SourceManager()

    var customTorrServerHost: String? = nil

    @Published private(set) var registeredSources: [LampaSourceRecord] = []

    private let storageKey = "ilampa_sources_registry_v1"
    private let defaults = UserDefaults.standard

    private init() {
        loadSources()
    }

    private func loadSources() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([LampaSourceRecord].self, from: data),
           !decoded.isEmpty {
            // Dynamic capabilities belong to the current runtime, not a previous process.
            self.registeredSources = decoded.filter { $0.parentPluginId == nil }.map { record in
                var record = record
                record.operationalStatus = record.canonicalKey == "anilibria_native" ? .initialized : .unconfigured
                return record
            }
        } else {
            // Baseline built-in sources
            self.registeredSources = [
                LampaSourceRecord(
                    id: UUID(),
                    canonicalKey: "anilibria_native",
                    displayName: "AniLibria Native API",
                    parentPluginId: nil,
                    providerType: .nativeAPI,
                    operationalStatus: .initialized,
                    supportedMediaTypes: [.anime],
                    supportedFeatures: [.multiQuality]
                ),
                LampaSourceRecord(
                    id: UUID(),
                    canonicalKey: "torrserver_default",
                    displayName: "TorrServer (Торрент-движок)",
                    parentPluginId: nil,
                    providerType: .torrServer,
                    operationalStatus: .unconfigured,
                    supportedMediaTypes: [.movie, .tvSeries, .anime, .cartoon],
                    supportedFeatures: [.multiQuality, .subtitles]
                )
            ]
            persist()
        }
        for (key, name) in [("jellyfin", "Jellyfin"), ("plex", "Plex"), ("emby", "Emby")] {
            if !registeredSources.contains(where: { $0.canonicalKey == key }) {
                registeredSources.append(LampaSourceRecord(canonicalKey: key, displayName: name,
                    providerType: .nativeAPI, operationalStatus: .unconfigured, supportedMediaTypes: [.movie]))
            }
        }
        if !registeredSources.contains(where: { $0.canonicalKey == "kodik_anime" }) {
            registeredSources.append(LampaSourceRecord(
                canonicalKey: "kodik_anime",
                displayName: "Kodik Anime API",
                parentPluginId: nil,
                providerType: .nativeAPI,
                operationalStatus: .unconfigured,
                supportedMediaTypes: [.anime],
                supportedFeatures: [.multiQuality]
            ))
        }
        if !registeredSources.contains(where: { $0.canonicalKey == "online_mod" }) {
            registeredSources.append(LampaSourceRecord(
                canonicalKey: "online_mod",
                displayName: "Онлайн-балансеры (Online Mod)",
                parentPluginId: nil,
                providerType: .pluginComponent,
                operationalStatus: .initialized,
                supportedMediaTypes: [.movie, .tvSeries],
                supportedFeatures: [.multiQuality, .multiVoice]
            ))
        }
        if !registeredSources.contains(where: { $0.canonicalKey == "sample_anilibria_1080p" }) {
            registeredSources.append(LampaSourceRecord(
                canonicalKey: "sample_anilibria_1080p",
                displayName: "AniLibria 1080p (Тестовый поток)",
                parentPluginId: nil,
                providerType: .directFeed,
                operationalStatus: .initialized,
                supportedMediaTypes: [.anime],
                supportedFeatures: [.multiQuality],
                isEnabled: true,
                customEndpointUrl: "https://cache.libria.fun/videos/media/ts/10337/1/1080/25b0e790d0149eaa94c4bd9512bfdbbf.m3u8"
            ))
        }
        persist()
    }

    func addDirectStream(title: String, streamUrl: String) -> LampaSourceRecord {
        let key = "direct_\(UUID().uuidString.prefix(8).lowercased())"
        let record = LampaSourceRecord(
            canonicalKey: key,
            displayName: title.trimmingCharacters(in: .whitespacesAndNewlines),
            parentPluginId: nil,
            providerType: .directFeed,
            operationalStatus: .initialized,
            supportedMediaTypes: [.movie, .tvSeries],
            supportedFeatures: [.multiQuality],
            isEnabled: true,
            customEndpointUrl: streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        registeredSources.append(record)
        persist()
        SourceProviderEngine.shared.invalidateCache()
        return record
    }

    func addCustomServer(title: String, endpointUrl: String, serverType: SourceProviderType) -> LampaSourceRecord {
        let key = "server_\(UUID().uuidString.prefix(8).lowercased())"
        let record = LampaSourceRecord(
            canonicalKey: key,
            displayName: title.trimmingCharacters(in: .whitespacesAndNewlines),
            parentPluginId: nil,
            providerType: serverType,
            operationalStatus: .unconfigured,
            supportedMediaTypes: [.movie, .tvSeries],
            supportedFeatures: [.multiQuality],
            isEnabled: true,
            customEndpointUrl: endpointUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        registeredSources.append(record)
        persist()
        SourceProviderEngine.shared.invalidateCache()
        return record
    }

    func removeSource(id: UUID) {
        registeredSources.removeAll(where: { $0.id == id })
        persist()
        SourceProviderEngine.shared.invalidateCache()
    }

    func toggleSource(id: UUID) {
        if let idx = registeredSources.firstIndex(where: { $0.id == id }) {
            registeredSources[idx].isEnabled.toggle()
            persist()
            SourceProviderEngine.shared.invalidateCache()
        }
    }

    func bulkToggleAll(enabled: Bool) {
        for i in 0..<registeredSources.count {
            registeredSources[i].isEnabled = enabled
        }
        persist()
        SourceProviderEngine.shared.invalidateCache()
    }

    func resetToDefaults() {
        defaults.removeObject(forKey: storageKey)
        loadSources()
        SourceProviderEngine.shared.invalidateCache()
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(registeredSources) {
            defaults.set(encoded, forKey: storageKey)
        }
    }

    // MARK: - SourceRegistryProtocol

    func registerSource(_ source: LampaSourceRecord) {
        let existing = registeredSources.first(where: { $0.canonicalKey == source.canonicalKey })
        // A canonical source cannot be stolen by a different plugin (or overwrite a built-in).
        if let existing, existing.parentPluginId != source.parentPluginId {
            DiagnosticsLogManager.shared.log(category: "[SourceManager]", message: "Отклонена смена владельца источника \(source.canonicalKey)", level: .warning)
            return
        }
        let record = LampaSourceRecord(id: existing?.id ?? source.id, canonicalKey: source.canonicalKey,
            displayName: source.displayName, parentPluginId: source.parentPluginId, providerType: source.providerType,
            operationalStatus: source.operationalStatus, supportedMediaTypes: source.supportedMediaTypes,
            supportedFeatures: source.supportedFeatures, consecutiveFailureCount: source.consecutiveFailureCount,
            lastResolvedAt: source.lastResolvedAt)
        registeredSources.removeAll(where: { $0.canonicalKey == source.canonicalKey })
        registeredSources.append(record)
        persist()

        SourceProviderEngine.shared.invalidateCache()

        DiagnosticsLogManager.shared.log(
            category: "[SourceManager]",
            message: "Зарегистрирован источник «\(source.displayName)» [\(source.canonicalKey)], статус: \(source.operationalStatus.rawValue)",
            level: .info
        )
    }

    func unregisterSources(forPluginId pluginId: UUID) {
        let countBefore = registeredSources.count
        registeredSources.removeAll(where: { $0.parentPluginId == pluginId })
        let removedCount = countBefore - registeredSources.count
        persist()

        SourceProviderEngine.shared.invalidateCache()

        DiagnosticsLogManager.shared.log(
            category: "[SourceManager]",
            message: "Инвалидация источников для плагина \(pluginId): удалено \(removedCount) источников",
            level: .info
        )
    }

    func updateOperationalStatus(sourceKey: String, status: ProviderOperationalStatus) {
        if let idx = registeredSources.firstIndex(where: { $0.canonicalKey == sourceKey }) {
            registeredSources[idx].operationalStatus = status
            if status == .playbackVerified || status == .resolutionVerified {
                registeredSources[idx].lastResolvedAt = Date()
                registeredSources[idx].consecutiveFailureCount = 0
            } else if status == .failed {
                registeredSources[idx].consecutiveFailureCount += 1
            }
            persist()

        }
    }

    func sources(forMediaCategory category: ContractMediaCategory) -> [LampaSourceRecord] {
        return registeredSources.filter { $0.supportedMediaTypes.contains(category) }
    }

    func clearDynamicSources() {
        registeredSources.removeAll(where: { $0.parentPluginId != nil })
        persist()

        SourceProviderEngine.shared.invalidateCache()
    }

    // MARK: - Stream Sanitization & External Players

    // Validates URL schemes and guards against unauthorized internal network access.
    func sanitizeStreamUrl(_ rawUrl: String) throws -> URL {
        guard let url = URL(string: rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "SourceManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL string"])
        }

        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "infuse", "open-vidhub"].contains(scheme) else {
            throw NSError(domain: "SourceManager", code: 403, userInfo: [NSLocalizedDescriptionKey: "Unsupported stream protocol: \(url.scheme ?? "")"])
        }

        if ["http", "https"].contains(scheme), url.host == nil {
            throw NSError(domain: "SourceManager", code: 400, userInfo: [NSLocalizedDescriptionKey: "Stream URL has no host"])
        }

        if let host = url.host?.lowercased() {
            let configuredServers = [("torrserver", "8090"), ("jellyfin", "8096"), ("plex", "32400"), ("emby", "8096")]
            let isConfiguredLocalServer = host == customTorrServerHost?.lowercased() || configuredServers.contains { key, port in
                guard let server = ProviderHTTP.serverURL(host: defaults.string(forKey: key + "_host") ?? "",
                    port: defaults.string(forKey: key + "_port") ?? port) else { return false }
                return server.host?.lowercased() == host && server.port == url.port && server.scheme == url.scheme
            }

            // Block cloud provider link-local metadata endpoints.
            if host.hasPrefix("169.254.") {
                throw NSError(domain: "SourceManager", code: 403, userInfo: [NSLocalizedDescriptionKey: "Blocked link-local address"])
            }

            // Restrict unconfigured local loopback addresses.
            if (host == "localhost" || host.hasPrefix("127.") || host == "0.0.0.0" || host == "[::1]" || host == "::1") && !isConfiguredLocalServer {
                throw NSError(domain: "SourceManager", code: 403, userInfo: [NSLocalizedDescriptionKey: "Blocked unconfigured loopback address"])
            }
        }

        return url
    }

    func generateInfuseUrl(streamUrl: String) -> URL? {
        var components = URLComponents(string: "infuse://x-callback-url/play")
        components?.queryItems = [
            URLQueryItem(name: "url", value: streamUrl)
        ]
        return components?.url
    }

    func openInExternalPlayer(streamUrl: String) {
        guard let infuseUrl = generateInfuseUrl(streamUrl: streamUrl) else { return }

        DispatchQueue.main.async {
            if UIApplication.shared.canOpenURL(infuseUrl) {
                UIApplication.shared.open(infuseUrl, options: [:], completionHandler: nil)
            } else if let vidhubUrl = URL(string: "open-vidhub://play?url=\(streamUrl)"),
                      UIApplication.shared.canOpenURL(vidhubUrl) {
                UIApplication.shared.open(vidhubUrl, options: [:], completionHandler: nil)
            } else if let appStoreUrl = URL(string: "https://apps.apple.com/app/infuse-video-player/id1136220934") {
                UIApplication.shared.open(appStoreUrl, options: [:], completionHandler: nil)
            }
        }
    }
}
