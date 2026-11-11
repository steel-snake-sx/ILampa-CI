import SwiftUI
import WebKit

// Runtime operations are grouped into focused screens rather than a single test console.
struct WebKitRuntimeToolsView: View {
    enum Tool: String {
        case scheduling = "Планирование и таймеры"
        case bootstrap = "Инициализация Lampa Core"
        case plugins = "Управление расширениями"
        case search = "Поиск и передача потока"
    }
    var tool: Tool? = nil
    @ObservedObject var host = LampaHeadlessHost.shared
    @State private var showCanonicalImport = false

    // Таймер и планирование
    @State private var timerTestResult: String? = nil
    @State private var isRunningTimerTest: Bool = false

    // Плагины

    // Поиск и поток
    @State private var searchMovieId: String = "550"
    @State private var searchMovieTitle: String = "Бойцовский клуб"
    @State private var streamTestUrl: String = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"
    @State private var streamTestTitle: String = "Тест HLS Handoff"
    @State private var showLampaUiSheet: Bool = false

    var onPlayCustomUrl: ((String, String, Bool) -> Void)?

    var body: some View {
        List {
            if tool == nil {
                Section {
                    Text("Проверки используют текущую сессию WebKit и могут изменить её состояние. Журнал доступен отдельно без JavaScript.")
                        .foregroundStyle(.secondary)
                }
                Section("ПРОВЕРКИ") {
                    toolLink(.scheduling, "Режим WebKit и проверка таймера", "timer")
                    toolLink(.bootstrap, "Состояние модулей Lampa", "checkmark.shield")
                    toolLink(.plugins, "Активные плагины", "puzzlepiece")
                    toolLink(.search, "Поиск источников и AVPlayer", "play.tv")
                }
                Section("ПЛАГИНЫ") {
                    NavigationLink {
                        PluginsManagementView()
                    } label: {
                        developerRow("Управление плагинами", "Открыть основной раздел", "puzzlepiece.extension")
                    }
                    Button {
                        showCanonicalImport = true
                    } label: {
                        developerRow("Импорт по ссылкам", "Открыть единый мастер импорта", "tray.and.arrow.down")
                    }
                    .accessibilityIdentifier("openCanonicalPluginImport")
                }
                Section("ДИАГНОСТИКА") {
                    NavigationLink { LogViewerSubView(initialFilter: nil) } label: {
                        developerRow("Журнал событий", "Нативные записи", "list.bullet.rectangle")
                    }
                }
            }
            // MARK: - Section 1: iOS 18 WebKit Inactive Scheduling Matrix
            if tool == .scheduling {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Режим прикрепления WKWebView:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Режим", selection: $host.currentAttachmentMode) {
                        ForEach(WebKitAttachmentMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: host.currentAttachmentMode) { _, newMode in
                        host.setAttachmentMode(newMode)
                    }

                    Text("Политика неактивного планирования (iOS 18):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Политика", selection: $host.currentSchedulingPolicy) {
                        ForEach(WebKitSchedulingPolicy.allCases) { policy in
                            Text(policy.rawValue).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: host.currentSchedulingPolicy) { _, newPolicy in
                        host.updateSchedulingPolicy(newPolicy)
                    }

                    Divider()

                    // Live Heartbeat Gauge
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Heartbeat (JS setInterval)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(host.heartbeatCount) тиков")
                                .font(.headline)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Частота таймера")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.2f Гц", host.heartbeatFrequencyHz))
                                .font(.headline)
                                .foregroundColor(heartbeatColor)
                        }
                    }

                    HStack {
                        Circle()
                            .fill(heartbeatColor)
                            .frame(width: 10, height: 10)
                        Text(heartbeatStatusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Delayed Timer Test (5s)
                    Button(action: runTimerTest) {
                        HStack {
                            Image(systemName: "timer")
                            Text(isRunningTimerTest ? "Таймер выполняется..." : "Проверить таймер (5 сек)")
                        }
                    }
                    .disabled(isRunningTimerTest)

                    if let result = timerTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(6)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(6)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("iOS 18 WebKit Планирование", systemImage: "cpu")
            } footer: {
                Text("Частота отражает полученные сигналы текущей сессии и не доказывает причину их отсутствия или поведение WebKit в фоне.")
                    .font(.caption)
            }
            }

            // System state presented as native Settings rows, not a bespoke debug card.
            if tool == .bootstrap {
                Section {
                    LabeledContent("Статус", value: host.isAppReady ? "Готов" : "Инициализация…")
                    CoreCheckRow(name: "Lampa Core", isReady: host.bootstrapStatus.hasLampaGlobal)
                    CoreCheckRow(name: "JavaScript / jQuery", isReady: host.bootstrapStatus.hasJQuery)
                    CoreCheckRow(name: "Плагины", isReady: host.bootstrapStatus.hasPluginsModule)
                    CoreCheckRow(name: "Плеер", isReady: host.bootstrapStatus.hasPlayerModule)
                    CoreCheckRow(name: "Событие appready", isReady: host.isAppReady)
                } header: {
                    Label("Состояние движка", systemImage: "cpu")
                } footer: {
                    Text("Зелёные индикаторы подтверждают запуск модулей, но не совместимость конкретных плагинов.")
                }
                if let error = host.bootstrapStatus.bootstrapError, !error.isEmpty {
                    Section("Ошибка запуска") {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section {
                    LabeledContent("Сессия", value: host.lastLifecycleMessage)
                    Text("Перезапуск WebKit доступен в предыдущем разделе «Движок WebKit».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // Runtime plugin inspection. Installation and toggles live in PluginsManagementView.
            if tool == .plugins {
                Section("Текущая сессия") {
                    LabeledContent("Работающие плагины", value: String(host.runningPlugins.count))
                    if !host.isAppReady {
                        Text("WebKit ещё не готов").foregroundStyle(.secondary)
                    } else if host.runningPlugins.isEmpty {
                        Text("Нет активных плагинов").foregroundStyle(.secondary)
                    } else {
                        ForEach(host.runningPlugins, id: \.self) { url in
                            Text(url).font(.footnote.monospaced())
                                .lineLimit(3).textSelection(.enabled)
                        }
                    }
                }
                Section {
                    NavigationLink {
                        PluginsManagementView()
                    } label: {
                        developerRow("Управление плагинами", "Настройка и включение в основном разделе", "puzzlepiece.extension")
                    }
                }
            }

            if tool == .search {
                Section("Тестовая карточка") {
                    LabeledContent("TMDB ID") {
                        TextField("ID", text: $searchMovieId)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("developerSourceMovieID")
                    }
                    LabeledContent("Название") {
                        TextField("Название", text: $searchMovieTitle)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("developerSourceTitle")
                    }
                }

                Section {
                    Button {
                        guard let id = Int(searchMovieId), id > 0 else { return }
                        host.triggerMovieSearch(id: id, title: searchMovieTitle)
                    } label: {
                        Label("Проверить источники", systemImage: "magnifyingglass")
                    }
                    .disabled((Int(searchMovieId) ?? 0) <= 0 ||
                              searchMovieTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        showLampaUiSheet = true
                    } label: {
                        Label("Открыть интерфейс Lampa", systemImage: "rectangle.on.rectangle")
                    }
                } header: {
                    Text("Действия")
                } footer: {
                    Text("Тест использует текущую WebKit-сессию. Обнаруженная строка — ещё не подтверждённый видеопоток.")
                }

                Section("Результат поиска") {
                    LabeledContent("Состояние", value: host.isSearchingSources ? "Поиск…" : "Ожидание")
                    LabeledContent("Строки", value: String(host.discoveredSources.count))
                    if host.isSearchingSources {
                        ProgressView("Получение результатов…")
                    } else if host.discoveredSources.isEmpty {
                        Text("Движок не передал ни одной строки для этой карточки.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(host.discoveredSources) { source in
                            Label(source.title, systemImage: source.isFolder ? "folder" : "film")
                                .lineLimit(2)
                        }
                    }
                }

                Section {
                    Button {
                        host.simulateResolveAndPlay(url: streamTestUrl, title: streamTestTitle)
                    } label: {
                        Label("Проверить HLS-передачу", systemImage: "play.rectangle")
                    }
                    if let payload = host.lastInterceptedPayload {
                        LabeledContent("Перехвачено", value: payload.title)
                        Button("Открыть поток в AVPlayer") {
                            onPlayCustomUrl?(payload.url, payload.title, false)
                        }
                        .disabled(onPlayCustomUrl == nil)
                    }
                } header: {
                    Text("Передача видеопотока")
                } footer: {
                    Text("Это самостоятельный тест AVPlayer, не проверка доступности потоков онлайн-балансеров.")
                }
            }

            // MARK: - Section 6: Live WebKit Canvas (When visible mode enabled)
            if tool == .scheduling && host.currentAttachmentMode == .attachedVisible {
                Section {
                    VStack {
                        Text("Живой холст WebKit (Lampa DOM):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        LampaHostContainerView(isInteractive: true)
                            .frame(height: 260)
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue, lineWidth: 1))
                    }
                } header: {
                    Label("Инспекция визуального слоя", systemImage: "eye")
                }
            }
        }
        .navigationTitle(tool?.rawValue ?? "Дополнительная диагностика")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCanonicalImport) {
            BatchImportModalView()
        }
        .sheet(isPresented: $showLampaUiSheet, onDismiss: {
            host.setAttachmentMode(.attachedUnobtrusive)
        }) {
            NavigationStack {
                VStack {
                    Text("Интерфейс выбора источников Lampa")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)

                    LampaHostContainerView(isInteractive: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationTitle("Lampa UI Selector")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Закрыть") {
                            showLampaUiSheet = false
                            host.setAttachmentMode(.attachedUnobtrusive)
                        }
                    }
                }
                .onAppear {
                    host.setAttachmentMode(.attachedVisible)
                }
                .onChange(of: host.lastInterceptedPayload) { _, newPayload in
                    if let newPayload = newPayload {
                        showLampaUiSheet = false
                        host.setAttachmentMode(.attachedUnobtrusive)
                        onPlayCustomUrl?(newPayload.url, newPayload.title, false)
                    }
                }
            }
        }
    }

    // MARK: - Helpers & Actions
    private func toolLink(_ tool: Tool, _ subtitle: String, _ icon: String) -> some View {
        NavigationLink { WebKitRuntimeToolsView(tool: tool, onPlayCustomUrl: onPlayCustomUrl) } label: {
            developerRow(tool.rawValue, subtitle, icon)
        }
    }

    private var heartbeatColor: Color {
        if host.heartbeatFrequencyHz >= 1.0 {
            return .green
        } else if host.heartbeatFrequencyHz > 0.0 {
            return .orange
        } else {
            return .red
        }
    }

    private var heartbeatStatusText: String {
        if host.heartbeatFrequencyHz >= 1.0 {
            return "Получены сигналы таймера"
        } else if host.heartbeatFrequencyHz > 0.0 {
            return "Низкая частота сигналов"
        } else {
            return "Сигналы не наблюдаются"
        }
    }

    private func runTimerTest() {
        isRunningTimerTest = true
        timerTestResult = "Таймер запущен на 5 секунд..."
        let start = Date()
        host.testDelayedTimer(delaySeconds: 5.0) { success, elapsed in
            DispatchQueue.main.async {
                self.isRunningTimerTest = false
                let wallElapsed = Date().timeIntervalSince(start)
                if success {
                    self.timerTestResult = String(format: "Успех! JS задержка: %.2f с, Реальное время: %.2f с", elapsed, wallElapsed)
                } else {
                    self.timerTestResult = "Ошибка вызова таймера в рантайме"
                }
            }
        }
    }


}

private struct CoreCheckRow: View {
    let name: String
    let isReady: Bool

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(isReady ? Color.green : Color.secondary)
                .accessibilityLabel(isReady ? "Доступен" : "Не готов")
        }
    }
}
