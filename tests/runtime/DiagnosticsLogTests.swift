import Combine
import XCTest
@testable import iLampa

@MainActor
final class DiagnosticsLogTests: XCTestCase {
    func testPrivacySafeSourceFailureCodesExcludeRawBridgeMetadata() throws {
        let entry = DiagnosticLogEntry(
            category: "[CompatibilityUI]",
            message: "Provider UI unavailable: {error=missing-component, token=very-secret}",
            level: .warning
        )
        let output = String(decoding: try DiagnosticsLogManager.safeExportData(entries: [entry]), as: UTF8.self)
        XCTAssertTrue(output.contains(#""reasonCode":"missing_component""#))
        XCTAssertFalse(output.contains("very-secret"))
        XCTAssertFalse(output.contains("Provider UI unavailable"))
    }


    func testUnsafeDiagnosticExportFailsClosed() {
        XCTAssertNil(DiagnosticsLogManager.shared.exportDiagnosticsZip())
    }

    func testAllowlistedExportOmitsUntrustedTextAndKeepsValidatedEvents() throws {
        let entries = [
            DiagnosticLogEntry(category: "[LampaJS]", message: "Bearer secret https://user:pass@example.com/video?token=secret", metadata: ["cookie": "session=secret"]),
            DiagnosticLogEntry(category: "[PlaybackStage]", message: "Authorization: Basic secret", level: .error,
                metadata: ["stage": "item_failed", "code": "-11800", "domain": "AVFoundationErrorDomain", "url": "https://example.com/?token=secret"]),
            DiagnosticLogEntry(category: "[PlaybackStage]", message: "secret", metadata: ["stage": "handoff secret", "code": "123secret"])
        ]
        let data = try DiagnosticsLogManager.safeExportData(entries: entries)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("example.com"))
        XCTAssertFalse(text.contains("cookie"))
        XCTAssertTrue(text.contains("item_failed"))
        XCTAssertTrue(text.contains("-11800"))
        XCTAssertEqual(text.split(separator: "\n").count, 4)
    }

    func testSafeExportCreatesJSONLFile() throws {
        let url = try DiagnosticsLogManager.shared.exportDiagnosticsJSONL()
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"type\":\"build\""))
        XCTAssertEqual(url.pathExtension, "jsonl")
    }

    func testPlaybackCorrelationIsExportedWithoutUntrustedFields() throws {
        let attempt = UUID()
        let discovery = UUID()
        let entries = ["selection", "handoff", "item_ready", "playing"].map { stage in
            DiagnosticLogEntry(category: "[PlaybackStage]", message: "https://secret.example/?token=secret",
                               actionId: attempt, metadata: ["stage": stage, "discoveryId": discovery.uuidString, "url": "https://secret.example/"])
        }
        let data = try DiagnosticsLogManager.safeExportData(entries: entries)
        let rows = try String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.compactMap { $0["stage"] as? String }, ["selection", "handoff", "item_ready", "playing"])
        XCTAssertTrue(rows.allSatisfy { ($0["actionId"] as? String) == attempt.uuidString })
        XCTAssertTrue(rows.allSatisfy { ($0["discoveryId"] as? String) == discovery.uuidString })
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("url"))
    }

    func testPlaybackExportRejectsInvalidDiscoveryIdentifier() throws {
        let entry = DiagnosticLogEntry(category: "[PlaybackStage]", message: "", metadata: ["stage": "discovery", "discoveryId": "https://secret.example"])
        let output = String(decoding: try DiagnosticsLogManager.safeExportData(entries: [entry]), as: UTF8.self)
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("discoveryId"))
    }

    func testBackgroundLoggingPublishesSanitizedEntriesOnMainThread() async {
        let logger = DiagnosticsLogManager.shared
        let marker = UUID().uuidString
        let received = expectation(description: "sanitized background entry")
        var observed: DiagnosticLogEntry?
        let subscription = logger.$entries.sink { entries in
            guard observed == nil, let entry = entries.first(where: { $0.message.contains(marker) }) else { return }
            XCTAssertTrue(Thread.isMainThread)
            observed = entry
            received.fulfill()
        }
        await Task.detached {
            logger.log(category: "[Test]", message: "\(marker) https://library.example/stream?api_key=secret123&X-Plex-Token=secret456", level: .warning)
        }.value
        await fulfillment(of: [received], timeout: 3)
        subscription.cancel()
        XCTAssertFalse(observed?.message.contains("secret123") ?? true)
        XCTAssertFalse(observed?.message.contains("secret456") ?? true)
        XCTAssertTrue(observed?.message.contains("[REDACTED]") ?? false)
        for exported in [logger.exportLogs(), logger.exportJSONL()] {
            XCTAssertTrue(exported.contains(marker), "Export should contain the observed entry")
            XCTAssertFalse(exported.contains("secret123"))
            XCTAssertFalse(exported.contains("secret456"))
            XCTAssertTrue(exported.contains("[REDACTED]"))
        }
    }
}
