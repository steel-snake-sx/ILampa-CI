import Foundation

struct RuntimePlugin: Equatable {
    let id: String
    let name: String
}

/// All WebKit effects cross this boundary. Tests drive readiness and suspend individual effects.
@MainActor
protocol RuntimeExecutionBoundary: AnyObject {
    func loadCore(generation: Int)
    func script(for plugin: RuntimePlugin) async throws -> String
    func evaluate(script: String, plugin: RuntimePlugin, generation: Int) async throws
}

@MainActor
final class RuntimeLifecycleController {
    enum State: String {
        case idle, loadingCore, waitingForCoreReady, restoringPlugins, ready, restarting, failed
    }

    private weak var boundary: RuntimeExecutionBoundary?
    private(set) var state: State = .idle
    private(set) var generation = 0
    private(set) var desiredPlugins: [RuntimePlugin] = []
    private(set) var runningPluginIDs: [String] = []
    private var evaluatingPluginID: String?
    private var revision = 0
    private var loadedRevision = 0
    private var coreReadyGeneration: Int?
    private var restoration: Task<Void, Never>?
    private var reconciliation: Task<Void, Never>?
    private var automaticRecoveryUsed = false
    private var needsRestart = false
    private var pendingReason = "configuration changed"

    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?
    var onPluginResult: ((RuntimePlugin, Result<Void, Error>) -> Void)?
    var onInvalidate: (() -> Void)?
    // Allows diagnostics/tests to await even a subsequently cancelled generation's operation.
    var restorationOperation: Task<Void, Never>? { restoration }

    init(boundary: RuntimeExecutionBoundary) { self.boundary = boundary }

    func configure(_ plugins: [RuntimePlugin], reason: String) {
        // Canonical order also makes concurrent callers converge on the same final configuration.
        let unique = Dictionary(plugins.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let next = unique.values.sorted { $0.id < $1.id }
        guard next != desiredPlugins || state == .idle else { return }
        desiredPlugins = next
        revision += 1
        pendingReason = reason
        if state == .restoringPlugins || state == .ready {
            needsRestart = true
            restoration?.cancel()
            evaluatingPluginID = nil
            state = .restarting
            onInvalidate?()
            onChange?()
        }
        scheduleReconciliation()
    }

    private func scheduleReconciliation() {
        guard reconciliation == nil else { return }
        reconciliation = Task { [weak self] in
            await Task.yield() // Batch same-turn intent changes; not a timing/readiness heuristic.
            guard let self, !Task.isCancelled else { return }
            self.reconciliation = nil
            if self.state == .idle || self.state == .failed || self.needsRestart {
                self.needsRestart = false
                self.beginGeneration(reason: self.pendingReason)
            }
        }
    }

    func restart(reason: String, automatic: Bool = false) {
        if automatic {
            guard !automaticRecoveryUsed else {
                fail(generation: generation, reason: "WebKit terminated again; automatic recovery exhausted")
                return
            }
            automaticRecoveryUsed = true
        } else {
            automaticRecoveryUsed = false
            if state == .loadingCore || state == .waitingForCoreReady || state == .restarting {
                onLog?("Coalesced restart reason=\(reason) generation=\(generation)")
                return
            }
        }
        reconciliation?.cancel()
        reconciliation = nil
        needsRestart = false
        beginGeneration(reason: reason)
    }

    private func beginGeneration(reason: String) {
        restoration?.cancel()
        restoration = nil
        generation += 1
        let loadingGeneration = generation
        coreReadyGeneration = nil
        runningPluginIDs = []
        evaluatingPluginID = nil
        state = .loadingCore
        onInvalidate?()
        guard generation == loadingGeneration, state == .loadingCore else { return }
        onLog?("Runtime load reason=\(reason) generation=\(loadingGeneration) desired=\(desiredPlugins.count)")
        guard generation == loadingGeneration, state == .loadingCore else { return }
        onChange?()
        guard generation == loadingGeneration, state == .loadingCore else { return }
        boundary?.loadCore(generation: loadingGeneration)
    }

    func navigationFinished(generation: Int) {
        guard generation == self.generation, state == .loadingCore else { return }
        state = .waitingForCoreReady
        onChange?()
    }

    func coreReady(generation: Int) {
        guard generation == self.generation,
              state == .loadingCore || state == .waitingForCoreReady,
              coreReadyGeneration != generation, !needsRestart else { return }
        coreReadyGeneration = generation
        loadedRevision = revision
        let restoringRevision = revision
        let plugins = desiredPlugins
        state = .restoringPlugins
        onChange?()
        guard self.generation == generation, self.revision == restoringRevision, state == .restoringPlugins else { return }
        restoration = Task { [weak self] in
            guard let self else { return }
            for plugin in plugins {
                guard self.canRestore(generation, revision: restoringRevision), let boundary = self.boundary else { return }
                do {
                    let script = try await boundary.script(for: plugin)
                    guard self.canRestore(generation, revision: restoringRevision) else { return }
                    self.evaluatingPluginID = plugin.id
                    try await boundary.evaluate(script: script, plugin: plugin, generation: generation)
                    guard self.canRestore(generation, revision: restoringRevision) else { return }
                    self.runningPluginIDs.append(plugin.id)
                    self.evaluatingPluginID = nil
                    self.onPluginResult?(plugin, .success(()))
                } catch {
                    guard self.canRestore(generation, revision: restoringRevision) else { return }
                    self.evaluatingPluginID = nil
                    self.onPluginResult?(plugin, .failure(error))
                }
            }
            guard self.canRestore(generation, revision: restoringRevision) else { return }
            self.state = .ready
            self.restoration = nil
            self.onChange?()
        }
    }

    private func canRestore(_ generation: Int, revision: Int) -> Bool {
        !Task.isCancelled && self.generation == generation && self.revision == revision && state == .restoringPlugins
    }

    func acceptsCoreWork(generation: Int) -> Bool {
        self.generation == generation && coreReadyGeneration == generation && loadedRevision == revision &&
            (state == .restoringPlugins || state == .ready)
    }

    /// Plugin scripts can synchronously register components while restoration is in progress.
    /// Reject a registration as soon as a newer desired configuration supersedes that execution.
    func acceptsPluginSideEffect(_ pluginID: String, generation: Int) -> Bool {
        acceptsCoreWork(generation: generation) && desiredPlugins.contains(where: { $0.id == pluginID }) &&
            (evaluatingPluginID == pluginID || runningPluginIDs.contains(pluginID))
    }

    func fail(generation: Int, reason: String) {
        guard self.generation == generation else { return }
        restoration?.cancel()
        restoration = nil
        reconciliation?.cancel()
        reconciliation = nil
        needsRestart = false
        coreReadyGeneration = nil
        runningPluginIDs = []
        evaluatingPluginID = nil
        state = .failed
        onInvalidate?()
        onLog?("Runtime failed reason=\(reason) generation=\(generation)")
        onChange?()
    }
}
