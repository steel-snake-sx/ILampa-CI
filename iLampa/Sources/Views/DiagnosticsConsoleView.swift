import SwiftUI
import WebKit

/// Standalone recovery entry point. Constructing this view must not access the
/// runtime singleton: its initializer creates a WKWebView. The app root can
/// present this instead of ContentView when entering native recovery mode.
struct NativeRecoveryDiagnosticsView: View {
    @ObservedObject private var logManager = DiagnosticsLogManager.shared
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Нативный режим восстановления. Состояние WebKit недоступно; события JS могут отсутствовать.")
                        .font(.caption)
                    .foregroundColor(.secondary)
                    Text("Чтобы вернуться в приложение, отключите режим восстановления в системных настройках iLampa и перезапустите приложение.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Section("События") {
                    NavigationLink("Журнал событий", destination: LogViewerSubView(initialFilter: nil))
                        .accessibilityIdentifier("navLogViewer")
                    NavigationLink("Ошибки", destination: LogViewerSubView(initialFilter: "ERROR"))
                        .accessibilityIdentifier("navLogViewerErrors")
                }
                Section("Сбор и экспорт") {
                    NavigationLink("Уровень журнала", destination: LogLevelSettingsView())
                        .accessibilityIdentifier("navLogLevel")
                    NavigationLink("Экспортировать журнал", destination: PrivacyExportView())
                        .accessibilityIdentifier("navPrivacyExport")
                }
                Section("Хранение") {
                    NavigationLink(destination: LogRetentionPolicyView(onClearRequested: {
                        showClearConfirm = true
                    })) {
                        Text("Срок хранения журнала")
                    }
                    .accessibilityIdentifier("navLogRetention")
                }
            }
            .navigationTitle("Диагностика")
            .alert("Очистить журнал?", isPresented: $showClearConfirm) {
                Button("Отмена", role: .cancel) {}
                Button("Очистить", role: .destructive) { logManager.clear() }
            } message: {
                Text("Все сохранённые записи журнала на диске и в памяти будут удалены. Настройки плагинов и история просмотров не затрагиваются.")
            }
        }
    }
}

/// Diagnostics remain available even when the WebKit process is not ready.
struct DiagnosticsConsoleView: View {
    var onLaunchTestStream: (() -> Void)?
    var onPlayCustomUrl: ((String, String, Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var logManager = DiagnosticsLogManager.shared
    @StateObject private var runtime = LampaHeadlessHost.shared
    @AppStorage(DeveloperMode.preferenceKey) private var developerModeEnabled = false

    @State private var showClearConfirm = false

    private var isWebKitDeadOrUninitialized: Bool {
        !runtime.isAppReady && runtime.heartbeatCount == 0
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - WebKit Status Banner
                if isWebKitDeadOrUninitialized {
                    Section {
                        NavigationLink(destination: WebKitOfflineView()) {
                            HStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.title3)
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("WebKit пока не готов")
                                        .font(.headline)
                                        .foregroundColor(.orange)
                                    Text("Посмотреть состояние и журнал")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // MARK: - 1. СОБЫТИЯ (Events)
                Section("События") {
                    NavigationLink(destination: LogViewerSubView(initialFilter: nil)) {
                        HStack(spacing: 12) {
                            Image(systemName: "list.bullet.rectangle.fill")
                                .font(.title3)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Журнал событий")
                                    .font(.headline)
                                Text("Ошибки, предупреждения, действия (\(logManager.entries.count))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(logManager.entries.count)")
                                .font(.caption.bold())
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityIdentifier("navLogViewer")

                    NavigationLink(destination: LogViewerSubView(initialFilter: "ERROR")) {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Ошибки источников")
                                    .font(.headline)
                                Text("События сбоев подключения и резолверов")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            let errCount = logManager.entries.filter { $0.level == .error }.count
                            Text("\(errCount)")
                                .font(.caption.bold())
                                .foregroundColor(errCount > 0 ? .red : .secondary)
                        }
                    }
                    .accessibilityIdentifier("navLogViewerErrors")
                }

                // MARK: - 2. СБОР И ЭКСПОРТ (Collection & Export)
                Section("Сбор и экспорт") {
                    NavigationLink(destination: LogLevelSettingsView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.title3)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Уровень журнала")
                                    .font(.headline)
                                Text("Текущий: \(logManager.logLevel.displayName)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("navLogLevel")

                    NavigationLink(destination: PrivacyExportView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "square.and.arrow.up.fill")
                                .font(.title3)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Экспортировать журнал")
                                    .font(.headline)
                                Text("Обезличенные события и данные сборки · JSONL")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("navPrivacyExport")
                }

                // MARK: - 3. ИНСТРУМЕНТЫ (Tools)
                Section("Инструменты") {
                    Button(action: {
                        onLaunchTestStream?()
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "play.tv.fill")
                                .font(.title3)
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Тест воспроизведения")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("Проверить HLS / MP4 отдельно от каталога")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("testHlsButton")

                    NavigationLink(destination: DeveloperToolsView(onPlayCustomUrl: onPlayCustomUrl)) {
                        HStack(spacing: 12) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.title3)
                                .foregroundColor(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Режим разработчика")
                                    .font(.headline)
                                Text("WebKit, мост, скрипты и кэш")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("navDevMode")
                }

                // MARK: - 4. ХРАНЕНИЕ (Retention Policy)
                Section("Хранение") {
                    NavigationLink(destination: LogRetentionPolicyView(onClearRequested: {
                        showClearConfirm = true
                    })) {
                        HStack(spacing: 12) {
                            Image(systemName: "archivebox.fill")
                                .font(.title3)
                                .foregroundColor(.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Срок хранения журнала")
                                    .font(.headline)
                                Text("7 дней или 16 МиБ (8 × 2 МиБ)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("navLogRetention")
                }

                // MARK: - 5. СБОРКА (Build Info)
                Section("Сборка") {
                    HStack {
                        Text("Версия приложения")
                        Spacer()
                        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Недоступно"
                        let buildNum = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Недоступно"
                        Text("\(appVer) (\(buildNum))")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Идентификатор")
                        Spacer()
                        Text(Bundle.main.bundleIdentifier ?? "Недоступно")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Коммит")
                        Spacer()
                        let gitSha = Bundle.main.infoDictionary?["ILAMPA_GIT_COMMIT"] as? String ?? ""
                        Text(gitSha.isEmpty ? "Недоступно" : String(gitSha.prefix(7)))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Среда")
                        Spacer()
                        Text("Native SwiftUI + Headless WebKit")
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - 6. ЕСЛИ ДВИЖОК НЕДОСТУПЕН
                Section("Если движок недоступен") {
                    NavigationLink(destination: WebKitOfflineView()) {
                        HStack(spacing: 12) {
                            Image(systemName: "cross.case.fill")
                                .font(.title3)
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Диагностика без WebKit")
                                    .font(.headline)
                                Text("Нативные события, экспорт и код ошибки")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("navWebKitOffline")
                }
            }
            .navigationTitle("Диагностика")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
            .alert("Очистить журнал?", isPresented: $showClearConfirm) {
                Button("Отмена", role: .cancel) {}
                Button("Очистить", role: .destructive) {
                    logManager.clear()
                }
            } message: {
                Text("Все сохранённые записи журнала на диске и в памяти будут удалены. Настройки плагинов и история просмотров не затрагиваются.")
            }
        }
    }
}

