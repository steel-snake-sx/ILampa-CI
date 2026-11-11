import XCTest
import AVKit
import SwiftUI
import MediaPlayer
@testable import iLampa

@MainActor
private final class ObserverRemovalRecord {
    private(set) var removals = 0
    private(set) var itemAtRemoval: AVPlayerItem?

    func record(item: AVPlayerItem?) {
        removals += 1
        itemAtRemoval = item
    }
}

private final class ObserverTrackingPlayer: AVPlayer {
    // Do not add global-actor isolation to the nonisolated AVPlayer superclass.
    let record: ObserverRemovalRecord
    @MainActor var removals: Int { record.removals }
    @MainActor var itemAtRemoval: AVPlayerItem? { record.itemAtRemoval }

    init(record: ObserverRemovalRecord) {
        self.record = record
        super.init()
    }

    override func removeTimeObserver(_ observer: Any) {
        // The framework override is nonisolated; production cleanup must execute on main.
        MainActor.assumeIsolated {
            record.record(item: currentItem)
        }
        super.removeTimeObserver(observer)
    }
}

/// Deliver held callbacks directly through the same boundaries used by KVO/AVKit.
/// No remote streams, sleeps, or assumptions about framework callback timing.
final class PlaybackConcurrencyTests: XCTestCase {
    // XCTest's inherited initializer is nonisolated; do not construct actor-owned helpers there.
    @MainActor
    private var url: URL { URL(fileURLWithPath: "/ilampa-callback-fixture.wav") }

    @MainActor
    private func makeCoordinator(
        lifecycle: PlayerPlaybackController,
        onDismiss: (@MainActor () -> Void)? = nil
    ) -> NativePlayerView.Coordinator {
        NativePlayerView.Coordinator(
            NativePlayerView(payload: .constant(PlayPayload(url: url.absoluteString)), onDismiss: onDismiss),
            playbackController: lifecycle
        )
    }

    @MainActor
    func testTokensRejectQueuedCallbacksAfterReplacementAndStop() {
        let session = PlaybackSessionToken()
        let first = session.current
        XCTAssertTrue(session.accepts(first))
        let second = session.renew()
        XCTAssertFalse(session.accepts(first))
        XCTAssertTrue(session.accepts(second))
        session.invalidate()
        XCTAssertFalse(session.accepts(second))
        XCTAssertFalse(session.accepts(nil))
    }

    @MainActor
    func testIdentityIncludesCanonicalSeasonAndEpisodeButNotDisplayMetadata() {
        let original = PlayPayload(url: url.absoluteString, title: "Original", canonicalId: "A",
                                   mediaType: "tv", season: 1, episode: 1)
        let identity = PlaybackItemIdentity(payload: original)
        var changed = original
        changed.canonicalId = "B"
        XCTAssertNotEqual(identity, PlaybackItemIdentity(payload: changed))
        changed = original
        changed.season = 2
        XCTAssertNotEqual(identity, PlaybackItemIdentity(payload: changed))
        changed = original
        changed.episode = 2
        XCTAssertNotEqual(identity, PlaybackItemIdentity(payload: changed))
        changed = original
        changed.title = "Updated title"
        changed.currentStudioName = "Updated studio"
        XCTAssertEqual(identity, PlaybackItemIdentity(payload: changed))
        changed = original
        changed.hash = "Different legacy hash"
        XCTAssertEqual(identity, PlaybackItemIdentity(payload: changed), "Canonical ID wins over a legacy hash")
        changed.canonicalId = nil
        let legacy = PlaybackItemIdentity(payload: changed)
        changed.hash = "Another legacy media item"
        XCTAssertNotEqual(legacy, PlaybackItemIdentity(payload: changed))
    }

    @MainActor
    func testSameURLIdentityChangesReplaceItemRenewTokenAndResetEndFlags() throws {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        var payload = PlayPayload(url: url.absoluteString, canonicalId: "A", mediaType: "tv", season: 1, episode: 1)
        let coordinator = NativePlayerView.Coordinator(NativePlayerView(payload: .constant(payload)), playbackController: lifecycle)
        let controller = AVPlayerViewController()
        let player = AVPlayer(playerItem: AVPlayerItem(url: url))
        coordinator.player = player
        controller.player = player
        defer { coordinator.cleanup() }
        for field in ["canonical", "season", "episode"] {
            let oldItem = try XCTUnwrap(player.currentItem)
            let oldToken = coordinator.itemSession.current
            coordinator.hasTriggeredEnd = true
            coordinator.hasTriggeredNearEnd = true
            switch field {
            case "canonical": payload.canonicalId = "B"
            case "season": payload.season = 2
            default: payload.episode = 2
            }
            coordinator.update(NativePlayerView(payload: .constant(payload)), controller: controller)
            XCTAssertFalse(oldItem === player.currentItem, field)
            XCTAssertNotEqual(coordinator.itemSession.current, oldToken, field)
            XCTAssertEqual(coordinator.currentIdentity, PlaybackItemIdentity(payload: payload))
            XCTAssertFalse(coordinator.hasTriggeredEnd)
            XCTAssertFalse(coordinator.hasTriggeredNearEnd)
            XCTAssertFalse(coordinator.acceptsCallback(from: oldItem, token: oldToken))
            XCTAssertTrue(coordinator.acceptsCallback(from: try XCTUnwrap(player.currentItem), token: coordinator.itemSession.current))
        }
    }

    @MainActor
    func testBoundIdentityChangeRejectsOldCallbacksEvenBeforeRepresentableUpdate() {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        var payload = PlayPayload(url: url.absoluteString, canonicalId: "A", mediaType: "tv", season: 1, episode: 1)
        var ends = 0
        let view = NativePlayerView(payload: Binding(get: { payload }, set: { payload = $0 }), onEnded: { ends += 1 })
        let coordinator = NativePlayerView.Coordinator(view, playbackController: lifecycle)
        let item = AVPlayerItem(url: url)
        coordinator.player = AVPlayer(playerItem: item)
        let token = coordinator.itemSession.current
        XCTAssertTrue(coordinator.acceptsCallback(from: item, token: token))
        payload.episode = 2
        XCTAssertFalse(coordinator.acceptsCallback(from: item, token: token))
        coordinator.handleEnd(of: item, token: token)
        XCTAssertEqual(ends, 0)
        coordinator.cleanup()
    }

    @MainActor
    func testMetadataOnlyUpdateKeepsItemAndToken() {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        var payload = PlayPayload(url: url.absoluteString, title: "Before", canonicalId: "A", season: 1, episode: 1)
        let coordinator = NativePlayerView.Coordinator(NativePlayerView(payload: .constant(payload)), playbackController: lifecycle)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let controller = AVPlayerViewController()
        controller.player = player
        coordinator.player = player
        let token = coordinator.itemSession.current
        payload.title = "After"
        payload.currentStudioName = "Known voice"
        coordinator.update(NativePlayerView(payload: .constant(payload)), controller: controller)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(coordinator.itemSession.current, token)
        XCTAssertEqual(item.externalMetadata.first(where: { $0.identifier == .commonIdentifierTitle })?.stringValue, "After")
        coordinator.cleanup()
    }

    @MainActor
    func testOffActorLastReleaseHandsOnlyResourcesToMainActorCleanup() async {
        let cleaned = expectation(description: "resource-only deinit fallback cleaned on main actor")
        let lifecycle = PlayerPlaybackController(deactivateAudio: {
            MainActor.assertIsolated()
            cleaned.fulfill()
        })
        let record = ObserverRemovalRecord()
        let url = self.url
        await Task.detached {
            var coordinator: NativePlayerView.Coordinator? = await MainActor.run {
                let coordinator = NativePlayerView.Coordinator(
                    NativePlayerView(payload: .constant(PlayPayload(url: url.absoluteString))), playbackController: lifecycle)
                let player = ObserverTrackingPlayer(record: record)
                let controller = AVPlayerViewController()
                let item = AVPlayerItem(url: url)
                player.replaceCurrentItem(with: item)
                controller.player = player
                coordinator.player = player
                coordinator.observeProgress(of: item)
                coordinator.register(controller: controller)
                lifecycle.claimAudioSession(owner: coordinator.ownerID)
                return coordinator
            }
            withExtendedLifetime(coordinator) {}
            coordinator = nil
        }.value
        let cleanupResult = await XCTWaiter().fulfillment(of: [cleaned], timeout: 3)
        XCTAssertEqual(cleanupResult, .completed)
        XCTAssertEqual(record.removals, 1)
        XCTAssertNil(lifecycle.activePlayer)
    }

    @MainActor
    func testExplicitTeardownRemovesObserverBeforeDetachingPlayerExactlyOnce() {
        var deactivations = 0
        let lifecycle = PlayerPlaybackController(deactivateAudio: { deactivations += 1 })
        let coordinator = makeCoordinator(lifecycle: lifecycle)
        let player = ObserverTrackingPlayer(record: ObserverRemovalRecord())
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        let controller = AVPlayerViewController()
        controller.player = player
        coordinator.player = player
        coordinator.observeProgress(of: item)
        coordinator.observeStatus(of: item)
        coordinator.observeEnd(of: item)
        coordinator.register(controller: controller)
        lifecycle.claimAudioSession(owner: coordinator.ownerID)
        XCTAssertNotNil(coordinator.timeObserver)

        lifecycle.pauseAndTeardown()

        XCTAssertEqual(player.removals, 1)
        XCTAssertTrue(player.itemAtRemoval === item, "Remove while the observed player/item are still attached")
        XCTAssertNil(coordinator.timeObserver)
        XCTAssertNil(coordinator.statusObserver)
        XCTAssertNil(coordinator.endObserver)
        XCTAssertNil(coordinator.player)
        XCTAssertNil(player.currentItem)
        XCTAssertNil(controller.player)
        XCTAssertNil(lifecycle.activePlayer)
        XCTAssertEqual(deactivations, 1)
        NativePlayerView.dismantleUIViewController(controller, coordinator: coordinator)
        lifecycle.pauseAndTeardown()
        XCTAssertEqual(player.removals, 1)
        XCTAssertEqual(deactivations, 1)
    }

    @MainActor
    func testOldCleanupCannotReleaseReplacementAudioOrRegistration() {
        var deactivations = 0
        let lifecycle = PlayerPlaybackController(deactivateAudio: { deactivations += 1 })
        let first = makeCoordinator(lifecycle: lifecycle)
        let second = makeCoordinator(lifecycle: lifecycle)
        let firstController = AVPlayerViewController()
        let secondController = AVPlayerViewController()
        first.player = AVPlayer()
        second.player = AVPlayer()
        firstController.player = first.player
        secondController.player = second.player
        first.register(controller: firstController)
        lifecycle.claimAudioSession(owner: first.ownerID)
        second.register(controller: secondController)
        lifecycle.claimAudioSession(owner: second.ownerID)

        first.cleanup()
        first.cleanup()
        XCTAssertEqual(deactivations, 0)
        XCTAssertTrue(lifecycle.activePlayer === second.player)
        XCTAssertTrue(lifecycle.isActive(owner: second.ownerID))
        second.cleanup()
        XCTAssertEqual(deactivations, 1)
    }

    @MainActor
    func testAudioSessionRemainsActiveUntilEveryOwnerReleases() {
        var deactivations = 0
        let lifecycle = PlayerPlaybackController(deactivateAudio: { deactivations += 1 })
        let first = UUID()
        let second = UUID()
        lifecycle.claimAudioSession(owner: first)
        lifecycle.claimAudioSession(owner: second)
        lifecycle.releaseAudioSession(owner: second)
        lifecycle.releaseAudioSession(owner: second)
        XCTAssertEqual(deactivations, 0, "Newer playback stopping must not deactivate an older live session either")
        lifecycle.releaseAudioSession(owner: first)
        lifecycle.releaseAudioSession(owner: first)
        XCTAssertEqual(deactivations, 1)
    }

    @MainActor
    func testDismissalCompletionRejectsOldItemGenerationAndOldOwner() {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        var dismissals = 0
        let first = makeCoordinator(lifecycle: lifecycle, onDismiss: { dismissals += 1 })
        let controller = AVPlayerViewController()
        first.player = AVPlayer()
        first.register(controller: controller)
        let oldToken = first.itemSession.current
        first.itemSession.renew()
        first.completeDismissal(token: oldToken, cancelled: false)
        XCTAssertEqual(dismissals, 0)
        XCTAssertFalse(first.isCleanedUp)

        let currentToken = first.itemSession.current
        first.completeDismissal(token: currentToken, cancelled: true)
        XCTAssertFalse(first.isCleanedUp)
        let second = makeCoordinator(lifecycle: lifecycle)
        second.player = AVPlayer()
        second.register(controller: controller)
        first.completeDismissal(token: currentToken, cancelled: false)
        XCTAssertEqual(dismissals, 0)
        XCTAssertFalse(second.isCleanedUp)
        first.cleanup()
        second.cleanup()
    }

    @MainActor
    func testCurrentDismissalCompletionIsDeliveredOnlyOnce() {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        var dismissals = 0
        let coordinator = makeCoordinator(lifecycle: lifecycle, onDismiss: { dismissals += 1 })
        let controller = AVPlayerViewController()
        coordinator.player = AVPlayer()
        coordinator.register(controller: controller)
        let token = coordinator.itemSession.current
        coordinator.completeDismissal(token: token, cancelled: false)
        coordinator.completeDismissal(token: token, cancelled: false)
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(coordinator.isCleanedUp)
    }

    @MainActor
    func testDetachedPictureInPictureRetainsCoordinatorUntilStop() {
        var deactivations = 0
        let lifecycle = PlayerPlaybackController(deactivateAudio: { deactivations += 1 })
        var coordinator: NativePlayerView.Coordinator? = makeCoordinator(lifecycle: lifecycle)
        weak var weakCoordinator = coordinator
        let controller = AVPlayerViewController()
        coordinator?.player = AVPlayer()
        controller.player = coordinator?.player
        controller.delegate = coordinator
        coordinator?.register(controller: controller)
        lifecycle.claimAudioSession(owner: coordinator!.ownerID)
        coordinator?.playerViewControllerWillStartPictureInPicture(controller)
        NativePlayerView.dismantleUIViewController(controller, coordinator: coordinator!)
        coordinator = nil

        XCTAssertNotNil(weakCoordinator, "The AVKit delegate is weak; a detached PiP session needs an owner")
        XCTAssertNotNil(controller.player)
        XCTAssertEqual(deactivations, 0)
        weakCoordinator?.playerViewControllerDidStopPictureInPicture(controller)
        XCTAssertNil(controller.player)
        XCTAssertNil(weakCoordinator)
        XCTAssertEqual(deactivations, 1)
    }

    @MainActor
    func testVideoCallbackGateRequiresBothItemIdentityAndGeneration() {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        let coordinator = makeCoordinator(lifecycle: lifecycle)
        let first = AVPlayerItem(url: url)
        let second = AVPlayerItem(url: url)
        coordinator.player = AVPlayer(playerItem: first)
        let token = coordinator.itemSession.current
        XCTAssertTrue(coordinator.acceptsCallback(from: first, token: token))
        XCTAssertFalse(coordinator.acceptsCallback(from: second, token: token))
        coordinator.itemSession.renew()
        XCTAssertFalse(coordinator.acceptsCallback(from: first, token: token), "Same item/URL cannot authenticate an old generation")
        coordinator.player?.replaceCurrentItem(with: second)
        XCTAssertFalse(coordinator.acceptsCallback(from: first, token: coordinator.itemSession.current))
        XCTAssertTrue(coordinator.acceptsCallback(from: second, token: coordinator.itemSession.current))
        coordinator.cleanup()
        XCTAssertFalse(coordinator.acceptsCallback(from: second, token: coordinator.itemSession.current))
    }

    @MainActor
    func testEndCallbackRejectsOldGenerationAndIsDeliveredOnceForCurrentItem() {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        var ends = 0
        let coordinator = NativePlayerView.Coordinator(
            NativePlayerView(payload: .constant(PlayPayload(url: url.absoluteString)), onEnded: { ends += 1 }),
            playbackController: lifecycle)
        let item = AVPlayerItem(url: url)
        coordinator.player = AVPlayer(playerItem: item)
        let oldToken = coordinator.itemSession.current
        coordinator.itemSession.renew()
        coordinator.handleEnd(of: item, token: oldToken)
        XCTAssertEqual(ends, 0)
        let token = coordinator.itemSession.current
        coordinator.handleEnd(of: item, token: token)
        coordinator.handleEnd(of: item, token: token)
        XCTAssertEqual(ends, 1)
        coordinator.cleanup()
        coordinator.handleEnd(of: item, token: token)
        XCTAssertEqual(ends, 1)
    }

    @MainActor
    func testHeldProgressCallbackCannotReportTimeAgainstReplacementItem() async throws {
        // The callback isolation contract is independent of audio hardware.
        // A separately loaded real fixture duration supplies the positive control.
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("playback-epoch-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frames: AVAudioFrameCount = 8_000 * 60
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0, count: Int(frames))
        do {
            let file = try AVAudioFile(forWriting: fixture, settings: format.settings)
            try file.write(from: buffer)
        }
        let preparedAsset = AVURLAsset(url: fixture)
        let loadedDuration = CMTimeGetSeconds(try await preparedAsset.load(.duration))
        XCTAssertEqual(loadedDuration, 60, accuracy: 0.1,
                       "Positive control requires real, readable media metadata")
        var times: [Double] = []
        var nearEnds = 0
        var payload = PlayPayload(url: fixture.absoluteString, canonicalId: "fixture-A")
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        let coordinator = NativePlayerView.Coordinator(
            NativePlayerView(payload: .constant(payload), onTimeUpdate: { time, _, _ in times.append(time) },
                             onNearEnd: { nearEnds += 1 }), playbackController: lifecycle)
        let first = AVPlayerItem(url: fixture)
        let player = AVPlayer(playerItem: first)
        coordinator.player = player
        let controller = AVPlayerViewController()
        controller.player = player
        defer { coordinator.cleanup() }
        let heldCallback = coordinator.progressHandler(for: first, testedAssetDuration: loadedDuration)
        payload.canonicalId = "fixture-B"
        coordinator.update(NativePlayerView(payload: .constant(payload), onTimeUpdate: { time, _, _ in times.append(time) },
                                           onNearEnd: { nearEnds += 1 }), controller: controller)
        let second = try XCTUnwrap(player.currentItem)
        XCTAssertFalse(first === second)
        // A stale event must be rejected even when AVPlayerItem readiness is
        // blocked by the CI simulator's CoreAudio service.
        // Readiness/play/seek remain covered by PlayerStateIntegrationTests.
        // Discard genuine framework callbacks delivered during the readiness wait.
        // All held/manual callbacks below execute synchronously on the main actor.
        times.removeAll()
        nearEnds = 0
        heldCallback(CMTime(seconds: 55, preferredTimescale: 600))
        XCTAssertTrue(times.isEmpty)
        XCTAssertEqual(nearEnds, 0)
        coordinator.progressHandler(for: second, testedAssetDuration: loadedDuration)(CMTime(seconds: 1, preferredTimescale: 600))
        XCTAssertEqual(times, [1], "Positive control: a current callback must actually report progress")
        let currentCallback = coordinator.progressHandler(for: second, testedAssetDuration: loadedDuration)
        coordinator.cleanup()
        XCTAssertNil(coordinator.timeObserver)
        XCTAssertNil(coordinator.endObserver)
        XCTAssertNil(coordinator.statusObserver)
        currentCallback(CMTime(seconds: 55, preferredTimescale: 600))
        XCTAssertEqual(times, [1], "Removed observers/invalidated owner cannot publish progress")
        XCTAssertEqual(nearEnds, 0)
    }

    @MainActor
    private func station(_ id: String) -> RadioStation {
        RadioStation(id: id, title: id, description: "", genre: "ambient", largeimage: "https://example.invalid/\(id).png",
                     listeners: 0, playlists: [])
    }

    @MainActor
    private func makeRadio(
        lifecycle: PlayerPlaybackController,
        publish: @escaping @MainActor ([String: Any]?) -> Void = { _ in }
    ) -> RadioPlayerModel {
        RadioPlayerModel(playbackController: lifecycle, installRemoteControls: false,
                         activateAudio: {}, publishNowPlaying: publish, loadArtwork: { _ in nil })
    }

    @MainActor
    func testRadioQueuedStatusCallbacksCannotChangeReplacementOrStoppedState() throws {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        var metadata: [String: Any]?
        let radio = makeRadio(lifecycle: lifecycle, publish: { metadata = $0 })
        defer { radio.stop() }
        radio.play(station: station("A"), streamURLs: [url])
        let firstItem = try XCTUnwrap(radio.playerItem)
        let firstPlayer = try XCTUnwrap(radio.player)
        let firstToken = radio.session.current
        radio.play(station: station("B"), streamURLs: [url])
        let secondItem = try XCTUnwrap(radio.playerItem)
        let secondPlayer = try XCTUnwrap(radio.player)
        let secondToken = radio.session.current
        let failure = NSError(domain: "PlaybackConcurrencyTests", code: 1)

        radio.handleItemStatus(.readyToPlay, error: nil, item: firstItem, token: firstToken)
        XCTAssertTrue(radio.isLoading)
        radio.handleItemStatus(.failed, error: failure, item: firstItem, token: firstToken)
        XCTAssertNil(radio.errorMessage)
        radio.handleItemStatus(.failed, error: failure, item: secondItem, token: firstToken)
        radio.handleItemStatus(.failed, error: failure, item: firstItem, token: secondToken)
        XCTAssertNil(radio.errorMessage, "Generation and item identity are independent checks")
        radio.handleTimeControlStatus(.playing, player: firstPlayer, token: firstToken)
        radio.handleTimeControlStatus(.playing, player: secondPlayer, token: firstToken)
        radio.handleTimeControlStatus(.playing, player: firstPlayer, token: secondToken)
        XCTAssertFalse(radio.isPlaying)
        XCTAssertEqual(metadata?[MPMediaItemPropertyTitle] as? String, "B")
        radio.handleItemStatus(.readyToPlay, error: nil, item: secondItem, token: secondToken)
        XCTAssertFalse(radio.isLoading, "Current readiness is still delivered")
        radio.handleTimeControlStatus(.playing, player: secondPlayer, token: secondToken)
        XCTAssertTrue(radio.isPlaying)
        radio.handleTimeControlStatus(.paused, player: firstPlayer, token: firstToken)
        radio.handleTimeControlStatus(.waitingToPlayAtSpecifiedRate, player: firstPlayer, token: firstToken)
        XCTAssertTrue(radio.isPlaying)
        XCTAssertFalse(radio.isLoading)

        radio.stop()
        radio.handleTimeControlStatus(.playing, player: secondPlayer, token: secondToken)
        radio.handleItemStatus(.failed, error: failure, item: secondItem, token: secondToken)
        XCTAssertFalse(radio.isCurrentlyPlaying)
        XCTAssertNil(radio.currentStation)
        XCTAssertNil(radio.errorMessage)
        XCTAssertNil(metadata)
    }

    @MainActor
    func testArtworkCompletionCannotOverwriteReplacementOrRecreateStoppedMetadata() throws {
        let lifecycle = PlayerPlaybackController(deactivateAudio: {})
        var metadata: [String: Any]?
        let radio = makeRadio(lifecycle: lifecycle, publish: { metadata = $0 })
        defer { radio.stop() }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let data = try XCTUnwrap(image.pngData())
        radio.play(station: station("A"), streamURLs: [url])
        let firstToken = radio.session.current
        radio.applyArtwork(data, stationID: "A", token: firstToken)
        XCTAssertNotNil(metadata?[MPMediaItemPropertyArtwork], "Positive control: valid artwork is published")
        radio.play(station: station("B"), streamURLs: [url])
        radio.applyArtwork(data, stationID: "A", token: firstToken)
        XCTAssertNil(metadata?[MPMediaItemPropertyArtwork])
        XCTAssertEqual(metadata?[MPMediaItemPropertyTitle] as? String, "B")
        radio.play(station: station("A"), streamURLs: [url])
        radio.applyArtwork(data, stationID: "A", token: firstToken)
        XCTAssertNil(metadata?[MPMediaItemPropertyArtwork], "Station identity alone is insufficient for A → B → A")
        let token = radio.session.current
        radio.stop()
        radio.applyArtwork(data, stationID: "A", token: token)
        XCTAssertNil(metadata)
    }

    @MainActor
    func testVideoCleanupCannotDeactivateNewerRadioAudioSession() {
        var deactivations = 0
        let lifecycle = PlayerPlaybackController(deactivateAudio: { deactivations += 1 })
        let video = makeCoordinator(lifecycle: lifecycle)
        lifecycle.claimAudioSession(owner: video.ownerID)
        let radio = makeRadio(lifecycle: lifecycle)
        radio.play(station: station("A"), streamURLs: [url])
        video.cleanup()
        XCTAssertEqual(deactivations, 0)
        radio.stop()
        XCTAssertEqual(deactivations, 1)
    }
}
