import SwiftUI

/// An installed record, not a claim that its capabilities are operational.
struct NativePluginCard: View {
    let plugin: LampaPluginRecord
    let statusText: String
    @ObservedObject private var manager = PluginManager.shared
    @State private var showConfirmEnable = false
    @State private var pendingHash: String?
    @State private var isPreparing = false

    private var isSoma: Bool {
        plugin.urlString.lowercased().contains("soma")
    }

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(destination: NativePluginDetailView(pluginID: plugin.id)) {
                HStack(spacing: 12) {
                    Image(systemName: isSoma ? "music.note" : "puzzlepiece.extension")
                        .foregroundColor(isSoma ? .blue : .secondary)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name).font(.body.bold())
                        Text(statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("plugin_info_\(plugin.name)")
            Toggle("Включить \(plugin.name)", isOn: Binding(
                get: { manager.installedPlugins.first(where: { $0.id == plugin.id })?.isEnabled ?? false },
                set: { enabled in
                    guard let current = manager.installedPlugins.first(where: { $0.id == plugin.id }),
                          enabled != current.isEnabled else { return }
                    if enabled && !manager.hasTrustedCachedScript(current) {
                        prepareApproval(for: current)
                    } else {
                        manager.toggle(plugin: current)
                    }
                }
            ))
            .labelsHidden()
            .disabled(isPreparing)
            .fixedSize()
            .accessibilityLabel("Включить \(plugin.name)")
            .accessibilityIdentifier("plugin_list_toggle_\(plugin.name)")
        }
        .alert("Включить плагин «\(plugin.name)»?", isPresented: $showConfirmEnable) {
            Button("Включить") {
                if let hash = pendingHash { _ = manager.approveCachedScript(pluginID: plugin.id, expectedSHA256: hash) }
                pendingHash = nil
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Подтвердите запуск стороннего JavaScript. Если код плагина изменится, приложение запросит разрешение повторно.")
        }
    }

    private func prepareApproval(for plugin: LampaPluginRecord) {
        isPreparing = true
        Task { @MainActor in
            defer { isPreparing = false }
            do {
                let hash = try await manager.prepareScriptForApproval(pluginID: plugin.id)
                guard let current = manager.installedPlugins.first(where: { $0.id == plugin.id }), !current.isEnabled else { return }
                if manager.hasTrustedCachedScript(current) {
                    manager.toggle(plugin: current)
                } else {
                    pendingHash = hash
                    showConfirmEnable = true
                }
            } catch { manager.lastError = error.localizedDescription }
        }
    }
}
