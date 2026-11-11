import SwiftUI

/// Autonomous Plugin Diagnostics Center conforming strictly to the iLampa Final Design Lock.
/// Activated by ONE primary switch, testing plugins sequentially, capturing technical evidence,
/// and exporting a comprehensive diagnostic ZIP.
struct PluginLabView: View {
    @StateObject private var coordinator = PluginLabCoordinator.shared
    @State private var shareURL: URL?
    @State private var showShareSheet = false
    @State private var showExportErrorAlert = false

    var body: some View {
        Form {
            // MARK: - Section 1: ONE-SWITCH PRIMARY TOGGLE
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Автоматическая диагностика плагинов", isOn: $coordinator.isDiagnosticsActive)
                        .font(.headline)
                        .accessibilityIdentifier("togglePluginLab")

                    Text("Проверяет загрузку, регистрацию и обращения API в изолированном WebKit. Работа интерфейса и реальных потоков требует дополнительной проверки на устройстве.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if coordinator.isDiagnosticsActive {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: coordinator.progress)
                                .tint(.blue)
                            HStack {
                                Text(coordinator.currentStageText)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(coordinator.progress * 100))%")
                                    .font(.caption2.bold())
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("УПРАВЛЕНИЕ")
            }

            // MARK: - Section 2: METRICS & COUNTERS
            Section("МЕТРИКИ СОВМЕСТИМОСТИ") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Обнаружено")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(coordinator.discoveredCount)")
                            .font(.title3.bold())
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Проверено")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(coordinator.testedCount)")
                            .font(.title3.bold())
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Совместимы")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(coordinator.passCount)")
                            .font(.title3.bold())
                            .foregroundColor(.green)
                    }
                }
                .padding(.vertical, 2)

                HStack {
                    VStack(alignment: .leading) {
                        Text("Частично")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(coordinator.partialCount)")
                            .font(.title3.bold())
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Сбои")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(coordinator.failCount)")
                            .font(.title3.bold())
                            .foregroundColor(.red)
                    }
                    Spacer()
                    VStack(alignment: .leading) {
                        Text("Не проверено")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(coordinator.inconclusiveCount)")
                            .font(.title3.bold())
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            // MARK: - Section 3: ACTIVE TEST
            if let active = coordinator.currentPlugin {
                Section("ТЕКУЩИЙ ТЕСТ") {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(active.name)
                                .font(.headline)
                            Text(coordinator.currentStageText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            // MARK: - Section 4: REPORT & EXPORT
            Section("ОТЧЁТ И ЭКСПОРТ") {
                if let date = coordinator.lastReportDate {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.blue)
                            Text("Отчёт сформирован")
                                .font(.subheadline.bold())
                        }
                        Text("Дата: \(date.formatted(date: .abbreviated, time: .standard)) · Длительность: \(String(format: "%.1f", coordinator.lastReportDuration)) с")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)

                    Button(action: handleExport) {
                        HStack(spacing: 10) {
                            Image(systemName: "square.and.arrow.up.fill")
                                .foregroundColor(.blue)
                            Text("Экспортировать ZIP (PluginLab-Report.zip)")
                                .font(.body.bold())
                                .foregroundColor(.primary)
                        }
                    }
                    .accessibilityIdentifier("exportPluginLabZipButton")
                }

                Button(action: {
                    coordinator.runAgain()
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                        Text("Запустить диагностику повторно")
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                }
                .disabled(coordinator.isDiagnosticsActive)
                .accessibilityIdentifier("runAgainPluginLabButton")
            }

            // MARK: - Section 5: TESTED PLUGINS INVENTORY
            Section("РЕЗУЛЬТАТЫ ПО ПЛАГИНАМ (\(coordinator.inventory.count))") {
                if coordinator.inventory.isEmpty {
                    Text("Плагины не обнаружены.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(coordinator.inventory) { item in
                        NavigationLink(destination: PluginLabPluginDetailView(item: item)) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.subheadline.bold())
                                        .foregroundColor(.primary)
                                    HStack(spacing: 6) {
                                        Text(item.origin.displayName)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        if let cause = item.primaryRootCause {
                                            Text("· \(cause.displayName)")
                                                .font(.caption2)
                                                .foregroundColor(.orange)
                                        }
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(item.status.color)
                                            .frame(width: 6, height: 6)
                                        Text(item.status.rawValue)
                                            .font(.caption.bold())
                                            .foregroundColor(item.status.color)
                                    }
                                    Text(item.confidence.displayName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Plugin Lab")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                DiagnosticsShareSheet(activityItems: [url])
            }
        }
        .alert("Ошибка экспорта", isPresented: $showExportErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(coordinator.exportError ?? "Не удалось сформировать ZIP-архив.")
        }
    }

    private func handleExport() {
        do {
            let url = try coordinator.exportReportArchive()
            self.shareURL = url
            self.showShareSheet = true
        } catch {
            coordinator.exportError = error.localizedDescription
            self.showExportErrorAlert = true
        }
    }
}
