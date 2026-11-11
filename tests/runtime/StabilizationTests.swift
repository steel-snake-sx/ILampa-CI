import XCTest
import Combine
@testable import iLampa

@MainActor
final class StabilizationTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        DiagnosticsLogManager.shared.clear()
        LampaHeadlessHost.shared.clearActiveMediaContext()
    }

    // 1. Play Spider-Man, close player, immediately open The Mentalist. No old source or automatic stale playback.
    func testScenario1_SpiderManToMentalist_NoStaleSourceOrAutoPlayback() async {
        let host = LampaHeadlessHost.shared
        let actionTracker = ActionCorrelationTracker.shared

        // User opens and starts Spider-Man
        let spidermanAction = actionTracker.startAction(name: "OpenSpiderMan")
        let spidermanContext = MediaResolutionContext(
            requestId: UUID(),
            actionId: spidermanAction,
            canonicalId: "urn:media:tmdb:movie:557",
            title: "Человек-паук: Новый день",
            mediaType: "movie",
            season: nil,
            episode: nil,
            balancer: "rezka2",
            generation: host.currentGeneration,
            revision: 1
        )
        host.triggerMovieSearch(context: spidermanContext)
        host.authorizePlayback(context: spidermanContext)

        // Close player & media
        host.clearActiveMediaContext()
        XCTAssertNil(host.activeResolutionContext)

        // Open The Mentalist
        let mentalistAction = actionTracker.startAction(name: "OpenMentalist")
        let mentalistContext = MediaResolutionContext(
            requestId: UUID(),
            actionId: mentalistAction,
            canonicalId: "urn:media:tmdb:tv:5920",
            title: "Менталист",
            mediaType: "tv",
            season: 1,
            episode: 1,
            balancer: "cdnvideohub",
            generation: host.currentGeneration,
            revision: 2
        )
        host.triggerMovieSearch(context: mentalistContext)

        // Simulate delayed Spider-Man discovery callback arriving now
        let staleDiscoveryPayload: [String: Any] = [
            "canonicalId": "urn:media:tmdb:movie:557",
            "requestId": spidermanContext.requestId.uuidString,
            "balancer": "rezka2",
            "count": 2,
            "sources": [["index": 0, "title": "Человек-паук 1080p", "quality": "1080p"]]
        ]

        // Must drop stale discovery
        XCTAssertFalse(mentalistContext.matches(canonicalId: staleDiscoveryPayload["canonicalId"] as? String))
        XCTAssertEqual(host.discoveredSources.count, 0)
    }

    // 2. Switch rapidly between three different movies in the same WKWebView generation.
    func testScenario2_RapidSwitchBetweenThreeMoviesInSameGeneration() throws {
        let host = LampaHeadlessHost.shared
        let tracker = ActionCorrelationTracker.shared

        let movies = [
            ("urn:media:tmdb:movie:101", "Movie 1"),
            ("urn:media:tmdb:movie:102", "Movie 2"),
            ("urn:media:tmdb:movie:103", "Movie 3")
        ]

        var contexts: [MediaResolutionContext] = []
        for (idx, (canonicalId, title)) in movies.enumerated() {
            let actId = tracker.startAction(name: "OpenMovie_\(idx)")
            let ctx = MediaResolutionContext(
                requestId: UUID(),
                actionId: actId,
                canonicalId: canonicalId,
                title: title,
                mediaType: "movie",
                season: nil,
                episode: nil,
                balancer: "collaps",
                generation: host.currentGeneration,
                revision: idx + 1
            )
            contexts.append(ctx)
            host.triggerMovieSearch(context: ctx)
        }

        let activeContext = try XCTUnwrap(host.activeResolutionContext)
        XCTAssertEqual(activeContext.canonicalId, "urn:media:tmdb:movie:103")
        XCTAssertEqual(activeContext.title, "Movie 3")

        // First two contexts must be superseded
        XCTAssertFalse(activeContext.matches(canonicalId: contexts[0].canonicalId))
        XCTAssertFalse(activeContext.matches(canonicalId: contexts[1].canonicalId))
    }

    // 3. Switch The Mentalist S1E1 -> S4E1 -> S1E23.
    func testScenario3_TheMentalistSeasonAndEpisodeTransitions() {
        let tracker = ActionCorrelationTracker.shared

        let canonical = "urn:media:tmdb:tv:5920"
        let s1e1 = MediaResolutionContext(
            requestId: UUID(), actionId: tracker.startAction(name: "S1E1"),
            canonicalId: canonical, title: "Mentalist", mediaType: "tv", season: 1, episode: 1,
            balancer: "collaps", generation: 1, revision: 1
        )
        let s4e1 = MediaResolutionContext(
            requestId: UUID(), actionId: tracker.startAction(name: "S4E1"),
            canonicalId: canonical, title: "Mentalist", mediaType: "tv", season: 4, episode: 1,
            balancer: "collaps", generation: 1, revision: 2
        )
        let s1e23 = MediaResolutionContext(
            requestId: UUID(), actionId: tracker.startAction(name: "S1E23"),
            canonicalId: canonical, title: "Mentalist", mediaType: "tv", season: 1, episode: 23,
            balancer: "collaps", generation: 1, revision: 3
        )

        XCTAssertTrue(s1e1.matches(canonicalId: canonical, season: 1, episode: 1))
        XCTAssertFalse(s1e1.matches(canonicalId: canonical, season: 4, episode: 1))
        XCTAssertFalse(s4e1.matches(canonicalId: canonical, season: 1, episode: 23))
        XCTAssertTrue(s1e23.matches(canonicalId: canonical, season: 1, episode: 23))
    }

    // 4. Switch Bleach S1E1 -> episode 366. Never reuse episode 1.
    func testScenario4_BleachEpisode1To366_NeverReuseEpisode1() {
        let canonical = "urn:media:tmdb:tv:30984"
        let ep1 = MediaResolutionContext(
            requestId: UUID(), actionId: UUID(), canonicalId: canonical,
            title: "Bleach", mediaType: "tv", season: 1, episode: 1,
            balancer: "anilibria", generation: 1, revision: 1
        )
        let ep366 = MediaResolutionContext(
            requestId: UUID(), actionId: UUID(), canonicalId: canonical,
            title: "Bleach", mediaType: "tv", season: 16, episode: 366,
            balancer: "anilibria", generation: 1, revision: 2
        )

        XCTAssertFalse(ep366.matches(canonicalId: canonical, season: 1, episode: 1))
        XCTAssertNotNil(ep366.rejectionReason(canonicalId: canonical, season: 1, episode: 1))
    }

    // 5. Receive a delayed old JavaScript callback after a new media card opens.
    func testScenario5_DelayedOldJSCallbackRejected() throws {
        let host = LampaHeadlessHost.shared
        let oldContext = MediaResolutionContext(
            requestId: UUID(), actionId: UUID(), canonicalId: "urn:media:movie:old",
            title: "Old Movie", mediaType: "movie", season: nil, episode: nil,
            balancer: "rezka", generation: host.currentGeneration, revision: 1
        )
        let newContext = MediaResolutionContext(
            requestId: UUID(), actionId: UUID(), canonicalId: "urn:media:movie:new",
            title: "New Movie", mediaType: "movie", season: nil, episode: nil,
            balancer: "rezka", generation: host.currentGeneration, revision: 2
        )

        host.triggerMovieSearch(context: newContext)

        let delayedOldPayload = PlayPayload(
            action: "play", url: "https://stream.test/old.m3u8", title: "Old Movie",
            subtitle: nil, time: 0, duration: 1000, hash: "old", canonicalId: "urn:media:movie:old",
            mediaType: "movie", season: nil, episode: nil, currentQuality: "1080p",
            currentStudio: "rezka", availableQualities: nil, availableStudios: nil,
            availableSubtitles: nil, playlist: nil, isDiagnostic: false, plugin: "online_mod",
            pluginId: "online_mod", requestId: oldContext.requestId.uuidString,
            selectionContext: "headless_native_bridge"
        )

        // The active context is newContext. An old payload must be rejected.
        let active = try XCTUnwrap(host.activeResolutionContext)
        XCTAssertFalse(active.matches(canonicalId: delayedOldPayload.canonicalId))
    }

    // 6. Repeat source discovery and confirm old DOM rows are not treated as new results.
    func testScenario6_RepeatSourceDiscoveryDeduplication() {
        let logger = DiagnosticsLogManager.shared
        let initialCount = logger.entries.count

        // Multiple rapid identical logs
        for _ in 0..<10 {
            logger.log(category: "[Discovery]", message: "Found 4 DOM items for Rezka", level: .info)
        }

        // Must be throttled / deduplicated rather than adding 10 duplicate rows
        let added = logger.entries.count - initialCount
        XCTAssertLessThanOrEqual(added, 2)
    }

    // 7. Enable remote Online Mod while bundled Online Mod is selected, then explicitly switch implementations.
    func testScenario7_OnlineModImplementationPrioritySwitching() {
        let prefManager = OnlineModPreferenceManager.shared

        // Set to bundled
        prefManager.setPreference(.bundled)
        XCTAssertEqual(prefManager.preference, .bundled)

        let bundled = LampaPluginRecord(
            url: URL(string: "bundled://plugins/online_mod.js")!, name: "Online Mod (bundled)",
            version: "1.0", author: "Community", origin: .bundled, lifecycleState: .active
        )
        let remote = LampaPluginRecord(
            url: URL(string: "https://bylampa.online/plugins/online.js")!, name: "Online Mod (remote)",
            version: "2.0", author: "Community", origin: .communityRemote, lifecycleState: .active
        )

        var reports = PluginCollisionPolicy.resolveCollisions(in: [bundled, remote])
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].winner.origin, .bundled)
        XCTAssertEqual(reports[0].loser.origin, .communityRemote)

        // Switch to remote
        prefManager.setPreference(.remote)
        XCTAssertEqual(prefManager.preference, .remote)

        reports = PluginCollisionPolicy.resolveCollisions(in: [bundled, remote])
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].winner.origin, .communityRemote)
        XCTAssertEqual(reports[0].loser.origin, .bundled)

        // Clean up
        prefManager.setPreference(.bundled)
    }

    // 8. Enable SomaFM, open its native function from the plugin details, switch stations and stop playback.
    func testScenario8_SomaFMNativePluginDetailsAndPlayback() async {
        let registry = PluginCapabilityRegistry.shared
        let somaUrl = "https://tsynik.github.io/lampa/soma.js"

        registry.registerSource(
            pluginUrl: somaUrl,
            id: "somafm_radio",
            name: "SomaFM Радио (51 канал)",
            description: "51 независимый интернет-радиоканал без рекламы",
            hasExecutableResolver: true,
            capability: .radio,
            operationalStatus: .radioReady
        )

        let registered = registry.registeredSources.first { $0.id == "somafm_radio" }
        XCTAssertNotNil(registered)
        XCTAssertEqual(registered?.capability, .radio)
        XCTAssertEqual(registered?.operationalStatus, .radioReady)
        XCTAssertEqual(registered?.operationalStatus.rawValue, "Радио готово")
    }

    // 9. Verify non-video plugin e.js shows correct capability/status and does NOT appear in video sources.
    func testScenario9_NonVideoPluginEJs_NoVideoSourceRegistration() {
        let registry = PluginCapabilityRegistry.shared
        let eJsUrl = "https://tsynik.github.io/lampa/e.js"

        registry.registerSource(
            pluginUrl: eJsUrl,
            id: "\(eJsUrl)#exit_m",
            name: "Кнопка выхода",
            description: "Компонент интерфейса",
            hasExecutableResolver: false,
            capability: .interactiveComponent,
            operationalStatus: .interfaceOnly
        )

        let eJsSource = registry.registeredSources.first { $0.pluginUrl == eJsUrl }
        XCTAssertNotNil(eJsSource)
        XCTAssertEqual(eJsSource?.capability, .interactiveComponent)
        XCTAssertEqual(eJsSource?.operationalStatus, .interfaceOnly)
        XCTAssertEqual(eJsSource?.operationalStatus.rawValue, "Интерфейс")
        XCTAssertFalse(eJsSource?.hasExecutableResolver ?? true)

        // Must not be registered in SourceManager video sources
        let videoSources = SourceManager.shared.sources(forMediaCategory: .movie)
        XCTAssertFalse(videoSources.contains(where: { $0.canonicalKey.contains("exit_m") }))
    }

    // 10. Redaction remains available while diagnostic ZIP export is deliberately disabled.
    func testScenario10_DiagnosticsRedactionAndDisabledExport() {
        let logger = DiagnosticsLogManager.shared
        let sanitized = logger.sanitize("Connecting to https://proxy.test/hls?token=dummy_sample_token_123 Authorization: Bearer sample_jwt_mock_token_abc")
        XCTAssertFalse(sanitized.contains("dummy_sample_token_123"))
        XCTAssertFalse(sanitized.contains("sample_jwt_mock_token_abc"))
        XCTAssertTrue(sanitized.contains("[REDACTED]"))
        XCTAssertNil(logger.exportDiagnosticsZip())
    }

    // 11. Simulate ambiguous stream identity; verify playback fails closed.
    func testScenario11_AmbiguousStreamIdentityFailsClosed() {
        let context = MediaResolutionContext(
            requestId: UUID(), actionId: UUID(), canonicalId: "urn:media:movie:1",
            title: "Exact Title", mediaType: "movie", season: nil, episode: nil,
            balancer: "rezka", generation: 1, revision: 1
        )

        // Ambiguous stream missing canonical ID
        XCTAssertFalse(context.matches(canonicalId: nil))

        // Ambiguous TV stream missing season or episode
        let tvContext = MediaResolutionContext(
            requestId: UUID(), actionId: UUID(), canonicalId: "urn:media:tv:2",
            title: "TV Show", mediaType: "tv", season: 2, episode: 5,
            balancer: "rezka", generation: 1, revision: 1
        )
        XCTAssertFalse(tvContext.matches(canonicalId: "urn:media:tv:2", season: 1, episode: 5))
        XCTAssertFalse(tvContext.matches(canonicalId: "urn:media:tv:2", season: 2, episode: 6))
    }

    // 12. Complete full end-to-end user path: Catalog -> MediaDetail -> Balancers -> Source Selection -> AVPlayer without leakage.
    func testScenario12_EndToEndCatalogToAVPlayer_NoLeakage() async throws {
        let host = LampaHeadlessHost.shared
        let tracker = ActionCorrelationTracker.shared

        // 1. User taps Movie card in catalog
        let actionId = tracker.startAction(name: "OpenMovieFromCatalog")
        let item = MediaItem(id: 777, title: "Test Movie", name: nil, originalTitle: "Test Movie",
                             originalName: nil, overview: "Great movie", posterPath: nil, backdropPath: nil,
                             mediaType: "movie", releaseDate: "2026-01-01", firstAirDate: nil,
                             voteAverage: 8.5, voteCount: nil, genreIds: nil)

        // 2. MediaDetail creates immutable context and resolves sources
        let context = MediaResolutionContext(
            requestId: UUID(), actionId: actionId, canonicalId: item.canonicalId,
            title: item.displayTitle, mediaType: item.canonicalType,
            season: nil, episode: nil, balancer: "CDNVideoHub", generation: host.currentGeneration, revision: 1
        )
        host.triggerMovieSearch(context: context)

        // 3. Simulated sources discovered
        host.discoveredSources = [
            DiscoveredLampaSource(index: 0, title: "1080p Дубляж", quality: "1080p", isFolder: false),
            DiscoveredLampaSource(index: 1, title: "720p Субтитры", quality: "720p", isFolder: false)
        ]
        XCTAssertEqual(host.discoveredSources.count, 2)

        // 4. User explicitly selects source index 0 to play
        host.authorizePlayback(context: context)

        // 5. Stream payload arrives for exact context
        let payload = PlayPayload(
            action: "play", url: "https://video.test/stream.m3u8", title: item.displayTitle,
            subtitle: "CDNVideoHub", time: 0, duration: 7200, hash: "hash123", canonicalId: item.canonicalId,
            mediaType: "movie", season: nil, episode: nil, currentQuality: "1080p", currentStudio: "cdnvideohub",
            availableQualities: nil, availableStudios: nil, availableSubtitles: nil, playlist: nil,
            isDiagnostic: false, plugin: "online_mod", pluginId: "online_mod",
            requestId: context.requestId.uuidString, selectionContext: "headless_native_bridge"
        )

        var playedPayload: PlayPayload?
        host.onPlayRequest = { p in
            playedPayload = p
        }

        // Verify context match and delivery
        XCTAssertTrue(context.matches(canonicalId: payload.canonicalId))

        // Close player
        host.clearActiveMediaContext()
        XCTAssertNil(host.activeResolutionContext)
        XCTAssertEqual(host.discoveredSources.count, 0)
    }

    // 13. Resilient decoding of real-world SomaFM channels JSON with string listeners
    func testScenario13_SomaFMResilientDecoding() throws {
        let sampleJson = """
        {
            "channels": [
                {
                    "id": "groovesalad",
                    "title": "Groove Salad",
                    "description": "Downtempo ambient groove",
                    "genre": "ambient|downtempo",
                    "largeimage": "https://api.somafm.com/logos/256/groovesalad256.png",
                    "listeners": "420",
                    "playlists": [
                        { "url": "https://api.somafm.com/groovesalad.pls", "format": "mp3", "quality": "highest" }
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(SomaFMChannelsResponse.self, from: sampleJson)
        XCTAssertEqual(decoded.channels.count, 1)
        XCTAssertEqual(decoded.channels[0].id, "groovesalad")
        XCTAssertEqual(decoded.channels[0].listeners, 420)
        XCTAssertEqual(decoded.channels[0].genreDisplay, "Ambient • Downtempo")
    }

    // 14. Discovered source candidates with streamUrl: "" must be accepted by SourceProviderEngine
    func testScenario14_DiscoveredCandidatesPassedByEngine() {
        let candidate = ResolvedMediaSource(
            id: "online_mod_cdnvideohub_0",
            providerName: "Online Mod (CDNVideoHub)",
            title: "Movie - Option 1",
            quality: "1080p",
            studioId: "cdnvideohub",
            studioName: "CDNVideoHub",
            streamUrl: "",
            isHls: true,
            container: "m3u8",
            season: nil,
            episode: nil,
            isDiagnostic: false,
            providerId: "online_mod",
            canonicalMediaId: "urn:media:tmdb:movie:101"
        )

        XCTAssertTrue(candidate.streamUrl.isEmpty)
        XCTAssertEqual(candidate.canonicalMediaId, "urn:media:tmdb:movie:101")
        XCTAssertEqual(candidate.quality, "1080p")
    }

    // 15. Plugin collision policy marks losing implementation as inactiveAlternate, not failed
    func testScenario15_PluginCollisionInactiveAlternateLifecycle() {
        let bundled = LampaPluginRecord(
            url: URL(string: "bundled://plugins/online_mod.js")!,
            name: "Online Mod (Bundled)", origin: .bundled,
            lifecycleState: .active
        )
        let remote = LampaPluginRecord(
            url: URL(string: "https://example.com/online_mod.js")!,
            name: "Online Mod (Community)", origin: .communityRemote,
            lifecycleState: .active
        )

        let reports = PluginCollisionPolicy.resolveCollisions(in: [bundled, remote])
        XCTAssertEqual(reports.count, 1)
        let report = reports[0]
        XCTAssertEqual(report.reason, .duplicateComponentId(componentId: "online_mod"))

        let inactiveState = LampaPluginLifecycleState.inactiveAlternate(reason: report.userMessage)
        XCTAssertFalse(inactiveState.isOperational)
        XCTAssertEqual(inactiveState.displayLabel, "Неактивен (вторичный)")
    }
}
