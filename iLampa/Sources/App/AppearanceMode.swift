import SwiftUI

/// The persisted raw values are shared with existing installations.
enum AppearanceMode: String {
    case system, light, dark

    init(storedValue: String) {
        self = AppearanceMode(rawValue: storedValue) ?? .system
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Exposes the effective SwiftUI environment to UI tests, not to app users.
struct AppearanceTestProbe: View {
    @Environment(\.colorScheme) private var colorScheme
    let identifier: String

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--uitesting") {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(identifier)
                .accessibilityValue(colorScheme == .dark ? "dark" : "light")
                .allowsHitTesting(false)
        }
    }
}
