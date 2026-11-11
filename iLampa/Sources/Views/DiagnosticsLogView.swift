import SwiftUI
import UIKit

// MARK: - Log Viewer Subview (`logviewer`, `logevent`)

struct LogViewerSubView: View {
    var initialFilter: String?

    @ObservedObject private var logManager = DiagnosticsLogManager.shared
    @State private var filterQuery = ""
    @State private var selectedLevel: String = "ALL"
    @State private var isFrozen = false
    @State private var frozenEntries: [DiagnosticLogEntry] = []
    @State private var pendingCount = 0
    @State private var selectedEntryForDetail: DiagnosticLogEntry?

    private var activeEntries: [DiagnosticLogEntry] {
        isFrozen ? frozenEntries : logManager.entries
    }

    private var filteredEntries: [DiagnosticLogEntry] {
        var list = activeEntries
        if selectedLevel != "ALL" {
            list = list.filter { $0.level.rawValue == selectedLevel }
        }
        let q = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            list = list.filter {
                $0.message.localizedCaseInsensitiveContains(q) ||
                $0.category.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search Bar & Filter Controls
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Поиск по тексту или категории...", text: $filterQuery)
                    .font(.subheadline)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if !filterQuery.isEmpty {
                    Button(action: { filterQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Severity Level Picker
            Picker("Уровень", selection: $selectedLevel) {
                Text("Все").tag("ALL")
                Text("Ошибки").tag("ERROR")
                Text("Предупреждения").tag("WARN")
                Text("Информация").tag("INFO")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            // Freeze Scroll Banner (Prevents shifting content under user's finger)
            HStack {
                Button(action: {
                    if isFrozen {
                        isFrozen = false
                        pendingCount = 0
                    } else {
                        isFrozen = true
                        frozenEntries = logManager.entries
                        pendingCount = 0
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: isFrozen ? "pause.circle.fill" : "play.circle")
                        Text(isFrozen ? "Лента остановлена" : "Лента активна")
                            .font(.caption.bold())
                    }
                    .foregroundColor(isFrozen ? .orange : .blue)
                }

                Spacer()

                if isFrozen && pendingCount > 0 {
                    Button(action: {
                        frozenEntries = logManager.entries
                        pendingCount = 0
                    }) {
                        Text("Новые события: +\(pendingCount)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(UIColor.secondarySystemGroupedBackground))

            Divider()

            // Structured Records List
            if filteredEntries.isEmpty {
                Spacer()
                Text("Нет подходящих записей")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                Spacer()
            } else {
                List {
                    ForEach(filteredEntries) { entry in
                        Button(action: {
                            selectedEntryForDetail = entry
                        }) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(entry.formattedTime)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)

                                    Text(entry.level.rawValue)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(levelColor(entry.level).opacity(0.15))
                                        .foregroundColor(levelColor(entry.level))
                                        .cornerRadius(3)

                                    Text(entry.category)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.primary)

                                    Spacer()

                                    if entry.actionId != nil {
                                        Image(systemName: "link")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                    }
                                }

                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Журнал событий")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = filteredEntries
                        .map(\.fullLine).joined(separator: "\n")
                } label: {
                    Label("Скопировать видимые записи", systemImage: "doc.on.doc")
                }
                .disabled(filteredEntries.isEmpty)
                .accessibilityIdentifier("copyVisibleDiagnostics")
            }
        }
        .sheet(item: $selectedEntryForDetail) { entry in
            LogEventDetailSheet(entry: entry)
        }
        .onAppear {
            if let f = initialFilter {
                selectedLevel = f
            }
        }
        .onChange(of: logManager.entries.count) { _, newCount in
            if isFrozen {
                pendingCount = max(0, newCount - frozenEntries.count)
            }
        }
    }

    private func levelColor(_ level: DiagnosticLogEntry.LogLevel) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }
}

// MARK: - Single Log Event Detail Sheet (`logevent`, `logtechnical`)

struct LogEventDetailSheet: View {
    let entry: DiagnosticLogEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Событие") {
                    LabeledContent("Время", value: entry.formattedTime)
                    LabeledContent("Уровень", value: entry.level.rawValue)
                    LabeledContent("Подсистема", value: entry.category)
                    if let act = entry.actionId {
                        LabeledContent("Корреляция", value: act.uuidString)
                    } else {
                        LabeledContent("Связь", value: "Связь не установлена")
                    }
                }

                Section("Сообщение") {
                    Text(entry.message)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                if !entry.metadata.isEmpty {
                    Section("Метаданные") {
                        ForEach(Array(entry.metadata.keys.sorted()), id: \.self) { k in
                            LabeledContent(k, value: entry.metadata[k] ?? "")
                                .font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Детали события")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

