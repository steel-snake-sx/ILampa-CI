import Foundation

/// MainActor-owned SwiftUI presentation state. Cancelling a request cannot cancel
/// UIKit's dismissal transition: a newer request must join that transition rather
/// than be stranded behind the cancelled request's presentation identity.
struct PlaybackPresentationState {
    private var pending: PlayPayload?
    private var dismissalID: UUID?

    mutating func request(_ payload: PlayPayload) -> Bool {
        pending = payload
        return dismissalID == nil
    }

    mutating func beginDismissal() -> UUID {
        let id = UUID()
        dismissalID = id
        return id
    }

    mutating func completeDismissal(id: UUID) -> PlayPayload? {
        guard dismissalID == id else { return nil }
        dismissalID = nil
        return takeImmediate()
    }

    mutating func takeImmediate() -> PlayPayload? {
        defer { pending = nil }
        return pending
    }

    mutating func cancel() { pending = nil }
}
