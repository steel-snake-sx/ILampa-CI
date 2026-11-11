import Foundation

/// Correlates user-initiated UI events with subsequent provider requests,
/// JS bridge dispatches, network activity, and player lifecycle transitions.
@MainActor
final class ActionCorrelationTracker: ObservableObject {
    static let shared = ActionCorrelationTracker()

    private(set) var sessionId = UUID()
    @Published private(set) var currentActionId = UUID()
    @Published private(set) var currentActionName = "AppLaunch"

    private init() {}

    /// Starts a new correlated user action and emits a log event.
    @discardableResult
    func startAction(name: String, category: String = "[Action]", metadata: [String: String] = [:]) -> UUID {
        let actionId = UUID()
        self.currentActionId = actionId
        self.currentActionName = name

        var enrichedMeta = metadata
        enrichedMeta["actionId"] = actionId.uuidString
        enrichedMeta["actionName"] = name
        enrichedMeta["sessionId"] = sessionId.uuidString

        DiagnosticsLogManager.shared.log(
            category: category,
            message: "User Action: \(name)",
            level: .info,
            actionId: actionId,
            metadata: enrichedMeta
        )

        return actionId
    }

    /// Resets session correlation (e.g. on clean restart).
    func resetSession() {
        sessionId = UUID()
        startAction(name: "NewSession")
    }
}
