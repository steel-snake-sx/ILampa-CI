import SwiftUI

/// Sorting modes for resolved media candidates conforming to the iLampa Final Design Lock
enum SourceSortMode: String, CaseIterable, Identifiable {
    case recommended = "recommended"
    case quality = "quality"
    case studio = "studio"
    case provider = "provider"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recommended: return "Рекомендуемые"
        case .quality: return "По качеству"
        case .studio: return "По озвучке"
        case .provider: return "По провайдеру"
        }
    }
}

/// Compact native Source & Episode Picker conforming strictly to the iLampa Final Design Lock:
/// - Baseline iPhone XS: 375 pt logical width
/// - Three equal-width non-scrolling facet buttons: Качество, Озвучка, Источник (>= 44pt high, >= 90pt wide)
/// - Independent full-width sorting row below facets
/// - Explicit episode identity pinning (e.g. 2×03 for series)
/// - Asynchronous candidate stability: "Новые варианты N" pill to prevent moving rows under finger
/// - Honest confidence status (advertised vs verified)
struct SourcePickerSheetView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let mediaTitle: String
    let canonicalId: String
    let mediaType: String
    let season: Int?
    let episode: Int?
    let initialSources: [ResolvedMediaSource]
    var onSelect: (ResolvedMediaSource) -> Void
    var onNavigate: (ResolvedMediaSource) async -> Result<[ResolvedMediaSource], SourceNavigationError>
    var onRestart: () async -> [ResolvedMediaSource]
    var onCancelNavigation: () -> Void
    var onConfigureSources: () -> Void
    var onViewLogs: () -> Void
    var onDismiss: () -> Void

    @State private var displayedSources: [ResolvedMediaSource] = []
    @State private var pendingSources: [ResolvedMediaSource]? = nil
    @State private var hasInitializedSources = false
    @State private var navigationGeneration = UUID()
    @State private var navigationTask: Task<Void, Never>?
    @State private var handingOff = false
    @State private var navigationState: NavigationState = .root
    @State private var unsupportedAlternative: ResolvedMediaSource?

    private enum NavigationState {
        case root, loading, children, empty, error(String)
    }

    @State private var selectedQuality: String? = nil
    @State private var selectedStudio: String? = nil
    @State private var selectedProvider: String? = nil
    @State private var selectedSortMode: SourceSortMode = .recommended

    @State private var showQualitySheet = false
    @State private var showStudioSheet = false
    @State private var showProviderSheet = false
    @State private var showSortingSheet = false

    private var isTv: Bool {
        mediaType == "tv"
    }

    private var episodeIdentityText: String? {
        if isTv, let s = season, let e = episode {
            return "Сезон \(s), Серия \(e) (\(s)×\(e < 10 ? "0\(e)" : "\(e)"))"
        }
        return nil
    }

    // MARK: - Facet Options Extracted from Current Sources

    private var availableQualities: [String] {
        let set = Set(displayedSources.map { qualityLabel($0.quality) })
        return ["Все"] + Array(set).sorted {
            let lhs = qualityRank($0), rhs = qualityRank($1)
            return lhs == rhs ? $0.localizedStandardCompare($1) == .orderedAscending : lhs > rhs
        }
    }

    private var availableStudios: [String] {
        let set = Set(displayedSources.map { $0.studioName.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return ["Любая"] + Array(set).sorted()
    }

    private var availableProviders: [String] {
        let set = Set(displayedSources.map { $0.providerName.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return ["Все"] + Array(set).sorted()
    }

    // MARK: - Filtered & Sorted Candidates Snapshot

    private var filteredAndSortedSources: [ResolvedMediaSource] {
        var list = displayedSources

        // Filter 1: Quality
        if let q = selectedQuality, q != "Все" {
            list = list.filter { qualityLabel($0.quality).caseInsensitiveCompare(q) == .orderedSame }
        }

        // Filter 2: Studio / Voiceover
        if let s = selectedStudio, s != "Любая" {
            list = list.filter { $0.studioName.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(s) == .orderedSame }
        }

        // Filter 3: Provider
        if let p = selectedProvider, p != "Все" {
            list = list.filter { $0.providerName.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(p) == .orderedSame }
        }

        // Independent Sorting
        return list.enumerated().sorted { lhs, rhs in
            let order: ComparisonResult
            switch selectedSortMode {
            case .recommended:
                order = .orderedSame
            case .quality:
                let left = qualityRank(lhs.element.quality), right = qualityRank(rhs.element.quality)
                order = left == right ? .orderedSame : (left > right ? .orderedAscending : .orderedDescending)
            case .studio:
                order = lhs.element.studioName.localizedStandardCompare(rhs.element.studioName)
            case .provider:
                order = lhs.element.providerName.localizedStandardCompare(rhs.element.providerName)
            }
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }

    private func qualityRank(_ q: String) -> Int {
        let lower = q.lowercased()
        if lower.contains("4k") || lower.contains("2160") { return 4 }
        if lower.contains("1080") { return 3 }
        if lower.contains("720") { return 2 }
        if lower.contains("480") { return 1 }
        return 0
    }

    private func qualityLabel(_ quality: String) -> String {
        let trimmed = quality.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?i)^(auto|4k|(?:360|480|576|720|1080|1440|2160)p?)(?:\s*[-–/~]\s*(?:360|480|576|720|1080|1440|2160)p?)*$"#
        return trimmed.range(of: pattern, options: .regularExpression) == nil ? "Неизвестно" : trimmed
    }

    private func sourceRow(_ src: ResolvedMediaSource) -> some View {
        let quality = qualityLabel(src.quality)
        let qualityText = quality == "Неизвестно" ? "Качество неизвестно" : "Качество: \(quality) · заявлено"
        let statusText: String
        if src.isAlternativeTitle { statusText = "Выбор пока недоступен" }
        else if src.isNavigationFolder { statusText = "Раздел · открыть" }
        else if src.streamUrl.isEmpty { statusText = "Источник найден · поток не проверен" }
        else { statusText = "Поток получен · воспроизведение не проверено" }
        return Button(action: {
            if src.isAlternativeTitle { unsupportedAlternative = src }
            else if src.isNavigationFolder { openFolder(src) }
            else if !handingOff { handingOff = true; onSelect(src) }
        }) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(src.providerName).font(.body.bold()).foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !src.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(src.title).font(.subheadline).foregroundColor(.primary)
                    }
                    if src.isAlternativeTitle {
                        Text("Другое произведение · идентификатор не подтверждён")
                            .font(.caption.bold()).foregroundColor(.orange)
                        if !src.quality.isEmpty && src.quality != "----" {
                            Text("Год: \(src.quality)").font(.caption).foregroundColor(.secondary)
                        }
                    } else if !src.studioName.isEmpty {
                        Text(src.studioName).font(.subheadline).foregroundColor(.secondary)
                    } else {
                        Text("Озвучка неизвестна").font(.subheadline).foregroundColor(.secondary)
                    }
                    if !src.isAlternativeTitle {
                        Text(qualityText).font(.caption).foregroundColor(.secondary)
                    }
                    Text(statusText).font(.caption).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: src.isNavigationFolder ? "folder" : (src.streamUrl.isEmpty ? "chevron.right.circle" : "play.circle.fill"))
                    .font(.title2).foregroundColor(.blue)
            }.padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sourceRow_\(src.id)")
    }

    private var pickerContent: some View {
            VStack(spacing: 0) {
                // MARK: - Episode Identity Header (Pinned 2×03 for TV)
                if let epText = episodeIdentityText {
                    HStack(spacing: 6) {
                        Image(systemName: "tv")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text(epText)
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                        Spacer()
                        Text(mediaTitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    Divider()
                } else {
                    Text(mediaTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }

                // MARK: - Row 1: Three Equal-Width Facet Controls (iPhone XS Baseline)
                let facetLayout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
                facetLayout {
                    FacetButton(
                        title: "Качество",
                        value: selectedQuality ?? "Все",
                        accessibilityId: "facet_quality"
                    ) {
                        showQualitySheet = true
                    }

                    FacetButton(
                        title: "Озвучка",
                        value: selectedStudio ?? "Любая",
                        accessibilityId: "facet_studio"
                    ) {
                        showStudioSheet = true
                    }

                    FacetButton(
                        title: "Источник",
                        value: selectedProvider ?? "Все",
                        accessibilityId: "facet_provider"
                    ) {
                        showProviderSheet = true
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

                // MARK: - Row 2: Single Full-Width Independent Sorting Row
                Button(action: {
                    showSortingSheet = true
                }) {
                    HStack {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("Сортировка — \(selectedSortMode.displayName)")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(10)
                }
                .accessibilityIdentifier("picker_sorting_button")
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // MARK: - Async Updates Floating Pill ("Новые варианты N")
                if let pending = pendingSources {
                    Button(action: applyPendingSources) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            let existingIDs = Set(displayedSources.map(\.id))
                            let newCount = pending.filter { !existingIDs.contains($0.id) }.count
                            Text(newCount > 0 ? "Новые варианты: \(newCount)" : "Обновить варианты")
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                        .shadow(radius: 3)
                    }
                    .padding(.bottom, 6)
                }

                Divider()

                // MARK: - Candidates List
                let candidates = filteredAndSortedSources
                if case .loading = navigationState {
                    Spacer()
                    ProgressView("Открываем источник…")
                    Spacer()
                } else if case .error(let message) = navigationState {
                    Spacer()
                    Text(message).multilineTextAlignment(.center).padding()
                    Button("Начать поиск заново", action: restartNavigation)
                    Spacer()
                } else if case .empty = navigationState {
                    Spacer()
                    Text("В этом разделе нет доступных вариантов.")
                    Button("Начать поиск заново", action: restartNavigation).padding()
                    Spacer()
                } else if candidates.isEmpty {
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "film.stack")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Варианты с выбранными фильтрами не найдены")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button("Сбросить фильтры") {
                            selectedQuality = nil
                            selectedStudio = nil
                            selectedProvider = nil
                        }
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                        Spacer()
                    }
                    .padding(24)
                } else {
                    List {
                        ForEach(candidates) { src in
                            sourceRow(src)
                        }
                    }
                    .listStyle(.plain)
                }
            }
    }

    var body: some View {
        NavigationStack {
            pickerContent
            .navigationTitle("Выбор источника")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") {
                        cancelNavigation()
                        onDismiss()
                    }
                    .accessibilityIdentifier("cancelSourceSelectionButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Настроить источники") {
                            handingOff = true
                            onConfigureSources()
                        }
                        Button("Журнал диагностики") {
                            handingOff = true
                            onViewLogs()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Действия с источниками")
                }
                ToolbarItem(placement: .bottomBar) {
                    if case .root = navigationState { EmptyView() } else {
                        Button("К исходным результатам", action: restartNavigation)
                    }
                }
            }
            .onAppear {
                if !hasInitializedSources {
                    displayedSources = initialSources
                    hasInitializedSources = true
                }
            }
            .onChange(of: initialSources) { sources in
                guard hasInitializedSources else { return }
                guard case .root = navigationState else { return }
                if displayedSources.isEmpty {
                    displayedSources = sources
                    pendingSources = nil
                } else {
                    pendingSources = sources == displayedSources ? nil : sources
                }
            }
            .onDisappear {
                navigationTask?.cancel()
                navigationGeneration = UUID()
                if !handingOff { onCancelNavigation() }
            }
            .alert("Другое произведение", isPresented: Binding(
                get: { unsupportedAlternative != nil },
                set: { if !$0 { unsupportedAlternative = nil } }
            )) {
                Button("Вернуться", role: .cancel) { unsupportedAlternative = nil }
            } message: {
                Text("«\(unsupportedAlternative?.title ?? "")» может быть другим произведением. Плагин пока не позволяет безопасно связать поток и историю с этим выбором. Вернитесь к исходным результатам или найдите нужную карточку в каталоге.")
            }
            // Facet Selection Sheets
            .confirmationDialog("Качество", isPresented: $showQualitySheet, titleVisibility: .visible) {
                ForEach(availableQualities, id: \.self) { q in
                    Button(q) { selectedQuality = q == "Все" ? nil : q }
                }
            }
            .confirmationDialog("Озвучка", isPresented: $showStudioSheet, titleVisibility: .visible) {
                ForEach(availableStudios, id: \.self) { s in
                    Button(s) { selectedStudio = s == "Любая" ? nil : s }
                }
            }
            .confirmationDialog("Источник", isPresented: $showProviderSheet, titleVisibility: .visible) {
                ForEach(availableProviders, id: \.self) { p in
                    Button(p) { selectedProvider = p == "Все" ? nil : p }
                }
            }
            .confirmationDialog("Сортировка", isPresented: $showSortingSheet, titleVisibility: .visible) {
                ForEach(SourceSortMode.allCases) { mode in
                    Button(mode.displayName) { selectedSortMode = mode }
                }
            }
        }
    }

    private func applyPendingSources() {
        guard let pendingSources else { return }
        displayedSources = pendingSources
        self.pendingSources = nil
    }

    private func cancelNavigation() {
        navigationGeneration = UUID()
        navigationTask?.cancel()
        onCancelNavigation()
    }

    private func openFolder(_ source: ResolvedMediaSource) {
        navigationTask?.cancel()
        let generation = UUID()
        navigationGeneration = generation
        displayedSources = []
        pendingSources = nil
        navigationState = .loading
        navigationTask = Task {
            let result = await onNavigate(source)
            guard !Task.isCancelled, navigationGeneration == generation else { return }
            switch result {
            case .success(let children):
                displayedSources = children
                selectedQuality = nil; selectedStudio = nil; selectedProvider = nil
                navigationState = children.isEmpty ? .empty : .children
            case .failure(let error): navigationState = .error(error.message)
            }
        }
    }

    private func restartNavigation() {
        navigationTask?.cancel()
        let generation = UUID()
        navigationGeneration = generation
        displayedSources = []
        pendingSources = nil
        navigationState = .loading
        navigationTask = Task {
            let sources = await onRestart()
            guard !Task.isCancelled, navigationGeneration == generation else { return }
            displayedSources = sources
            selectedQuality = nil; selectedStudio = nil; selectedProvider = nil
            navigationState = sources.isEmpty ? .empty : .root
        }
    }
}

struct SourceNavigationError: Error {
    let message: String
}

/// Equal-width facet button conforming to minimum 44pt touch target and 90pt width constraints
private struct FacetButton: View {
    let title: String
    let value: String
    let accessibilityId: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text(value)
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(10)
        }
        .accessibilityIdentifier(accessibilityId)
        .accessibilityLabel("\(title): \(value)")
        .accessibilityHint("Выбрать фильтр")
        .buttonStyle(.plain)
    }
}

/// Stream resolution failure view conforming to canonical `resolvefailure` screen
struct ResolveFailureView: View {
    let mediaTitle: String
    let identitySubtitle: String?
    let errorMessage: String
    var otherOptionTitle: String = "Другой вариант"
    var onRetry: () -> Void
    var onChooseAnotherSource: () -> Void
    var onConfigureSources: () -> Void
    var onViewLogs: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.red)

                    Text("Поток недоступен")
                        .font(.title2.bold())

                    if let idText = identitySubtitle {
                        Text(idText)
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                    }

                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Actionable recovery buttons
                VStack(spacing: 12) {
                    Button(action: onRetry) {
                        HStack {
                            Spacer()
                            Label("Повторить", systemImage: "arrow.clockwise")
                                .font(.headline)
                            Spacer()
                        }
                        .frame(height: 50)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .accessibilityIdentifier("retryResolutionButton")

                    Button(action: onChooseAnotherSource) {
                        HStack {
                            Spacer()
                            Label(otherOptionTitle, systemImage: "list.bullet")
                                .font(.headline)
                            Spacer()
                        }
                        .frame(height: 50)
                        .background(Color(UIColor.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                    .accessibilityIdentifier("chooseAnotherSourceButton")

                    Button(action: onConfigureSources) {
                        HStack {
                            Spacer()
                            Label("Настроить источник", systemImage: "gearshape")
                                .font(.headline)
                            Spacer()
                        }
                        .frame(height: 50)
                        .background(Color(UIColor.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(12)
                    }
                    .accessibilityIdentifier("configureSourceRecoveryButton")

                    Button(action: onViewLogs) {
                        Label("Журнал ошибки", systemImage: "stethoscope")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                    .accessibilityIdentifier("viewLogsRecoveryButton")
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") {
                        onDismiss()
                    }
                }
            }
        }
    }
}
