import Foundation
import AVFoundation
import MediaPlayer
import Combine
import SwiftUI

@MainActor
final class RadioPlayerModel: ObservableObject {
    static let shared = RadioPlayerModel()
    
    @Published private(set) var currentStation: RadioStation?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    
    private(set) var player: AVPlayer?
    private(set) var playerItem: AVPlayerItem?
    private var playerItemObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    let session: PlaybackSessionToken
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingInfo: [String: Any]?
    private let playbackController: PlayerPlaybackController
    private let activateAudio: (@MainActor () -> Void)?
    private let publishNowPlaying: @MainActor ([String: Any]?) -> Void
    private let loadArtwork: @MainActor (URL) async -> Data?
    
    init(
        playbackController: PlayerPlaybackController? = nil,
        installRemoteControls: Bool = true,
        activateAudio: (@MainActor () -> Void)? = nil,
        publishNowPlaying: @escaping @MainActor ([String: Any]?) -> Void = { MPNowPlayingInfoCenter.default().nowPlayingInfo = $0 },
        loadArtwork: @escaping @MainActor (URL) async -> Data? = { url in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return data
        }
    ) {
        self.playbackController = playbackController ?? .shared
        self.session = PlaybackSessionToken()
        self.activateAudio = activateAudio
        self.publishNowPlaying = publishNowPlaying
        self.loadArtwork = loadArtwork
        if installRemoteControls { setupRemoteTransportControls() }
    }
    
    private func configureAudioSession() {
        if let activateAudio { activateAudio(); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            DiagnosticsLogManager.shared.log(category: "[Radio]", message: "AVAudioSession error: \(error.localizedDescription)", level: .error)
        }
    }
    
    func play(station: RadioStation, streamURLs: [URL]) {
        guard let url = streamURLs.first else {
            errorMessage = "No stream URL available for \(station.title)"
            return
        }
        
        DiagnosticsLogManager.shared.log(
            category: "[RadioPlayer]",
            message: "Запуск радио-потока для «\(station.title)» url=\(url.absoluteString)",
            level: .info
        )
        
        // Stop existing playback
        stop()
        let token = session.renew()
        playbackController.claimAudioSession(owner: token)
        configureAudioSession()
        
        currentStation = station
        isLoading = true
        isPlaying = false
        errorMessage = nil
        
        let item = AVPlayerItem(url: url)
        playerItem = item
        
        player = AVPlayer(playerItem: item)
        
        // Observe player item status
        playerItemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleItemStatus(item.status, error: item.error, item: item, token: token)
            }
        }
        
        // Observe timeControlStatus for buffering state
        timeControlObserver = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatus(player.timeControlStatus, player: player, token: token)
            }
        }
        
        player?.play()
        updateNowPlaying(station: station)
    }
    
    func stop() {
        let token = session.current
        session.invalidate()
        artworkTask?.cancel()
        artworkTask = nil
        playerItemObserver?.invalidate()
        playerItemObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerItem = nil
        isPlaying = false
        isLoading = false
        clearNowPlaying()
        if let token { playbackController.releaseAudioSession(owner: token) }
    }

    // These are also the delivery boundary for callbacks already queued before stop/replacement.
    func handleItemStatus(_ status: AVPlayerItem.Status, error: Error?, item: AVPlayerItem, token: UUID?) {
        guard session.accepts(token), item === playerItem, let station = currentStation else { return }
        switch status {
        case .readyToPlay:
            isLoading = false
            DiagnosticsLogManager.shared.log(category: "[RadioPlayer]",
                message: "Радио-поток готов к воспроизведению: «\(station.title)»", level: .info)
        case .failed:
            isLoading = false
            isPlaying = false
            let desc = error?.localizedDescription ?? "Playback failed"
            errorMessage = desc
            DiagnosticsLogManager.shared.log(category: "[RadioPlayer]",
                message: "Сбой радио-потока для «\(station.title)»: \(desc)", level: .error)
        default:
            break
        }
    }

    func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus, player: AVPlayer, token: UUID?) {
        guard session.accepts(token), player === self.player, let station = currentStation else { return }
        switch status {
        case .playing:
            isPlaying = true
            isLoading = false
            updateNowPlaying(station: station)
            DiagnosticsLogManager.shared.log(category: "[RadioPlayer]",
                message: "Радио-поток играет: «\(station.title)»", level: .info)
        case .paused:
            isPlaying = false
        case .waitingToPlayAtSpecifiedRate:
            isLoading = true
        @unknown default:
            break
        }
    }
    
    func togglePlayback() {
        guard player != nil else { return }
        if isPlaying {
            player?.pause()
        } else {
            player?.play()
        }
    }
    
    var isCurrentlyPlaying: Bool { isPlaying || isLoading }
    
    private func updateNowPlaying(station: RadioStation) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = station.title
        info[MPMediaItemPropertyArtist] = "SomaFM"
        info[MPMediaItemPropertyAlbumTitle] = station.genreDisplay
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        nowPlayingInfo = info
        publishNowPlaying(info)
        
        // Load artwork asynchronously
        artworkTask?.cancel()
        let token = session.current
        let loader = loadArtwork
        if let imageURL = station.imageURL {
            artworkTask = Task { [weak self] in
                guard let data = await loader(imageURL), !Task.isCancelled else { return }
                self?.applyArtwork(data, stationID: station.id, token: token)
            }
        }
    }

    func applyArtwork(_ data: Data, stationID: String, token: UUID?) {
        guard session.accepts(token), currentStation?.id == stationID,
              let uiImage = UIImage(data: data), var updated = nowPlayingInfo else { return }
        updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: uiImage.size) { _ in uiImage }
        nowPlayingInfo = updated
        publishNowPlaying(updated)
    }
    
    private func clearNowPlaying() {
        nowPlayingInfo = nil
        publishNowPlaying(nil)
        currentStation = nil
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.player?.play() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.player?.pause() }
            return .success
        }
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.stop() }
            return .success
        }
    }
}
