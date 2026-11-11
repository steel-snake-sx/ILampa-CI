import AVFoundation
import XCTest

/// Compiled unchanged into BOTH the empty control host and the production host.
/// No iLampa import, service, audio lease, or remote stream is used by this file.
@MainActor
final class PlayerStateIntegrationTests: XCTestCase {
    private func errorDescription(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "none" }
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error
        return "\(error.domain) code=\(error.code) description=\(error.localizedDescription) underlying=[\(underlying.map { errorDescription($0) } ?? "none")]"
    }

    func probe(_ url: URL, exercisePlayback: Bool, providedPlayer: AVPlayer? = nil) async throws {
        var lines: [String] = []
        func log(_ message: String) {
            lines.append(message)
            print("[LocalPlayerProbe] \(message)")
        }
        defer {
            let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
            attachment.name = "LocalPlayerProbe"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // This fixture is generated in temporary storage, not copied from the test bundle.
        log("bundle=\(Bundle(for: Self.self).bundleURL.path) url=\(url.absoluteString) fileURL=\(url.isFileURL) readable=\(FileManager.default.isReadableFile(atPath: url.path))")
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            XCTFail("Fixture is not a readable local file"); return
        }
        let file = try AVAudioFile(forReading: url)
        let decoded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
        try file.read(into: decoded)
        XCTAssertGreaterThan(decoded.frameLength, 0, "Fixture must decode real frames, not only expose metadata")
        let session = AVAudioSession.sharedInstance()
        func route(_ stage: String) {
            log("audio route snapshot begin stage=\(stage)")
            log("audio stage=\(stage) category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate) buffer=\(session.ioBufferDuration) outputChannels=\(session.outputNumberOfChannels) outputs=\(session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName):\($0.uid):channels=\($0.channels?.count ?? 0)" })")
        }
        route("before")
        if providedPlayer == nil {
            log("audio activation begin")
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            log("audio activation returned")
        }
        route("active")
        defer {
            if providedPlayer == nil {
                log("audio deactivation begin")
                do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
                catch { XCTFail("Audio deactivation failed: \(errorDescription(error))") }
                log("audio deactivation returned")
                route("inactive")
            }
        }
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let playable = try await asset.load(.isPlayable)
            let tracks = try await asset.load(.tracks)
            log("duration=\(CMTimeGetSeconds(duration)) playable=\(playable) tracks=\(tracks.count)")
            for track in tracks {
                let formats = try await track.load(.formatDescriptions)
                log("track mediaType=\(track.mediaType.rawValue) formats=\(formats)")
            }
            guard playable, CMTimeGetSeconds(duration).isFinite,
                  CMTimeGetSeconds(duration) > 4.5, tracks.contains(where: { $0.mediaType == .audio }) else {
                XCTFail("Asset preparation/metadata validation failed; playback not attempted"); return
            }
        } catch {
            log("asset loading failed: \(errorDescription(error))")
            XCTFail("Asset loading failed; playback not attempted: \(errorDescription(error))"); return
        }

        let player = providedPlayer ?? AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let item = try XCTUnwrap(player.currentItem)
        defer {
            if providedPlayer == nil {
                log("player teardown begin")
                player.pause()
                player.replaceCurrentItem(with: nil)
                log("player teardown returned")
            } else {
                log("player teardown delegated to production owner")
            }
        }
        let ready = expectation(description: "item reaches ready or failed")
        ready.assertForOverFulfill = false
        let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status != .unknown { ready.fulfill() }
        }
        defer { observation.invalidate(); log("readiness observer invalidated") }
        // Match the production startup contract: request playback, then observe
        // asynchronous item readiness. Do not infer readiness from player.status.
        player.play()
        let result = await XCTWaiter().fulfillment(of: [ready], timeout: 15)
        log("readiness wait=\(result.rawValue) itemStatus=\(item.status.rawValue) error=\(errorDescription(item.error)) playerStatus=\(player.status.rawValue) playerError=\(errorDescription(player.error))")
        guard result == .completed, item.status == .readyToPlay else {
            // Range/time/waiting-reason getters can themselves wait on the failed
            // preparation lock. Keep the original failure observable FIRST.
            XCTFail("Item readiness failed or timed out; playback and seek not attempted"); return
        }
        log("ready duration=\(CMTimeGetSeconds(item.duration)) seekableRanges=\(item.seekableTimeRanges)")
        guard exercisePlayback else { return }

        func waitForTime(after seconds: Double) async -> Bool {
            let advanced = expectation(description: "time advances beyond \(seconds)")
            advanced.assertForOverFulfill = false
            let token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { time in
                if CMTimeGetSeconds(time) > seconds { advanced.fulfill() }
            }
            defer { player.removeTimeObserver(token) }
            player.play()
            let result = await XCTWaiter().fulfillment(of: [advanced], timeout: 15)
            log("advance wait=\(result.rawValue)")
            guard result == .completed else { return false }
            log("advance wait=\(result.rawValue) time=\(CMTimeGetSeconds(player.currentTime())) rate=\(player.rate) control=\(player.timeControlStatus.rawValue) reason=\(player.reasonForWaitingToPlay?.rawValue ?? "none") itemStatus=\(item.status.rawValue) error=\(errorDescription(item.error))")
            return true
        }
        guard await waitForTime(after: 0.2) else { XCTFail("Ready item did not advance"); return }
        player.pause()
        XCTAssertEqual(player.rate, 0)
        let pausedTime = CMTimeGetSeconds(player.currentTime())
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(CMTimeGetSeconds(player.currentTime()), pausedTime, accuracy: 0.05,
                       "A paused player must stop its clock, not merely report zero rate")
        let seek = expectation(description: "seek completion")
        var seekFinished = false
        player.seek(to: CMTime(seconds: 4, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            seekFinished = finished
            seek.fulfill()
        }
        let seekResult = await XCTWaiter().fulfillment(of: [seek], timeout: 15)
        log("seek wait=\(seekResult.rawValue) finished=\(seekFinished)")
        guard seekResult == .completed, seekFinished else { XCTFail("Seek failed or timed out"); return }
        XCTAssertEqual(CMTimeGetSeconds(player.currentTime()), 4, accuracy: 0.1)
        guard await waitForTime(after: 4.2) else { XCTFail("Ready item did not resume after seek"); return }
    }

    func testLocalPlayerAdvancesPausesSeeksAndResumes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ilampa-player-\(UUID().uuidString).wav")
        let samples = 8_000 * 8
        var wav = Data()
        func word<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        wav.append(contentsOf: "RIFF".utf8); word(UInt32(36 + samples * 2))
        wav.append(contentsOf: "WAVEfmt ".utf8); word(UInt32(16)); word(UInt16(1))
        word(UInt16(1)); word(UInt32(8_000)); word(UInt32(16_000)); word(UInt16(2)); word(UInt16(16))
        wav.append(contentsOf: "data".utf8); word(UInt32(samples * 2))
        wav.append(Data(repeating: 0, count: samples * 2))
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await probe(url, exercisePlayback: true)
    }

    /// Independently create the media with AVAudioFile, rather than the hand-written WAV header.
    func testIndependentAVAudioFileAndAVPlayer() async throws {
        let url = try makeIndependentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        try await probe(url, exercisePlayback: true)
    }

    func makeIndependentFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ilampa-independent-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let frames: AVAudioFrameCount = 44_100 * 8
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.initialize(repeating: 0, count: Int(frames))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }
}
