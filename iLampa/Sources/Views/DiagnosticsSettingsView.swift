import SwiftUI
import WebKit

// MARK: - Log Level Settings View (`loglevel`)

struct LogLevelSettingsView: View {
    @ObservedObject private var logManager = DiagnosticsLogManager.shared

    var body: some View {
        Form {
            Section {
                Picker("Уровень логирования", selection: $logManager.logLevel) {
                    ForEach(DiagnosticsLogLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Выбор уровня")
            } footer: {
                if logManager.logLevel == .detailed {
                    Text("Подробный режим включен на 24 часа. По истечении этого времени уровень автоматически вернётся к обычному.")
                        .foregroundColor(.orange)
                } else {
                    Text("Обычный уровень рекомендуется для повседневного использования.")
                }
            }
        }
        .navigationTitle("Уровень журнала")
    }
}

// MARK: - Log Retention Policy View (`logretention`)

struct LogRetentionPolicyView: View {
    var onClearRequested: () -> Void
    @AppStorage("ilampa_diagnostics_memory_entries") private var memoryLimit = 250

    var body: some View {
        Form {
            Section("Политика хранения") {
                LabeledContent("Срок хранения", value: "7 дней")
                LabeledContent("Максимальный размер", value: "16 МиБ")
                LabeledContent("Сегментов на диске", value: "До 8 × 2 МиБ")
                Picker("Записей в оперативной памяти", selection: $memoryLimit) {
                    ForEach([250, 500, 1000, 2500, 5000, 10000], id: \.self) { count in
                        Text(count.formatted()).tag(count)
                    }
                }
                .accessibilityIdentifier("diagnosticsMemoryLimit")
                LabeledContent("Удаление", value: "По первому пределу")
            }

            Section("Запись") {
                LabeledContent("Уровень по умолчанию", value: "Обычный")
                LabeledContent("Одна запись", value: "Макс. 8 КиБ")
                LabeledContent("Подробный режим", value: "До 24 часов")
            }

            Section("Управление") {
                Button(role: .destructive, action: onClearRequested) {
                    Label("Очистить журнал", systemImage: "trash")
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Хранение журнала")
        .onChange(of: memoryLimit) { _, limit in
            DiagnosticsLogManager.shared.trimMemoryEntries(to: limit)
        }
    }
}

// MARK: - WebKit Offline View (`webkitoffline`)

struct WebKitOfflineView: View {
    @ObservedObject private var logManager = DiagnosticsLogManager.shared
    @StateObject private var runtime = LampaHeadlessHost.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.title2)
                            .foregroundColor(.orange)
                        Text(runtime.isAppReady ? "WebKit работает" : "WebKit не готов")
                            .font(.headline)
                    }

                    Text(runtime.isAppReady
                         ? "Движок готов. Журнал и диагностика доступны."
                         : "Журнал работает независимо от WebKit; события JavaScript могут появиться после запуска движка.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Доступная диагностика") {
                NavigationLink(destination: LogViewerSubView()) {
                    HStack {
                        Image(systemName: "list.bullet.rectangle")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Нативный журнал")
                                .font(.body)
                            Text("Последняя попытка запуска и системные события")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                NavigationLink("Экспортировать журнал", destination: PrivacyExportView())
            }

            Section("Движок") {
                LabeledContent("Состояние") {
                    Text(runtime.isAppReady ? "Готов" : "Не запущен")
                        .foregroundColor(runtime.isAppReady ? .green : .red)
                }
                LabeledContent("Последняя попытка", value: runtime.lastLifecycleMessage.isEmpty ? "Не удалось инициализировать" : runtime.lastLifecycleMessage)
                LabeledContent("JS-компоненты") {
                    Text(runtime.isAppReady ? "См. инструменты разработчика" : "Пока недоступны")
                        .foregroundColor(runtime.isAppReady ? .secondary : .orange)
                }
                LabeledContent("Мост Swift ↔ JS") {
                    Text(runtime.isAppReady ? "Связь есть" : "Нет связи")
                        .foregroundColor(runtime.isAppReady ? .green : .red)
                }
            }

            Section {
                Text("Проверяйте журнал прежде, чем изменять данные или настройки приложения.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Состояние WebKit")
    }
}

