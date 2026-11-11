import SwiftUI

/// Detailed drill-down view displaying technical diagnostic evidence for a single plugin.
struct PluginLabPluginDetailView: View {
    let item: PluginLabItem
    @State private var evidence: PluginDiagnosticEvidence?

    var body: some View {
        Form {
            // MARK: - Verdict Section
            Section("ВЕРДИКТ СОВМЕСТИМОСТИ") {
                LabeledContent("Статус") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.status.color)
                            .frame(width: 8, height: 8)
                        Text(item.status.rawValue)
                            .bold()
                            .foregroundColor(item.status.color)
                    }
                }

                LabeledContent("Уверенность", value: item.confidence.displayName)

                if let cause = item.primaryRootCause {
                    LabeledContent("Причина сбоя", value: cause.displayName)
                }

                if let summary = item.failureSummary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Диагностическое заключение")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                    .padding(.vertical, 2)
                }
            }

            // MARK: - UI & Components
            if let ev = evidence, !ev.uiComponents.isEmpty {
                Section("ИНТЕРФЕЙСНЫЕ КОМПОНЕНТЫ") {
                    ForEach(ev.uiComponents) { comp in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(comp.name)
                                    .font(.headline)
                                Spacer()
                                Text(comp.nativeActionStatus)
                                    .font(.caption.bold())
                                    .foregroundColor(comp.hasNativeRenderer ? .green : .orange)
                            }

                            if !comp.missingActions.isEmpty {
                                Text("Отсутствуют нативные действия: \(comp.missingActions.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }

                            if !comp.platformDependencies.isEmpty {
                                Text("Платформенные запросы: \(comp.platformDependencies.joined(separator: ", "))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            // MARK: - API Coverage
            if let ev = evidence, !ev.apiCoverage.isEmpty {
                Section("ПОКРЫТИЕ LAMPA API") {
                    ForEach(ev.apiCoverage.filter { $0.isReferenced || $0.isUsedAtRuntime }) { api in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(api.apiName)
                                    .font(.subheadline.bold())
                                if let note = api.note {
                                    Text(note)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: api.isSupported ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(api.isSupported ? .green : .red)
                        }
                    }
                }
            }

            // MARK: - Metadata Section
            Section("МЕТАДАННЫЕ ПЛАГИНА") {
                LabeledContent("Название", value: item.name)
                LabeledContent("Источник", value: item.origin.displayName)
                LabeledContent("URL", value: item.url)
                if let author = item.author {
                    LabeledContent("Автор", value: author)
                }
                if let bytes = item.byteCount {
                    LabeledContent("Размер", value: "\(bytes) байт")
                }
                if let sha = item.sha256 {
                    LabeledContent("SHA-256", value: String(sha.prefix(16)) + "...")
                }
                if let duration = item.downloadDurationMs {
                    LabeledContent("Время загрузки", value: String(format: "%.1f мс", duration))
                }
            }

            // MARK: - Timeline Section
            if let ev = evidence, !ev.timeline.isEmpty {
                Section("ХРОНОЛОГИЯ ТЕСТА") {
                    ForEach(ev.timeline) { evt in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(evt.category)
                                    .font(.caption.bold())
                                    .foregroundColor(evt.level == "ERROR" ? .red : (evt.level == "SUCCESS" ? .green : .blue))
                                Spacer()
                                Text(evt.stage)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Text(evt.message)
                                .font(.footnote)
                                .foregroundColor(.primary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            self.evidence = PluginDiagnosticsRecorder.shared.getEvidence(for: item.id)
        }
    }
}
