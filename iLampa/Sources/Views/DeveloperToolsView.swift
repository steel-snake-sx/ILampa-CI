import SwiftUI
import WebKit

struct DeveloperToolsView: View {
    @AppStorage(DeveloperMode.preferenceKey) private var developerModeEnabled = false
    @State private var showOriginalWebUI = false
    var onPlayCustomUrl: ((String, String, Bool) -> Void)?

    var body: some View {
        List {
            Section {
                Text("Инструменты предназначены для диагностики. Обычный просмотр не зависит от них.")
                    .foregroundStyle(.orange)
                    .listRowBackground(Color.orange.opacity(0.1))
            }
            Section("ДОСТУП") {
                Toggle("Режим разработчика", isOn: $developerModeEnabled)
                if DeveloperMode.isForcedForTesting && !developerModeEnabled {
                    Text("Доступ включён аргументом тестирования")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if DeveloperMode.isEnabled(preference: developerModeEnabled) {
                Section("ИНСТРУМЕНТЫ") {
                    NavigationLink { LogViewerSubView(initialFilter: nil) } label: {
                        developerRow("Журнал событий", "Нативный журнал, доступен без JavaScript", "list.bullet.rectangle")
                    }
                    NavigationLink { WebKitEngineDiagnosticsView(onPlayCustomUrl: onPlayCustomUrl) } label: {
                        developerRow("Движок WebKit", "Состояние и мост со Swift", "cpu")
                    }
                    .accessibilityIdentifier("navWebKitEngine")
                    NavigationLink { DeveloperMediaTestView(onPlayCustomUrl: onPlayCustomUrl) } label: {
                        developerRow("Тестовый медиаплеер", "HLS / MP4, изолированная проверка", "play.rectangle")
                    }
                    NavigationLink { PluginLabView() } label: {
                        developerRow("Plugin Lab", "Изолированная диагностика совместимости плагинов", "flask")
                    }
                    .accessibilityIdentifier("navPluginLab")
                }
                Section("ОТЛАДОЧНОЕ ПРЕДСТАВЛЕНИЕ") {
                    Button { showOriginalWebUI = true } label: {
                        developerRow("Оригинальный интерфейс Lampa", "Для проверки поведения плагинов", "arrow.up.right.square")
                    }
                }
            }
        }
        .navigationTitle("Режим разработчика")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showOriginalWebUI) {
            LampaWebSheetView()
        }
    }
}

func developerRow(_ title: String, _ subtitle: String, _ icon: String) -> some View {
    Label {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).fontWeight(.semibold)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    } icon: { Image(systemName: icon).foregroundStyle(.secondary).frame(width: 28) }
}

private struct WebKitEngineDiagnosticsView: View {
    @ObservedObject private var host = LampaHeadlessHost.shared
    @State private var showRestartConfirmation = false
    var onPlayCustomUrl: ((String, String, Bool) -> Void)?

    var body: some View {
        List {
            Section("СОСТОЯНИЕ") {
                LabeledContent("WKWebView", value: host.webView == nil ? "Не создан" : host.currentAttachmentMode.rawValue)
                LabeledContent("Lampa Core", value: host.isAppReady ? "Готов" : "Не готов")
                LabeledContent("Swift ↔ JavaScript", value: "Не проверено")
                LabeledContent("Инициализация", value: host.bootstrapStatus.bootstrapError ?? host.lastLifecycleMessage)
            }
            Section("РАСШИРЕНИЯ") {
                NavigationLink { WebKitComponentsView() } label: { developerRow("Компоненты и владельцы", "Фактическая регистрация", "square.grid.2x2") }
                NavigationLink { WebKitScriptsView() } label: { developerRow("Активные скрипты", "Что загружено в текущей сессии", "list.bullet") }
                NavigationLink { LogViewerSubView(initialFilter: "ERROR") } label: { developerRow("Ошибки запуска", "Журнал и сведения об ошибках", "exclamationmark.triangle") }
            }
            Section("ОБСЛУЖИВАНИЕ") {
                Button {
                    showRestartConfirmation = true
                } label: {
                    developerRow("Перезапустить движок", "Восстановить текущую конфигурацию", "arrow.clockwise")
                }
                NavigationLink { WebKitCacheView() } label: { developerRow("Проверить кэш", "Проверка без очистки", "externaldrive") }
                NavigationLink { WebKitRuntimeToolsView(onPlayCustomUrl: onPlayCustomUrl) } label: { developerRow("Дополнительная диагностика", "Планирование, таймеры и мост", "wrench.and.screwdriver") }
            }
        }
        .navigationTitle("Движок WebKit")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Перезапустить WebKit?", isPresented: $showRestartConfirmation, titleVisibility: .visible) {
            Button("Перезапустить", role: .destructive) {
                host.controlledRestart(activePluginUrls: host.runningPlugins)
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Текущие поиски и JS-операции прервутся. Сохранённые настройки и разрешённые плагины будут восстановлены из конфигурации.")
        }
    }
}

private struct WebKitComponentsView: View {
    @ObservedObject private var host = LampaHeadlessHost.shared
    @ObservedObject private var registry = PluginCapabilityRegistry.shared

    var body: some View {
        List {
            Section("Платформа") {
                if host.bootstrapStatus.hasPlayerModule {
                    Label("Lampa.Player", systemImage: "checkmark.circle")
                }
                if host.bootstrapStatus.hasPluginsModule {
                    Label("Lampa.Plugins", systemImage: "checkmark.circle")
                }
                if !host.bootstrapStatus.hasPlayerModule && !host.bootstrapStatus.hasPluginsModule {
                    Text("Данные ещё не получены").foregroundStyle(.secondary)
                }
            }
            Section("Регистрации плагинов") {
                if !host.isAppReady {
                    Text("WebKit не готов").foregroundStyle(.secondary)
                } else if registry.registeredSources.isEmpty {
                    Text("Нет зарегистрированных возможностей").foregroundStyle(.secondary)
                } else {
                    ForEach(registry.registeredSources) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name)
                                .font(.subheadline.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(source.pluginUrl)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Section {
                NavigationLink {
                    LogViewerSubView(initialFilter: nil)
                } label: {
                    Label("Открыть журнал событий", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("Журнал")
            } footer: {
                Text("Регистрация не доказывает, что компонент функционирует. Работоспособность проверяется отдельно.")
            }
        }
        .navigationTitle("Компоненты и владельцы")
    }
}

private struct WebKitScriptsView: View {
    @ObservedObject private var host = LampaHeadlessHost.shared

    var body: some View {
        List {
            Section("Текущая сессия") {
                LabeledContent("Движок", value: host.isAppReady ? "Готов" : "Не готов")
                LabeledContent("Загружено", value: String(host.runningPlugins.count))
            }
            Section {
                if !host.isAppReady {
                    Text("Данные текущей сессии недоступны").foregroundStyle(.secondary)
                } else if host.runningPlugins.isEmpty {
                    Text("Нет загруженных плагинов").foregroundStyle(.secondary)
                } else {
                    ForEach(host.runningPlugins, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(URL(string: url)?.lastPathComponent ?? "Скрипт")
                                .font(.subheadline.weight(.medium))
                            Text(url)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Скрипты")
            } footer: {
                Text("Загрузка JavaScript не является доказательством работоспособности плагина.")
            }
        }
        .navigationTitle("Загруженные скрипты")
    }
}

private struct DeveloperMediaTestView: View {
    @State private var url = ""
    var onPlayCustomUrl: ((String, String, Bool) -> Void)?
    private var validURL: Bool {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
              parsed.host != nil else { return false }
        return true
    }
    var body: some View {
        List {
            Section("ПРЯМАЯ ССЫЛКА") {
                TextField("Адрес HLS / MP4", text: $url)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("ПРОВЕРКИ") {
                LabeledContent("Формат", value: "Не проверен")
                LabeledContent("Сетевой ответ", value: "Не проверен")
                LabeledContent("Разрешение", value: "Неизвестно")
                LabeledContent("AVPlayer", value: "Не запускался на этом экране")
            }
            Section { Text("Запуск не добавляет источник и не подтверждает качество потока.").foregroundStyle(.secondary) }
            Section {
                Button("Открыть в плеере") {
                    onPlayCustomUrl?(url.trimmingCharacters(in: .whitespacesAndNewlines), "Тест видеопотока", true)
                }.disabled(!validURL || onPlayCustomUrl == nil)
            }
        }
        .navigationTitle("Тест видеопотока")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct WebKitCacheView: View {
    private let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
    @State private var records: [WKWebsiteDataRecord] = []
    @State private var loaded = false

    var body: some View {
        List {
            Section("Состояние кэша") {
                LabeledContent("Записи", value: loaded ? String(records.count) : "Проверка…")
                LabeledContent("Размер", value: "WebKit не предоставляет")
                LabeledContent("Дисковый кэш", value: String(records.filter {
                    $0.dataTypes.contains(WKWebsiteDataTypeDiskCache)
                }.count))
                LabeledContent("Кэш памяти", value: String(records.filter {
                    $0.dataTypes.contains(WKWebsiteDataTypeMemoryCache)
                }.count))
            }
            if loaded && !records.isEmpty {
                Section("Состав") {
                    ForEach(records.indices, id: \.self) { index in
                        let record = records[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.displayName)
                                .font(.subheadline.weight(.medium))
                            Text(record.dataTypes.sorted().map { type in
                                switch type {
                                case WKWebsiteDataTypeDiskCache: return "Дисковый"
                                case WKWebsiteDataTypeMemoryCache: return "В памяти"
                                default: return "Другие данные"
                                }
                            }.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                NavigationLink("Очистить временный кэш") {
                    StorageSettingsView()
                }
            }
        }
        .navigationTitle("Кэш WebKit")
        .onAppear {
            WKWebsiteDataStore.default().fetchDataRecords(ofTypes: types) { result in
                DispatchQueue.main.async { records = result; loaded = true }
            }
        }
    }
}
