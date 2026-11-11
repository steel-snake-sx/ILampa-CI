import SwiftUI

/// A live view of the installed record and current-session registrations.
@MainActor
struct NativePluginDetailView: View {
    let pluginID: UUID

    @ObservedObject private var manager = PluginManager.shared
    @ObservedObject private var registry = PluginCapabilityRegistry.shared
    @ObservedObject private var runtime = LampaHeadlessHost.shared
    @ObservedObject private var onlineModPref = OnlineModPreferenceManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirmRemove = false
    @State private var showConfirmEnable = false
    @State private var pendingHash: String?
    @State private var isPreparing = false
    @State private var showTechnicalDetails = false
    @State private var showInteractiveLampa = false
    @AppStorage(DeveloperMode.preferenceKey) private var developerModeEnabled = false

    private var plugin: LampaPluginRecord? {
        manager.installedPlugins.first { $0.id == pluginID }
    }

    var body: some View {
        Group {
            if let plugin = plugin {
                details(for: plugin)
            } else {
                Text("Плагин больше не установлен")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(plugin?.name ?? "Сведения о плагине")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func details(for plugin: LampaPluginRecord) -> some View {
        let capabilities = registry.registeredSources.filter { $0.pluginUrl == plugin.urlString }
        let snapshot = PluginRuntimeSnapshot(installed: manager.installedPlugins,
                                             runningPluginURLs: runtime.runningPlugins,
                                             capabilities: registry.registeredSources)
        let isSoma = plugin.urlString.lowercased().contains("soma")
        let isOnlineMod = plugin.urlString.lowercased().contains("online_mod") || plugin.urlString.lowercased().contains("online.js")

        return Form {
            if isSoma {
                Section {
                    Text("Радиостанции открываются в нативном интерфейсе. Доступность потоков зависит от станции и сети.")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                if plugin.isEnabled {
                    Section("ДОСТУПНАЯ ВОЗМОЖНОСТЬ") {
                        NavigationLink {
                            NativeRadioView(embeddedInNavigation: true)
                        } label: {
                            HStack {
                                Label("Радиостанции", systemImage: "music.note")
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("openSomaRadioButton")
                    }
                }
            }

            Section("РАСШИРЕНИЕ") {
                Toggle("Плагин включён", isOn: Binding(
                    get: { self.plugin?.isEnabled ?? false },
                    set: { enabled in
                        guard let current = self.plugin, enabled != current.isEnabled else { return }
                        if enabled && !manager.hasTrustedCachedScript(current) {
                            prepareApproval(for: current)
                        } else {
                            manager.toggle(plugin: current)
                        }
                    }
                ))
                .accessibilityIdentifier("plugin_toggle_\(plugin.name)")
                .disabled(isPreparing)

                LabeledContent("Состояние", value: plugin.lifecycleState.displayLabel)
                LabeledContent("Исполнение", value: snapshot.isExecutedInCurrentGeneration(plugin) ? "Выполнено" : "Не подтверждено")

                if !manager.hasTrustedCachedScript(plugin),
                   let hash = manager.cachedScriptSHA256(for: plugin.urlString) {
                    Button("Подтвердить текущий код") {
                        pendingHash = hash
                        showConfirmEnable = true
                    }
                }
                if plugin.isEnabled && !manager.hasTrustedCachedScript(plugin),
                   manager.cachedScriptSHA256(for: plugin.urlString) == nil {
                    Button("Загрузить код для подтверждения") { prepareApproval(for: plugin) }
                        .disabled(isPreparing)
                }
                if plugin.isEnabled && plugin.automaticRetryBlocked == true {
                    Button("Повторить запуск") { manager.retry(plugin: plugin) }
                }
                if let error = plugin.errorDescription {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }

            if plugin.isEnabled && snapshot.isExecutedInCurrentGeneration(plugin) {
                LegacyPluginSettingsSections(pluginURL: plugin.urlString)
            }

            if plugin.isEnabled {
                Section {
                    Button {
                        showInteractiveLampa = true
                    } label: {
                        Label("Открыть в интерфейсе Lampa", systemImage: "rectangle.on.rectangle")
                    }
                    .accessibilityIdentifier("openPluginInLampa")
                } footer: {
                    Text("Интерактивные JS-плагины выполняют свои действия в Lampa. Их кнопки и меню не появляются автоматически в нативной карточке фильма.")
                }
            }

            if plugin.origin != .bundled {
                Section {
                    Button(role: .destructive) { showConfirmRemove = true } label: {
                        Label("Удалить плагин", systemImage: "trash")
                    }
                    .accessibilityIdentifier("pluginRemoveButton")
                }
            }

            if isOnlineMod {
                Section {
                    Picker("Активная реализация", selection: $onlineModPref.preference) {
                        ForEach(OnlineModOriginPreference.allCases, id: \.self) { pref in
                            Text(pref.displayName).tag(pref)
                        }
                    }
                } header: {
                    Text("ПРИОРИТЕТ ONLINE MOD")
                } footer: {
                    Text("При наличии встроенной и удалённой версий используется выбранная реализация.")
                }
            }

            if DeveloperMode.isEnabled(preference: developerModeEnabled) {
                Section {
                    if capabilities.isEmpty {
                        Text("Нет зарегистрированных возможностей")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(capabilities) { capability in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(capability.name)
                                Text(capability.capability.displayName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusBadge(status: capability.operationalStatus)
                        }
                    }
                } header: {
                    Text("Регистрации этой сессии")
                } footer: {
                    Text("Регистрация не доказывает работоспособность плагина.")
                }
            }

            Section {
                DisclosureGroup("Технические сведения", isExpanded: $showTechnicalDetails) {
                    LabeledContent("URL источника", value: plugin.urlString)
                    LabeledContent("Версия", value: plugin.version)
                    if let author = plugin.author { LabeledContent("Автор", value: author) }
                    if let error = plugin.errorDescription {
                        LabeledContent("Ошибка", value: error).foregroundColor(.red)
                    }
                }
            }
        }
        .sheet(isPresented: $showInteractiveLampa) {
            LampaWebSheetView()
        }
        .alert("Удалить плагин «\(plugin.name)»?", isPresented: $showConfirmRemove) {
            Button("Удалить", role: .destructive) {
                if let current = self.plugin { manager.remove(plugin: current) }
                dismiss()
            }
            Button("Отмена", role: .cancel) { }
        } message: {
            Text("Плагин будет удалён из списка, а его зарегистрированные компоненты — отключены.")
        }
        .confirmationDialog("Разрешить выполнение JavaScript?", isPresented: $showConfirmEnable, titleVisibility: .visible) {
            Button("Подтвердить и включить") {
                if let hash = pendingHash {
                    _ = manager.approveCachedScript(pluginID: plugin.id, expectedSHA256: hash)
                }
                pendingHash = nil
            }
            Button("Отмена", role: .cancel) { pendingHash = nil }
        } message: {
            Text("Код плагина выполнится в WebKit. Если он изменится, подтверждение потребуется повторно.")
        }
    }

    private func prepareApproval(for plugin: LampaPluginRecord) {
        isPreparing = true
        Task { @MainActor in
            defer { isPreparing = false }
            do {
                let hash = try await manager.prepareScriptForApproval(pluginID: plugin.id)
                guard let current = manager.installedPlugins.first(where: { $0.id == plugin.id }) else { return }
                if manager.hasTrustedCachedScript(current) {
                    if current.isEnabled && current.automaticRetryBlocked == true { manager.retry(plugin: current) }
                    else if current.isEnabled { manager.synchronizeRuntime(reason: "trusted script prepared") }
                    else { manager.toggle(plugin: current) }
                } else {
                    pendingHash = hash
                    showConfirmEnable = true
                }
            } catch { manager.lastError = error.localizedDescription }
        }
    }


}

