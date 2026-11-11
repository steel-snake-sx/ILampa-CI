import SwiftUI

// MARK: - 1. Plugins Management View (`plugins`)
struct PluginsManagementView: View {
    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var registry = PluginCapabilityRegistry.shared
    @StateObject private var runtime = LampaHeadlessHost.shared

    @State private var showBatchImportModal = false

    private var collisionReports: [PluginCollisionReport] {
        PluginCollisionPolicy.resolveCollisions(in: pluginManager.installedPlugins)
    }

    private var runtimeSnapshot: PluginRuntimeSnapshot {
        PluginRuntimeSnapshot(installed: pluginManager.installedPlugins,
                              runningPluginURLs: runtime.runningPlugins,
                              capabilities: registry.registeredSources)
    }

    var body: some View {
        Form {
            // MARK: - 1. ДЕЙСТВИЯ (Actions)
            Section("ДЕЙСТВИЯ") {
                NavigationLink(destination: PluginCatalogView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Каталог плагинов")
                                .font(.body.bold())
                                .foregroundColor(.primary)
                            Text("Просмотр доступных расширений")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("navPluginCatalog")

                Button {
                    showBatchImportModal = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Добавить по ссылке")
                                .font(.body.bold())
                                .foregroundColor(.primary)
                            Text("Один адрес или список URL")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .accessibilityIdentifier("buttonBatchImport")
            }

            // MARK: - 2. УСТАНОВЛЕННЫЕ (Installed)
            Section("УСТАНОВЛЕННЫЕ") {
                if let error = pluginManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                if pluginManager.installedPlugins.isEmpty {
                    Text("Нет установленных плагинов")
                        .foregroundColor(.secondary)
                }
                ForEach(pluginManager.installedPlugins) { plugin in
                    NativePluginCard(
                        plugin: plugin,
                        statusText: statusText(for: plugin)
                    )
                }
            }

            // MARK: - 3. ОБСЛУЖИВАНИЕ (Maintenance)
            Section("ОБСЛУЖИВАНИЕ") {
                NavigationLink(destination: PluginUpdatesView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Обновления")
                                .font(.body.bold())
                                .foregroundColor(.primary)
                            Text("Проверять вручную")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("navPluginUpdates")

                NavigationLink(destination: PluginCollisionsView(reports: collisionReports)) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Конфликты")
                                .font(.body.bold())
                                .foregroundColor(.primary)
                            Text("Возможные пересечения компонентов")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("navCollisions")
            }
        }
        .navigationTitle("Плагины")
        .fullScreenCover(isPresented: $showBatchImportModal) {
            BatchImportModalView()
        }
    }

    private func statusText(for plugin: LampaPluginRecord) -> String {
        if !pluginManager.hasTrustedCachedScript(plugin), pluginManager.cachedScriptSHA256(for: plugin.urlString) != nil {
            return "Требуется подтверждение кода"
        }
        if !plugin.isEnabled {
            if case .inactiveAlternate = plugin.lifecycleState { return "Неактивен (вторичный)" }
            return "Отключен"
        }
        if plugin.automaticRetryBlocked == true { return "Требуется повторная попытка" }
        if plugin.errorDescription != nil { return "Ошибка выполнения" }
        if case .failed = plugin.lifecycleState { return plugin.lifecycleState.displayLabel }
        if case .loading = plugin.lifecycleState { return "Загрузка…" }
        if runtimeSnapshot.isExecutedInCurrentGeneration(plugin) { return "Выполнен в текущей сессии" }
        return "Ожидает или требует проверки"
    }
}

// MARK: - 2. Plugin Catalog View (`plugincatalog`)
struct PluginCatalogView: View {
    @ObservedObject private var pluginManager = PluginManager.shared
    @StateObject private var catalog = PluginCatalogStore()
    @State private var searchText = ""
    @State private var selectedCategory = "Все"
    @State private var pendingPlugin: CuratedPlugin?
    @State private var showApproval = false
    @State private var installationError: String?

    private var categories: [String] {
        ["Все"] + Array(Set((catalog.snapshot?.entries ?? []).compactMap(\.category))).sorted()
    }

    private var filteredEntries: [PluginCatalogEntry] {
        (catalog.snapshot?.entries ?? []).filter { entry in
            let categoryMatches = selectedCategory == "Все" || entry.category == selectedCategory
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return categoryMatches && (query.isEmpty || [entry.title, entry.author ?? "", entry.description ?? "", entry.category ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    var body: some View {
        Form {
            Section {
                Text("Наличие в каталоге не означает установку или совместимость.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("ВСТРОЕННЫЕ И РЕКОМЕНДУЕМЫЕ") {
                ForEach(pluginManager.curatedPlugins) { plugin in
                    HStack(spacing: 12) {
                        Image(systemName: plugin.iconName)
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(plugin.name)
                                .font(.body.bold())
                            Text(plugin.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if pluginManager.installedPlugins.contains(where: { $0.urlString == plugin.url }) {
                            Text("Установлен")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if pluginManager.isInstalling(url: plugin.url) {
                            ProgressView()
                        } else {
                            Button("Установить") {
                                pendingPlugin = plugin
                                showApproval = true
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("install_\(plugin.name)")
                        }
                    }
                }
            }
            Section("КАТАЛОГ LAMPAPLUGINS") {
                Picker("Категория", selection: $selectedCategory) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
                if catalog.isRefreshing { ProgressView("Обновление каталога…") }
                if let error = catalog.error { Text(error).font(.caption).foregroundColor(.secondary) }
                if let snapshot = catalog.snapshot {
                    Text("Источник: lampaplugins/store · обновлено \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundColor(.secondary)
                    if snapshot.unsupportedCount > 0 {
                        Text("Небезопасные или некорректные адреса исключены: \(snapshot.unsupportedCount)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if filteredEntries.isEmpty { Text("Ничего не найдено").foregroundColor(.secondary) }
                    ForEach(filteredEntries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title).font(.body.bold())
                                    if let author = entry.author { Text(author).font(.caption).foregroundColor(.secondary) }
                                }
                                Spacer()
                                if pluginManager.installedPlugins.contains(where: { $0.urlString == entry.sourceURL.absoluteString }) {
                                    Text("Установлен").font(.caption).foregroundColor(.secondary)
                                } else if pluginManager.isInstalling(url: entry.sourceURL.absoluteString) {
                                    ProgressView()
                                } else {
                                    Button("Установить") {
                                        pendingPlugin = CuratedPlugin(name: entry.title, description: entry.description ?? "",
                                            url: entry.sourceURL.absoluteString, iconName: "puzzlepiece.extension")
                                        showApproval = true
                                    }.buttonStyle(.bordered)
                                }
                            }
                            if let description = entry.description { Text(description).font(.caption).foregroundColor(.secondary) }
                            Text("\(entry.category ?? "Без категории") · Совместимость не проверена")
                                .font(.caption).foregroundColor(.secondary)
                        }.padding(.vertical, 4)
                    }
                } else if !catalog.isRefreshing {
                    Text("Каталог пока недоступен").foregroundColor(.secondary)
                }
                Button("Обновить каталог") { Task { await catalog.refresh() } }
                    .disabled(catalog.isRefreshing)
            }
        }
        .navigationTitle("Каталог плагинов")
        .searchable(text: $searchText, prompt: "Название, автор или категория")
        .task { await catalog.refresh() }
        .alert("Подтверждение безопасности", isPresented: $showApproval) {
            Button("Загрузить") {
                guard let plugin = pendingPlugin else { return }
                pendingPlugin = nil
                pluginManager.install(curated: plugin) { success, error in
                    if !success { installationError = error ?? "Не удалось установить плагин." }
                }
            }
            Button("Отмена", role: .cancel) { pendingPlugin = nil }
        } message: {
            Text("Код будет загружен и отключён. Перед выполнением подтвердите его в списке плагинов.")
        }
        .alert("Ошибка установки", isPresented: Binding(
            get: { installationError != nil },
            set: { if !$0 { installationError = nil } }
        )) {
            Button("Понятно", role: .cancel) { installationError = nil }
        } message: {
            Text(installationError ?? "")
        }
    }
}

// MARK: - 4. SomaFM Plugin Detail View (`somafmplugin`)
struct SomaFMPluginDetailView: View {
    var body: some View {
        Form {
            Section {
                Text("У некоторых станций подтверждено нативное воспроизведение. Доступность остальных проверяется отдельно.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("ДОСТУПНАЯ ВОЗМОЖНОСТЬ") {
                NavigationLink(destination: NativeRadioView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Радиостанции")
                                .font(.body.bold())
                            Text("Каталог каналов SomaFM")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("Слушать")
                            .font(.caption.bold())
                            .foregroundColor(.blue)
                    }
                }
            }

            Section("СВЕДЕНИЯ О ПЛАГИНЕ") {
                LabeledContent("Автор", value: "@tsynik")
                LabeledContent("Тип", value: "Аудио-расширение")
            }
        }
        .navigationTitle("SomaFM")
    }
}

// MARK: - 5. Plugin Generic Detail View (`pluginfilmix`)
struct PluginGenericDetailView: View {
    let pluginName: String

    var body: some View {
        Form {
            Section {
                Text("Установка и возможности не подтверждены. Управляйте установленными плагинами в разделе «Плагины».")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("ДЕЙСТВИЯ") {
                NavigationLink(destination: PluginUnsupportedView(pluginName: pluginName)) {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Неподдерживаемые компоненты")
                    }
                }
            }

        }
        .navigationTitle(pluginName)
    }
}
