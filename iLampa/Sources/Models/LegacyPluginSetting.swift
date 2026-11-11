import Foundation

struct LegacyPluginSetting: Codable, Identifiable, Equatable {
    struct Option: Codable, Equatable, Hashable {
        let value: String
        let label: String
    }

    let id: String
    let owner: String
    let generation: Int
    let component: String
    let componentName: String
    let type: String
    let name: String
    let description: String
    let defaultValue: String
    let placeholder: String
    let value: String
    let options: [Option]
    let onRender: Bool
}

/// Owned by the MainActor host. Script messages and evaluation replies share
/// this clock, since their delivery order need not match their JS commit order.
struct LegacySettingsSnapshotClock {
    private var revisions: [String: Int] = [:]

    mutating func accept(owner: String, revision: Int) -> Bool {
        guard revision > (revisions[owner] ?? -1) else { return false }
        revisions[owner] = revision
        return true
    }

    mutating func reset() { revisions.removeAll() }
}

enum LegacySettingsError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Настройка больше недоступна в текущем сеансе."
        case .failed(let message): return "Не удалось изменить настройку: \(message)"
        }
    }
}
