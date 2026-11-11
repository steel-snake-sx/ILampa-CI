import XCTest
@testable import iLampa

/// The real controller is the subject; only asynchronous WebKit effects are mocked.
@MainActor
final class RuntimeLifecycleControllerTests: XCTestCase {
    private let alpha = RuntimePlugin(id: "alpha", name: "Alpha")
    private let beta = RuntimePlugin(id: "beta", name: "Beta")

    private enum BoundaryError: Error { case rejected }

    @MainActor
    private final class Boundary: RuntimeExecutionBoundary {
        struct ScriptRequest {
            let plugin: RuntimePlugin
            var continuation: CheckedContinuation<String, Error>?
        }

        struct Evaluation {
            let script: String
            let plugin: RuntimePlugin
            let generation: Int
            var continuation: CheckedContinuation<Void, Error>?
        }

        var loads: [Int] = []
        var scripts: [ScriptRequest] = []
        var evaluations: [Evaluation] = []
        var onEvent: (() -> Void)?

        func loadCore(generation: Int) {
            loads.append(generation)
            onEvent?()
        }

        func script(for plugin: RuntimePlugin) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                scripts.append(ScriptRequest(plugin: plugin, continuation: continuation))
                onEvent?()
            }
        }

        func evaluate(script: String, plugin: RuntimePlugin, generation: Int) async throws {
            try await withCheckedThrowingContinuation { continuation in
                evaluations.append(Evaluation(script: script, plugin: plugin,
                                              generation: generation, continuation: continuation))
                onEvent?()
            }
        }

        func completeScript(_ index: Int, result: Result<String, Error> = .success("plugin script")) {
            guard scripts.indices.contains(index), let continuation = scripts[index].continuation else {
                XCTFail("No pending script at index \(index)")
                return
            }
            scripts[index].continuation = nil
            continuation.resume(with: result)
        }

        func completeEvaluation(_ index: Int, result: Result<Void, Error> = .success(())) {
            guard evaluations.indices.contains(index), let continuation = evaluations[index].continuation else {
                XCTFail("No pending evaluation at index \(index)")
                return
            }
            evaluations[index].continuation = nil
            continuation.resume(with: result)
        }

        func finishPending() {
            for index in scripts.indices where scripts[index].continuation != nil {
                completeScript(index, result: .failure(BoundaryError.rejected))
            }
            for index in evaluations.indices where evaluations[index].continuation != nil {
                completeEvaluation(index, result: .failure(BoundaryError.rejected))
            }
        }
    }

    /// Expectations observe real state/effect transitions; no sleeps or assumed scheduler delays.
    private func waitFor(_ controller: RuntimeLifecycleController, _ boundary: Boundary,
                         description: String = "lifecycle transition",
                         condition: @escaping () -> Bool) async {
        let reached = expectation(description: description)
        var fulfilled = false
        let check = {
            if !fulfilled && condition() {
                fulfilled = true
                reached.fulfill()
            }
        }
        controller.onChange = check
        boundary.onEvent = check
        check()
        await fulfillment(of: [reached], timeout: 3)
        controller.onChange = nil
        boundary.onEvent = nil
    }

    private func cleanUp(_ controller: RuntimeLifecycleController, _ boundary: Boundary) {
        controller.fail(generation: controller.generation, reason: "test cleanup")
        boundary.finishPending()
    }

    func testColdBootRestoresAllEnabledPluginsExactlyOnceOnlyAfterReady() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        var successes: [String] = []
        controller.onPluginResult = { plugin, result in
            if case .success = result { successes.append(plugin.id) }
        }

        controller.configure([beta, alpha, alpha], reason: "cold boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        XCTAssertEqual(controller.desiredPlugins, [alpha, beta])
        XCTAssertEqual(controller.state, .loadingCore)
        XCTAssertTrue(boundary.scripts.isEmpty)
        XCTAssertTrue(boundary.evaluations.isEmpty)
        XCTAssertFalse(controller.acceptsCoreWork(generation: 1))

        controller.navigationFinished(generation: 1)
        XCTAssertEqual(controller.state, .waitingForCoreReady)
        XCTAssertTrue(boundary.scripts.isEmpty)
        controller.coreReady(generation: 1)
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        XCTAssertEqual(boundary.scripts[0].plugin, alpha)
        XCTAssertTrue(controller.acceptsCoreWork(generation: 1))
        XCTAssertTrue(boundary.evaluations.isEmpty)

        boundary.completeScript(0, result: .success("alpha script"))
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        XCTAssertEqual(boundary.evaluations[0].script, "alpha script")
        XCTAssertEqual(boundary.evaluations[0].generation, 1)
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
        boundary.completeEvaluation(0)
        await waitFor(controller, boundary) { boundary.scripts.count == 2 }
        XCTAssertEqual(controller.runningPluginIDs, ["alpha"])
        XCTAssertEqual(boundary.scripts[1].plugin, beta)
        boundary.completeScript(1)
        await waitFor(controller, boundary) { boundary.evaluations.count == 2 }
        boundary.completeEvaluation(1)
        await waitFor(controller, boundary) { controller.state == .ready }

        controller.coreReady(generation: 1)
        controller.navigationFinished(generation: 1)
        controller.configure([alpha, beta], reason: "same intent")
        XCTAssertEqual(controller.runningPluginIDs, ["alpha", "beta"])
        XCTAssertEqual(successes, ["alpha", "beta"])
        XCTAssertEqual(boundary.scripts.count, 2)
        XCTAssertEqual(boundary.loads, [1])
    }

    func testRapidConfigurationCoalescesToLastEnabledSubset() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        controller.configure([alpha, beta], reason: "initial")
        controller.configure([], reason: "disable all")
        controller.configure([beta], reason: "last intent")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        XCTAssertEqual(controller.desiredPlugins, [beta])
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        XCTAssertEqual(boundary.scripts[0].plugin, beta)
        boundary.completeScript(0)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        boundary.completeEvaluation(0)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertEqual(controller.runningPluginIDs, ["beta"])
        XCTAssertEqual(boundary.loads, [1])
    }

    func testConcurrentConfigurationDuringLoadingUsesFinalIntentWithoutReloadingCore() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        controller.configure([], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }

        await withTaskGroup(of: Void.self) { group in
            for plugins in [[alpha], [beta], [], [alpha, beta]] {
                group.addTask { @MainActor in
                    controller.configure(plugins, reason: "concurrent intent")
                }
            }
        }
        // Ordering among concurrent callers is deliberately unspecified; this is the last intent.
        controller.configure([beta], reason: "final intent after concurrent callers")
        controller.navigationFinished(generation: 1)
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        XCTAssertEqual(boundary.scripts[0].plugin, beta)
        boundary.completeScript(0)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        boundary.completeEvaluation(0)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertEqual(controller.desiredPlugins, [beta])
        XCTAssertEqual(controller.runningPluginIDs, ["beta"])
        XCTAssertEqual(boundary.loads, [1])
    }

    func testDisabledPluginPendingScriptCannotEvaluateOrReturnAfterRestart() async throws {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        var results: [String] = []
        controller.onPluginResult = { plugin, _ in results.append(plugin.id) }
        controller.configure([alpha], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }

        let obsoleteRestoration = try XCTUnwrap(controller.restorationOperation)
        controller.configure([], reason: "disable pending plugin")
        XCTAssertFalse(controller.acceptsCoreWork(generation: 1))
        await waitFor(controller, boundary) { boundary.loads == [1, 2] }
        boundary.completeScript(0)
        await obsoleteRestoration.value
        XCTAssertTrue(boundary.evaluations.isEmpty)
        XCTAssertTrue(results.isEmpty)
        controller.coreReady(generation: 1)
        controller.navigationFinished(generation: 1)
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertTrue(boundary.evaluations.isEmpty)
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
        XCTAssertTrue(results.isEmpty)
    }

    func testDisabledPluginCannotPublishComponentSideEffectAfterItsConfigurationIsSuperseded() async throws {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        let sample = RuntimePlugin(id: "bundled://plugins/sample_source_plugin.js", name: "Sample Source")
        controller.configure([sample], reason: "explicit sample install")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        boundary.completeScript(0)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        XCTAssertTrue(controller.acceptsPluginSideEffect(sample.id, generation: 1))

        // This models a toggle arriving while WebKit has an evaluation in flight. JavaScript
        // cannot be unsent, so its registration message must fail the revision/intent gate.
        controller.configure([], reason: "toggle sample disabled")
        XCTAssertFalse(controller.acceptsPluginSideEffect(sample.id, generation: 1))
        await waitFor(controller, boundary) { boundary.loads == [1, 2] }
        boundary.completeEvaluation(0)
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertFalse(controller.acceptsPluginSideEffect(sample.id, generation: 2))
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
    }

    func testOnlyEvaluatingOrSuccessfullyRunPluginsCanPublishSideEffects() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        controller.configure([alpha, beta], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        XCTAssertFalse(controller.acceptsPluginSideEffect(alpha.id, generation: 1), "Fetching is not execution")
        XCTAssertFalse(controller.acceptsPluginSideEffect(beta.id, generation: 1))
        boundary.completeScript(0)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        XCTAssertTrue(controller.acceptsPluginSideEffect(alpha.id, generation: 1), "Synchronous registration must remain supported")
        XCTAssertFalse(controller.acceptsPluginSideEffect(beta.id, generation: 1))
        boundary.completeEvaluation(0, result: .failure(BoundaryError.rejected))
        await waitFor(controller, boundary) { boundary.scripts.count == 2 }
        XCTAssertFalse(controller.acceptsPluginSideEffect(alpha.id, generation: 1), "Late callbacks from failed evaluation must not register")
        boundary.completeScript(1)
        await waitFor(controller, boundary) { boundary.evaluations.count == 2 }
        XCTAssertTrue(controller.acceptsPluginSideEffect(beta.id, generation: 1))
        boundary.completeEvaluation(1)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertTrue(controller.acceptsPluginSideEffect(beta.id, generation: 1))
        XCTAssertFalse(controller.acceptsPluginSideEffect(alpha.id, generation: 1))
    }

    func testStaleEvaluationCannotRestoreDisabledPluginOrReportSuccess() async throws {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        var results: [String] = []
        controller.onPluginResult = { plugin, _ in results.append(plugin.id) }
        controller.configure([alpha], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        boundary.completeScript(0)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }

        let obsoleteRestoration = try XCTUnwrap(controller.restorationOperation)
        controller.configure([beta], reason: "replace enabled subset")
        controller.configure([], reason: "disable all before reconciliation")
        await waitFor(controller, boundary) { boundary.loads == [1, 2] }
        controller.navigationFinished(generation: 1)
        controller.coreReady(generation: 1)
        XCTAssertEqual(controller.state, .loadingCore)
        XCTAssertFalse(controller.acceptsCoreWork(generation: 1))
        boundary.completeEvaluation(0)
        await obsoleteRestoration.value
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
        XCTAssertTrue(results.isEmpty)
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertEqual(boundary.scripts.count, 1)
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(controller.acceptsCoreWork(generation: 2))
    }

    func testObsoleteEvaluationFailureAfterProcessRestartCannotReportPluginFailure() async throws {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        var results: [String] = []
        controller.onPluginResult = { plugin, _ in results.append(plugin.id) }
        controller.configure([alpha], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        boundary.completeScript(0)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        let obsoleteRestoration = try XCTUnwrap(controller.restorationOperation)
        controller.restart(reason: "process terminated", automatic: true)
        boundary.completeEvaluation(0, result: .failure(BoundaryError.rejected))
        await obsoleteRestoration.value
        XCTAssertEqual(boundary.loads, [1, 2])
        XCTAssertEqual(controller.state, .loadingCore)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
        controller.configure([], reason: "disable before recovered runtime is ready")
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertTrue(results.isEmpty)
    }

    func testDisablingRunningPluginRebuildsOnlyEnabledSubsetAndCoalescesRestart() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        controller.configure([alpha, beta], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        for index in 0..<2 {
            await waitFor(controller, boundary) { boundary.scripts.count == index + 1 }
            boundary.completeScript(index)
            await waitFor(controller, boundary) { boundary.evaluations.count == index + 1 }
            boundary.completeEvaluation(index)
        }
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertEqual(controller.runningPluginIDs, ["alpha", "beta"])

        controller.configure([beta], reason: "disable alpha")
        controller.restart(reason: "same-turn restart")
        controller.coreReady(generation: 1)
        XCTAssertFalse(controller.acceptsCoreWork(generation: 1))
        await waitFor(controller, boundary) { boundary.loads == [1, 2] }
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { boundary.scripts.count == 3 }
        XCTAssertEqual(boundary.scripts[2].plugin, beta)
        boundary.completeScript(2)
        await waitFor(controller, boundary) { boundary.evaluations.count == 3 }
        boundary.completeEvaluation(2)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertEqual(controller.runningPluginIDs, ["beta"])
        XCTAssertEqual(boundary.loads, [1, 2])
        XCTAssertEqual(boundary.evaluations.map { $0.plugin.id }, ["alpha", "beta", "beta"])
    }

    func testRepeatedManualRestartsCoalesceWhileLoadingAndWaitingForReady() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        controller.configure([], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.restart(reason: "duplicate during load")
        controller.navigationFinished(generation: 1)
        controller.restart(reason: "duplicate while waiting")
        XCTAssertEqual(boundary.loads, [1])
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { controller.state == .ready }

        controller.restart(reason: "user restart")
        controller.restart(reason: "duplicate user restart")
        controller.navigationFinished(generation: 2)
        controller.restart(reason: "duplicate after navigation")
        XCTAssertEqual(boundary.loads, [1, 2])
        controller.coreReady(generation: 1)
        controller.navigationFinished(generation: 1)
        XCTAssertEqual(controller.state, .waitingForCoreReady)
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { controller.state == .ready }
    }

    func testProcessTerminationRecoveryIsBoundedAndManualRetryResetsBudget() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        controller.configure([], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { controller.state == .ready }

        controller.restart(reason: "process terminated", automatic: true)
        XCTAssertEqual(boundary.loads, [1, 2])
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { controller.state == .ready }
        controller.restart(reason: "process terminated again", automatic: true)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(boundary.loads, [1, 2])
        XCTAssertFalse(controller.acceptsCoreWork(generation: 2))
        controller.restart(reason: "still terminated", automatic: true)
        controller.coreReady(generation: 2)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(boundary.loads, [1, 2])

        controller.restart(reason: "explicit retry")
        XCTAssertEqual(boundary.loads, [1, 2, 3])
        controller.restart(reason: "new process terminated", automatic: true)
        XCTAssertEqual(boundary.loads, [1, 2, 3, 4])
        controller.restart(reason: "new recovery exhausted", automatic: true)
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(boundary.loads, [1, 2, 3, 4])
    }

    func testStaleFailureIsIgnoredAndCurrentFailureInvalidatesPendingEvaluation() async throws {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        var results: [String] = []
        controller.onPluginResult = { plugin, _ in results.append(plugin.id) }
        controller.configure([alpha], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        boundary.completeScript(0)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        let obsoleteRestoration = try XCTUnwrap(controller.restorationOperation)
        controller.fail(generation: 0, reason: "stale navigation failure")
        XCTAssertEqual(controller.state, .restoringPlugins)
        controller.fail(generation: 1, reason: "current navigation failure")
        XCTAssertEqual(controller.state, .failed)
        XCTAssertFalse(controller.acceptsCoreWork(generation: 1))
        boundary.completeEvaluation(0)
        await obsoleteRestoration.value
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
        controller.restart(reason: "recover manually")
        controller.configure([], reason: "disabled before ready")
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(controller.runningPluginIDs.isEmpty)
    }

    func testReentrantAutomaticRestartDuringFirstLoadLoadsOnlyGenerationTwo() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        let loaded = expectation(description: "reentrant generation two loaded")
        var restarted = false
        controller.onChange = {
            if !restarted && controller.generation == 1 && controller.state == .loadingCore {
                restarted = true
                controller.restart(reason: "reentrant process termination", automatic: true)
            }
        }
        boundary.onEvent = { loaded.fulfill() }
        controller.configure([], reason: "boot")
        await fulfillment(of: [loaded], timeout: 3)
        controller.onChange = nil
        boundary.onEvent = nil
        XCTAssertTrue(restarted)
        XCTAssertEqual(controller.generation, 2)
        XCTAssertEqual(controller.state, .loadingCore)
        XCTAssertEqual(boundary.loads, [2], "Superseded generation one must not issue a second load")
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { controller.state == .ready }
    }

    func testReentrantFailureDuringLoadIsNotOverwrittenAndDoesNotLoadCore() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        let failed = expectation(description: "reentrant load failure")
        var injected = false
        controller.onChange = {
            if !injected && controller.generation == 1 && controller.state == .loadingCore {
                injected = true
                controller.fail(generation: 1, reason: "reentrant failure")
                failed.fulfill()
            }
        }
        controller.configure([], reason: "boot")
        await fulfillment(of: [failed], timeout: 3)
        controller.onChange = nil
        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(controller.generation, 1)
        XCTAssertTrue(boundary.loads.isEmpty)
        XCTAssertTrue(boundary.scripts.isEmpty)
    }

    func testReentrantFailureDuringCoreReadyDoesNotCreateRestorationTask() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        controller.configure([alpha], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.onChange = {
            if controller.state == .restoringPlugins {
                controller.fail(generation: 1, reason: "reentrant ready failure")
            }
        }
        controller.coreReady(generation: 1)
        controller.onChange = nil
        XCTAssertEqual(controller.state, .failed)
        XCTAssertNil(controller.restorationOperation)
        XCTAssertTrue(boundary.scripts.isEmpty)
        XCTAssertFalse(controller.acceptsCoreWork(generation: 1))
    }

    func testChangedConfigurationRecoversFromFailedState() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        controller.configure([], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.fail(generation: 1, reason: "navigation failed")
        controller.configure([beta], reason: "new intent after failure")
        await waitFor(controller, boundary) { boundary.loads == [1, 2] }
        controller.coreReady(generation: 2)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        XCTAssertEqual(boundary.scripts[0].plugin, beta)
        boundary.completeScript(0)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        boundary.completeEvaluation(0)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertEqual(controller.runningPluginIDs, ["beta"])
    }

    func testPluginFailuresAreReportedAndDoNotPreventRemainingRestoration() async {
        let boundary = Boundary()
        let controller = RuntimeLifecycleController(boundary: boundary)
        defer { cleanUp(controller, boundary) }
        let gamma = RuntimePlugin(id: "gamma", name: "Gamma")
        var failed: [String] = []
        controller.onPluginResult = { plugin, result in
            if case .failure = result { failed.append(plugin.id) }
        }
        controller.configure([alpha, beta, gamma], reason: "boot")
        await waitFor(controller, boundary) { boundary.loads == [1] }
        controller.coreReady(generation: 1)
        await waitFor(controller, boundary) { boundary.scripts.count == 1 }
        boundary.completeScript(0, result: .failure(BoundaryError.rejected))
        await waitFor(controller, boundary) { boundary.scripts.count == 2 }
        boundary.completeScript(1)
        await waitFor(controller, boundary) { boundary.evaluations.count == 1 }
        boundary.completeEvaluation(0, result: .failure(BoundaryError.rejected))
        await waitFor(controller, boundary) { boundary.scripts.count == 3 }
        boundary.completeScript(2)
        await waitFor(controller, boundary) { boundary.evaluations.count == 2 }
        boundary.completeEvaluation(1)
        await waitFor(controller, boundary) { controller.state == .ready }
        XCTAssertEqual(failed, ["alpha", "beta"])
        XCTAssertEqual(controller.runningPluginIDs, ["gamma"])
        XCTAssertEqual(boundary.evaluations[0].plugin, beta)
    }
}
