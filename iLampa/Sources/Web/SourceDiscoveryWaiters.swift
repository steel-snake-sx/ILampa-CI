import Foundation

/// Independent consumers may await the same search. Every deadline/cancellation
/// owns one ticket, so late cleanup cannot remove a replacement waiter.
@MainActor
final class SourceDiscoveryWaiters<Value> {
    private struct Waiter {
        let deadline: DispatchWorkItem
        let complete: ([Value]) -> Void
    }
    private var requests: [String: [UUID: Waiter]] = [:]

    func insert(requestId: String, ticket: UUID, deadline: DispatchWorkItem,
                complete: @escaping ([Value]) -> Void) {
        requests[requestId, default: [:]][ticket] = Waiter(deadline: deadline, complete: complete)
    }

    func contains(requestId: String) -> Bool { requests[requestId]?.isEmpty == false }

    @discardableResult
    func finish(requestId: String, ticket: UUID, values: [Value]) -> Bool {
        guard let waiter = requests[requestId]?.removeValue(forKey: ticket) else { return false }
        if requests[requestId]?.isEmpty == true { requests.removeValue(forKey: requestId) }
        waiter.deadline.cancel()
        waiter.complete(values)
        return true
    }

    func finish(requestId: String, values: [Value]) {
        let waiters = requests.removeValue(forKey: requestId) ?? [:]
        for waiter in waiters.values { waiter.deadline.cancel(); waiter.complete(values) }
    }

    func cancelAll() {
        let waiters = requests.values.flatMap { $0.values }
        requests.removeAll()
        for waiter in waiters { waiter.deadline.cancel(); waiter.complete([]) }
    }
}
