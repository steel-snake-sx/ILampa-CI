import SwiftUI

private struct LegacySettingsGroup: Identifiable {
    let id: String
    let name: String
    var settings: [LegacyPluginSetting]
}

/// Renders only structured, current-document registrations; never interprets plugin HTML.
@MainActor
struct LegacyPluginSettingsSections: View {
    let pluginURL: String
    @ObservedObject private var runtime = LampaHeadlessHost.shared
    @State private var pending: Set<String> = []
    @State private var error: String?
    @State private var changes: [String: Task<Void, Never>] = [:]
    @State private var scope = UUID()
    @State private var isPresented = false

    private var groups: [LegacySettingsGroup] {
        var result: [LegacySettingsGroup] = []
        for setting in runtime.legacySettings where setting.owner == pluginURL {
            if let last = result.indices.last, result[last].settings.last?.component == setting.component {
                result[last].settings.append(setting)
            } else {
                result.append(LegacySettingsGroup(id: setting.id, name: setting.componentName, settings: [setting]))
            }
        }
        return result
    }

    var body: some View {
        ForEach(groups) { group in
            Section(group.name) {
                ForEach(group.settings) { setting in
                    LegacySettingRow(setting: setting, disabled: pending.contains(setting.id)) { value in
                        change(setting, value: value)
                    }
                }
                if let error { Text(error).foregroundColor(.red).font(.caption) }
            }
        }
        .onAppear { isPresented = true }
        .onDisappear { isPresented = false; cancelChanges() }
        .onChange(of: runtime.currentGeneration) { _, _ in cancelChanges() }
        .onChange(of: pluginURL) { _, _ in cancelChanges() }
    }

    private func cancelChanges() {
        scope = UUID()
        changes.values.forEach { $0.cancel() }
        changes.removeAll()
        pending.removeAll()
        error = nil
    }

    private func change(_ setting: LegacyPluginSetting, value: String) {
        guard isPresented, !pending.contains(setting.id) else { return }
        pending.insert(setting.id)
        error = nil
        let requestScope = scope
        changes[setting.id] = Task { @MainActor in
            defer {
                if isPresented && scope == requestScope {
                    pending.remove(setting.id)
                    changes[setting.id] = nil
                }
            }
            do { try await runtime.changeLegacySetting(setting, value: value) }
            catch {
                if isPresented && scope == requestScope && !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

private struct LegacySettingRow: View {
    let setting: LegacyPluginSetting
    let disabled: Bool
    let change: (String) -> Void
    @State private var draft: String
    @State private var toggleValue: Bool
    @State private var selectedValue: String
    @State private var showingChoices = false

    init(setting: LegacyPluginSetting, disabled: Bool, change: @escaping (String) -> Void) {
        self.setting = setting
        self.disabled = disabled
        self.change = change
        _draft = State(initialValue: setting.value)
        _toggleValue = State(initialValue: setting.value == "true")
        _selectedValue = State(initialValue: setting.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch setting.type {
            case "trigger":
                Toggle(setting.name, isOn: Binding(
                    get: { toggleValue },
                    set: { toggleValue = $0; change($0 ? "true" : "false") }
                ))
            case "select":
                // A native confirmation sheet avoids inaccessible AX cell proxies
                // reported by iOS 18's menu-picker presentation, and remains fully
                // operable without changing plugin callback/storage semantics.
                Button {
                    showingChoices = true
                } label: {
                    HStack(spacing: 8) {
                        Text(setting.name)
                        Spacer()
                        Text(setting.options.first(where: { $0.value == selectedValue })?.label ?? selectedValue)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .confirmationDialog(setting.name, isPresented: $showingChoices,
                                    titleVisibility: .visible) {
                    ForEach(setting.options, id: \.value) { option in
                        Button(option.label) {
                            selectedValue = option.value
                            change(option.value)
                        }
                    }
                }
            case "input":
                if !setting.placeholder.isEmpty { Text(setting.name) }
                TextField(setting.placeholder.isEmpty ? setting.name : setting.placeholder, text: $draft)
                    .onSubmit { if draft != setting.value { change(draft) } }
                    .onChange(of: setting.value) { _, value in draft = value }
                    .onChange(of: disabled) { _, busy in if !busy { draft = setting.value } }
            case "title":
                Text(setting.name).font(.headline)
            default:
                EmptyView()
            }
            if !setting.description.isEmpty {
                Text(setting.description).font(.caption).foregroundColor(.secondary)
            }
            if setting.onRender {
                Text("Часть поведения зависит от веб-интерфейса и здесь не поддерживается.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .disabled(disabled)
        .onChange(of: setting.value) { _, value in
            toggleValue = value == "true"
            selectedValue = value
        }
        .onChange(of: disabled) { _, busy in
            if !busy {
                toggleValue = setting.value == "true"
                selectedValue = setting.value
            }
        }
        .accessibilityIdentifier("legacy_setting_\(setting.id)")
    }
}
