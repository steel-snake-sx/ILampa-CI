import XCTest
@testable import iLampa

@MainActor
final class SourceDiscoveryWaitersTests: XCTestCase {
    func testSameRequestHasIndependentWaitersAndCompletesEachExactlyOnce() {
        let waiters = SourceDiscoveryWaiters<Int>()
        let first = UUID(), second = UUID()
        var results: [[Int]] = []
        let firstDeadline = DispatchWorkItem {}, secondDeadline = DispatchWorkItem {}
        waiters.insert(requestId: "search", ticket: first, deadline: firstDeadline) { results.append($0) }
        waiters.insert(requestId: "search", ticket: second, deadline: secondDeadline) { results.append($0) }
        waiters.finish(requestId: "search", values: [42])
        waiters.finish(requestId: "search", values: [99])
        XCTAssertEqual(results, [[42], [42]])
        XCTAssertTrue(firstDeadline.isCancelled)
        XCTAssertTrue(secondDeadline.isCancelled)
        XCTAssertFalse(waiters.contains(requestId: "search"))
    }

    func testCancellationAndOldDeadlineCannotConsumeReplacementOrSibling() {
        let waiters = SourceDiscoveryWaiters<Int>()
        let old = UUID(), sibling = UUID(), replacement = UUID()
        var oldResults: [[Int]] = [], siblingResults: [[Int]] = [], replacementResults: [[Int]] = []
        waiters.insert(requestId: "search", ticket: old, deadline: DispatchWorkItem {}) { oldResults.append($0) }
        waiters.insert(requestId: "search", ticket: sibling, deadline: DispatchWorkItem {}) { siblingResults.append($0) }
        XCTAssertTrue(waiters.finish(requestId: "search", ticket: old, values: []))
        waiters.insert(requestId: "search", ticket: replacement, deadline: DispatchWorkItem {}) { replacementResults.append($0) }
        // Manually release an obsolete timeout; no clock delay or scheduler assumption.
        XCTAssertFalse(waiters.finish(requestId: "search", ticket: old, values: [999]))
        XCTAssertTrue(waiters.contains(requestId: "search"))
        XCTAssertEqual(oldResults, [[]])
        XCTAssertTrue(siblingResults.isEmpty)
        XCTAssertTrue(replacementResults.isEmpty)
        waiters.finish(requestId: "search", values: [7])
        XCTAssertEqual(siblingResults, [[7]])
        XCTAssertEqual(replacementResults, [[7]])
    }

    func testRuntimeInvalidationRevokesEveryRequestAndObsoleteTimeoutIsInert() {
        let waiters = SourceDiscoveryWaiters<Int>()
        let first = UUID(), second = UUID()
        var cancelled = 0
        for (request, ticket) in [("old", first), ("current", second)] {
            waiters.insert(requestId: request, ticket: ticket, deadline: DispatchWorkItem {}) {
                XCTAssertTrue($0.isEmpty); cancelled += 1
            }
        }
        waiters.cancelAll()
        XCTAssertEqual(cancelled, 2)
        XCTAssertFalse(waiters.finish(requestId: "old", ticket: first, values: [1]))
        XCTAssertFalse(waiters.contains(requestId: "current"))
    }
}
