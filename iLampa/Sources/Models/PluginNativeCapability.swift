import Foundation

/// A descriptor is a proposal, not evidence that an arbitrary JS interface can
/// be rendered or invoked natively. It is scoped to an owner and runtime.
struct PluginNativeCapability: Equatable {
    enum Kind: Equatable {
        case mediaDetail
        case setting
        case catalogAction
    }

    enum Contract: Equatable {
        case structuredMetadata
        case booleanSetting
        case choiceSetting
        case nativeCatalogAction
        case javascriptOnly
    }

    let owner: String
    let generation: Int
    let id: String
    let kind: Kind
    let contract: Contract

    /// Callers must independently verify registration, data and callback semantics.
    /// Neither this predicate nor the descriptor grants permission to execute JS.
    func matchesScope(owner: String, generation: Int) -> Bool {
        !self.owner.isEmpty && !id.isEmpty && self.owner == owner && self.generation == generation
    }

    var hasStructuredNativeContract: Bool {
        switch (kind, contract) {
        case (.mediaDetail, .structuredMetadata),
             (.setting, .booleanSetting), (.setting, .choiceSetting),
             (.catalogAction, .nativeCatalogAction):
            return true
        default:
            return false
        }
    }
}

struct PluginMetadataSection: Identifiable, Equatable {
    struct Field: Equatable {
        let label: String
        let value: String
    }
    enum State: String { case loading, ready, unavailable, error }
    let capability: PluginNativeCapability
    let canonicalId: String
    let title: String
    let state: State
    let fields: [Field]
    var id: String { "\(capability.owner.utf8.count):\(capability.owner)\(capability.id)" }

    static func decode(_ body: [String: Any], capability: PluginNativeCapability, canonicalId: String) -> Self? {
        guard let title = body["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 120, let raw = body["state"] as? String, let state = State(rawValue: raw),
              let rows = body["fields"] as? [[String: Any]], rows.count <= 20 else { return nil }
        var fields: [Field] = []
        for row in rows {
            guard let label = row["label"] as? String, let value = row["value"] as? String,
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  label.count <= 120, value.count <= 1000 else { return nil }
            fields.append(Field(label: label, value: value))
        }
        return Self(capability: capability, canonicalId: canonicalId, title: title, state: state, fields: fields)
    }
}
