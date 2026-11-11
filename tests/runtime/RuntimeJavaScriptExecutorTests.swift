import XCTest
@testable import iLampa

@MainActor
final class RuntimeJavaScriptExecutorTests: XCTestCase {
    func testDeadlineRevokesTicketAndLateCompletionCannotCompleteReplacement() async throws {
        let submitted = expectation(description: "first submitted")
        let replacementSubmitted = expectation(description: "replacement submitted")
        var callbacks: [(Any?, Error?) -> Void] = []
        let executor = RuntimeJavaScriptExecutor { _, callback in
            callbacks.append(callback)
            if callbacks.count == 1 { submitted.fulfill() } else { replacementSubmitted.fulfill() }
        }
        let first = Task { try await executor.execute(body: "return 1", generation: 1, documentToken: "doc", eligible: { true }) }
        await fulfillment(of: [submitted], timeout: 2)
        let oldID = try XCTUnwrap(executor.inFlightID)
        executor.expire(id: oldID) // Controlled delivery of the real deadline path.
        XCTAssertFalse(executor.authorize(id: oldID, generation: 1, documentToken: "doc"))
        do { _ = try await first.value; XCTFail("Timed-out action succeeded") }
        catch {
            guard let outcome = error as? RuntimeExecutionError, case .deadlineExceeded(false) = outcome else {
                return XCTFail("Wrong timeout outcome: \(error)")
            }
        }
        let replacement = Task { try await executor.execute(body: "return 2", generation: 1, documentToken: "doc", eligible: { true }) }
        await fulfillment(of: [replacementSubmitted], timeout: 2)
        let newID = try XCTUnwrap(executor.inFlightID)
        callbacks[0](1, nil)
        executor.expire(id: oldID)
        XCTAssertEqual(executor.inFlightID, newID)
        XCTAssertTrue(executor.authorize(id: newID, generation: 1, documentToken: "doc"))
        callbacks[1](2, nil)
        let value = try await replacement.value
        XCTAssertEqual(value as? Int, 2)
    }

    func testInvalidationCancelsCurrentAndEveryQueuedOperation() async throws {
        let submitted = expectation(description: "first submitted")
        let queued = expectation(description: "two queued admissions")
        queued.expectedFulfillmentCount = 2
        var callbacks: [(Any?, Error?) -> Void] = []
        let executor = RuntimeJavaScriptExecutor { _, callback in callbacks.append(callback); submitted.fulfill() }
        let first = Task { try await executor.execute(body: "return 1", generation: 1, documentToken: "doc", eligible: { true }) }
        await fulfillment(of: [submitted], timeout: 2)
        func enqueue(_ number: Int) -> Task<Any?, Error> {
            var admitted = false
            return Task { try await executor.execute(body: "return \(number)", generation: 1, documentToken: "doc", eligible: {
                if !admitted { admitted = true; queued.fulfill() }; return true
            }) }
        }
        let second = enqueue(2), third = enqueue(3)
        await fulfillment(of: [queued], timeout: 2)
        XCTAssertEqual(callbacks.count, 1)
        executor.invalidate()
        for operation in [first, second, third] {
            do { _ = try await operation.value; XCTFail("Invalidated operation succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        callbacks[0](1, nil)
        XCTAssertEqual(callbacks.count, 1)
    }

    func testCancellationOfMiddleQueuedActionDoesNotCancelItsSibling() async throws {
        let firstSubmitted = expectation(description: "first submitted")
        let middleAdmitted = expectation(description: "middle admitted")
        let lastAdmitted = expectation(description: "last admitted")
        let lastSubmitted = expectation(description: "last submitted")
        var scripts: [String] = [], callbacks: [(Any?, Error?) -> Void] = []
        let executor = RuntimeJavaScriptExecutor { script, callback in
            scripts.append(script); callbacks.append(callback)
            if scripts.count == 1 { firstSubmitted.fulfill() } else { lastSubmitted.fulfill() }
        }
        let first = Task { try await executor.execute(body: "return 1", generation: 1, documentToken: "doc", eligible: { true }) }
        await fulfillment(of: [firstSubmitted], timeout: 2)
        var middleSeen = false, lastSeen = false
        XCTAssertTrue(executor.authorize(id: try XCTUnwrap(executor.inFlightID), generation: 1, documentToken: "doc"))
        let middle = Task { try await executor.execute(body: "return 2", generation: 1, documentToken: "doc", eligible: {
            if !middleSeen { middleSeen = true; middleAdmitted.fulfill() }; return true
        }) }
        await fulfillment(of: [middleAdmitted], timeout: 2)
        let last = Task { try await executor.execute(body: "return 3", generation: 1, documentToken: "doc", eligible: {
            if !lastSeen { lastSeen = true; lastAdmitted.fulfill() }; return true
        }) }
        await fulfillment(of: [lastAdmitted], timeout: 2)
        middle.cancel()
        do { _ = try await middle.value; XCTFail("Middle action succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        callbacks[0](1, nil)
        await fulfillment(of: [lastSubmitted], timeout: 2)
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts[1].contains("return 3"))
        XCTAssertTrue(executor.authorize(id: try XCTUnwrap(executor.inFlightID), generation: 1, documentToken: "doc"))
        callbacks[1](3, nil)
        let one = try await first.value, three = try await last.value
        XCTAssertEqual(one as? Int, 1); XCTAssertEqual(three as? Int, 3)
    }

    func testCancellationRevokesAtOnceWithoutWaitingForMainActorCleanupTask() async throws {
        let submitted = expectation(description: "submission held")
        var completion: ((Any?, Error?) -> Void)?
        let executor = RuntimeJavaScriptExecutor { _, callback in completion = callback; submitted.fulfill() }
        let action = Task { try await executor.execute(body: "return true", generation: 1, documentToken: "doc", eligible: { true }) }
        await fulfillment(of: [submitted], timeout: 2)
        let id = try XCTUnwrap(executor.inFlightID)
        action.cancel()
        // Deliberately no await/yield: actor cleanup has not had a chance to run.
        XCTAssertFalse(executor.authorize(id: id, generation: 1, documentToken: "doc"))
        completion?(true, nil)
        do { _ = try await action.value; XCTFail("Cancelled action succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testInvalidationRevokesSubmittedTicketAndIgnoresOldCompletion() async throws {
        let submitted = expectation(description: "WebKit submission held")
        var completions: [(Any?, Error?) -> Void] = []
        let executor = RuntimeJavaScriptExecutor { _, callback in
            completions.append(callback)
            submitted.fulfill()
        }
        let action = Task { try await executor.execute(body: "return true", generation: 1,
                                                      documentToken: "doc", eligible: { true }) }
        await fulfillment(of: [submitted], timeout: 2)
        let id = try XCTUnwrap(executor.inFlightID)
        executor.invalidate()
        XCTAssertFalse(executor.authorize(id: id, generation: 1, documentToken: "doc"))
        completions[0](true, nil)
        do { _ = try await action.value; XCTFail("Invalidated action completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(executor.inFlightID)
    }

    func testExecutionEligibilityIsCheckedAtRendezvousAndTicketIsOneUse() async throws {
        let submitted = expectation(description: "submitted")
        var completion: ((Any?, Error?) -> Void)?
        var eligible = true
        let executor = RuntimeJavaScriptExecutor { _, callback in completion = callback; submitted.fulfill() }
        let action = Task { try await executor.execute(body: "return true", generation: 1,
                                                      documentToken: "doc", eligible: { eligible }) }
        await fulfillment(of: [submitted], timeout: 2)
        let id = try XCTUnwrap(executor.inFlightID)
        eligible = false
        XCTAssertFalse(executor.authorize(id: id, generation: 1, documentToken: "doc"))
        eligible = true
        XCTAssertFalse(executor.authorize(id: id, generation: 2, documentToken: "doc"))
        XCTAssertFalse(executor.authorize(id: id, generation: 1, documentToken: "other"))
        XCTAssertTrue(executor.authorize(id: id, generation: 1, documentToken: "doc"))
        XCTAssertFalse(executor.authorize(id: id, generation: 1, documentToken: "doc"))
        completion?(true, nil)
        let result = try await action.value
        XCTAssertEqual(result as? Bool, true)
    }

    func testFIFOAllowsOnlyOneSubmissionAndStartsNextAfterCompletion() async throws {
        let firstSubmitted = expectation(description: "first submitted")
        let secondAdmitted = expectation(description: "second queued")
        let secondSubmitted = expectation(description: "second submitted")
        var completions: [(Any?, Error?) -> Void] = []
        let executor = RuntimeJavaScriptExecutor { _, callback in
            completions.append(callback)
            if completions.count == 1 { firstSubmitted.fulfill() } else { secondSubmitted.fulfill() }
        }
        let first = Task { try await executor.execute(body: "return 1", generation: 1, documentToken: "doc", eligible: { true }) }
        await fulfillment(of: [firstSubmitted], timeout: 2)
        let firstID = try XCTUnwrap(executor.inFlightID)
        XCTAssertTrue(executor.authorize(id: firstID, generation: 1, documentToken: "doc"))
        var admitted = false
        let second = Task { try await executor.execute(body: "return 2", generation: 1, documentToken: "doc", eligible: {
            if !admitted { admitted = true; secondAdmitted.fulfill() }
            return true
        }) }
        await fulfillment(of: [secondAdmitted], timeout: 2)
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(executor.inFlightID, firstID)
        completions[0](1, nil)
        await fulfillment(of: [secondSubmitted], timeout: 2)
        let secondID = try XCTUnwrap(executor.inFlightID)
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertTrue(executor.authorize(id: secondID, generation: 1, documentToken: "doc"))
        completions[1](2, nil)
        let one = try await first.value, two = try await second.value
        XCTAssertEqual(one as? Int, 1); XCTAssertEqual(two as? Int, 2)
    }

    func testReplacementDoesNotDependOnWebKitCallbackOrder() async throws {
        let firstSubmitted = expectation(description: "first submitted")
        let replacementSubmitted = expectation(description: "replacement submitted")
        var completions: [(Any?, Error?) -> Void] = []
        let executor = RuntimeJavaScriptExecutor { _, callback in
            completions.append(callback)
            if completions.count == 1 { firstSubmitted.fulfill() }
            else { replacementSubmitted.fulfill() }
        }
        let first = Task { try await executor.execute(body: "return 1", generation: 1, documentToken: "old", eligible: { true }) }
        await fulfillment(of: [firstSubmitted], timeout: 2)
        executor.invalidate()
        let replacement = Task { try await executor.execute(body: "return 2", generation: 2, documentToken: "new", eligible: { true }) }
        await fulfillment(of: [replacementSubmitted], timeout: 2)
        let replacementID = try XCTUnwrap(executor.inFlightID)
        completions[0](1, nil)
        XCTAssertEqual(executor.inFlightID, replacementID)
        XCTAssertTrue(executor.authorize(id: replacementID, generation: 2, documentToken: "new"))
        completions[1](2, nil)
        let result = try await replacement.value
        XCTAssertEqual(result as? Int, 2)
        do { _ = try await first.value; XCTFail("Old operation restored") } catch { }
    }
}
