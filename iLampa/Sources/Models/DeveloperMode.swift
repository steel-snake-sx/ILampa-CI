import Foundation

/// Keeps engineering controls out of the normal viewing experience while allowing an
/// explicit, persistent opt-in for support and development work. UI tests opt in through
/// their launch argument so diagnostic coverage does not leak into production navigation.
enum DeveloperMode {
    static let preferenceKey = "developer_mode_enabled"

    static var isForcedForTesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    static func isEnabled(preference: Bool) -> Bool {
        preference || isForcedForTesting
    }
}
