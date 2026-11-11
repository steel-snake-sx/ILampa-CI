import SwiftUI
import AVKit
import Combine

/// Metadata is derived from the current session, not from a stream URL or a guessed track name.
struct PlayerDisplayMetadata: Equatable {
    let title: String
    let subtitle: String?

    init(payload: PlayPayload) {
        title = payload.title
        var details: [String] = []
        if let season = payload.season, season > 0 { details.append("Сезон \(season)") }
        if let episode = payload.episode, episode > 0 { details.append("Серия \(episode)") }
        let episodeDescription = details.joined(separator: ", ")
        let studioName = payload.availableStudios?.first(where: { $0.id == payload.currentStudio })?.name
            ?? payload.currentStudioName
        let voice = studioName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = [episodeDescription, voice ?? ""].filter { !$0.isEmpty }
        let fallback = payload.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        subtitle = components.isEmpty ? (fallback?.isEmpty == false ? fallback : nil) : components.joined(separator: " • ")
    }

    func apply(to item: AVPlayerItem) {
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = title as NSString
        var metadata: [AVMetadataItem] = [titleItem]
        if let subtitle {
            let subtitleItem = AVMutableMetadataItem()
            subtitleItem.identifier = .iTunesMetadataTrackSubTitle
            subtitleItem.value = subtitle as NSString
            metadata.append(subtitleItem)
        }
        item.externalMetadata = metadata
    }
}

/// URL alone does not identify the timeline whose progress belongs in watch history.
struct PlaybackItemIdentity: Equatable {
    let url: String
    let canonicalID: String?
    let fallbackHash: String?
    let mediaType: String?
    let season: Int?
    let episode: Int?

    init(payload: PlayPayload) {
        url = payload.url
        canonicalID = payload.canonicalId
        fallbackHash = payload.canonicalId == nil ? payload.hash : nil
        mediaType = payload.mediaType
        season = payload.season
        episode = payload.episode
    }
}

/// Separate from the delegate so its nonisolated deinit can hand off this Sendable
/// main-actor reference without escaping the dying coordinator or relying on UIKit dealloc.
@MainActor
private final class PlayerPlaybackResources {
    let ownerID = UUID()
    let itemSession: PlaybackSessionToken
    let playbackController: PlayerPlaybackController
    var player: AVPlayer?
    var timeObserver: Any?
    var endObserver: Any?
    var stallObserver: Any?
    var statusObserver: NSKeyValueObservation?
#if DEBUG
    var timeControlObserver: NSKeyValueObservation?
#endif
    var detachedController: AVPlayerViewController?
    private(set) var isCleanedUp = false

    init(playbackController: PlayerPlaybackController) {
        self.playbackController = playbackController
        self.itemSession = PlaybackSessionToken()
    }

    func cleanup() {
        guard !isCleanedUp else { return }
        isCleanedUp = true
        itemSession.invalidate()
        DiagnosticsLogManager.shared.log(category: "[Player]",
            message: "Остановка воспроизведения и освобождение AVPlayer", level: .info)
        statusObserver?.invalidate()
        statusObserver = nil
#if DEBUG
        timeControlObserver?.invalidate()
        timeControlObserver = nil
#endif
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
        if let observer = stallObserver {
            NotificationCenter.default.removeObserver(observer)
            stallObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        detachedController?.player = nil
        detachedController = nil
        playbackController.unregister(owner: ownerID)
        playbackController.releaseAudioSession(owner: ownerID)
        playbackController.releasePictureInPicture(owner: ownerID)
    }
}

// Observes the actual presentation window lifecycle. Gestures attached solely
// to AVPlayerViewController.view can lose to AVKit's internal transparent layers.
private final class PlayerWindowAttachmentView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}

// AVPlayerViewController wrapper handling HLS/MP4 playback, PiP, timecodes, metadata, and lifecycle teardown.
@MainActor
struct NativePlayerView: UIViewControllerRepresentable {
    @Binding var payload: PlayPayload
    var onTimeUpdate: (@MainActor (_ time: Double, _ duration: Double, _ hash: String?) -> Void)?
    var onNearEnd: (@MainActor () -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onPlaybackError: (@MainActor (PlaybackDiagnosis) -> Void)?
    var onDismiss: (@MainActor () -> Void)?
    var onControlsInteraction: (@MainActor () -> Void)? = nil

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        controller.requiresLinearPlayback = false
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        // Native AVKit owns gestures and its controls. This recognizer observes
        // touches without cancelling or competing with the system handlers.
        let visibilityTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.notifyControlsInteraction)
        )
        visibilityTap.cancelsTouchesInView = false
        visibilityTap.delegate = context.coordinator
        controller.view.addGestureRecognizer(visibilityTap)

        // AVKit installs transparent video/control layers which may intercept
        // touches before a recognizer attached to controller.view sees them.
        // Apple's public contentOverlayView is the intended interactive
        // overlay surface above the video and below transport controls.
        // Keep touches available to AVKit itself (seek, PiP, pause).
        if let contentOverlay = controller.contentOverlayView {
            let touchSurface = UIView(frame: contentOverlay.bounds)
            touchSurface.backgroundColor = .clear
            touchSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            touchSurface.isUserInteractionEnabled = true
            let contentTap = UITapGestureRecognizer(
                target: context.coordinator, action: #selector(Coordinator.notifyControlsInteraction)
            )
            contentTap.cancelsTouchesInView = false
            contentTap.delaysTouchesBegan = false
            contentTap.delegate = context.coordinator
            touchSurface.addGestureRecognizer(contentTap)
            contentOverlay.addSubview(touchSurface)
        }

        // An invisible lifecycle witness attaches a simultaneous observer to
        // the UIWindow once the player actually becomes visible. UIWindow is an
        // ancestor of AVKit's internal video controls, unlike the SwiftUI layer.
        let windowWitness = PlayerWindowAttachmentView(frame: .zero)
        windowWitness.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        windowWitness.onWindowChange = { [weak coordinator] window in
            coordinator?.attachTouchObserver(to: window)
        }
        controller.view.addSubview(windowWitness)

        guard let videoURL = URL(string: payload.url) else {
            let diag = PlaybackDiagnosis(
                category: .unknown(details: "Некорректный адрес"),
                title: "Некорректная ссылка",
                message: "Адрес видеопотока не является валидным URL.",
                canOpenInExternalPlayer: false,
                primaryActionTitle: "Закрыть",
                isExternalFallbackRecommended: false
            )
            onPlaybackError?(diag)
            return controller
        }

        let assetOptions: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": PlaybackAssetMetadata.headers(for: payload, url: videoURL)]
        let asset = AVURLAsset(url: videoURL, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)

        context.coordinator.playbackController.claimAudioSession(owner: context.coordinator.ownerID)
        do {
            let audioMode: AVAudioSession.Mode = payload.mediaType == "audio" ? .default : .moviePlayback
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: audioMode)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Do not silently claim that audio is configured; AVPlayer may still provide a
            // useful system error, while the diagnostic identifies the audio-session failure.
            DiagnosticsLogManager.shared.log(category: "[Player]",
                message: "Не удалось активировать аудиосеанс: \((error as NSError).domain) code=\((error as NSError).code)",
                level: .error)
        }

        let displayMetadata = PlayerDisplayMetadata(payload: payload)
        displayMetadata.apply(to: playerItem)
        context.coordinator.displayMetadata = displayMetadata

        let player = AVPlayer(playerItem: playerItem)
        controller.player = player

        context.coordinator.player = player
#if DEBUG
        context.coordinator.timeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            print("[PlayerProbe] timeControl=\(player.timeControlStatus.rawValue) rate=\(player.rate) main=\(Thread.isMainThread)")
        }
        // Do not synchronously query currentTime from a media notification. It
        // can acquire MediaToolbox locks while preparation is still in flight.
        // Progress diagnostics already receive time through the periodic observer.
#endif
        context.coordinator.hasTriggeredEnd = false
        context.coordinator.hasTriggeredNearEnd = false

        context.coordinator.register(controller: controller)

        // Diagnostic status observation with structured error classifier
        context.coordinator.observeStatus(of: playerItem)

        var startTime = payload.time ?? 0.0
        if payload.time == nil, let canonicalId = payload.canonicalId,
           let season = payload.season, let episode = payload.episode {
            startTime = WatchHistoryManager.shared.getResumePosition(
                canonicalId: canonicalId, season: season, episode: episode
            ).time
        }
        // An AVPlayerItem may ignore an early seek before it is ready.
        // Save it and apply once the current item becomes readyToPlay.
        context.coordinator.pendingResumeTime = startTime.isFinite && startTime > 0 ? startTime : nil

        context.coordinator.observeProgress(of: playerItem)

        context.coordinator.observeEnd(of: playerItem)
        context.coordinator.observeStall(of: playerItem)

        DiagnosticsLogManager.shared.log(
            category: "[Player]",
            message: "Запуск AVPlayer: «\(payload.title)», diagnostic=\(payload.isDiagnostic)",
            level: .info
        )

        if context.coordinator.pendingResumeTime == nil { player.play() }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        context.coordinator.update(self, controller: uiViewController)
    }

    // Explicit lifecycle teardown: guarantees audio stops immediately when dismissed
    static func dismantleUIViewController(_ uiViewController: AVPlayerViewController, coordinator: Coordinator) {
        print("[NativePlayerView] dismantleUIViewController: stopping playback (pipActive=\(coordinator.isPictureInPictureActive))")
        coordinator.isDismantled = true
        coordinator.attachTouchObserver(to: nil)
        if coordinator.isPictureInPictureActive && !coordinator.isCleanedUp {
            // AVPlayerViewController.delegate is weak; SwiftUI no longer owns this coordinator.
            coordinator.detachedController = uiViewController
            coordinator.playbackController.retainPictureInPicture(coordinator, owner: coordinator.ownerID)
        } else {
            coordinator.cleanup()
            if let player = uiViewController.player {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            uiViewController.player = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var parent: NativePlayerView
        private weak var observedTouchWindow: UIWindow?
        private var windowTapGesture: UITapGestureRecognizer?

        func attachTouchObserver(to window: UIWindow?) {
            guard observedTouchWindow !== window else { return }
            if let previous = windowTapGesture {
                observedTouchWindow?.removeGestureRecognizer(previous)
            }
            observedTouchWindow = window
            windowTapGesture = nil
            guard let window else { return }
            let tap = UITapGestureRecognizer(target: self,
                action: #selector(notifyControlsInteraction))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            windowTapGesture = tap
        }

        @objc func notifyControlsInteraction(_ gesture: UITapGestureRecognizer) {
            parent.onControlsInteraction?()
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
        // Only this immutable, actor-protected reference is readable from nonisolated deinit.
        nonisolated private let resources: PlayerPlaybackResources
        private(set) var currentIdentity: PlaybackItemIdentity
        var ownerID: UUID { resources.ownerID }
        var itemSession: PlaybackSessionToken { resources.itemSession }
        var playbackController: PlayerPlaybackController { resources.playbackController }
        var isCleanedUp: Bool { resources.isCleanedUp }
        // Resource ownership survives the coordinator until explicit/fallback cleanup.
        var player: AVPlayer? {
            get { resources.player }
            set { resources.player = newValue }
        }
        var isDismantled = false
        var detachedController: AVPlayerViewController? {
            get { resources.detachedController }
            set { resources.detachedController = newValue }
        }
        var timeObserver: Any? {
            get { resources.timeObserver }
            set { resources.timeObserver = newValue }
        }
        var endObserver: Any? {
            get { resources.endObserver }
            set { resources.endObserver = newValue }
        }
        var statusObserver: NSKeyValueObservation? {
            get { resources.statusObserver }
            set { resources.statusObserver = newValue }
        }
#if DEBUG
        var timeControlObserver: NSKeyValueObservation? {
            get { resources.timeControlObserver }
            set { resources.timeControlObserver = newValue }
        }
#endif
        var displayMetadata: PlayerDisplayMetadata?
        var hasTriggeredEnd: Bool = false
        var hasTriggeredNearEnd: Bool = false
        var isPictureInPictureActive: Bool = false
        var playbackEvidence = PlaybackProgressEvidence()
        var pendingResumeTime: Double?

        init(_ parent: NativePlayerView, playbackController: PlayerPlaybackController? = nil) {
            self.parent = parent
            self.currentIdentity = PlaybackItemIdentity(payload: parent.payload)
            self.resources = PlayerPlaybackResources(playbackController: playbackController ?? .shared)
        }

        /// Shared by UIViewControllerRepresentable updates and deterministic native tests.
        func update(_ parent: NativePlayerView, controller: AVPlayerViewController) {
            self.parent = parent
            controller.showsPlaybackControls = true
            controller.requiresLinearPlayback = false
            guard !isCleanedUp else { return }
            let payload = parent.payload
            let identity = PlaybackItemIdentity(payload: payload)
            if identity != currentIdentity, let url = URL(string: payload.url) {
                itemSession.renew()
                currentIdentity = identity
                let requestedPosition = payload.time ?? 0
                pendingResumeTime = requestedPosition > 0 && requestedPosition.isFinite
                    ? requestedPosition : nil
                controller.player?.pause()
                hasTriggeredEnd = false
                hasTriggeredNearEnd = false
                playbackEvidence = PlaybackProgressEvidence()
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackAssetMetadata.headers(for: payload, url: url)])
                let item = AVPlayerItem(asset: asset)
                let metadata = PlayerDisplayMetadata(payload: payload)
                metadata.apply(to: item)
                displayMetadata = metadata
                observeEnd(of: item)
                observeStall(of: item)
                controller.player?.replaceCurrentItem(with: item)
                observeStatus(of: item)
                observeProgress(of: item)
                register(controller: controller)
                if pendingResumeTime == nil { controller.player?.play() }
            } else if let item = controller.player?.currentItem {
                let metadata = PlayerDisplayMetadata(payload: payload)
                if metadata != displayMetadata {
                    metadata.apply(to: item)
                    displayMetadata = metadata
                }
            }
        }

        func register(controller: AVPlayerViewController) {
            guard !isCleanedUp, let player else { return }
            playbackController.register(player: player, controller: controller, owner: ownerID) { [weak self] in
                self?.cleanup()
            }
        }

        func acceptsCallback(from item: AVPlayerItem, token: UUID?) -> Bool {
            !isCleanedUp && itemSession.accepts(token) && item === player?.currentItem
                && PlaybackItemIdentity(payload: parent.payload) == currentIdentity
        }

        func observeEnd(of item: AVPlayerItem) {
            if let observer = endObserver { NotificationCenter.default.removeObserver(observer) }
            let token = itemSession.current
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self, weak item] _ in
                // NotificationCenter explicitly targets OperationQueue.main.
                MainActor.assumeIsolated {
                    guard let self, let item else { return }
                    self.handleEnd(of: item, token: token)
                }
            }
        }

        func observeStall(of item: AVPlayerItem) {
            if let observer = resources.stallObserver { NotificationCenter.default.removeObserver(observer) }
            let token = itemSession.current
            resources.stallObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
            ) { [weak self, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self, let item, self.acceptsCallback(from: item, token: token) else { return }
                    let status = item.errorLog()?.events.last?.errorStatusCode ?? 0
                    self.logPlaybackStage("stalled", message: "AVPlayer playback stalled",
                        level: .warning, metadata: ["status": String(status)])
                }
            }
        }

        func handleEnd(of item: AVPlayerItem, token: UUID?) {
            guard acceptsCallback(from: item, token: token), !hasTriggeredEnd else { return }
            hasTriggeredEnd = true
            parent.onEnded?()
        }

        func observeProgress(of item: AVPlayerItem) {
            if let observer = timeObserver {
                player?.removeTimeObserver(observer)
                timeObserver = nil
            }
            guard let player else { return }
            let handler = progressHandler(for: item)
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 2, preferredTimescale: 600), queue: .main) { time in
                MainActor.assumeIsolated { handler(time) }
            }
        }

        func progressHandler(
            for item: AVPlayerItem,
            testedAssetDuration: Double? = nil
        ) -> @MainActor (CMTime) -> Void {
            // Tests may pass the independently loaded asset duration to verify
            // stale callback isolation without depending on simulator audio HAL.
            // Production always uses the current AVPlayerItem duration.
            let token = itemSession.current
            return { [weak self, weak item] time in
                guard let self, let item, self.acceptsCallback(from: item, token: token),
                      let player = self.player else { return }
                let currentTime = CMTimeGetSeconds(time)
                let duration = testedAssetDuration ?? CMTimeGetSeconds(item.duration)
                if self.playbackEvidence.observe(time: currentTime, isPlaying: player.rate > 0) {
                    self.logPlaybackStage("playing", message: "Playback progress observed")
                    if let pluginID = self.parent.payload.pluginId {
                        SourceManager.shared.updateOperationalStatus(sourceKey: pluginID, status: .playbackVerified)
                        PluginCapabilityRegistry.shared.updateOperationalStatus(id: pluginID, status: .playbackVerified)
                    }
                }
                if currentTime.isFinite && duration.isFinite && duration > 0,
                   self.pendingResumeTime == nil {
                    if !self.parent.payload.isDiagnostic,
                       let canonicalId = self.parent.payload.canonicalId,
                       let season = self.parent.payload.season,
                       let episode = self.parent.payload.episode {
                        WatchHistoryManager.shared.saveTimecode(
                            canonicalId: canonicalId, season: season, episode: episode,
                            time: currentTime, duration: duration, title: self.parent.payload.title,
                            studio: self.parent.payload.currentStudio, quality: self.parent.payload.currentQuality
                        )
                    }
                    self.parent.onTimeUpdate?(currentTime, duration, self.parent.payload.hash)
                    // A client callback can synchronously replace/dismiss playback.
                    guard self.acceptsCallback(from: item, token: token) else { return }
                    if !self.parent.payload.isDiagnostic && duration - currentTime <= 20 && !self.hasTriggeredNearEnd {
                        self.hasTriggeredNearEnd = true
                        self.parent.onNearEnd?()
                    }
                }
            }
        }

        func logPlaybackStage(_ stage: String, message: String, level: DiagnosticLogEntry.LogLevel = .info, metadata: [String: String] = [:]) {
            var fields = metadata
            fields["stage"] = stage
            DiagnosticsLogManager.shared.log(category: "[PlaybackStage]", message: message, level: level,
                                             actionId: parent.payload.diagnosticActionId, metadata: fields)
        }

        func observeStatus(of item: AVPlayerItem) {
            statusObserver?.invalidate()
            let token = itemSession.current
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, self.acceptsCallback(from: item, token: token) else { return }
                    let payload = self.parent.payload
                    if item.status == .failed {
                        self.logFailure(item)
                        let diagnosis = PlaybackErrorClassifier.diagnose(url: payload.url, error: item.error, errorLog: item.errorLog())
                        self.parent.onPlaybackError?(diagnosis)
                        guard self.acceptsCallback(from: item, token: token) else { return }
                        if let pluginID = payload.pluginId {
                            SourceManager.shared.updateOperationalStatus(sourceKey: pluginID, status: .connectionFailed)
                            PluginCapabilityRegistry.shared.updateOperationalStatus(id: pluginID, status: .connectionFailed)
                        }
                    } else if item.status == .readyToPlay {
                        self.logPlaybackStage("item_ready", message: "Player item ready")
                        if let position = self.pendingResumeTime, position.isFinite, position > 0 {
                            let target = CMTime(seconds: position, preferredTimescale: 600)
                            self.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
                                [weak self, weak item] finished in
                                Task { @MainActor in
                                    guard let self, let item,
                                          self.acceptsCallback(from: item, token: token) else { return }
                                    self.pendingResumeTime = nil
                                    if finished { self.player?.play() } else {
                                        self.logPlaybackStage("seek_incomplete", message: "Resume seek did not complete", level: .warning)
                                        self.player?.play()
                                    }
                                }
                            }
                        }
                        if let pluginID = payload.pluginId {
                            SourceManager.shared.updateOperationalStatus(sourceKey: pluginID, status: .streamResolved)
                            PluginCapabilityRegistry.shared.updateOperationalStatus(id: pluginID, status: .streamResolved)
                        }
                    }
                }
            }
        }

        /// Do not log error descriptions or URLs: providers may embed credentials in them.
        func logFailure(_ item: AVPlayerItem) {
            let error = item.error as NSError?
            let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
            func safeDomain(_ error: NSError?) -> String {
                guard let domain = error?.domain,
                      [AVFoundationErrorDomain, NSURLErrorDomain, NSOSStatusErrorDomain].contains(domain) else { return "other" }
                return domain
            }
            let status = item.errorLog()?.events.last?.errorStatusCode ?? 0
            DiagnosticsLogManager.shared.log(category: "[Player]", message:
                "AVPlayerItem failed domain=\(safeDomain(error)) code=\(error?.code ?? 0) underlying=\(safeDomain(underlying)) code=\(underlying?.code ?? 0) errorLogStatus=\(status)", level: .error)
            logPlaybackStage("item_failed", message: "Player item failed", level: .error,
                             metadata: ["domain": safeDomain(error), "code": String(error?.code ?? 0),
                                        "underlyingCode": String(underlying?.code ?? 0), "status": String(status)])
        }

        // AVKit's Objective-C delegate entry points are synchronous UI callbacks.
        // Explicit nonisolated witnesses + checked bridges avoid SDK-dependent isolation inference.
        nonisolated func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            MainActor.assumeIsolated {
                let token = itemSession.current
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    MainActor.assumeIsolated {
                        self?.completeDismissal(token: token, cancelled: context.isCancelled)
                    }
                }
            }
        }

        func completeDismissal(token: UUID?, cancelled: Bool) {
            guard !cancelled, !isPictureInPictureActive, itemSession.accepts(token),
                  PlaybackItemIdentity(payload: parent.payload) == currentIdentity,
                  playbackController.isActive(owner: ownerID) else { return }
            cleanup()
            parent.onDismiss?()
        }

        // MARK: - Picture-in-Picture Lifecycle
        nonisolated func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            MainActor.assumeIsolated {
                print("[NativePlayerView] PiP will start")
                isPictureInPictureActive = true
            }
        }

        nonisolated func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            MainActor.assumeIsolated {
                print("[NativePlayerView] PiP did start")
                isPictureInPictureActive = true
            }
        }

        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error) {
            MainActor.assumeIsolated {
                print("[NativePlayerView] PiP failed to start: \(error.localizedDescription)")
                isPictureInPictureActive = false
                if isDismantled { cleanup() }
            }
        }

        nonisolated func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            MainActor.assumeIsolated {
                print("[NativePlayerView] PiP did stop")
                isPictureInPictureActive = false
                if isDismantled { cleanup() }
            }
        }

        nonisolated func playerViewController(_ playerViewController: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            MainActor.assumeIsolated {
                print("[NativePlayerView] PiP restore UI requested")
                completionHandler(!isDismantled)
            }
        }

        deinit {
            // Plain deinit is NOT main-actor isolated, even on an @MainActor NSObject.
            // Capture only the immutable Sendable resource owner, never the dying self.
            // Normal dismissal/dismantle still performs synchronous cleanup first.
            let resources = resources
            Task { @MainActor [resources] in resources.cleanup() }
        }

        func cleanup() {
            attachTouchObserver(to: nil)
            resources.cleanup()
        }
    }
}
