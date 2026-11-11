import SwiftUI
import UIKit

/// The single import workflow: input, review, installation and results.
enum BatchImportStage: Equatable {
    case input
    case review
    case installing
    case results
}

/// Modal view providing transactional batch installation of plugins from multiline input.
/// Guarantees:
/// - Exact non-blank line counting (e.g. 20 addresses)
/// - Keyboard-dismissal via toolbar Done, scroll, and outside tap
/// - Zero-selection installation lock (disabled install button)
/// - Candidates start unselected
/// - Default-disabled installed plugins
/// - Distinct cancel and partial failure results
/// - Preservation of input text on navigation back
struct BatchImportModalView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var pluginManager = PluginManager.shared

    @State private var currentStage: BatchImportStage = .input
    @State private var rawText = ""
    @State private var inputRevision = 0
    @State private var analysisRevision = 0

    @State private var candidates: [BatchImportCandidate] = []
    @State private var selectedSnapshot: [BatchImportCandidate] = []
    @State private var executionResult: BatchImportResult? = nil

    @State private var progressCompleted = 0
    @State private var progressTotal = 0
    @State private var currentInstallingUrl = ""
    @State private var cancelRequested = false
    @State private var installTask: Task<Void, Never>? = nil

    @FocusState private var isInputFocused: Bool

    // MARK: - Computed Counts

    private var nonEmptyLineCount: Int {
        rawText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .count
    }

    private var selectedCount: Int {
        candidates.filter { $0.isSelectedForInstall && $0.isInstallable }.count
    }

    private var validCandidatesCount: Int {
        candidates.filter { $0.isInstallable }.count
    }

    private var duplicateCount: Int {
        candidates.filter {
            if case .duplicate = $0.status { return true }
            return false
        }.count
    }

    private var rejectedCount: Int {
        candidates.filter {
            if case .unsupportedWebpage = $0.status { return true }
            if case .invalid = $0.status { return true }
            if case .directMediaStream = $0.status { return true }
            if case .providerEndpoint = $0.status { return true }
            return false
        }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                switch currentStage {
                case .input:
                    stageInputView
                case .review:
                    stageReviewView
                case .installing:
                    stageInstallingView
                case .results:
                    stageResultsView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                toolbarContent
            }
        }
    }

    // MARK: - Stage 1: Input (`importinput`, `importkeyboard`)

    private var stageInputView: some View {
        VStack(spacing: 0) {
            // Header Info Pill
            HStack {
                Label("Ввод ссылок", systemImage: "doc.text")
                    .font(.subheadline.bold())
                Spacer()
                Text(nonEmptyLineCount == 1 ? "1 адрес" : "\(nonEmptyLineCount) адресов")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.12))
                    .foregroundColor(.blue)
                    .cornerRadius(8)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Multiline Editor
            ZStack(alignment: .topLeading) {
                if rawText.isEmpty {
                    Text("Ссылки на JS-плагины — по одной на строку\nhttps://example.org/plugin.js")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.7))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $rawText)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .foregroundStyle(.primary)
                    .tint(.blue)
                    .focused($isInputFocused)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("batchImportTextEditor")
                    .onChange(of: rawText) { _, _ in
                        inputRevision += 1
                        if analysisRevision != inputRevision {
                            candidates = []
                            executionResult = nil
                        }
                    }
            }
            .frame(height: 235)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .padding(.horizontal, 16)

            // Input actions
            HStack {
                Button {
                    if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty {
                        rawText = clipboard
                        isInputFocused = false
                    }
                } label: {
                    Label("Вставить из буфера", systemImage: "doc.on.clipboard")
                }
                .font(.footnote)
                Spacer()

                if !rawText.isEmpty {
                    Button("Очистить") {
                        rawText = ""
                        inputRevision += 1
                        candidates = []
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Spacer(minLength: 8)

            // Pinned Primary CTA (Above Keyboard / Safe Area)
            VStack(spacing: 4) {
                Button(action: analyzeAndProceedToReview) {
                    HStack {
                        Spacer()
                        Image(systemName: "checklist")
                        Text("Проверить \(nonEmptyLineCount) адресов")
                            .font(.headline)
                        Spacer()
                    }
                    .frame(height: 50)
                    .background(nonEmptyLineCount > 0 ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(nonEmptyLineCount == 0)
                .accessibilityIdentifier("analyzeBatchButton")

                Text("Плагины устанавливаются выключенными и не запускаются автоматически")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .navigationTitle("Импорт плагинов")
    }

    // MARK: - Stage 2: Review (`importreview`, `importselected`)

    private var stageReviewView: some View {
        VStack(spacing: 0) {
            // Metrics Summary Bar
            HStack(spacing: 8) {
                MetricPill(label: "Всего", value: "\(candidates.count)", color: .blue)
                MetricPill(label: "Готово", value: "\(validCandidatesCount)", color: .green)
                MetricPill(label: "Дубликаты", value: "\(duplicateCount)", color: .orange)
                MetricPill(label: "Отклонено", value: "\(rejectedCount)", color: .red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Select All / Deselect Controls
            HStack {
                Text("Выбрано: \(selectedCount) из \(validCandidatesCount)")
                    .font(.subheadline.bold())

                Spacer()

                Button("Выбрать все подходящие") {
                    for i in candidates.indices {
                        if candidates[i].isInstallable {
                            candidates[i].isSelectedForInstall = true
                        }
                    }
                }
                .font(.caption.bold())
                .foregroundColor(.blue)

                Text("•")
                    .foregroundColor(.secondary)

                Button("Снять выбор") {
                    for i in candidates.indices {
                        candidates[i].isSelectedForInstall = false
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(UIColor.secondarySystemGroupedBackground))

            Divider()

            // Scrollable Candidate List
            List {
                ForEach($candidates) { $candidate in
                    HStack(alignment: .top, spacing: 12) {
                        if candidate.isInstallable {
                            Button(action: {
                                candidate.isSelectedForInstall.toggle()
                            }) {
                                Image(systemName: candidate.isSelectedForInstall ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundColor(candidate.isSelectedForInstall ? .blue : .secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("candidate_toggle_\(candidate.id)")
                        } else {
                            Image(systemName: "nosign")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.displayTitle)
                                .font(.subheadline.monospaced())
                                .lineLimit(1)
                                .foregroundColor(candidate.isInstallable ? .primary : .secondary)

                            HStack(spacing: 6) {
                                CategoryBadge(categoryLabel: candidate.categoryLabel, status: candidate.status)
                            }

                            Text(candidate.statusDescription)
                                .font(.caption2)
                                .foregroundColor(candidate.isInstallable ? .secondary : .red)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)

            Divider()

            // Pinned Primary CTA (Zero-Selected Lock!)
            VStack(spacing: 4) {
                Button(action: startInstallingSelected) {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Установить \(selectedCount)")
                            .font(.headline)
                        Spacer()
                    }
                    .frame(height: 50)
                    .background(selectedCount > 0 ? Color.blue : Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(selectedCount == 0)
                .accessibilityIdentifier("executeBatchInstallButton")

                Text(selectedCount == 0 ? "Выберите хотя бы один плагин для установки" : "Выбранные плагины будут загружены и останутся отключенными")
                    .font(.caption2)
                    .foregroundColor(selectedCount == 0 ? .orange : .secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(UIColor.systemBackground))
        }
        .navigationTitle("Проверка ссылок")
    }

    // MARK: - Stage 3: Installing (`importing`)

    private var stageInstallingView: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 12) {
                ProgressView(value: Double(progressCompleted), total: Double(max(progressTotal, 1)))
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .padding(.horizontal, 32)

                Text("Установка: \(progressCompleted) из \(progressTotal)")
                    .font(.headline)

                if !currentInstallingUrl.isEmpty {
                    Text(currentInstallingUrl)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 32)
                }
            }

            // Summary of Progress
            VStack(spacing: 8) {
                HStack {
                    Text("В очереди:")
                    Spacer()
                    Text("\(max(0, progressTotal - progressCompleted))")
                        .bold()
                }
                Divider()
                HStack {
                    Text("Обработано:")
                    Spacer()
                    Text("\(progressCompleted)")
                        .bold()
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal, 32)

            Spacer()

            // Cancel Button
            Button(role: .cancel, action: requestCancelInstallation) {
                HStack {
                    Spacer()
                    Text("Отменить")
                        .font(.headline)
                    Spacer()
                }
                .frame(height: 50)
                .background(Color.red.opacity(0.12))
                .foregroundColor(.red)
                .cornerRadius(12)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .navigationTitle("Установка")
    }

    // MARK: - Stage 4: Results (`importpartial`, `importcomplete`, `importcanceled`)

    private var stageResultsView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Result Header Card
                    VStack(spacing: 10) {
                        Image(systemName: resultIconName)
                            .font(.system(size: 48))
                            .foregroundColor(resultHeaderColor)
                            .padding(.top, 8)

                        Text(resultTitle)
                            .font(.title3.bold())

                        Text(resultSubtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 12)

                    // Results Breakdown Card
                    if let res = executionResult {
                        VStack(spacing: 12) {
                            HStack {
                                Label("Установлено (отключены):", systemImage: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Spacer()
                                Text("\(res.installedSuccessfully.count)")
                                    .bold()
                            }

                            if !res.failedInstallations.isEmpty {
                                Divider()
                                HStack {
                                    Label("Ошибки установки:", systemImage: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                    Spacer()
                                    Text("\(res.failedInstallations.count)")
                                        .bold()
                                }

                                ForEach(Array(res.failedInstallations.keys.sorted()), id: \.self) { url in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(url)
                                            .font(.caption2.monospaced())
                                            .lineLimit(1)
                                        Text(res.failedInstallations[url] ?? "Ошибка")
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                    }
                                    .padding(.leading, 8)
                                }
                            }

                            if !res.canceledInstallations.isEmpty {
                                Divider()
                                HStack {
                                    Label("Отменено:", systemImage: "slash.circle.fill")
                                        .foregroundColor(.orange)
                                    Spacer()
                                    Text("\(res.canceledInstallations.count)")
                                        .bold()
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                    }

                    // Retry button for failures/canceled
                    if let res = executionResult, res.hasFailures || res.wasCanceled {
                        Button(action: retryFailedOrCanceled) {
                            Label("Повторить неудавшиеся", systemImage: "arrow.clockwise")
                                .font(.subheadline.bold())
                                .foregroundColor(.blue)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 16)
            }

            Divider()

            // Pinned Primary "Done" CTA
            Button(action: {
                dismiss()
            }) {
                HStack {
                    Spacer()
                    Text("Готово")
                        .font(.headline)
                    Spacer()
                }
                .frame(height: 50)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .navigationTitle(resultNavigationTitle)
    }

    // MARK: - Toolbar Items

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        switch currentStage {
        case .input:
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") {
                    isInputFocused = false
                }
                .bold()
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Отмена") {
                    dismiss()
                }
            }

        case .review:
            ToolbarItem(placement: .topBarLeading) {
                Button("Назад") {
                    // Navigate back to input preserving text and cursor
                    currentStage = .input
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Отмена") {
                    dismiss()
                }
            }

        case .installing:
            ToolbarItem(placement: .topBarTrailing) {
                Button("Отмена") {
                    requestCancelInstallation()
                }
            }

        case .results:
            ToolbarItem(placement: .topBarTrailing) {
                Button("Готово") {
                    dismiss()
                }
                .bold()
            }
        }
    }

    // MARK: - Actions & Business Logic

    private func analyzeAndProceedToReview() {
        isInputFocused = false
        analysisRevision = inputRevision
        let installedUrls = Set(pluginManager.installedPlugins.map { $0.url.absoluteString })
        let parsed = BatchPluginImporter.shared.parse(rawText: rawText, currentlyInstalledUrls: installedUrls)
        self.candidates = parsed
        self.currentStage = .review
    }

    private func startInstallingSelected() {
        let selected = candidates.filter { $0.isSelectedForInstall && $0.isInstallable }
        guard !selected.isEmpty else { return }

        self.selectedSnapshot = selected
        self.progressCompleted = 0
        self.progressTotal = selected.count
        self.cancelRequested = false
        self.currentStage = .installing

        installTask = Task {
            let result = await BatchPluginImporter.shared.executeBatchInstall(
                candidates: selected,
                isCancelled: { self.cancelRequested },
                onProgress: { completed, total in
                    Task { @MainActor in
                        self.progressCompleted = completed
                        self.progressTotal = total
                    }
                }
            )

            await MainActor.run {
                self.executionResult = result
                self.currentStage = .results
            }
        }
    }

    private func requestCancelInstallation() {
        cancelRequested = true
        installTask?.cancel()
    }

    private func retryFailedOrCanceled() {
        guard let res = executionResult else { return }
        let failedUrls = Set(res.failedInstallations.keys).union(res.canceledInstallations)
        let installedUrls = Set(pluginManager.installedPlugins.map { BatchPluginImporter.shared.normalizeUrl($0.url) })
        for i in candidates.indices {
            if let clean = candidates[i].cleanUrl, failedUrls.contains(clean), !installedUrls.contains(clean), candidates[i].isInstallable {
                candidates[i].isSelectedForInstall = true
            } else {
                candidates[i].isSelectedForInstall = false
            }
        }
        if selectedCount > 0 {
            startInstallingSelected()
        } else {
            analyzeAndProceedToReview()
        }
    }

    private func insertSample20Urls() {
        rawText = """
        https://tsynik.github.io/lampa/soma.js
        https://tsynik.github.io/lampa/e.js
        https://bwa.ad/rc
        https://nb557.github.io/plugins/rating.js
        https://plugin.root/online_mod.js
        https://tsynik.github.io/lampa/soma.js
        https://example.org/plugin/fx.js
        https://example.org/plugin/fx.js
        https://devstreaming-cdn.apple.com/sample.m3u8
        https://example.org/stream/sample.mp4
        https://google.com
        https://youtube.com/watch?v=123
        https://kinopoisk.ru/film/12345/
        https://wikipedia.org/wiki/Swift
        https://example.com/invalid url with spaces
        ftp://invalid-protocol.org/test.js
        https://example.org/plugin/cinema.js
        https://example.org/plugin/shows.js
        https://bwa.ad/rc/v2
        https://example.org/plugin/last.js
        """
        inputRevision += 1
    }

    // MARK: - Results Presentation Helpers

    private var resultNavigationTitle: String {
        guard let res = executionResult else { return "Результаты" }
        switch res.outcome {
        case .complete: return "Установка завершена"
        case .partial: return "Часть плагинов не установлена"
        case .canceled: return "Установка отменена"
        }
    }

    private var resultTitle: String {
        resultNavigationTitle
    }

    private var resultSubtitle: String {
        guard let res = executionResult else { return "" }
        switch res.outcome {
        case .complete:
            return "Все \(res.installedSuccessfully.count) выбранных плагинов успешно сохранены на устройстве. Они остаются выключенными по умолчанию."
        case .partial:
            return "Успешно установлено: \(res.installedSuccessfully.count). Ошибок: \(res.failedInstallations.count). Установленные плагины выключены."
        case .canceled:
            return "Операция была прервана пользователем. Успешно установлено: \(res.installedSuccessfully.count), отменено: \(res.canceledInstallations.count)."
        }
    }

    private var resultHeaderColor: Color {
        guard let res = executionResult else { return .blue }
        switch res.outcome {
        case .complete: return .green
        case .partial: return .orange
        case .canceled: return .secondary
        }
    }

    private var resultIconName: String {
        guard let res = executionResult else { return "info.circle" }
        switch res.outcome {
        case .complete: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .canceled: return "slash.circle.fill"
        }
    }
}

// MARK: - Metric Pill & Badges

private struct MetricPill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

private struct CategoryBadge: View {
    let categoryLabel: String
    let status: BatchCandidateStatus

    var body: some View {
        Text(categoryLabel)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeBackgroundColor)
            .foregroundColor(badgeForegroundColor)
            .cornerRadius(4)
    }

    private var badgeBackgroundColor: Color {
        switch status {
        case .pluginScript: return Color.blue.opacity(0.15)
        case .directMediaStream: return Color.green.opacity(0.15)
        case .providerEndpoint: return Color.purple.opacity(0.15)
        case .unsupportedWebpage: return Color.red.opacity(0.15)
        case .duplicate: return Color.orange.opacity(0.15)
        case .invalid: return Color.gray.opacity(0.15)
        }
    }

    private var badgeForegroundColor: Color {
        switch status {
        case .pluginScript: return .blue
        case .directMediaStream: return .green
        case .providerEndpoint: return .purple
        case .unsupportedWebpage: return .red
        case .duplicate: return .orange
        case .invalid: return .secondary
        }
    }
}
