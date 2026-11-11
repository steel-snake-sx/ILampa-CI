import XCTest
@testable import iLampa

final class PlaybackPresentationStateTests: XCTestCase {
    func testCancelThenNewRequestDuringUIKitDismissalDoesNotLoseNewPlayback() {
        var state = PlaybackPresentationState()
        let first = PlayPayload(url: "https://fixture.invalid/first.mp4")
        let second = PlayPayload(url: "https://fixture.invalid/second.mp4")
        XCTAssertTrue(state.request(first))
        let transition = state.beginDismissal()
        state.cancel()
        XCTAssertFalse(state.request(second), "New request joins the actual in-flight UIKit transition")
        XCTAssertEqual(state.completeDismissal(id: transition), second)
        XCTAssertNil(state.completeDismissal(id: transition), "No duplicate handoff")
    }

    func testCancelWithoutSuccessorDoesNotPresentAndOldCompletionCannotConsumeNewRequest() {
        var state = PlaybackPresentationState()
        XCTAssertTrue(state.request(PlayPayload(url: "https://fixture.invalid/first.mp4")))
        let old = state.beginDismissal()
        state.cancel()
        XCTAssertNil(state.completeDismissal(id: old))
        let next = PlayPayload(url: "https://fixture.invalid/next.mp4")
        XCTAssertTrue(state.request(next))
        let transition = state.beginDismissal()
        XCTAssertNil(state.completeDismissal(id: old))
        XCTAssertEqual(state.completeDismissal(id: transition), next)
    }
}
