import AVFoundation
@testable import iLampa

/// Direct AVPlayer tests bypass NativePlayerView's audio-session setup. Give
/// them the same activation prerequisite and ownership as the shipped player.
@MainActor
enum LocalPlaybackTestSession {
    static func activate() throws -> UUID {
        let owner = UUID()
        PlayerPlaybackController.shared.claimAudioSession(owner: owner)
        do {
            let session = AVAudioSession.sharedInstance()
            print("[LocalPlayerProbe] owned audio activation begin")
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            print("[LocalPlayerProbe] owned audio activation returned category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate) outputs=\(session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName):\($0.uid)" })")
            return owner
        } catch {
            PlayerPlaybackController.shared.releaseAudioSession(owner: owner)
            throw error
        }
    }

    static func release(_ owner: UUID) {
        print("[LocalPlayerProbe] owned audio release begin")
        PlayerPlaybackController.shared.releaseAudioSession(owner: owner)
        print("[LocalPlayerProbe] owned audio release returned")
    }
}
