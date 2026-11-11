import SwiftUI
import AVFoundation

@main
struct iLampaApp: App {
    @AppStorage("app_appearance_mode") private var appearanceMode = "system"
    @AppStorage("ilampa_native_recovery_mode") private var nativeRecoveryMode = false

    init() {
        configureAudioSession()
        configureNetworkCache()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--legacy-settings-ui-fixture") {
                    LegacySettingsUITestFixtureView()
                } else if ProcessInfo.processInfo.arguments.contains("--metadata-ui-fixture") {
                    MetadataUITestFixtureView()
                } else if nativeRecoveryMode {
                    NativeRecoveryDiagnosticsView()
                } else {
                    ContentView()
                }
                #else
                if nativeRecoveryMode {
                    NativeRecoveryDiagnosticsView()
                } else {
                    ContentView()
                }
                #endif
            }
            .overlay(alignment: .topLeading) {
                AppearanceTestProbe(identifier: "appearance_root_scheme")
            }
            .preferredColorScheme(AppearanceMode(storedValue: appearanceMode).colorScheme)
        }
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            print("[iLampaApp] Failed to configure audio session: \(error.localizedDescription)")
        }
    }

    private func configureNetworkCache() {
        // Catalog metadata and posters have different hosts and may fail independently on
        // restrictive networks. Keep successful responses available for offline/retry UI;
        // this never supplies media streams or changes provider identity.
        URLCache.shared = URLCache(memoryCapacity: 24 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024,
                                   diskPath: "ilampa-network-cache")
    }
}
