import SwiftUI

// Pure native extensions and source provider manager with functional plugin installation lifecycle,
// live WebKit JavaScript runtime execution, and observable capability registry.
// TorrServer is managed exclusively in Sources Manager.
struct ExtensionsView: View {
    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var sourceManager = SourceManager.shared
    @StateObject private var registry = PluginCapabilityRegistry.shared
    @StateObject private var runtime = LampaHeadlessHost.shared

    @AppStorage(DeveloperMode.preferenceKey) private var developerModeEnabled = false

    @State private var searchText = ""
    @State private var newPluginUrl = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    // Modals & Safety Gate
    @State private var showBatchImport = false
    @State private var showCollisionsSheet = false
    @State private var showLampaWebSheet = false
    @State private var showSinglePluginApproval = false
    @State private var showAddPluginSheet = false
    @State private var pendingPluginUrl = ""
    @State private var pendingCuratedPlugin: CuratedPlugin? = nil

    private var runtimeSnapshot: PluginRuntimeSnapshot {
        PluginRuntimeSnapshot(installed: pluginManager.installedPlugins,
                              runningPluginURLs: runtime.runningPlugins,
                              capabilities: registry.registeredSources)
    }

    private var filteredPlugins: [LampaPluginRecord] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return pluginManager.installedPlugins
        }
        let query = trimmed.lowercased()
        return pluginManager.installedPlugins.filter {
            $0.name.lowercased().contains(query) ||
            $0.urlString.lowercased().contains(query) ||
            ($0.author?.lowercased().contains(query) ?? false)
        }
    }

    private func capabilities(for plugin: LampaPluginRecord) -> [PluginRegisteredSource] {
        registry.registeredSources.filter { $0.pluginUrl == plugin.urlString }
    }

    private func statusText(for plugin: LampaPluginRecord) -> String {
        if !plugin.isEnabled { return "Отключен" }
        if plugin.automaticRetryBlocked == true { return "Автоповтор остановлен" }
        if runtimeSnapshot.isExecutedInCurrentGeneration(plugin) { return "Выполнен в текущей сессии" }
        if let error = plugin.errorDescription { return "Сбой: \(error)" }
        return plugin.lifecycleState == .loading ? "Инициализация…" : "Ожидает готовности среды"
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Truthful runtime state
                Section {
                    LabeledContent("Установлено", value: "\(runtimeSnapshot.installedCount)")
                    LabeledContent("Включено", value: "\(runtimeSnapshot.desiredEnabledCount)")
                    LabeledContent("Выполнено сейчас", value: "\(runtimeSnapshot.executedCurrentGenerationCount)")
                    LabeledContent("Зарегистрировано сейчас", value: "\(runtimeSnapshot.registeredActiveCapabilityCount)")
                    if runtimeSnapshot.failedOrBlockedCount > 0 {
                        LabeledContent("Требует внимания", value: "\(runtimeSnapshot.failedOrBlockedCount)")
                            .foregroundColor(.orange)
                    }
                } header: {
                    Label("Состояние среды плагинов", systemImage: "chart.bar")
                } footer: {
                    Text("«Выполнено сейчас» означает успешный запуск в текущей сессии WebKit. Регистрация компонента сама по себе не подтверждает воспроизведение.")
                        .font(.caption)
                }

                // MARK: - Registered capabilities owned by current generation
                if !registry.registeredSources.isEmpty || !registry.activeHooks.isEmpty {
                    Section {
                        ForEach(registry.registeredSources) { src in
                            HStack {
                                Image(systemName: src.capability.iconName)
                                    .foregroundColor(runtimeSnapshot.isCapabilityActive(src) ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(src.name)
                                        .font(.subheadline.bold())
                                    Text(src.capability.displayName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let desc = src.description {
                                        Text(desc)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Text(runtimeSnapshot.isCapabilityActive(src) ? "Текущая сессия" : "Не выполнен сейчас")
                                    .font(.caption.bold())
                                    .foregroundColor(runtimeSnapshot.isCapabilityActive(src) ? .green : .secondary)
                            }
                            .accessibilityIdentifier("activeCapability_\(src.id)")
                        }
                    } header: {
                        Label("Зарегистрированные возможности (\(registry.registeredSources.count))", systemImage: "sparkles")
                    } footer: {
                        Text("Возможности, заявленные плагинами в рантайме. Провайдеры видео автоматически отображаются в разделе «Источники».")
                            .font(.caption)
                    }
                }

                // MARK: - Installed Plugins
                Section {
                    if filteredPlugins.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text(pluginManager.installedPlugins.isEmpty ? "Нет установленных плагинов" : "Плагины не найдены")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8)
                            Spacer()
                        }
                    } else {
                        ForEach(filteredPlugins) { plugin in
                            NativePluginCard(
                                plugin: plugin,
                                statusText: statusText(for: plugin)
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    pluginManager.remove(plugin: plugin)
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }

                    // Add Custom Plugin inline input
                    HStack {
                        TextField("URL плагина (https://...)", text: $newPluginUrl)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.subheadline)

                        Button("Добавить") {
                            requestCustomPluginApproval()
                        }
                        .disabled(newPluginUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("addPluginButton")
                    }
                } header: {
                    Label("Установленные плагины (\(filteredPlugins.count))", systemImage: "puzzlepiece.extension.fill")
                }

                // MARK: - Curated Extensions Directory
                Section {
                    ForEach(pluginManager.curatedPlugins) { plugin in
                        HStack(spacing: 12) {
                            Image(systemName: plugin.iconName)
                                .font(.title3)
                                .foregroundColor(.blue)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.name)
                                    .font(.body)
                                Text(plugin.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if pluginManager.isInstalled(url: plugin.url) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.green)
                                    .accessibilityIdentifier("installed_\(plugin.name)")
                            } else if pluginManager.isInstalling(url: plugin.url) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button("Установить") {
                                    requestCuratedPluginApproval(plugin)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("install_\(plugin.name)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Label("Каталог плагинов", systemImage: "square.grid.2x2")
                } footer: {
                    Text("Установка загружает сторонний JavaScript в изолированную среду WebKit. Исполнение плагина не означает, что он является источником видео.")
                        .font(.caption)
                }
            }
            .searchable(text: $searchText, prompt: "Поиск по названию или ссылке")
            .navigationTitle("Плагины")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Button {
                            showBatchImport = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityIdentifier("addBatchToolbarButton")

                        if DeveloperMode.isEnabled(preference: developerModeEnabled) {
                            Button {
                                showLampaWebSheet = true
                            } label: {
                                Image(systemName: "safari")
                            }
                            .accessibilityIdentifier("openLampaSheetToolbarButton")
                        }

                        Menu {
                            Button {
                                showBatchImport = true
                            } label: {
                                Label("Пакетный импорт ссылок", systemImage: "doc.on.clipboard")
                            }

                            Button {
                                showCollisionsSheet = true
                            } label: {
                                Label("Конфликты плагинов", systemImage: "exclamationmark.shield")
                            }
                            .accessibilityIdentifier("openCollisionsButton")

                            if DeveloperMode.isEnabled(preference: developerModeEnabled) {
                                Button {
                                    showLampaWebSheet = true
                                } label: {
                                    Label("Открыть веб-интерфейс Lampa", systemImage: "safari")
                                }
                            }

                            Divider()

                            Button {
                                pluginManager.bulkToggleAll(enabled: true)
                            } label: {
                                Label("Включить все плагины", systemImage: "checkmark.circle")
                            }

                            Button {
                                pluginManager.bulkToggleAll(enabled: false)
                            } label: {
                                Label("Отключить все плагины", systemImage: "xmark.circle")
                            }

                            Divider()

                            Button(role: .destructive) {
                                pluginManager.resetToDefaults()
                            } label: {
                                Label("Сбросить к исходным", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityIdentifier("extensionsMenuButton")
                    }
                }
            }
            .sheet(isPresented: $showBatchImport) {
                BatchImportModalView()
            }
            .sheet(isPresented: $showCollisionsSheet) {
                NavigationStack {
                    PluginCollisionsView(reports: PluginCollisionPolicy.resolveCollisions(in: pluginManager.installedPlugins))
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Закрыть") {
                                    showCollisionsSheet = false
                                }
                            }
                        }
                }
            }
            .sheet(isPresented: $showLampaWebSheet) {
                LampaWebSheetView()
            }
            .alert("Плагины", isPresented: $showAlert) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .alert("Подтверждение безопасности", isPresented: $showSinglePluginApproval) {
                Button("Загрузить", role: .none) {
                    if let curated = pendingCuratedPlugin {
                        executeInstallCurated(curated)
                    } else if !pendingPluginUrl.isEmpty {
                        executeAddCustom(url: pendingPluginUrl)
                    }
                }
                Button("Отмена", role: .cancel) {
                    pendingCuratedPlugin = nil
                    pendingPluginUrl = ""
                }
            } message: {
                Text("Код будет загружен и отключён. Перед выполнением подтвердите его в списке плагинов.")
            }
        }
    }

    private func requestCuratedPluginApproval(_ plugin: CuratedPlugin) {
        pendingCuratedPlugin = plugin
        pendingPluginUrl = ""
        showSinglePluginApproval = true
    }

    private func requestCustomPluginApproval() {
        let clean = newPluginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        pendingPluginUrl = clean
        pendingCuratedPlugin = nil
        showSinglePluginApproval = true
    }

    private func executeInstallCurated(_ plugin: CuratedPlugin) {
        pluginManager.install(curated: plugin) { success, error in
            if !success, let err = error {
                alertMessage = err
                showAlert = true
            }
            pendingCuratedPlugin = nil
        }
    }

    private func executeAddCustom(url: String) {
        pluginManager.addCustom(url: url) { success, error in
            if success {
                newPluginUrl = ""
            } else if let err = error {
                alertMessage = err
                showAlert = true
            }
            pendingPluginUrl = ""
        }
    }
}
