import XCTest
@testable import iLampa

final class LegacySettingsSnapshotClockTests: XCTestCase {
    func testOldReplyCannotOverwriteNewerMessageOrReplayEqualRevision() {
        var clock = LegacySettingsSnapshotClock()
        XCTAssertTrue(clock.accept(owner: "first", revision: 4)) // New JS message.
        XCTAssertFalse(clock.accept(owner: "first", revision: 3)) // Held older eval reply.
        XCTAssertFalse(clock.accept(owner: "first", revision: 4)) // Duplicate message.
        XCTAssertTrue(clock.accept(owner: "other", revision: 1)) // Independent owner.
        XCTAssertTrue(clock.accept(owner: "first", revision: 5))
    }

    func testInvalidationAllowsNewDocumentClockToRestart() {
        var clock = LegacySettingsSnapshotClock()
        XCTAssertTrue(clock.accept(owner: "owner", revision: 100))
        clock.reset()
        XCTAssertTrue(clock.accept(owner: "owner", revision: 1))
        // Old-document messages are rejected by the host's document/generation
        // envelope BEFORE reaching this per-document clock.
        XCTAssertFalse(clock.accept(owner: "owner", revision: 0))
    }
}
