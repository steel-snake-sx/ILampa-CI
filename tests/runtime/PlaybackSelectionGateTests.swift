import Foundation
import XCTest
@testable import iLampa

final class PlaybackSelectionGateTests: XCTestCase {
    private let selectedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func selection(requestID: String = "request-1", canonicalID: String = "tmdb:movie:550",
                           mediaType: String = "movie", pluginID: String = "plugin-alpha",
                           season: Int? = nil, episode: Int? = nil, audio: String? = nil,
                           context: String = "user_source_select", generation: Int = 7)
        -> PlaybackSelectionGate.Selection {
        PlaybackSelectionGate.Selection(requestID: requestID, canonicalID: canonicalID,
                                        mediaType: mediaType, pluginID: pluginID, context: context,
                                        generation: generation, createdAt: selectedAt,
                                        season: season, episode: episode, audio: audio)
    }

    private func payload(for selection: PlaybackSelectionGate.Selection,
                         url: String = "https://media.example.test/selected.m3u8") -> PlayPayload {
        PlayPayload(url: url, title: "Selected title", canonicalId: selection.canonicalID,
                    mediaType: selection.mediaType, season: selection.season, episode: selection.episode,
                    currentStudio: selection.audio, pluginId: selection.pluginID,
                    requestId: selection.requestID, selectionContext: selection.context)
    }

    func testExactVisibleSelectionIsAcceptedOnlyOnce() {
        var gate = PlaybackSelectionGate()
        let selected = selection()
        let play = payload(for: selected)
        gate.select(selected, isVisible: true)
        XCTAssertTrue(gate.consume(play, generation: 7, isVisible: true, now: selectedAt))
        XCTAssertNil(gate.pending)
        XCTAssertFalse(gate.consume(play, generation: 7, isVisible: true, now: selectedAt))
    }

    func testSelectedVoiceIsAvailableOnlyFromAcceptedOnlineModSelection() {
        var gate = PlaybackSelectionGate()
        let selected = selection(audio: " AniLibria ", context: "lampa_player_create")
        gate.select(selected, isVisible: true)
        var mismatch = payload(for: selected)
        mismatch.currentStudio = "another voice"
        XCTAssertNil(gate.consumeSelection(mismatch, generation: 7, isVisible: true, now: selectedAt))
        let accepted = gate.consumeSelection(payload(for: selected), generation: 7, isVisible: true, now: selectedAt)
        XCTAssertEqual(accepted?.selectedVoiceName, "AniLibria")
        XCTAssertNil(gate.consumeSelection(payload(for: selected), generation: 7, isVisible: true, now: selectedAt))
        XCTAssertNil(selection(audio: "opaque-id").selectedVoiceName)
        XCTAssertNil(selection(audio: "  ", context: "headless_native_bridge").selectedVoiceName)
        XCTAssertEqual(selection(audio: String(repeating: "a", count: 210), context: "headless_native_bridge").selectedVoiceName?.count, 200)
    }

    func testUnselectedPlaybackCannotBeAccepted() {
        var gate = PlaybackSelectionGate()
        XCTAssertFalse(gate.consume(payload(for: selection()), generation: 7,
                                    isVisible: true, now: selectedAt))
        XCTAssertNil(gate.pending)
    }

    func testEachAttributionFieldMustMatchExactlyWithoutConsumingValidSelection() {
        let mutations: [(String, (inout PlayPayload) -> Void)] = [
            ("action", { $0.action = "pause" }),
            ("request", { $0.requestId = "request-2" }),
            ("canonical identity despite identical title", { $0.canonicalId = "tmdb:movie:551" }),
            ("media category", { $0.mediaType = "tv" }),
            ("plugin", { $0.pluginId = "plugin-beta" }),
            ("background context", { $0.selectionContext = "background" }),
            ("missing request", { $0.requestId = nil }),
            ("missing canonical identity", { $0.canonicalId = nil }),
            ("missing media category", { $0.mediaType = nil }),
            ("missing plugin", { $0.pluginId = nil }),
            ("missing context", { $0.selectionContext = nil })
        ]
        for (field, mutate) in mutations {
            var gate = PlaybackSelectionGate()
            let selected = selection()
            gate.select(selected, isVisible: true)
            var invalid = payload(for: selected)
            mutate(&invalid)
            XCTAssertFalse(gate.consume(invalid, generation: 7, isVisible: true, now: selectedAt), field)
            XCTAssertEqual(gate.pending?.requestID, selected.requestID, field)
            XCTAssertTrue(gate.consume(payload(for: selected), generation: 7,
                                       isVisible: true, now: selectedAt), field)
        }
    }

    func testStaleAndFutureRuntimeGenerationsAreRejected() {
        var gate = PlaybackSelectionGate()
        let selected = selection()
        gate.select(selected, isVisible: true)
        for generation in [6, 8] {
            XCTAssertFalse(gate.consume(payload(for: selected), generation: generation,
                                        isVisible: true, now: selectedAt))
        }
        XCTAssertTrue(gate.consume(payload(for: selected), generation: 7,
                                   isVisible: true, now: selectedAt))
    }

    func testExpiryUsesStrictSixtySecondBoundaryAndRejectsFutureSelections() {
        for (elapsed, accepted) in [(-1.0, false), (0.0, true), (59.999, true), (60.0, false), (61.0, false)] {
            var gate = PlaybackSelectionGate()
            let selected = selection()
            gate.select(selected, isVisible: true)
            XCTAssertEqual(gate.consume(payload(for: selected), generation: 7, isVisible: true,
                                        now: selectedAt.addingTimeInterval(elapsed)), accepted,
                           "Elapsed seconds: \(elapsed)")
            XCTAssertEqual(gate.pending == nil, accepted)
        }
    }

    func testBackgroundSelectionDoesNotAuthorizeLaterVisiblePlayback() {
        var gate = PlaybackSelectionGate()
        let selected = selection()
        gate.select(selected, isVisible: false)
        XCTAssertNil(gate.pending)
        XCTAssertFalse(gate.consume(payload(for: selected), generation: 7,
                                    isVisible: true, now: selectedAt))
    }

    func testBackgroundPlaybackCannotConsumeVisibleUserSelection() {
        var gate = PlaybackSelectionGate()
        let selected = selection()
        gate.select(selected, isVisible: true)
        XCTAssertFalse(gate.consume(payload(for: selected), generation: 7,
                                    isVisible: false, now: selectedAt))
        XCTAssertEqual(gate.pending?.requestID, selected.requestID)
        XCTAssertTrue(gate.consume(payload(for: selected), generation: 7,
                                   isVisible: true, now: selectedAt))
    }

    func testIncompleteSelectionsDoNotCreateAuthorization() {
        let incomplete = [selection(requestID: ""), selection(canonicalID: ""),
                          selection(pluginID: ""), selection(context: "")]
        for selected in incomplete {
            var gate = PlaybackSelectionGate()
            gate.select(selected, isVisible: true)
            XCTAssertNil(gate.pending)
            XCTAssertFalse(gate.consume(payload(for: selected), generation: 7,
                                        isVisible: true, now: selectedAt))
        }
    }

    func testOnlyAbsoluteHTTPAndHTTPSMediaURLsAreAccepted() {
        let urls = [("https://media.example.test/selected.m3u8", true),
                    ("http://media.example.test/selected.mp4", true),
                    ("HTTPS://media.example.test/selected.m3u8", true),
                    ("file:///private/selected.mp4", false),
                    ("javascript:alert(1)", false), ("data:video/mp4;base64,AAAA", false),
                    ("/relative/selected.m3u8", false), ("https:/selected.m3u8", false),
                    ("", false)]
        for (url, accepted) in urls {
            var gate = PlaybackSelectionGate()
            let selected = selection()
            gate.select(selected, isVisible: true)
            XCTAssertEqual(gate.consume(payload(for: selected, url: url), generation: 7,
                                        isVisible: true, now: selectedAt), accepted, url)
            XCTAssertEqual(gate.pending == nil, accepted, url)
        }
    }

    func testNewSelectionSupersedesLateResponseFromPreviousSelection() {
        var gate = PlaybackSelectionGate()
        let first = selection()
        let next = selection(requestID: "request-2", canonicalID: "tmdb:tv:60059",
                             mediaType: "tv", pluginID: "plugin-beta", context: "user_episode_select")
        gate.select(first, isVisible: true)
        gate.select(next, isVisible: true)
        XCTAssertFalse(gate.consume(payload(for: first), generation: 7,
                                    isVisible: true, now: selectedAt))
        XCTAssertEqual(gate.pending?.requestID, next.requestID)
        XCTAssertTrue(gate.consume(payload(for: next), generation: 7,
                                   isVisible: true, now: selectedAt))
    }

    func testDifferentEpisodeAndVoiceAreRejectedWithoutConsumingExactSelection() {
        var gate = PlaybackSelectionGate()
        let selected = selection(canonicalID: "tmdb:tv:60059", mediaType: "tv",
                                 season: 2, episode: 5, audio: "voice-alpha",
                                 context: "user_episode_select")
        gate.select(selected, isVisible: true)

        var wrongEpisode = payload(for: selected)
        wrongEpisode.episode = 4
        XCTAssertFalse(gate.consume(wrongEpisode, generation: 7, isVisible: true, now: selectedAt))
        XCTAssertEqual(gate.pending?.episode, 5)

        var wrongVoice = payload(for: selected)
        wrongVoice.currentStudio = "voice-beta"
        XCTAssertFalse(gate.consume(wrongVoice, generation: 7, isVisible: true, now: selectedAt))
        XCTAssertEqual(gate.pending?.audio, "voice-alpha")

        XCTAssertTrue(gate.consume(payload(for: selected), generation: 7, isVisible: true, now: selectedAt))
        XCTAssertNil(gate.pending)
    }

    func testClearingSelectionRevokesOtherwiseMatchingPlayback() {
        var gate = PlaybackSelectionGate()
        let selected = selection()
        gate.select(selected, isVisible: true)
        gate.clear()
        XCTAssertNil(gate.pending)
        XCTAssertFalse(gate.consume(payload(for: selected), generation: 7,
                                    isVisible: true, now: selectedAt))
    }
}
