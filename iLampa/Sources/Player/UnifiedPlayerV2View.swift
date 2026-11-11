import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Candidate D: one AVPlayerLayer surface and one authoritative SwiftUI controls layer.
/// The production AVPlayerViewController implementation remains available as a fallback.
private final class PlayerV2LayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private struct PlayerV2Surface: UIViewRepresentable {
    let player: AVPlayer
    let onLayer: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerV2LayerView {
        let view = PlayerV2LayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        onLayer(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerV2LayerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

private struct PlayerV2RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.activeTintColor = .white
        view.tintColor = .white
        view.prioritizesVideoDevices = true
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

@MainActor
private final class PlayerV2State: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published var controlsVisible = true
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var isPictureInPictureActive = false
    @Published var errorMessage: String?

    let player = AVPlayer()
    private let owner = UUID()
    private var currentIdentity: PlaybackItemIdentity?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var pipController: AVPictureInPictureController?
    private var hideTask: Task<Void, Never>?
    private var isMounted = false
    private var surfaceVisible = false
    private var nearEndTriggered = false
    private var resumeTime: Double = 0
    private var currentHash: String?
    var onTimeUpdate: ((Double, Double, String?) -> Void)?
    var onNearEnd: (() -> Void)?
    var onEnded: (() -> Void)?
    var onPlaybackError: ((PlaybackDiagnosis) -> Void)?

    func attachLayer(_ layer: AVPlayerLayer) {
        if pipController == nil && AVPictureInPictureController.isPictureInPictureSupported() {
            let controller = AVPictureInPictureController(playerLayer: layer)
            controller.delegate = self
            pipController = controller
        }
    }

    func mount(_ payload: PlayPayload) {
        surfaceVisible = true
        if !isMounted {
            isMounted = true
            PlayerPlaybackController.shared.claimAudioSession(owner: owner)
            PlayerPlaybackController.shared.registerLayer(player: player, owner: owner) { [weak self] in
                self?.teardown()
            }
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                errorMessage = "Не удалось настроить аудиосеанс"
            }
            player.allowsExternalPlayback = true
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                Task { @MainActor [weak self] in self?.observeProgress(time) }
            }
        }
        load(payload)
        showControls()
    }

    func load(_ payload: PlayPayload) {
        let identity = PlaybackItemIdentity(payload: payload)
        guard currentIdentity != identity else { return }
        guard let url = URL(string: payload.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Неверный URL потока"
            return
        }
        currentIdentity = identity
        currentHash = payload.hash
        nearEndTriggered = false
        position = 0
        duration = 0
        errorMessage = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player.pause()

        let headers = PlaybackAssetMetadata.headers(for: payload, url: url)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        PlayerDisplayMetadata(payload: payload).apply(to: item)
        resumeTime = max(0, payload.time ?? 0)
        player.replaceCurrentItem(with: item)
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    if self.resumeTime > 0 {
                        let time = self.resumeTime
                        self.resumeTime = 0
                        self.player.seek(to: CMTime(seconds: time, preferredTimescale: 600)) { [weak self] _ in
                            Task { @MainActor [weak self] in self?.player.play() }
                        }
                    } else { self.player.play() }
                    self.isPlaying = true
                case .failed:
                    self.errorMessage = "Ошибка AVPlayer: \(item.error?.localizedDescription ?? "неизвестная")"
                    self.onPlaybackError?(PlaybackDiagnosis(
                        category: .unknown(details: "Player V2 item failure"),
                        title: "Ошибка воспроизведения",
                        message: self.errorMessage ?? "Ошибка плеера",
                        canOpenInExternalPlayer: true,
                        primaryActionTitle: "Закрыть",
                        isExternalFallbackRecommended: false
                    ))
                default: break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.isPlaying = false
                self.onEnded?()
            }
        }
    }

    private func observeProgress(_ time: CMTime) {
        guard isMounted, let item = player.currentItem else { return }
        let current = CMTimeGetSeconds(time)
        let total = CMTimeGetSeconds(item.duration)
        guard current.isFinite, current >= 0 else { return }
        position = current
        if total.isFinite && total > 0 {
            duration = total
            if !nearEndTriggered && total - current <= 12 && total - current > 0 {
                nearEndTriggered = true
                onNearEnd?()
            }
        }
        isPlaying = player.rate > 0
        onTimeUpdate?(current, duration, currentHash)
    }

    func togglePlay() {
        if player.rate > 0 { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
        showControls()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        showControls()
    }

    func toggleControls() {
        if controlsVisible { hideTask?.cancel(); controlsVisible = false }
        else { showControls() }
    }

    func showControls() {
        hideTask?.cancel()
        controlsVisible = true
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    func startPictureInPicture() {
        guard let pipController, pipController.isPictureInPicturePossible else { return }
        pipController.startPictureInPicture()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = true
        PlayerPlaybackController.shared.retainPictureInPicture(self, owner: owner)
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isPictureInPictureActive = false
        PlayerPlaybackController.shared.releasePictureInPicture(owner: owner)
        if !surfaceVisible { teardown() }
    }

    func surfaceDisappeared() {
        surfaceVisible = false
        if isPictureInPictureActive {
            PlayerPlaybackController.shared.retainPictureInPicture(self, owner: owner)
        } else { teardown() }
    }

    func teardown() {
        guard isMounted else { return }
        isMounted = false
        hideTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        pipController?.delegate = nil
        pipController = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentIdentity = nil
        PlayerPlaybackController.shared.unregister(owner: owner)
        PlayerPlaybackController.shared.releaseAudioSession(owner: owner)
        PlayerPlaybackController.shared.releasePictureInPicture(owner: owner)
    }
}

@MainActor
struct UnifiedPlayerV2View: View {
    @Binding var payload: PlayPayload
    var isResolvingEpisode: Bool
    var onTimeUpdate: ((Double, Double, String?) -> Void)?
    var onNearEnd: (() -> Void)?
    var onEnded: (() -> Void)?
    var onPlaybackError: ((PlaybackDiagnosis) -> Void)?
    var onDismiss: () -> Void
    var onQualitySelected: (QualityOption) -> Void
    var onStudioSelected: (AudioTrackOption) -> Void
    var onEpisodeSelected: (PlaylistItem) -> Void
    var onNextEpisode: () -> Void

    @StateObject private var playback = PlayerV2State()
    @State private var scrub: Double?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerV2Surface(player: playback.player) { layer in playback.attachLayer(layer) }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { playback.toggleControls() }
            if playback.controlsVisible {
                VStack(spacing: 14) {
                    HStack(spacing: 14) {
                        Button(action: onDismiss) { Image(systemName: "xmark.circle.fill") }
                            .accessibilityIdentifier("playerCloseV2")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(payload.title).lineLimit(1).font(.headline)
                            Text(PlayerDisplayMetadata(payload: payload).subtitle ?? "")
                                .lineLimit(1).font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer(minLength: 0)
                        PlayerV2RoutePicker().frame(width: 42, height: 42)
                        if AVPictureInPictureController.isPictureInPictureSupported() {
                            Button { playback.startPictureInPicture() } label: {
                                Image(systemName: "pip.enter")
                            }.accessibilityLabel("Картинка в картинке")
                        }
                        Menu {
                            if let episodes = payload.playlist {
                                ForEach(episodes) { item in
                                    Button(item.title) { onEpisodeSelected(item) }
                                }
                            }
                            if let qualities = payload.availableQualities {
                                ForEach(qualities) { quality in
                                    Button("Качество: " + quality.label) { onQualitySelected(quality) }
                                }
                            }
                            if let studios = payload.availableStudios {
                                ForEach(studios) { studio in
                                    Button("Озвучка: " + studio.name) { onStudioSelected(studio) }
                                }
                            }
                        } label: { Image(systemName: "list.bullet.circle.fill") }
                            .accessibilityLabel("Серии, качество и озвучка")
                    }
                    .font(.system(size: 23))
                    .padding(.top, 40)
                    Spacer()
                    HStack(spacing: 36) {
                        Button { playback.seek(to: playback.position - 10) } label: {
                            Image(systemName: "gobackward.10")
                        }
                        Button { playback.togglePlay() } label: {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 35))
                        }
                        Button { playback.seek(to: playback.position + 10) } label: {
                            Image(systemName: "goforward.10")
                        }
                        if payload.mediaType == "tv" {
                            Button(action: onNextEpisode) { Image(systemName: "forward.end.fill") }
                        }
                    }
                    .font(.system(size: 26))
                    HStack(spacing: 12) {
                        Text(Self.clock(scrub ?? playback.position))
                            .font(.caption.monospacedDigit())
                        Slider(value: Binding(
                            get: { scrub ?? playback.position },
                            set: { scrub = $0 }
                        ), in: 0...max(playback.duration, 1), onEditingChanged: { editing in
                            if !editing {
                                playback.seek(to: scrub ?? playback.position)
                                scrub = nil
                            }
                        })
                        Text(Self.clock(playback.duration)).font(.caption.monospacedDigit())
                    }
                    .padding(.bottom, 35)
                }
                .padding(.horizontal, 16)
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.35))
                .transition(.opacity)
            }
            if isResolvingEpisode {
                ProgressView("Поиск серии…").tint(.white)
                    .padding(16).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            }
            if let error = playback.errorMessage {
                Text(error).foregroundStyle(.white).padding()
                    .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onAppear {
            playback.onTimeUpdate = onTimeUpdate
            playback.onNearEnd = onNearEnd
            playback.onEnded = onEnded
            playback.onPlaybackError = onPlaybackError
            playback.mount(payload)
        }
        .onChange(of: PlaybackItemIdentity(payload: payload)) { _, _ in playback.load(payload) }
        .onDisappear { playback.surfaceDisappeared() }
    }

    private static func clock(_ time: Double) -> String {
        guard time.isFinite else { return "0:00" }
        let value = Int(max(0, time))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
