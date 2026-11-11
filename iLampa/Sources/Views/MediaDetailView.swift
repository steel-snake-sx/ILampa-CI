import SwiftUI

enum SourceResolutionIntentPolicy {
    /// View reappearance is not a source-refresh request. A different typed context is.
    static func shouldStartAutomaticResolution(lastContext: String?, nextContext: String) -> Bool {
        lastContext != nextContext
    }

    static func isCurrentResult(requestId: UUID, currentRequestId: UUID,
                                context: String, currentContext: String, isCancelled: Bool) -> Bool {
        !isCancelled && requestId == currentRequestId && context == currentContext
    }
}

// Catalog identity and explicit source discovery, with optional catalog details.
@MainActor
struct MediaDetailView: View {
    let item: MediaItem
    var onPlayRequest: (PlayPayload) -> Void

    @StateObject private var favoritesManager = FavoritesManager.shared
    @StateObject private var pluginManager = PluginManager.shared
    @ObservedObject private var metadataHost = LampaHeadlessHost.shared
    @State private var metadataRequestId: String?
    @AppStorage(DeveloperMode.preferenceKey) private var developerModeEnabled = false
    @State private var detail: MediaDetail?
    @State private var isLoading = true
    @State private var selectedSeason: Int = 1
    @State private var selectedEpisode: Int = 1
    @State private var pendingEpisodePlaybackContext: String?
    @State private var showEpisodes = false

    @State private var isResolvingSources = false
    @State private var availableSources: [ResolvedMediaSource] = []
    @State private var showSourceSelectionSheet = false
    @State private var showResolveFailureSheet = false
    @State private var showNoSourcesAlert = false
    @State private var showSourcesManagementSheet = false
    @State private var showDiagnosticsSheet = false
    @State private var showLampaWebSheet = false
    @State private var showPluginsSheet = false
    @State private var pickerFollowup: PickerFollowup?
    @State private var failureFollowup: FailureFollowup?
    @State private var reopenPickerAfterConfiguration = false
    @State private var reopenPickerAfterDiagnostics = false
    @State private var noSourcesMessage = ""
    @State private var onlineModActivationError: String?

    private enum PickerFollowup { case sources, diagnostics, play(ResolvedMediaSource) }
    private enum FailureFollowup { case retry, picker, sources, diagnostics, lampa, activateOnlineMod }

    @State private var currentResolutionTask: Task<Void, Never>? = nil
    @State private var currentRequestId = UUID()
    @State private var resolvedContext: String?
    // A SwiftUI reappearance is not a user retry. Preserve the last automatic intent,
    // including an honest empty result, until media/season/episode changes or Refresh is used.
    @State private var lastAutomaticResolutionContext: String?

    private var selectedContext: String {
        "\(item.canonicalId)|\(item.canonicalType == "tv" ? String(selectedSeason) : "none")|\(item.canonicalType == "tv" ? String(selectedEpisode) : "none")"
    }

    private var onlineModIsEnabled: Bool {
        pluginManager.installedPlugins.contains {
            ($0.urlString.contains("online_mod") || $0.urlString.contains("online.js")) &&
            $0.isEligibleForAutomaticRuntime
        }
    }

    private var developerToolsVisible: Bool {
        DeveloperMode.isEnabled(preference: developerModeEnabled)
    }

    var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Catalog information stays separate from source availability.
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(detail?.displayTitle ?? item.displayTitle)
                                .font(.headline)
                            Text(item.canonicalType == "tv"
                                 ? "Сериал · выбрана серия \(selectedSeason)×\(String(format: "%02d", selectedEpisode))"
                                 : "Фильм · информация каталога")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                    .padding(.horizontal, 16)

                    if item.canonicalType != "tv" {
                        Text("Каталог и источники независимы. Список источников появляется после нажатия «Смотреть».")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("ПРОСМОТР")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                        VStack(spacing: 0) {
                            Button(action: {
                                resolveAndPlay(season: item.canonicalType == "tv" ? selectedSeason : nil,
                                               episode: item.canonicalType == "tv" ? selectedEpisode : nil)
                            }) {
                                HStack(spacing: 12) {
                                    if isResolvingSources {
                                        ProgressView().frame(width: 28)
                                    } else {
                                        Image(systemName: "play.fill")
                                            .foregroundColor(.blue)
                                            .frame(width: 28)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(isResolvingSources ? "Поиск источников..." :
                                             (item.canonicalType == "tv" ? "Смотреть серию \(selectedSeason)×\(String(format: "%02d", selectedEpisode))" : "Выбрать способ просмотра"))
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text(item.canonicalType == "tv" ? "Перейти к источникам серии" : "Озвучка, качество и источник")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundColor(.secondary)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .disabled(isResolvingSources)
                            .accessibilityIdentifier("watchNowButton")
                            if item.canonicalType == "tv" {
                                Divider().padding(.leading, 54)
                                Button(action: { showEpisodes = true }) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "square.grid.3x3.fill")
                                            .foregroundColor(.secondary)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Выбрать другую серию").font(.headline).foregroundColor(.primary)
                                            Text("Сезоны и эпизоды").font(.caption).foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityIdentifier("chooseEpisodeButton")
                            }
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 16)

                    catalogMetadata
                    pluginMetadata
                    catalogCast

                    Spacer(minLength: 32)
                }
                .padding(.top, 12)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(detail?.displayTitle ?? item.displayTitle)
            .navigationDestination(isPresented: $showEpisodes) {
                TVEpisodeSelectionView(seasons: detail?.seasons ?? [], isLoading: isLoading,
                                       selectedSeason: selectedSeason, selectedEpisode: selectedEpisode) { season, episode in
                    let context = "\(item.canonicalId)|\(season)|\(episode)"
                    showEpisodes = false
                    if context == selectedContext {
                        DispatchQueue.main.async { resolveAndPlay(season: season, episode: episode) }
                    } else {
                        pendingEpisodePlaybackContext = context
                        selectedSeason = season
                        selectedEpisode = episode
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { favoritesManager.toggleFavorite(item) }) {
                        Image(systemName: favoritesManager.isFavorite(item) ? "bookmark.fill" : "bookmark")
                    }
                    .accessibilityLabel(favoritesManager.isFavorite(item) ? "Удалить из избранного" : "В избранное")
                    .accessibilityIdentifier("favoriteButton")
                }
            }
            .sheet(isPresented: $showSourceSelectionSheet, onDismiss: {
                switch pickerFollowup {
                case .sources:
                    reopenPickerAfterConfiguration = true
                    showSourcesManagementSheet = true
                case .diagnostics:
                    reopenPickerAfterDiagnostics = true
                    showDiagnosticsSheet = true
                case .play(let source):
                    launchSource(source)
                case nil:
                    break
                }
                pickerFollowup = nil
            }) {
                SourcePickerSheetView(
                    mediaTitle: detail?.displayTitle ?? item.displayTitle,
                    canonicalId: item.canonicalId,
                    mediaType: item.canonicalType,
                    season: item.canonicalType == "tv" ? selectedSeason : nil,
                    episode: item.canonicalType == "tv" ? selectedEpisode : nil,
                    initialSources: availableSources,
                    onSelect: { chosenSource in
                        pickerFollowup = .play(chosenSource)
                        showSourceSelectionSheet = false
                    },
                    onNavigate: { source in
                        let host = LampaHeadlessHost.shared
                        let context = selectedContext
                        let request = currentRequestId
                        guard source.isNavigationFolder, let search = source.discoveryRequestId,
                              let index = source.discoveryRowIndex, let token = source.discoveryRowToken,
                              let root = host.activeResolutionContext, root.requestId == search,
                              root.generation == host.currentGeneration, root.canonicalId == item.canonicalId,
                              root.mediaType == item.canonicalType,
                              root.season == (item.canonicalType == "tv" ? selectedSeason : nil),
                              root.episode == (item.canonicalType == "tv" ? selectedEpisode : nil) else {
                            return .failure(SourceNavigationError(message: "Запрос устарел. Начните поиск заново."))
                        }
                        let result = await host.navigateFolderSnapshot(index: index, searchId: search, rowToken: token)
                        guard !Task.isCancelled, request == currentRequestId, context == selectedContext,
                              host.activeResolutionContext == root, host.currentGeneration == root.generation else {
                            return .failure(SourceNavigationError(message: "Запрос изменился. Начните поиск заново."))
                        }
                        switch result {
                        case .failure(let message):
                            return .failure(SourceNavigationError(message: "«\(source.title)»: \(message)"))
                        case .success(let rows):
                            let children = OnlineModSourceProvider.mapDiscoveredSources(rows, item: item,
                                season: root.season, episode: root.episode,
                                balancer: host.currentOnlineModBalancer ?? "", requestId: search)
                            availableSources = children
                            return .success(children)
                        }
                    },
                    onRestart: {
                        let context = selectedContext
                        let request = UUID()
                        currentRequestId = request
                        LampaHeadlessHost.shared.clearActiveMediaContext()
                        let sources = await SourceProviderEngine.shared.resolveSources(for: item,
                            season: item.canonicalType == "tv" ? selectedSeason : nil,
                            episode: item.canonicalType == "tv" ? selectedEpisode : nil, forceRefresh: true)
                        guard !Task.isCancelled, currentRequestId == request, selectedContext == context else { return [] }
                        availableSources = sources
                        resolvedContext = context
                        return sources
                    },
                    onCancelNavigation: {
                        currentRequestId = UUID()
                        currentResolutionTask?.cancel()
                        LampaHeadlessHost.shared.clearActiveMediaContext()
                        availableSources = []
                        resolvedContext = nil
                    },
                    onConfigureSources: {
                        pickerFollowup = .sources
                        showSourceSelectionSheet = false
                    },
                    onViewLogs: {
                        pickerFollowup = .diagnostics
                        showSourceSelectionSheet = false
                    },
                    onDismiss: {
                        showSourceSelectionSheet = false
                    }
                )
            }
            .sheet(isPresented: $showResolveFailureSheet, onDismiss: {
                switch failureFollowup {
                case .retry:
                    resolveAndPlay(season: item.canonicalType == "tv" ? selectedSeason : nil,
                                   episode: item.canonicalType == "tv" ? selectedEpisode : nil)
                case .picker:
                    showSourceSelectionSheet = !availableSources.isEmpty
                case .sources:
                    showSourcesManagementSheet = true
                case .diagnostics:
                    showDiagnosticsSheet = true
                case .lampa:
                    openInLampa()
                case .activateOnlineMod:
                    activateBundledOnlineMod()
                case nil: break
                }
                failureFollowup = nil
            }) {
                ResolveFailureView(
                    mediaTitle: detail?.displayTitle ?? item.displayTitle,
                    identitySubtitle: item.canonicalType == "tv" ? "Сезон \(selectedSeason), Серия \(selectedEpisode) (\(selectedSeason)×\(selectedEpisode < 10 ? "0\(selectedEpisode)" : "\(selectedEpisode)"))" : nil,
                    errorMessage: noSourcesMessage.isEmpty ? "Для выбранного произведения не найдены активные видеопотоки среди настроенных провайдеров." : noSourcesMessage,
                    otherOptionTitle: onlineModIsEnabled ? "Выбрать в Lampa" : "Включить встроенный Online Mod",
                    onRetry: {
                        failureFollowup = .retry
                        showResolveFailureSheet = false
                    },
                    onChooseAnotherSource: {
                        failureFollowup = onlineModIsEnabled ? .lampa : .activateOnlineMod
                        showResolveFailureSheet = false
                    },
                    onConfigureSources: {
                        failureFollowup = .sources
                        showResolveFailureSheet = false
                    },
                    onViewLogs: {
                        failureFollowup = .diagnostics
                        showResolveFailureSheet = false
                    },
                    onDismiss: {
                        showResolveFailureSheet = false
                    }
                )
            }
            .alert("Не удалось включить Online Mod", isPresented: Binding(
                get: { onlineModActivationError != nil },
                set: { if !$0 { onlineModActivationError = nil } }
            )) {
                Button("Понятно", role: .cancel) { onlineModActivationError = nil }
            } message: {
                Text(onlineModActivationError ?? "")
            }
            .alert("Источники не найдены", isPresented: $showNoSourcesAlert) {
                Button("Настроить источники") {
                    showSourcesManagementSheet = true
                }
                .accessibilityIdentifier("configureSourcesFromAlert")

                if developerToolsVisible {
                    Button("Журнал диагностики") {
                        showDiagnosticsSheet = true
                    }
                    .accessibilityIdentifier("openLogsFromAlert")

                    if onlineModIsEnabled {
                        Button("[Dev] Открыть Lampa") { openInLampa() }
                    }
                }

                Button("Понятно", role: .cancel) {}
            } message: {
                Text(noSourcesMessage)
            }
            .sheet(isPresented: $showSourcesManagementSheet, onDismiss: {
                let reopen = reopenPickerAfterConfiguration
                reopenPickerAfterConfiguration = false
                fetchSources(season: item.canonicalType == "tv" ? selectedSeason : nil,
                             episode: item.canonicalType == "tv" ? selectedEpisode : nil,
                             forceRefresh: true, reopenPicker: reopen)
            }) {
                NavigationStack {
                    SourcesManagementView(onPlayCustomUrl: { url, title, isDiag in
                        showSourcesManagementSheet = false
                        let payload = PlayPayload(
                            action: "play",
                            url: url,
                            title: title,
                            subtitle: isDiag ? "Диагностический прямой поток" : "Прямой поток",
                            time: 0,
                            duration: 1800,
                            hash: "direct_\(url.hashValue)",
                            canonicalId: isDiag ? "diagnostic_direct" : "direct_\(url.hashValue)",
                            mediaType: "movie",
                            season: nil,
                            episode: nil,
                            currentQuality: "Auto",
                            currentStudio: "original",
                            availableQualities: nil,
                            availableStudios: nil,
                            availableSubtitles: nil,
                            playlist: nil,
                            isDiagnostic: isDiag
                        )
                        onPlayRequest(payload)
                    })
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Закрыть") {
                                showSourcesManagementSheet = false
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showDiagnosticsSheet, onDismiss: {
                if reopenPickerAfterDiagnostics {
                    reopenPickerAfterDiagnostics = false
                    showSourceSelectionSheet = !availableSources.isEmpty
                }
            }) {
                DiagnosticsConsoleView()
            }
            .sheet(isPresented: $showLampaWebSheet) {
                LampaWebSheetView()
            }
            .sheet(isPresented: $showPluginsSheet) {
                ExtensionsView()
            }
            .onAppear {
                metadataRequestId = metadataHost.beginMetadata(for: item)
                TMDBService.shared.loadDetails(id: item.id, type: item.canonicalType) { loaded in
                    self.detail = loaded
                    self.isLoading = false
                }
            }
            .onDisappear {
                if let requestId = metadataRequestId { metadataHost.endMetadata(requestId: requestId) }
                metadataRequestId = nil
                currentResolutionTask?.cancel()
                currentRequestId = UUID()
                if isResolvingSources {
                    isResolvingSources = false
                    lastAutomaticResolutionContext = nil
                }
                LampaHeadlessHost.shared.clearActiveMediaContext()
            }
            .onChange(of: selectedContext) { _, context in
                currentResolutionTask?.cancel()
                currentRequestId = UUID()
                isResolvingSources = false
                availableSources = []
                resolvedContext = nil
                LampaHeadlessHost.shared.clearActiveMediaContext()
                if pendingEpisodePlaybackContext == context {
                    pendingEpisodePlaybackContext = nil
                    let season = selectedSeason
                    let episode = selectedEpisode
                    DispatchQueue.main.async {
                        guard selectedContext == context else { return }
                        resolveAndPlay(season: season, episode: episode)
                    }
                }
            }
            .onChange(of: item.canonicalId) { _, _ in
                if let requestId = metadataRequestId { metadataHost.endMetadata(requestId: requestId) }
                metadataRequestId = metadataHost.beginMetadata(for: item)
            }
    }

    private var pluginMetadata: some View {
        ForEach(metadataHost.metadataSections.filter { $0.canonicalId == item.canonicalId }) { section in
            VStack(alignment: .leading, spacing: 8) {
                Text(section.title).font(.headline)
                switch section.state {
                case .loading:
                    ProgressView("Загрузка…").font(.subheadline)
                case .unavailable:
                    Text("Информация недоступна").font(.subheadline).foregroundColor(.secondary)
                case .error:
                    Text("Не удалось загрузить информацию").font(.subheadline).foregroundColor(.secondary)
                case .ready:
                    ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.label).font(.caption).foregroundColor(.secondary)
                            Text(field.value).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pluginMetadataSection_\(section.capability.id)")
        }
    }

    @ViewBuilder
    private var catalogMetadata: some View {
        VStack(alignment: .leading, spacing: 16) {
            let year = (detail?.displayYear.isEmpty == false ? detail?.displayYear : nil) ?? item.displayYear
            let duration = detail?.durationOrSeasonsText ?? ""
            if !year.isEmpty || !duration.isEmpty || (item.voteAverage ?? 0) > 0 {
                HStack(spacing: 8) {
                    if !year.isEmpty { Text(year) }
                    if !duration.isEmpty { Text(duration) }
                    if (item.voteAverage ?? 0) > 0 {
                        Label(item.ratingText, systemImage: "star.fill")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
            }

            // Keep catalog artwork available without placing it ahead of playback.
            if (detail?.backdropUrl ?? item.backdropUrl) != nil || (detail?.posterUrl ?? item.posterUrl) != nil {
                HStack(alignment: .top, spacing: 12) {
                    if let posterURL = detail?.posterUrl ?? item.posterUrl {
                        AsyncImage(url: posterURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fit)
                                    .frame(width: 100).cornerRadius(10)
                            } else if case .failure = phase {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, height: 150)
                                    .task { await ImageNetworkDiagnostics.inspectFailure(of: posterURL) }
                            }
                        }
                    }
                    if let backdropURL = detail?.backdropUrl ?? item.backdropUrl,
                       backdropURL != (detail?.posterUrl ?? item.posterUrl) {
                        AsyncImage(url: backdropURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity).cornerRadius(12)
                            } else if case .failure = phase {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 100)
                                    .task { await ImageNetworkDiagnostics.inspectFailure(of: backdropURL) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            // MARK: - Synopsis
            if let overview = detail?.overview ?? item.overview, !overview.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Описание")
                        .font(.headline)
                    Text(overview)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineSpacing(4)
                }
                .padding(.horizontal, 16)
            } else {
                Text(isLoading ? "Загрузка информации каталога…" : "Описание в каталоге недоступно")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }

        }
    }

    @ViewBuilder
    private var catalogCast: some View {
        // MARK: - Cast
        if let cast = detail?.credits?.cast, !cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("В главных ролях")
                    .font(.headline)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(cast.prefix(10)) { person in
                            VStack(spacing: 6) {
                                if let pUrl = person.profileUrl {
                                    AsyncImage(url: pUrl) { phase in
                                        switch phase {
                                        case .success(let img):
                                            img.resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 60)
                                                .clipShape(Circle())
                                        case .empty, .failure:
                                            Circle().fill(Color.gray.opacity(0.3)).frame(width: 60, height: 60)
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                } else {
                                    Circle().fill(Color.gray.opacity(0.3)).frame(width: 60, height: 60)
                                }

                                Text(person.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 70)

                                if let character = person.character {
                                    Text(character)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 70)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }

    }

    private func fetchSources(season: Int?, episode: Int?, forceRefresh: Bool = false,
                              deduplicateAutomaticIntent: Bool = false, reopenPicker: Bool = false) {
        let context = selectedContext
        guard !deduplicateAutomaticIntent || SourceResolutionIntentPolicy.shouldStartAutomaticResolution(
            lastContext: lastAutomaticResolutionContext, nextContext: context) else { return }
        if deduplicateAutomaticIntent { lastAutomaticResolutionContext = context }
        currentResolutionTask?.cancel()
        let reqId = UUID()
        currentRequestId = reqId
        isResolvingSources = true
        availableSources = []
        resolvedContext = nil
        showSourceSelectionSheet = false

        currentResolutionTask = Task {
            let sources = await SourceProviderEngine.shared.resolveSources(
                for: item,
                season: season,
                episode: episode,
                forceRefresh: forceRefresh
            )
            await MainActor.run {
                guard !Task.isCancelled, self.currentRequestId == reqId, self.selectedContext == context else { return }
                self.availableSources = sources
                self.resolvedContext = context
                self.isResolvingSources = false
                if reopenPicker {
                    if sources.isEmpty {
                        self.noSourcesMessage = "Для выбранного произведения источники не найдены."
                        self.showResolveFailureSheet = true
                    } else {
                        self.showSourceSelectionSheet = true
                    }
                }
            }
        }
    }

    private func activateBundledOnlineMod() {
        let url = "bundled://plugins/online_mod.js"
        func enableInstalledPlugin() {
            guard let installed = pluginManager.installedPlugins.first(where: { $0.urlString == url }),
                  let hash = pluginManager.cachedScriptSHA256(for: url) else {
                onlineModActivationError = "Не удалось получить встроенный код Online Mod."
                return
            }
            guard pluginManager.approveCachedScript(pluginID: installed.id, expectedSHA256: hash) else {
                onlineModActivationError = pluginManager.lastError ?? "Не удалось включить Online Mod."
                return
            }
            SourceProviderEngine.shared.configurationDidChange()
            fetchSources(season: item.canonicalType == "tv" ? selectedSeason : nil,
                         episode: item.canonicalType == "tv" ? selectedEpisode : nil,
                         forceRefresh: true, reopenPicker: true)
        }
        if pluginManager.isInstalled(url: url) {
            enableInstalledPlugin()
            return
        }
        guard let bundled = pluginManager.curatedPlugins.first(where: { $0.url == url }) else {
            onlineModActivationError = "Встроенный Online Mod отсутствует в каталоге приложения."
            return
        }
        pluginManager.install(curated: bundled) { success, error in
            if success { enableInstalledPlugin() }
            else { onlineModActivationError = error ?? "Не удалось установить встроенный Online Mod." }
        }
    }

    private func openInLampa() {
        LampaHeadlessHost.shared.triggerMovieSearch(item: item,
            season: item.canonicalType == "tv" ? selectedSeason : nil,
            episode: item.canonicalType == "tv" ? selectedEpisode : nil)
        showLampaWebSheet = true
    }

    private func resolveAndPlay(season: Int?, episode: Int?) {
        currentResolutionTask?.cancel()
        let reqId = UUID()
        currentRequestId = reqId
        isResolvingSources = true
        availableSources = []
        resolvedContext = nil
        showSourceSelectionSheet = false
        let context = selectedContext

        currentResolutionTask = Task {
            let sources = await SourceProviderEngine.shared.resolveSources(
                for: item,
                season: season,
                episode: episode
            )

            await MainActor.run {
                guard !Task.isCancelled, self.currentRequestId == reqId, self.selectedContext == context else { return }
                self.isResolvingSources = false
                self.availableSources = sources
                self.resolvedContext = context

                if sources.isEmpty {
                    let bridgeFailure = LampaHeadlessHost.shared.compatibilityError
                    self.noSourcesMessage = bridgeFailure ?? (onlineModIsEnabled
                        ? "Для «\(detail?.displayTitle ?? item.displayTitle)» поиск не вернул потоков. Можно открыть исходный выбор Lampa."
                        : "Для фильмов не включён онлайн-провайдер. Нажмите «Включить встроенный Online Mod», чтобы подключить его.")
                    self.showResolveFailureSheet = true
                } else {
                    self.availableSources = sources
                    self.showSourceSelectionSheet = true
                }
            }
        }
    }

    private func launchSource(_ source: ResolvedMediaSource) {
        guard !isResolvingSources, resolvedContext == selectedContext,
              availableSources.contains(source), source.canonicalMediaId == item.canonicalId else { return }
        let isTv = item.canonicalType == "tv"
        let s = source.season ?? (isTv ? selectedSeason : nil)
        let e = source.episode ?? (isTv ? selectedEpisode : nil)
        guard s == (isTv ? selectedSeason : nil), e == (isTv ? selectedEpisode : nil) else { return }

        if source.streamUrl.isEmpty {
            isResolvingSources = true
            let requestId = UUID()
            currentRequestId = requestId
            let context = selectedContext
            let host = LampaHeadlessHost.shared
            let discoveryContext = host.activeResolutionContext
            let runtimeGeneration = host.currentGeneration
            let actionId = ActionCorrelationTracker.shared.startAction(
                name: "LaunchOnlineModSource",
                metadata: ["canonicalId": item.canonicalId, "sourceId": source.id]
            )
            let resolutionContext = MediaResolutionContext(
                requestId: currentRequestId,
                actionId: actionId,
                canonicalId: item.canonicalId,
                title: item.displayTitle,
                mediaType: item.canonicalType,
                season: s,
                episode: e,
                balancer: source.studioName,
                generation: runtimeGeneration,
                revision: 1
            )
            currentResolutionTask = Task {
                do {
                    let payload = try await SourceProviderEngine.shared.onlineModProvider.resolveStream(for: source, context: resolutionContext)
                    await MainActor.run {
                        guard SourceResolutionIntentPolicy.isCurrentResult(
                            requestId: requestId, currentRequestId: self.currentRequestId,
                            context: context, currentContext: self.selectedContext, isCancelled: Task.isCancelled
                        ) else { return }
                        self.isResolvingSources = false
                        guard host.currentGeneration == runtimeGeneration, host.activeResolutionContext == discoveryContext else { return }
                        var playable = payload
                        playable.mediaLookupItem = item
                        self.onPlayRequest(playable)
                    }
                } catch {
                    await MainActor.run {
                        guard SourceResolutionIntentPolicy.isCurrentResult(
                            requestId: requestId, currentRequestId: self.currentRequestId,
                            context: context, currentContext: self.selectedContext, isCancelled: Task.isCancelled
                        ) else { return }
                        self.isResolvingSources = false
                        guard !(error is CancellationError), host.currentGeneration == runtimeGeneration,
                              host.activeResolutionContext == discoveryContext else { return }
                        self.noSourcesMessage = "Не удалось разрешить поток онлайн-балансера: \(error.localizedDescription)"
                        self.showResolveFailureSheet = true
                    }
                }
            }
            return
        }

        // Build available qualities and audio tracks from all resolved sources
        let sameContext = availableSources.filter {
            $0.providerId == source.providerId && $0.canonicalMediaId == source.canonicalMediaId &&
            $0.season == source.season && $0.episode == source.episode
        }
        let qualities = sameContext
            .filter { $0.studioId == source.studioId }
            .map { QualityOption(label: $0.quality, url: $0.streamUrl, bitrate: 0) }
            .reduce(into: [QualityOption]()) { options, option in
                if !options.contains(where: { $0.label == option.label }) { options.append(option) }
            }

        let studios = Dictionary(grouping: sameContext, by: { $0.studioId })
            .compactMap { key, list -> AudioTrackOption? in
                guard let first = list.first else { return nil }
                return AudioTrackOption(id: first.studioId, name: first.studioName, url: first.streamUrl, isOriginal: first.studioId == "original", language: "ru")
            }

        let payload = PlayPayload(
            action: "play",
            url: source.streamUrl,
            title: detail?.displayTitle ?? item.displayTitle,
            subtitle: isTv && e != nil ? "Сезон \(s ?? 1), Серия \(e!) • \(source.studioName)" : source.studioName,
            time: 0,
            duration: 1800,
            hash: "\(item.canonicalId):s\(s ?? 1):e\(e ?? 1):\(source.id)",
            canonicalId: item.canonicalId,
            mediaType: item.canonicalType,
            season: s,
            episode: e,
            currentQuality: source.quality,
            currentStudio: source.studioId,
            availableQualities: qualities.isEmpty ? nil : qualities,
            availableStudios: studios.isEmpty ? nil : studios,
            availableSubtitles: nil,
            playlist: nil,
            mediaLookupItem: item,
            isDiagnostic: source.isDiagnostic,
            plugin: source.providerId,
            pluginId: source.sourceKey,
            requestId: currentRequestId.uuidString,
            selectionContext: "native_source_select"
        )

        onPlayRequest(payload)
    }
}

// Native sheet presenting resolved media streams grouped by provider and studio.
struct SourceSelectionSheet: View {
    let sources: [ResolvedMediaSource]
    var onSelect: (ResolvedMediaSource) -> Void
    var onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Выберите качество и вариант озвучки для начала воспроизведения:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                let grouped = Dictionary(grouping: sources, by: { "\($0.providerName) — \($0.studioName)" })
                ForEach(grouped.keys.sorted(), id: \.self) { groupTitle in
                    Section(header: Text(groupTitle)) {
                        ForEach(grouped[groupTitle] ?? []) { src in
                            Button(action: {
                                onSelect(src)
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(src.title)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        Text("\(src.quality) • \(src.container.uppercased()) • \(src.providerName)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "play.circle.fill")
                                        .font(.title3)
                                        .foregroundColor(.blue)
                                }
                                .padding(.vertical, 4)
                            }
                            .accessibilityIdentifier("sourceRow_\(src.id)")
                        }
                    }
                }
            }
            .navigationTitle("Источники видео")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") {
                        onDismiss()
                    }
                    .accessibilityIdentifier("cancelSourceSelectionButton")
                }
            }
        }
    }
}
