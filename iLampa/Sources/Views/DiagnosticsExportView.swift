import SwiftUI
import UIKit

// MARK: - Privacy Safe Export View (`privacyexport`)

struct PrivacyExportView: View {
    @ObservedObject private var logManager = DiagnosticsLogManager.shared
    @State private var isPreparing = false
    @State private var exportError: String?
    @State private var shareURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.shield.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                        Text("Безопасный экспорт")
                            .font(.headline)
                    }
                    Text("Экспорт содержит типы и время событий, коды ошибок и данные сборки. Произвольный текст событий и метаданные исключены.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            Section("Что войдёт") {
                LabeledContent("Журнал событий", value: "\(logManager.entries.count) записей")
                LabeledContent("Данные сборки", value: "Доступны")
                LabeledContent("Формат", value: "JSONL")
                LabeledContent("Медиа-адреса", value: "Исключены")
            }

            Section("Что исключено") {
                HStack {
                    Text("Пароли, токены, cookies")
                    Spacer()
                    Text("Всегда").bold().foregroundColor(.green)
                }
                HStack {
                    Text("Полные ссылки с query")
                    Spacer()
                    Text("Всегда").bold().foregroundColor(.green)
                }
                HStack {
                    Text("Названия личных медиа")
                    Spacer()
                    Text("Всегда").bold().foregroundColor(.green)
                }
                HStack {
                    Text("Локальные пути")
                    Spacer()
                    Text("Всегда").bold().foregroundColor(.green)
                }
            }

            Section {
                Button(action: prepareArchive) {
                    HStack {
                        Spacer()
                        if isPreparing {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Подготовка…")
                        } else {
                            Image(systemName: "square.and.arrow.up")
                            Text("Поделиться журналом")
                                .bold()
                        }
                        Spacer()
                    }
                }
                .disabled(isPreparing)
            }

            if let err = exportError {
                Section {
                    Text("Ошибка: \(err)")
                        .foregroundColor(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Безопасный экспорт")
        .sheet(isPresented: $showShareSheet, onDismiss: {
            if let url = shareURL { try? FileManager.default.removeItem(at: url) }
            shareURL = nil
        }) {
            if let url = shareURL { DiagnosticsShareSheet(activityItems: [url]) }
        }
    }

    @MainActor private func prepareArchive() {
        isPreparing = true
        exportError = nil

        do {
            shareURL = try logManager.exportDiagnosticsJSONL()
            isPreparing = false
            showShareSheet = true
        } catch {
            isPreparing = false
            exportError = "Не удалось создать файл. Проверьте свободное место и попробуйте снова."
        }
    }
}

/// Simple UIActivityViewController representable to share diagnostics ZIP.
struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
