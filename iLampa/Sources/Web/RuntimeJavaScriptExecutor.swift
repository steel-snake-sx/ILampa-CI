import Foundation

/// Cancellation handlers are not actor-isolated. Only this tiny flag is locked;
/// neither WebKit nor user code ever runs under its lock.
private final class RuntimeExecutionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

enum RuntimeExecutionError: LocalizedError {
    case invalidatedAfterStart
    case deadlineExceeded(executionStarted: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidatedAfterStart:
            return "Сеанс изменился после начала действия. Уже выполненные изменения не отменены."
        case .deadlineExceeded(let started):
            return started ? "WebKit не подтвердил завершение начатого действия. Изменения могли сохраниться."
                : "WebKit не начал действие до истечения срока ожидания."
        }
    }
}

/// FIFO native-mediated transactions. A synchronous WKUIDelegate prompt is the
/// execution rendezvous, NOT an alert: the delegate answers immediately and never
/// calls back into WebKit. Consuming a ticket is the transaction's linearization
/// point. No actor/lock is held while third-party JavaScript runs.
@MainActor
final class RuntimeJavaScriptExecutor {
    static let prompt = "__ilampa_execute_v1__"
    typealias Evaluation = (String, @escaping (Any?, Error?) -> Void) -> Void

    private final class Operation {
        let id: String
        let generation: Int
        let documentToken: String
        let body: String
        let eligible: () -> Bool
        let cancellation: RuntimeExecutionCancellation
        var continuation: CheckedContinuation<Any?, Error>?
        var started = false
        var deadline: Task<Void, Never>?

        init(id: String, generation: Int, documentToken: String, body: String,
             eligible: @escaping () -> Bool, cancellation: RuntimeExecutionCancellation,
             continuation: CheckedContinuation<Any?, Error>) {
            self.id = id; self.generation = generation; self.documentToken = documentToken
            self.body = body; self.eligible = eligible; self.continuation = continuation
            self.cancellation = cancellation
        }
    }

    private let evaluate: Evaluation
    private let timeoutNanoseconds: UInt64
    private var queue: [Operation] = []
    private var current: Operation?
    var inFlightID: String? { current?.id }

    init(timeoutNanoseconds: UInt64 = 15_000_000_000, evaluate: @escaping Evaluation) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.evaluate = evaluate
    }

    func execute(body: String, generation: Int, documentToken: String,
                 eligible: @escaping () -> Bool) async throws -> Any? {
        let id = UUID().uuidString
        let cancellation = RuntimeExecutionCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            guard eligible() else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in
                queue.append(Operation(id: id, generation: generation, documentToken: documentToken,
                                       body: body, eligible: eligible, cancellation: cancellation, continuation: continuation))
                pump()
            }
        }, onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        })
    }

    /// Called only by the synchronous main-frame WKUIDelegate rendezvous.
    /// Authorization and lifecycle invalidation are ordered on the same actor.
    func authorize(id: String, generation: Int, documentToken: String) -> Bool {
        guard let op = current, op.id == id, !op.started, op.continuation != nil,
              op.generation == generation, op.documentToken == documentToken,
              op.eligible(), !op.cancellation.isCancelled else { return false }
        op.started = true
        return true
    }

    func invalidate() {
        let obsolete = queue + (current.map { [$0] } ?? [])
        queue.removeAll()
        current = nil
        for op in obsolete {
            op.deadline?.cancel()
            op.continuation?.resume(throwing: invalidationError(op))
            op.continuation = nil
        }
    }

    private func cancel(id: String) {
        if let op = current, op.id == id {
            // Do not overlap a subsequent transaction with a still-running JS turn.
            op.continuation?.resume(throwing: invalidationError(op))
            op.continuation = nil
        } else if let index = queue.firstIndex(where: { $0.id == id }) {
            let op = queue.remove(at: index)
            op.continuation?.resume(throwing: CancellationError())
            op.continuation = nil
        }
    }

    private func invalidationError(_ op: Operation) -> Error {
        op.started ? RuntimeExecutionError.invalidatedAfterStart : CancellationError()
    }

    /// Deadline delivery is keyed too; an old deadline cannot expire a replacement.
    func expire(id: String) {
        guard let op = current, op.id == id else { return }
        finish(op, result: .failure(RuntimeExecutionError.deadlineExceeded(executionStarted: op.started)))
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let op = queue.removeFirst()
        current = op
        guard !op.cancellation.isCancelled, op.eligible(), let data = try? JSONSerialization.data(withJSONObject:
            ["id": op.id, "generation": op.generation, "documentToken": op.documentToken]),
              let ticket = String(data: data, encoding: .utf8) else {
            finish(op, result: .failure(CancellationError()))
            return
        }
        op.deadline = Task { [weak self, weak op] in
            do { try await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0) } catch { return }
            guard let self, let op else { return }
            self.expire(id: op.id)
        }
        evaluate("window.LampaNativeBridge.executeNativeAction(\(ticket), function() {\n\(op.body)\n});") { [weak self, weak op] value, error in
            guard let self, let op else { return }
            self.finish(op, result: error.map { .failure($0) } ?? .success(value))
        }
    }

    private func finish(_ op: Operation, result: Result<Any?, Error>) {
        guard current === op else { return } // Obsolete WebKit/process callback.
        current = nil
        op.deadline?.cancel()
        op.continuation?.resume(with: op.cancellation.isCancelled ? .failure(invalidationError(op)) : result)
        op.continuation = nil
        pump()
    }
}
