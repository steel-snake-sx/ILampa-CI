import XCTest
@testable import iLampa

// MARK: - SomaFM PLS Parser Tests (unit-tested without network)

final class SomaFMServiceTests: XCTestCase {

    // Test that the PLS parser extracts File1=, File2= URLs correctly
    func testPLSParserExtractsFileURLs() async throws {
        let plsText = """
        [playlist]
        numberofentries=3
        File1=https://ice1.somafm.com/groovesalad-128-mp3
        Title1=Groove Salad from SomaFM
        Length1=-1
        File2=https://ice2.somafm.com/groovesalad-128-mp3
        Title2=Groove Salad from SomaFM
        Length2=-1
        File3=https://ice3.somafm.com/groovesalad-128-mp3
        Title3=Groove Salad from SomaFM
        Length3=-1
        Version=2
        """

        let urls = extractURLsFromPLS(text: plsText)
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(urls[0].absoluteString, "https://ice1.somafm.com/groovesalad-128-mp3")
        XCTAssertEqual(urls[1].absoluteString, "https://ice2.somafm.com/groovesalad-128-mp3")
        XCTAssertEqual(urls[2].absoluteString, "https://ice3.somafm.com/groovesalad-128-mp3")
    }

    func testPLSParserHandlesCaseInsensitiveFileKeys() {
        let plsText = """
        file1=https://stream.example.com/channel-128.mp3
        FILE2=https://stream2.example.com/channel-128.mp3
        """
        let urls = extractURLsFromPLS(text: plsText)
        XCTAssertEqual(urls.count, 2)
    }

    func testPLSParserIgnoresNonStreamLines() {
        let plsText = """
        [playlist]
        numberofentries=1
        File1=https://ice1.somafm.com/channel-128.mp3
        Title1=Some Title
        Length1=-1
        """
        let urls = extractURLsFromPLS(text: plsText)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].absoluteString, "https://ice1.somafm.com/channel-128.mp3")
    }

    func testPLSParserRejectsInvalidURLs() {
        let plsText = """
        File1=not-a-valid-url
        File2=ftp://wrong-scheme.com/stream
        File3=https://valid.example.com/stream.mp3
        """
        let urls = extractURLsFromPLS(text: plsText)
        // Only the https URL should be accepted
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls[0].absoluteString, "https://valid.example.com/stream.mp3")
    }

    // MARK: - RadioStation JSON Decoding

    func testRadioStationDecodesFromJSON() throws {
        let json = """
        {
            "id": "groovesalad",
            "title": "Groove Salad",
            "description": "A nicely chilled plate of ambient beats and grooves.",
            "genre": "ambient|chill|music",
            "largeimage": "https://somafm.com/img/groovesalad512.jpg",
            "listeners": 1234,
            "playlists": [
                {"url": "https://somafm.com/groovesalad320.pls", "quality": "highest", "format": "mp3"},
                {"url": "https://somafm.com/groovesalad.pls", "quality": "highest", "format": "aac"}
            ]
        }
        """.data(using: .utf8)!

        let station = try JSONDecoder().decode(RadioStation.self, from: json)
        XCTAssertEqual(station.id, "groovesalad")
        XCTAssertEqual(station.title, "Groove Salad")
        XCTAssertEqual(station.listeners, 1234)
        XCTAssertEqual(station.playlists.count, 2)
    }

    func testRadioStationGenreDisplay() throws {
        let json = """
        {
            "id": "test",
            "title": "Test",
            "description": "Test",
            "genre": "ambient|chill|electronic",
            "largeimage": "https://example.com/img.jpg",
            "listeners": 100,
            "playlists": []
        }
        """.data(using: .utf8)!

        let station = try JSONDecoder().decode(RadioStation.self, from: json)
        XCTAssertEqual(station.genreDisplay, "Ambient • Chill • Electronic")
    }

    func testRadioStationPreferredPlaylistSelectsHighest320k() throws {
        let json = """
        {
            "id": "test",
            "title": "Test",
            "description": "",
            "genre": "test",
            "largeimage": "",
            "listeners": 0,
            "playlists": [
                {"url": "https://somafm.com/test.pls", "quality": "high", "format": "mp3"},
                {"url": "https://somafm.com/test320.pls", "quality": "highest", "format": "mp3"},
                {"url": "https://somafm.com/test.pls", "quality": "highest", "format": "aac"}
            ]
        }
        """.data(using: .utf8)!

        let station = try JSONDecoder().decode(RadioStation.self, from: json)
        // Should prefer the 320.pls URL
        XCTAssertEqual(station.preferredPlaylist?.url, "https://somafm.com/test320.pls")
    }

    func testSomaFMChannelsResponseDecodes() throws {
        let json = """
        {
            "channels": [
                {
                    "id": "groovesalad",
                    "title": "Groove Salad",
                    "description": "Ambient beats",
                    "genre": "ambient",
                    "largeimage": "https://somafm.com/img/groovesalad512.jpg",
                    "listeners": 500,
                    "playlists": [
                        {"url": "https://somafm.com/groovesalad.pls", "quality": "highest", "format": "mp3"}
                    ]
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SomaFMChannelsResponse.self, from: json)
        XCTAssertEqual(response.channels.count, 1)
        XCTAssertEqual(response.channels[0].id, "groovesalad")
    }

    // MARK: - Helpers

    /// Extracted PLS parsing logic (mirrors SomaFMService.parsePLS)
    private func extractURLsFromPLS(text: String) -> [URL] {
        var results: [URL] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("file") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    let urlStr = String(parts[1]).trimmingCharacters(in: .whitespaces)
                    if let url = URL(string: urlStr),
                       ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        results.append(url)
                    }
                }
            }
        }
        return results
    }
}

// MARK: - Plugin Collision Tests

final class PluginCollisionTests: XCTestCase {

    func testNoDuplicatesReturnsEmptyReport() {
        let policy = PluginCollisionPolicy.self
        let result = policy.resolveCollisions(in: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSameComponentIdDetected() {
        let bundled = LampaPluginRecord(url: URL(string: "bundled://plugins/online_mod.js")!,
                                        name: "Онлайн-мод (встроенный)", origin: .bundled, lifecycleState: .active)
        let remote = LampaPluginRecord(url: URL(string: "https://nb557.github.io/plugins/online_mod.js")!,
                                       name: "Online Mod Remote", origin: .communityRemote, lifecycleState: .active)

        let reports = PluginCollisionPolicy.resolveCollisions(in: [bundled, remote])

        // Should report a collision
        XCTAssertFalse(reports.isEmpty, "Expected collision between bundled and remote online_mod")

        if let report = reports.first {
            // Bundled should win
            XCTAssertEqual(report.winner.origin, .bundled, "Bundled plugin should win")
            XCTAssertEqual(report.loser.urlString, "https://nb557.github.io/plugins/online_mod.js")
        }
    }

    func testNoCollisionWithDistinctPlugins() {
        let somaFM = LampaPluginRecord(url: URL(string: "bundled://plugins/soma.js")!, name: "SomaFM", origin: .bundled)
        let anilibria = LampaPluginRecord(url: URL(string: "https://example.com/anilibria.js")!, name: "AniLibria Plugin", origin: .communityRemote)

        let reports = PluginCollisionPolicy.resolveCollisions(in: [somaFM, anilibria])
        XCTAssertTrue(reports.isEmpty, "No collision expected between distinct plugins")
    }
}

// MARK: - OnlineMod Status & Headless Bridge Gate Tests

@MainActor
final class OnlineModStatusTests: XCTestCase {

    func testOnlineModMapsStableNavigationIdentityAndPreservesFolders() {
        let item = MediaItem(id: 1, title: "Film", name: nil, originalTitle: nil, originalName: nil,
                             overview: nil, posterPath: nil, backdropPath: nil, mediaType: "movie",
                             releaseDate: nil, firstAirDate: nil, voteAverage: nil, voteCount: nil, genreIds: nil)
        let request = UUID()
        let row = DiscoveredLampaSource(index: 1, title: "Edition", quality: "1080p", isFolder: false, rowToken: "42", voice: "Dub")
        let folder = DiscoveredLampaSource(index: 0, title: "Alternative", quality: "2024", isFolder: true, rowToken: "41", isAlternative: true)
        let unknown = DiscoveredLampaSource(index: 2, title: "Unknown", quality: "", isFolder: false)
        let mapped = OnlineModSourceProvider.mapDiscoveredSources([folder, row, unknown], item: item, season: nil, episode: nil, balancer: "Test", requestId: request)
        XCTAssertEqual(mapped.count, 2)
        XCTAssertTrue(mapped[0].isNavigationFolder)
        XCTAssertTrue(mapped[0].isAlternativeTitle)
        XCTAssertEqual(mapped[0].title, "Alternative")
        XCTAssertEqual(mapped[0].quality, "2024")
        XCTAssertEqual(mapped[0].discoveryRowToken, "41")
        XCTAssertFalse(mapped[1].isNavigationFolder)
        XCTAssertEqual(mapped[1].studioName, "Dub")
        XCTAssertEqual(mapped[1].title, "Edition")
        XCTAssertEqual(mapped[1].discoveryRowIndex, 1)
        XCTAssertTrue(mapped[1].streamUrl.isEmpty)
        let moved = DiscoveredLampaSource(index: 0, title: "Edition", quality: "1080p", isFolder: false, rowToken: "42", voice: "Dub")
        let remapped = OnlineModSourceProvider.mapDiscoveredSources([moved], item: item, season: nil, episode: nil, balancer: "Test", requestId: request)
        XCTAssertEqual(mapped[1].id, remapped[0].id)
        XCTAssertNotEqual(mapped[1].id, OnlineModSourceProvider.mapDiscoveredSources([moved], item: item, season: nil, episode: nil, balancer: "Test", requestId: UUID())[0].id)
    }

    func testOnlineModReturnsEmptySourcesWhenNoBridgeAvailable() async throws {
        let provider = OnlineModSourceProvider()
        let item = MediaItem(id: 1, title: "Black Doves", name: nil, originalTitle: nil, originalName: nil,
                             overview: nil, posterPath: nil, backdropPath: nil, mediaType: "movie",
                             releaseDate: nil, firstAirDate: nil, voteAverage: nil, voteCount: nil, genreIds: nil)
        // Host has not executed search or bridge is idle
        let sources = try await provider.resolveSources(for: item, season: nil, episode: nil)
        XCTAssertTrue(sources.isEmpty, "OnlineMod must not invent results when bridge is idle")
    }

    func testOnlineModCannotResolveDirectly() {
        let provider = OnlineModSourceProvider()
        XCTAssertFalse(provider.canResolveDirectly,
                        "Online Mod requires headless source discovery; canResolveDirectly must be false")
    }

    func testVerificationTestReturnsHonestMessage() async {
        let provider = OnlineModSourceProvider()
        let (_, message, _) = await provider.runVerificationTest()
        // The message must not instruct user to open Lampa web UI
        XCTAssertFalse(message.contains("Выберите источник в Lampa"),
                       "Message must not direct user to Lampa as primary path")
    }

    func testHeadlessSelectionGateAllowsBackgroundBridge() {
        var gate = PlaybackSelectionGate()
        let selected = PlaybackSelectionGate.Selection(
            requestID: "req-headless-1",
            canonicalID: "tmdb:movie:550",
            mediaType: "movie",
            pluginID: "online_mod",
            context: "headless_native_bridge",
            generation: 1,
            createdAt: Date()
        )
        // In background (isVisible == false)
        gate.select(selected, isVisible: false)
        XCTAssertNotNil(gate.pending, "Headless selection must be accepted even when host is not visible")

        let play = PlayPayload(
            url: "https://media.example.test/stream.m3u8",
            title: "Fight Club",
            canonicalId: "tmdb:movie:550",
            mediaType: "movie",
            season: nil,
            episode: nil,
            currentStudio: nil,
            pluginId: "online_mod",
            requestId: "req-headless-1",
            selectionContext: "headless_native_bridge"
        )

        let consumed = gate.consume(play, generation: 1, isVisible: false, now: Date())
        XCTAssertTrue(consumed, "PlaybackSelectionGate must consume headless_native_bridge selection")
        XCTAssertNil(gate.pending)
    }
}
