import XCTest
@testable import iLampa

final class EpisodeQueueTests: XCTestCase {
    private func playlist(_ episodes: [(Int, Int, String)]) -> [PlaylistItem] {
        episodes.enumerated().map { index, value in
            PlaylistItem(index: index, seasonNumber: value.0, episodeNumber: value.1,
                         title: "Episode \(value.1)", url: value.2)
        }
    }

    func testNextEpisodeUsesSamePlaylistAndSource() {
        let items = playlist([(1, 1, "https://source.test/s1e1"),
                              (1, 2, "https://source.test/s1e2")])
        let playing = PlayPayload(url: items[0].url, mediaType: "tv", season: 1, episode: 1,
                                  playlist: items)
        XCTAssertEqual(EpisodeQueue.nextEpisode(for: playing)?.episodeNumber, 2)
    }

    func testMissingMiddleEpisodeIsNotSkipped() {
        let items = playlist([(1, 1, "https://source.test/s1e1"),
                              (1, 3, "https://source.test/s1e3")])
        let playing = PlayPayload(url: items[0].url, mediaType: "tv", season: 1, episode: 1,
                                  playlist: items)
        XCTAssertNil(EpisodeQueue.nextEpisode(for: playing))
    }

    func testNextSeasonRequiresFirstEpisode() {
        let items = playlist([(1, 12, "https://source.test/s1e12"),
                              (2, 1, "https://source.test/s2e1")])
        let playing = PlayPayload(url: items[0].url, mediaType: "tv", season: 1, episode: 12,
                                  playlist: items)
        XCTAssertEqual(EpisodeQueue.nextEpisode(for: playing)?.seasonNumber, 2)
    }

    func testLastEpisodeHasNoWarningOrNextAction() {
        let items = playlist([(1, 1, "https://source.test/s1e1"),
                              (1, 2, "https://source.test/s1e2")])
        let last = PlayPayload(url: items[1].url, mediaType: "tv", season: 1, episode: 2,
                               playlist: items)
        if case .lastEpisode = EpisodeQueue.resolveNextEpisode(for: last) {
            // Expected: no error state for a normally completed playlist.
        } else {
            XCTFail("The final episode must be classified as a normal end")
        }
        XCTAssertFalse(EpisodeQueue.shouldShowNextEpisodeAction(for: last))
        XCTAssertNil(EpisodeQueue.nextEpisode(for: last))
    }

    func testMissingMiddleEpisodeShowsUnavailableState() {
        let items = playlist([(1, 1, "https://source.test/s1e1"),
                              (1, 3, "https://source.test/s1e3")])
        let current = PlayPayload(url: items[0].url, mediaType: "tv",
                                  season: 1, episode: 1, playlist: items)
        if case .unavailable = EpisodeQueue.resolveNextEpisode(for: current) {
            // Expected: this is a genuine gap, not the last episode.
        } else {
            XCTFail("A gap between episodes must be reported as unavailable")
        }
        XCTAssertTrue(EpisodeQueue.shouldShowNextEpisodeAction(for: current))
    }

    func testUnresolvedPlaylistDoesNotClaimEpisodeIsMissing() {
        let current = PlayPayload(url: "https://source.test/episode",
                                  mediaType: "tv", season: 1, episode: 1,
                                  playlist: nil)
        if case .unknown = EpisodeQueue.resolveNextEpisode(for: current) {
            // Without the source playlist, the presence of a next episode is unknown.
        } else {
            XCTFail("Do not infer a missing episode without playlist data")
        }
        XCTAssertFalse(EpisodeQueue.shouldShowNextEpisodeAction(for: current))
    }

    func testNoEpisodeAvailableOrUnresolvedURL() {
        let items = playlist([(1, 1, "https://source.test/s1e1")])
        let playing = PlayPayload(url: items[0].url, mediaType: "tv", season: 1, episode: 1,
                                  playlist: items)
        XCTAssertNil(EpisodeQueue.nextEpisode(for: playing))
        XCTAssertNil(EpisodeQueue.nextEpisode(for: PlayPayload(url: "https://other.test/episode",
                                                                mediaType: "tv", season: 1, episode: 7,
                                                                playlist: items)))
    }
    func testPlayerPresentationIdentityDoesNotChangeForNextEpisodeOrQuality() {
        let first = PlayPayload(url: "https://source.test/1.m3u8",
                                canonicalId: "urn:media:tmdb:tv:42", mediaType: "tv",
                                season: 1, episode: 1)
        let second = PlayPayload(url: "https://source.test/2.mp4",
                                 canonicalId: "urn:media:tmdb:tv:42", mediaType: "tv",
                                 season: 1, episode: 2, currentQuality: "1080p")
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(PlaybackItemIdentity(payload: first), PlaybackItemIdentity(payload: second))
    }

    func testNextEpisodeSourceKeepsProviderAndVoice() {
        func source(_ name: String, provider: String, studio: String) -> ResolvedMediaSource {
            ResolvedMediaSource(
                id: name, providerName: provider, title: "Episode 2",
                quality: "720p", studioId: studio, studioName: studio,
                streamUrl: "https://source.test/2.mp4", isHls: false, container: "mp4",
                season: 1, episode: 2, providerId: provider,
                canonicalMediaId: "urn:media:tmdb:tv:42"
            )
        }
        let original = PlayPayload(url: "https://source.test/1.mp4",
            canonicalId: "urn:media:tmdb:tv:42", mediaType: "tv",
            season: 1, episode: 1, currentStudio: "voiceA", plugin: "online_mod")
        let candidates = [source("other-provider", provider: "anilibria", studio: "voiceA"),
                          source("wrong-voice", provider: "online_mod", studio: "voiceB"),
                          source("same-voice", provider: "online_mod", studio: "voiceA")]
        XCTAssertEqual(EpisodeQueue.chooseNextSource(
            from: candidates, previous: original, canonicalId: "urn:media:tmdb:tv:42",
            season: 1, episode: 2
        )?.id, "same-voice")
        XCTAssertNil(EpisodeQueue.chooseNextSource(
            from: candidates, previous: original, canonicalId: "urn:media:tmdb:tv:42",
            season: 1, episode: 3
        ))
    }

    func testNativeCatalogIdentitySurvivesPayloadSerialization() throws {
        let item = MediaItem(id: 42, title: nil, name: "Series", originalTitle: nil,
            originalName: nil, overview: nil, posterPath: nil, backdropPath: nil,
            mediaType: "tv", releaseDate: nil, firstAirDate: nil,
            voteAverage: nil, voteCount: nil, genreIds: nil)
        let payload = PlayPayload(url: "https://source.test/s1e1.mp4",
            canonicalId: item.canonicalId, mediaType: "tv",
            season: 1, episode: 1, mediaLookupItem: item)
        let decoded = try JSONDecoder().decode(PlayPayload.self, from: JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.mediaLookupItem, item)
    }


}
