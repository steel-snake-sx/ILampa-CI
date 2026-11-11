import XCTest
import AVFoundation
import SwiftUI
import Combine
@testable import iLampa

final class PlaybackIntegrationEvidenceTests: XCTestCase {
    @MainActor
    func testPlaybackActionIDIsNativeOnlyAndFollowsCurrentPayload() async throws {
        let spoofed = UUID()
        let input = Data("""
        {"url":"https://example.test/one.m3u8","diagnosticActionId":"\(spoofed.uuidString)"}
        """.utf8)
        var payload = try JSONDecoder().decode(PlayPayload.self, from: input)
        XCTAssertNil(payload.diagnosticActionId)
        let trusted = UUID()
        payload.diagnosticActionId = trusted
        let encoded = try JSONEncoder().encode(payload)
        XCTAssertNil(try JSONDecoder().decode(PlayPayload.self, from: encoded).diagnosticActionId)

        let coordinator = NativePlayerView.Coordinator(NativePlayerView(payload: .constant(payload)))
        for stage in ["item_ready", "playing", "item_failed"] {
            coordinator.logPlaybackStage(stage, message: "test native stage", level: .error)
        }
        let next = UUID()
        payload.url = "https://example.test/two.m3u8"
        payload.diagnosticActionId = next
        coordinator.parent = NativePlayerView(payload: .constant(payload))
        coordinator.logPlaybackStage("item_ready", message: "test native stage", level: .error)
        let logger = DiagnosticsLogManager.shared
        let published = expectation(description: "native stage logs published")
        let subscription = logger.$entries.sink { entries in
            if entries.filter({ $0.actionId == trusted || $0.actionId == next }).count >= 4 {
                published.fulfill()
            }
        }
        await fulfillment(of: [published], timeout: 3)
        subscription.cancel()
        let entries = logger.entries.filter { $0.actionId == trusted || $0.actionId == next }
        let exported = try DiagnosticsLogManager.safeExportData(entries: entries)
        let rows = try String(decoding: exported, as: UTF8.self).split(separator: "\n").dropFirst().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.compactMap { $0["stage"] as? String }, ["item_ready", "playing", "item_failed", "item_ready"])
        XCTAssertEqual(rows.compactMap { $0["actionId"] as? String }, [trusted.uuidString, trusted.uuidString, trusted.uuidString, next.uuidString])
    }

    func testPlayerDisplayMetadataTracksKnownSessionIdentity() {
        var payload = PlayPayload(url: "https://example.test/one.m3u8", title: "Блич",
                                  subtitle: "Старые сведения", season: 1, episode: 1,
                                  currentStudio: "a", availableStudios: [
                                    AudioTrackOption(id: "a", name: "AniLibria", url: "https://example.test/one.m3u8"),
                                    AudioTrackOption(id: "b", name: "Другая озвучка", url: "https://example.test/two.m3u8")
                                  ])
        let first = PlayerDisplayMetadata(payload: payload)
        XCTAssertEqual(first.title, "Блич")
        XCTAssertEqual(first.subtitle, "Сезон 1, Серия 1 • AniLibria")

        payload.currentStudio = "b"
        payload.episode = 2
        let second = PlayerDisplayMetadata(payload: payload)
        XCTAssertEqual(second.subtitle, "Сезон 1, Серия 2 • Другая озвучка")
        XCTAssertNotEqual(first, second)

        payload.availableStudios = nil
        payload.currentStudioName = "Выбранная озвучка"
        XCTAssertEqual(PlayerDisplayMetadata(payload: payload).subtitle, "Сезон 1, Серия 2 • Выбранная озвучка")
        payload.currentStudioName = nil
        payload.subtitle = nil
        XCTAssertEqual(PlayerDisplayMetadata(payload: payload).subtitle, "Сезон 1, Серия 2")
    }

    func testExternalMetadataCanBeAppliedToReplacementAndUpdatedItem() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/video.m3u8"))
        let item = AVPlayerItem(url: url)
        var payload = PlayPayload(url: url.absoluteString, title: "Фильм", subtitle: "Прямой поток")
        PlayerDisplayMetadata(payload: payload).apply(to: item)
        XCTAssertEqual(item.externalMetadata.first(where: { $0.identifier == .commonIdentifierTitle })?.stringValue, "Фильм")
        XCTAssertEqual(item.externalMetadata.first(where: { $0.identifier == .iTunesMetadataTrackSubTitle })?.stringValue, "Прямой поток")

        payload.title = "Другой фильм"
        payload.subtitle = nil
        let replacement = AVPlayerItem(url: url)
        PlayerDisplayMetadata(payload: payload).apply(to: replacement)
        XCTAssertEqual(replacement.externalMetadata.first(where: { $0.identifier == .commonIdentifierTitle })?.stringValue, "Другой фильм")
        XCTAssertNil(replacement.externalMetadata.first(where: { $0.identifier == .iTunesMetadataTrackSubTitle }))
        PlayerDisplayMetadata(payload: payload).apply(to: item)
        XCTAssertEqual(item.externalMetadata.first(where: { $0.identifier == .commonIdentifierTitle })?.stringValue, "Другой фильм")
        XCTAssertNil(item.externalMetadata.first(where: { $0.identifier == .iTunesMetadataTrackSubTitle }))
    }

    func testReadyOrPausedClockDoesNotVerifyPlayback() {
        var evidence = PlaybackProgressEvidence()
        XCTAssertFalse(evidence.observe(time: .nan, isPlaying: true))
        XCTAssertFalse(evidence.observe(time: 100, isPlaying: false))
        XCTAssertFalse(evidence.observe(time: 100, isPlaying: true))
        XCTAssertFalse(evidence.observe(time: 102, isPlaying: false))
        XCTAssertTrue(evidence.observe(time: 104, isPlaying: true))
        XCTAssertFalse(evidence.observe(time: 106, isPlaying: true), "Publish verified only once per stream")
    }

    func testProviderHeadersTakePrecedenceWithoutChangingSelectedURL() throws {
        let data = Data("""
        {"action":"play","url":"https://cdn.libria.fun/exact.m3u8?token=opaque","title":"Selected",
         "customHeaders":{"referer":"https://provider.example/selected","User-Agent":"RequiredAgent","Authorization":"Bearer test"}}
        """.utf8)
        let payload = try JSONDecoder().decode(PlayPayload.self, from: data)
        let headers = PlaybackAssetMetadata.headers(for: payload, url: try XCTUnwrap(URL(string: payload.url)))
        XCTAssertEqual(headers["referer"], "https://provider.example/selected")
        XCTAssertNil(headers["Referer"])
        XCTAssertEqual(headers["User-Agent"], "RequiredAgent")
        XCTAssertEqual(headers["Authorization"], "Bearer test")
        XCTAssertEqual(payload.url, "https://cdn.libria.fun/exact.m3u8?token=opaque")
    }

    func testTLSPlaybackFailureGivesActionableErrorWithoutTLSBypass() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
                            userInfo: [NSLocalizedDescriptionKey: "secure connection fixture"])
        let diagnosis = PlaybackErrorClassifier.diagnose(url: "https://media.example/stream.m3u8?token=secret", error: error, errorLog: nil)
        XCTAssertEqual(diagnosis.title, "Защищённое соединение недоступно")
        XCTAssertTrue(diagnosis.message.contains("проверка TLS не отключалась"))
        XCTAssertFalse(diagnosis.canOpenInExternalPlayer)
    }
}
