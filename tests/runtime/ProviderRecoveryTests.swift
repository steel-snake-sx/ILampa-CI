import XCTest
@testable import iLampa

/// Only the HTTP boundary is mocked; these tests exercise production adapters and engine cache state.
@MainActor
final class ProviderRecoveryTests: XCTestCase {
    private static let keys = ["plex_host", "plex_port", "plex_token", "jellyfin_host", "jellyfin_port", "jellyfin_api_key",
                                "jellyfin_user_id", "emby_host", "emby_port", "emby_api_key", "kodik_api_token", "preferred_quality", SourcePriority.storageKey]
    private var saved: [String: Any] = [:]
    private var session: URLSession!

    private final class HTTPStub: URLProtocol {
        private static let lock = NSLock()
        private static var handler: ((URLRequest) -> (Int, Any))?

        static func respond(_ handler: ((URLRequest) -> (Int, Any))?) {
            lock.lock()
            defer { lock.unlock() }
            self.handler = handler
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock()
            let response = Self.handler?(request) ?? (500, [:])
            Self.lock.unlock()
            if response.0 < 0 {
                client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: response.0,
                                                                     userInfo: [NSLocalizedDescriptionKey: "fixture transport failure"]))
                return
            }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: response.1))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    override func setUp() async throws {
        for key in Self.keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPStub.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        HTTPStub.respond(nil)
        for key in Self.keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    private func item(type: String = "movie", year: String = "1999", anime: Bool = false) -> MediaItem {
        let json: [String: Any] = ["id": 550, "title": "Fight Club", "original_title": "Fight Club",
                                   "media_type": type, "release_date": year + "-10-15", "genre_ids": anime ? [16] : [18]]
        return try! JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func bleach() -> MediaItem {
        let json: [String: Any] = ["id": 30984, "name": "Bleach", "original_name": "Bleach",
                                   "media_type": "tv", "first_air_date": "2004-10-05", "genre_ids": [16]]
        return try! JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func configure(_ provider: String) {
        UserDefaults.standard.set("https://library.example", forKey: provider + "_host")
        UserDefaults.standard.set("", forKey: provider + "_port")
        UserDefaults.standard.set("test-token", forKey: provider == "plex" ? "plex_token" : provider + "_api_key")
    }

    func testKodikAndTorrServerNeverFabricateDirectStreams() async throws {
        let kodik = try await KodikAnimeSourceProvider(session: session).resolveSources(for: item(), season: nil, episode: nil)
        let torrents = try await TorrServerSourceProvider().resolveSources(for: item(type: "tv"), season: 2, episode: 5)
        XCTAssertTrue(kodik.isEmpty)
        XCTAssertTrue(torrents.isEmpty)
    }

    func testKodikRequiresConfiguredTokenAndReportsTLSFailureWithoutBypass() async {
        let unconfigured = KodikAnimeSourceProvider(session: session)
        let missing = await unconfigured.runVerificationTest()
        XCTAssertFalse(missing.success)
        XCTAssertEqual(unconfigured.operationalStatus, .unconfigured)
        XCTAssertTrue(missing.message.contains("API токен"))

        UserDefaults.standard.set("test-token", forKey: "kodik_api_token")
        HTTPStub.respond { _ in (-1200, [:]) }
        let configured = KodikAnimeSourceProvider(session: session)
        let failed = await configured.runVerificationTest()
        XCTAssertFalse(failed.success)
        XCTAssertEqual(configured.operationalStatus, .connectionFailed)
        XCTAssertTrue(failed.message.contains("kodikapi.com"))
        XCTAssertTrue(failed.message.contains("TLS"))
        XCTAssertFalse(failed.message.contains("test-token"))
    }

    func testAniLibriaMissingEpisodeDoesNotFallbackToFirst() async throws {
        HTTPStub.respond { request in
            if request.url!.path.contains("/search/") {
                return (200, [["id": 10, "name": ["main": "Fight Club"], "year": 1999, "type": ["value": "TV"]]])
            }
            return (200, ["id": 10, "episodes": [["ordinal": 1, "hls_1080": "https://cdn.example/episode1.m3u8"]]])
        }
        let provider = AniLibriaSourceProvider(session: session)
        let sources = try await provider.resolveSources(for: item(type: "tv", anime: true), season: 1, episode: 5)
        XCTAssertTrue(sources.isEmpty)
    }

    func testAniLibriaEpisodesOnlyResponseResolvesBleachEpisodeOneWithoutPlaybackVerification() async throws {
        // Current API v1 shape for release 8452: the `?include=episodes` response has no top-level id.
        // Identity remains verified by the selected release endpoint and the episode's release_id.
        let hls1080 = "https://cache.libria.fun/videos/media/ts/8452/1/1080/fixture.m3u8?countryIso=FI&isAuthorized=0"
        HTTPStub.respond { request in
            if request.url!.path.contains("/search/") {
                return (200, [["id": 8452, "name": ["main": "Блич", "english": "Bleach", "alternative": "Bleach"],
                               "year": 2004, "type": ["value": "TV"]]])
            }
            return (200, ["episodes": [["ordinal": 1, "release_id": 8452,
                                        "hls_1080": hls1080, "hls_720": hls1080.replacingOccurrences(of: "1080", with: "720"),
                                        "hls_480": hls1080.replacingOccurrences(of: "1080", with: "480")]]])
        }
        let provider = AniLibriaSourceProvider(session: session)
        let engine = SourceProviderEngine(providers: [provider])
        let sources = await engine.resolveSources(for: bleach(), season: 1, episode: 1)
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources.map(\.quality), ["1080p", "720p", "480p"])
        XCTAssertTrue(sources.allSatisfy { $0.season == 1 && $0.episode == 1 && $0.isHls })
        XCTAssertEqual(sources.first?.streamUrl, hls1080)
        XCTAssertEqual(provider.operationalStatus, .streamResolved,
                       "A resolved URL is selectable before AVPlayer demonstrates playback")
        XCTAssertNotEqual(provider.operationalStatus, .playbackVerified)
    }

    func testAniLibriaRejectsEpisodesWithExplicitMismatchedReleaseIdentity() async throws {
        HTTPStub.respond { request in
            if request.url!.path.contains("/search/") {
                return (200, [["id": 8452, "name": ["main": "Блич", "english": "Bleach"], "year": 2004,
                               "type": ["value": "TV"]]])
            }
            return (200, ["episodes": [["ordinal": 1, "release_id": 9999, "hls_1080": "https://cache.libria.fun/wrong.m3u8"]]])
        }
        let provider = AniLibriaSourceProvider(session: session)
        let sources = try await provider.resolveSources(for: bleach(), season: 1, episode: 1)
        XCTAssertTrue(sources.isEmpty)
    }

    func testAniLibriaDeduplicatesEquivalentAliasesBeforeUnmatchedSearches() async throws {
        var searches = 0
        HTTPStub.respond { request in
            if request.url!.path.contains("/search/") { searches += 1 }
            return (200, [])
        }
        let json: [String: Any] = ["id": 1, "name": "Same Title", "original_name": "same title",
                                   "media_type": "tv", "first_air_date": "2004-01-01", "genre_ids": [16]]
        let duplicateAliases = try! JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
        let provider = AniLibriaSourceProvider(session: session)
        let sources = try await provider.resolveSources(for: duplicateAliases, season: 1, episode: 1)
        XCTAssertTrue(sources.isEmpty)
        XCTAssertEqual(searches, 1)
    }

    func testAniLibriaSeasonTwoRejectsSeasonOneAndResolvesExplicitSeasonRelease() async throws {
        HTTPStub.respond { request in
            if request.url!.path.contains("/search/") {
                return (200, [["id": 1, "name": ["english": "Bleach"], "year": 2004, "type": ["value": "TV"]],
                              ["id": 2, "name": ["english": "Bleach II"], "year": 2006, "type": ["value": "TV"]]])
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/2"))
            return (200, ["id": 2, "episodes": [["ordinal": 1, "release_id": 2, "hls_720": "https://cdn.example/season2.m3u8"]]])
        }
        let sources = try await AniLibriaSourceProvider(session: session).resolveSources(for: bleach(), season: 2, episode: 1)
        XCTAssertEqual(sources.map(\.streamUrl), ["https://cdn.example/season2.m3u8"])
        XCTAssertEqual(sources.first?.season, 2)
    }

    func testAniLibriaSeasonTwoDoesNotRelabelUnnumberedRelease() async throws {
        HTTPStub.respond { request in
            XCTAssertTrue(request.url!.path.contains("/search/"), "An unnumbered release must never reach episode lookup")
            return (200, [["id": 1, "name": ["english": "Bleach"], "year": 2004, "type": ["value": "TV"]]])
        }
        let sources = try await AniLibriaSourceProvider(session: session).resolveSources(for: bleach(), season: 2, episode: 1)
        XCTAssertTrue(sources.isEmpty)
    }

    func testIdentityWithoutCanonicalIDRequiresExactTitleAndYear() {
        let movie = item()
        XCTAssertTrue(MediaIdentityMatcher.matches(movie, titles: ["Fight Club"], year: 1999, type: "movie"))
        XCTAssertFalse(MediaIdentityMatcher.matches(movie, titles: ["Fight Club 2"], year: 1999, type: "movie"))
        XCTAssertFalse(MediaIdentityMatcher.matches(movie, titles: ["Fight Club"], year: nil, type: "movie"))
        XCTAssertFalse(MediaIdentityMatcher.matches(movie, titles: ["Fight Club"], year: 2000, type: "movie"))
    }

    func testAniLibriaRejectsInvalidSeasonWithoutNetworkRequest() async throws {
        HTTPStub.respond { _ in
            XCTFail("Invalid seasons must not trigger a lookup")
            return (500, [:])
        }
        let sources = try await AniLibriaSourceProvider(session: session).resolveSources(for: bleach(), season: 0, episode: 1)
        XCTAssertTrue(sources.isEmpty)
    }

    func testPlexResolvesActualPartNotMetadataURL() async throws {
        configure("plex")
        HTTPStub.respond { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "test-token")
            let record: [String: Any] = ["ratingKey": "100", "key": "/library/metadata/100", "type": "movie",
                "title": "Fight Club", "year": 1999, "Guid": [["id": "tmdb://550"]],
                "Media": [["container": "mp4", "height": 720, "Part": [["id": "200", "key": "/library/parts/200/0/file.mp4"]]]]]
            return (200, ["MediaContainer": ["Metadata": [record]]])
        }
        let sources = try await PlexSourceProvider(session: session).resolveSources(for: item(), season: nil, episode: nil)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(URL(string: sources[0].streamUrl)?.path, "/library/parts/200/0/file.mp4")
        XCTAssertEqual(sources[0].quality, "720p")
        XCTAssertFalse(sources[0].streamUrl.contains("/library/metadata/"))
    }

    func testPlexRejectsWrongYearEvenWithMatchingTitle() async throws {
        configure("plex")
        HTTPStub.respond { _ in
            (200, ["MediaContainer": ["Metadata": [["ratingKey": "100", "title": "Fight Club", "type": "movie", "year": 2026]]]])
        }
        let sources = try await PlexSourceProvider(session: session).resolveSources(for: item(), season: nil, episode: nil)
        XCTAssertTrue(sources.isEmpty)
    }

    func testPersonalServersRejectUnauthorizedLibraryAccess() async {
        configure("plex")
        configure("jellyfin")
        configure("emby")
        HTTPStub.respond { request in
            XCTAssertFalse(request.url!.path.contains("/Public"))
            XCTAssertNotEqual(request.url!.path, "/identity")
            return (401, [:])
        }
        let providers: [SourceProviderProtocol] = [PlexSourceProvider(session: session), JellyfinSourceProvider(session: session), EmbySourceProvider(session: session)]
        for provider in providers {
            let result = await provider.runVerificationTest()
            XCTAssertFalse(result.success)
            XCTAssertEqual(provider.operationalStatus, .authRequired)
        }
    }

    func testJellyfinRejectsSeriesAndWrongCanonicalMovie() async throws {
        configure("jellyfin")
        HTTPStub.respond { _ in
            (200, ["Items": [["Id": "series", "Name": "Fight Club", "Type": "Series", "ProductionYear": 1999],
                             ["Id": "wrong", "Name": "Fight Club", "Type": "Movie", "ProductionYear": 1999, "ProviderIds": ["Tmdb": "999"]]]])
        }
        let sources = try await JellyfinSourceProvider(session: session).resolveSources(for: item(), season: nil, episode: nil)
        XCTAssertTrue(sources.isEmpty)
    }

    func testEmbyRequiresActualPlayableContainer() async throws {
        configure("emby")
        HTTPStub.respond { request in
            if request.url!.path.hasSuffix("PlaybackInfo") {
                return (200, ["MediaSources": [["Id": "mkv", "Container": "mkv", "SupportsDirectPlay": true]]])
            }
            return (200, ["Items": [["Id": "movie", "Name": "Fight Club", "Type": "Movie", "ProductionYear": 1999, "ProviderIds": ["Tmdb": "550"]]]])
        }
        let sources = try await EmbySourceProvider(session: session).resolveSources(for: item(), season: nil, episode: nil)
        XCTAssertTrue(sources.isEmpty)
    }

    @MainActor private final class Provider: SourceProviderProtocol {
        let providerId: String
        init(_ id: String = "test") { providerId = id }
        var displayName: String { "Test" }
        var supportedContentDescription: String { "Test" }
        var operationalStatus: ProviderOperationalStatus = .initialized
        var canResolveDirectly = true
        var isConfigured = true
        var calls = 0
        var failure = false
        var empty = false
        var diagnostic = false
        var container = "mp4"
        var omitCanonicalIdentity = false
        var onResolve: (() async -> Void)?
        func resolveSources(for item: MediaItem, season: Int?, episode: Int?) async throws -> [ResolvedMediaSource] {
            calls += 1
            await onResolve?()
            if failure { throw ProviderRequestError.http(503) }
            if empty { return [] }
            return [ResolvedMediaSource(id: "test", providerName: "Test", title: item.displayTitle, quality: "Auto",
                studioId: "original", studioName: "Original", streamUrl: "https://cdn.example/movie.mp4", isHls: false,
                container: container, season: season, episode: episode, isDiagnostic: diagnostic,
                providerId: providerId, canonicalMediaId: omitCanonicalIdentity ? "" : item.canonicalId)]
        }
        func runVerificationTest() async -> (success: Bool, message: String, sampleUrl: String?) { (true, "Test", nil) }
    }

    func testEngineSkipsInteractiveAndUnconfiguredProviders() async {
        let provider = Provider()
        provider.canResolveDirectly = false
        let engine = SourceProviderEngine(providers: [provider])
        _ = await engine.resolveSources(for: item())
        provider.canResolveDirectly = true
        provider.isConfigured = false
        _ = await engine.resolveSources(for: item())
        XCTAssertEqual(provider.calls, 0)
    }

    func testPriorityOrdersRealResolverResultsAndChangesInvalidateCache() async {
        let first = Provider("first")
        let second = Provider("second")
        let engine = SourceProviderEngine(providers: [first, second])
        UserDefaults.standard.set(SourcePriority.encode(["second", "first"]), forKey: SourcePriority.storageKey)
        let initial = await engine.resolveSources(for: item())
        XCTAssertEqual(initial.map(\.providerId), ["second", "first"])
        _ = await engine.resolveSources(for: item())
        XCTAssertEqual(first.calls, 1)
        UserDefaults.standard.set(SourcePriority.encode(["first", "second"]), forKey: SourcePriority.storageKey)
        let reordered = await engine.resolveSources(for: item())
        XCTAssertEqual(reordered.map(\.providerId), ["first", "second"])
        XCTAssertEqual(first.calls, 2)
        XCTAssertEqual(second.calls, 2)
    }

    func testPriorityFallsBackOnEmptyFailureOrIneligibleProvider() async {
        let preferred = Provider("preferred")
        let fallback = Provider("fallback")
        let engine = SourceProviderEngine(providers: [preferred, fallback])
        UserDefaults.standard.set(SourcePriority.encode(["preferred", "fallback"]), forKey: SourcePriority.storageKey)
        preferred.empty = true
        let empty = await engine.resolveSources(for: item(), forceRefresh: true)
        XCTAssertEqual(empty.map(\.providerId), ["fallback"])
        preferred.empty = false
        preferred.failure = true
        let failed = await engine.resolveSources(for: item(), forceRefresh: true)
        XCTAssertEqual(failed.map(\.providerId), ["fallback"])
        preferred.failure = false
        preferred.isConfigured = false
        let unavailable = await engine.resolveSources(for: item(), forceRefresh: true)
        XCTAssertEqual(unavailable.map(\.providerId), ["fallback"])
        XCTAssertEqual(preferred.calls, 2)
    }

    func testPriorityChangeRejectsInFlightResults() async {
        let preferred = Provider("preferred")
        let fallback = Provider("fallback")
        let engine = SourceProviderEngine(providers: [preferred, fallback])
        UserDefaults.standard.set(SourcePriority.encode(["preferred", "fallback"]), forKey: SourcePriority.storageKey)
        var continuation: CheckedContinuation<Void, Never>?
        let started = expectation(description: "preferred provider started")
        preferred.onResolve = {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        let request = Task { await engine.resolveSources(for: self.item()) }
        await fulfillment(of: [started], timeout: 2)
        UserDefaults.standard.set(SourcePriority.encode(["fallback", "preferred"]), forKey: SourcePriority.storageKey)
        continuation?.resume()
        let stale = await request.value
        XCTAssertTrue(stale.isEmpty)
        preferred.onResolve = nil
        let current = await engine.resolveSources(for: item())
        XCTAssertEqual(current.map(\.providerId), ["fallback", "preferred"])
    }

    func testPriorityReconcilesMalformedDuplicatesAndMissingProviders() {
        XCTAssertEqual(SourcePriority.decode("not json"), [])
        let saved = SourcePriority.decode(SourcePriority.encode(["missing", "second", "second", ""]))
        XCTAssertEqual(SourcePriority.order(saved: saved, available: ["first", "second", "new"]),
                       ["missing", "second", "first", "new"])
    }

    func testEngineDoesNotCacheFailuresOrEmptyResults() async {
        let provider = Provider()
        let engine = SourceProviderEngine(providers: [provider])
        provider.failure = true
        _ = await engine.resolveSources(for: item())
        provider.failure = false
        provider.empty = true
        _ = await engine.resolveSources(for: item())
        provider.empty = false
        let recovered = await engine.resolveSources(for: item())
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(provider.calls, 3)
    }

    func testEngineNeverTreatsDiagnosticSampleAsResolvedMedia() async {
        let provider = Provider()
        provider.diagnostic = true
        let engine = SourceProviderEngine(providers: [provider])
        let sources = await engine.resolveSources(for: item())
        XCTAssertTrue(sources.isEmpty)
    }

    func testEngineDoesNotPresentNonAVPlayerContainersAsNativeSources() async {
        let provider = Provider()
        provider.container = "mkv"
        let engine = SourceProviderEngine(providers: [provider])
        let sources = await engine.resolveSources(for: item())
        XCTAssertTrue(sources.isEmpty, "A provider result must be playable by AVPlayer before it reaches the native source picker")
    }

    func testEngineRejectsCandidateWithoutExplicitCanonicalIdentity() async {
        let provider = Provider()
        provider.omitCanonicalIdentity = true
        let engine = SourceProviderEngine(providers: [provider])
        let sources = await engine.resolveSources(for: item())
        XCTAssertTrue(sources.isEmpty)
    }

    func testEngineMarksAnEmptyProviderSearchAsNoMatchingTitles() async {
        let provider = Provider()
        provider.empty = true
        let engine = SourceProviderEngine(providers: [provider])
        _ = await engine.resolveSources(for: item())
        XCTAssertEqual(provider.operationalStatus, .noMatchingTitles)
    }

    func testHTTPAuthenticationStatusesStayExactWhileMappingToAuthRequired() async {
        let request = URLRequest(url: URL(string: "https://provider.example.test/library")!)
        for code in [401, 403] {
            HTTPStub.respond { _ in (code, [:]) }
            do {
                _ = try await ProviderHTTP.data(for: request, session: session)
                XCTFail("HTTP \(code) must be reported as an HTTP error")
            } catch let ProviderRequestError.http(actualCode) {
                XCTAssertEqual(actualCode, code)
                XCTAssertEqual(ProviderRequestError.status(for: ProviderRequestError.http(actualCode)), .authRequired)
            } catch {
                XCTFail("Expected exact HTTP status, received \(error)")
            }
        }

        HTTPStub.respond { _ in (503, [:]) }
        do {
            _ = try await ProviderHTTP.data(for: request, session: session)
            XCTFail("HTTP 503 must not be accepted")
        } catch let ProviderRequestError.http(code) {
            XCTAssertEqual(code, 503)
            XCTAssertEqual(ProviderRequestError.status(for: ProviderRequestError.http(code)), .connectionFailed)
        } catch {
            XCTFail("Expected exact HTTP status, received \(error)")
        }
    }

    func testProviderDiagnosticRetainsUnderlyingNSErrorDomainAndCode() {
        let underlying = NSError(domain: "ProviderFixture.Transport", code: -1009,
                                 userInfo: [NSLocalizedDescriptionKey: "offline fixture"])
        let diagnostic = ProviderRequestError.diagnostic(underlying)
        XCTAssertTrue(diagnostic.contains("ProviderFixture.Transport"))
        XCTAssertTrue(diagnostic.contains("code=-1009"))
        XCTAssertTrue(diagnostic.contains("offline fixture"))
    }

    func testForceRefreshAndConfigurationChangeBypassPositiveCache() async {
        let provider = Provider()
        let engine = SourceProviderEngine(providers: [provider])
        _ = await engine.resolveSources(for: item())
        _ = await engine.resolveSources(for: item())
        XCTAssertEqual(provider.calls, 1)
        _ = await engine.resolveSources(for: item(), forceRefresh: true)
        XCTAssertEqual(provider.calls, 2)
        UserDefaults.standard.set("changed", forKey: "preferred_quality")
        _ = await engine.resolveSources(for: item())
        XCTAssertEqual(provider.calls, 3)
    }

    func testInvalidatedInFlightWorkCannotReturnOrCacheStaleResults() async {
        let provider = Provider()
        let engine = SourceProviderEngine(providers: [provider])
        var continuation: CheckedContinuation<Void, Never>?
        let started = expectation(description: "provider started")
        provider.onResolve = {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        let task = Task { await engine.resolveSources(for: self.item()) }
        await fulfillment(of: [started], timeout: 2)
        engine.invalidateCache()
        continuation?.resume()
        let stale = await task.value
        XCTAssertTrue(stale.isEmpty)
        provider.onResolve = nil
        let current = await engine.resolveSources(for: item())
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(provider.calls, 2)
    }

    func testFinalConsumerCancellationCancelsProviderWorkAndDoesNotCacheIt() async {
        let provider = Provider()
        let engine = SourceProviderEngine(providers: [provider])
        let started = expectation(description: "provider suspended")
        let cancelled = expectation(description: "shared provider task cancelled")
        var continuation: CheckedContinuation<Void, Never>?
        provider.onResolve = {
            await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            }, onCancel: { cancelled.fulfill() })
        }
        let request = Task { await engine.resolveSources(for: self.item()) }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        continuation?.resume()
        let stale = await request.value
        XCTAssertTrue(stale.isEmpty)
        provider.onResolve = nil
        let current = await engine.resolveSources(for: item())
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(provider.calls, 2)
    }
}
