import SwiftUI
import WebKit
import AVFoundation

// Root navigation and playback presentation.
@MainActor
struct ContentView: View {
    @State private var activePayload: PlayPayload?
    @State private var playbackDiagnosis: PlaybackDiagnosis?
    @State private var selectedTab: Int = 0
    @State private var submittedCatalogSearch = ""

    @State private var isCountdownActive = false
    @State private var countdownSeconds = 10
    @State private var countdownTimer: Timer?
    @State private var playbackRequestError: String?
    @State private var playbackPresentation = PlaybackPresentationState()
    @State private var showPlayerSettings = false
    @State private var showPlayerEpisodes = false
    @State private var nextEpisodeUnavailable = false
    @State private var isResolvingNextEpisode = false
    @State private var nextEpisodeResolutionTask: Task<Void, Never>?
    @AppStorage("ilampa_player_v2_enabled") private var usePlayerV2 = true
    @State private var playerActionsVisible = true
    @State private var hidePlayerActionsTask: Task<Void, Never>?

    var body: some View {
        TabView(selection: $selectedTab) {
            // Catalog
            CatalogView(onPlayRequest: { payload in
                startPlayback(payload)
            }, onSearchRequested: { query in
                submittedCatalogSearch = query
                selectedTab = 1
            })
            .tabItem {
                Label("Каталог", systemImage: "film.stack")
            }
            .tag(0)

            // Search has one canonical destination; the catalog entry switches tabs.
            NavigationStack {
                SearchView(onPlayRequest: { payload in
                    startPlayback(payload)
                }, initialQuery: submittedCatalogSearch)
            }
            .tabItem {
                Label("Поиск", systemImage: "magnifyingglass")
            }
            .tag(1)

            // MARK: - Library
            MyLibraryView(onResumePlayback: { record in
                resumePlayback(from: record)
            }, onPlayRequest: { payload in
                startPlayback(payload)
            })
            .tabItem {
                Label("Моё", systemImage: "play.square.stack")
            }
            .tag(2)

            // Settings
            SettingsView(
                onLaunchTestStream: {
                    launchTestHlsStream()
                },
                onPlayCustomUrl: { url, title, isDiag in
                    startCustomDirectPlayback(url: url, title: title, isDiagnostic: isDiag)
                }
            )
            .tabItem {
                Label("Настройки", systemImage: "gearshape")
            }
            .tag(3)
        }
        .accentColor(.blue)
        .alert("Воспроизведение недоступно", isPresented: Binding(
            get: { playbackRequestError != nil },
            set: { if !$0 { playbackRequestError = nil } }
        )) {
            Button("Понятно", role: .cancel) { playbackRequestError = nil }
        } message: {
            Text(playbackRequestError ?? "")
        }
        .overlay(alignment: .bottomLeading) {
            // Diagnostic anchor for automated CI UI tests
            if ProcessInfo.processInfo.arguments.contains("--uitesting") {
                Button(action: launchTestHlsStream) {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("testHlsButton")
                .accessibilityLabel("testHlsButton")
            }
        }
        .fullScreenCover(item: $activePayload) { payload in
            ZStack {
                // AVKit owns the entire playback surface and its transport controls.
                // No bottom VStack/toolbar may reduce the video viewport.
                Color.black.ignoresSafeArea()
                if usePlayerV2 {
                    UnifiedPlayerV2View(
                        payload: Binding(
                            get: { activePayload ?? payload },
                            set: { activePayload = $0 }
                        ),
                        isResolvingEpisode: isResolvingNextEpisode,
                        onTimeUpdate: { time, duration, hash in
                            syncTimeToHistory(time: time, duration: duration, hash: hash)
                        },
                        onNearEnd: { startAutoNextCountdown() },
                        onEnded: { handleEpisodeEnded() },
                        onPlaybackError: { diag in self.playbackDiagnosis = diag },
                        onDismiss: { dismissPlayer() },
                        onQualitySelected: switchQuality,
                        onStudioSelected: switchStudio,
                        onEpisodeSelected: switchEpisode,
                        onNextEpisode: advanceToNextEpisodeNow
                    )
                    .ignoresSafeArea()
                } else {
                NativePlayerView(
                    payload: Binding(
                        get: { activePayload ?? payload },
                        set: { activePayload = $0 }
                    ),
                    onTimeUpdate: { time, duration, hash in
                        syncTimeToHistory(time: time, duration: duration, hash: hash)
                    },
                    onNearEnd: { startAutoNextCountdown() },
                    onEnded: { handleEpisodeEnded() },
                    onPlaybackError: { diag in self.playbackDiagnosis = diag },
                    onDismiss: { dismissPlayer() },
                    onControlsInteraction: { togglePlayerActionsOnTap() }
                )
                .ignoresSafeArea()


                // Only iLampa-specific actions are overlaid on the video.
                // Close, more, scrubbing, transport and PiP belong to AVKit.
                if isResolvingNextEpisode {
                    ProgressView("Поиск следующей серии…")
                        .tint(.white)
                        .foregroundStyle(.white)
                        .padding(18)
                        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                }

                PlayerControlsOverlayView(
                    payload: Binding(
                        get: { activePayload ?? payload },
                        set: { activePayload = $0 }
                    ),
                    isPresented: Binding(
                        get: { activePayload != nil },
                        set: { if !$0 { dismissPlayer() } }
                    ),
                    diagnosis: $playbackDiagnosis,
                    onQualitySelected: switchQuality,
                    onStudioSelected: switchStudio,
                    onEpisodeSelected: switchEpisode,
                    onRestartRequested: restartCurrentEpisode,
                    onOpenInInfuse: {
                        if let current = activePayload {
                            SourceManager.shared.openInExternalPlayer(streamUrl: current.url)
                        }
                    },
                    onNextEpisodeTriggered: advanceToNextEpisodeNow,
                    showSettingsSheet: $showPlayerSettings,
                    showEpisodesSheet: $showPlayerEpisodes,
                    countdownSecondsRemaining: $countdownSeconds,
                    isCountdownActive: $isCountdownActive
                )

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if ((activePayload ?? payload).playlist?.count ?? 0) > 1 {
                            Button {
                                showPlayerEpisodes = true
                                showPlayerActionsTemporarily()
                            } label: {
                                Image(systemName: "rectangle.stack")
                                    .frame(width: 42, height: 42)
                                    .background(Color.black.opacity(0.4), in: Circle())
                            }
                            .accessibilityLabel("Серии")
                            .accessibilityIdentifier("playerEpisodesButton")
                        }
                        if (EpisodeQueue.shouldShowNextEpisodeAction(for: activePayload ?? payload) ||
                            ((activePayload ?? payload).mediaType == "tv" &&
                             (activePayload ?? payload).playlist == nil &&
                             (activePayload ?? payload).episode != nil &&
                             !(activePayload ?? payload).isDiagnostic)) && !isResolvingNextEpisode {
                            Button {
                                advanceToNextEpisodeNow()
                                showPlayerActionsTemporarily()
                            } label: {
                                Image(systemName: "forward.end")
                                    .frame(width: 42, height: 42)
                                    .background(Color.black.opacity(0.4), in: Circle())
                            }
                            .accessibilityLabel("Следующая серия")
                            .accessibilityIdentifier("playerNextEpisodeButton")
                        }
                        Button {
                            showPlayerSettings = true
                            showPlayerActionsTemporarily()
                        } label: {
                            Image(systemName: "gearshape")
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.4), in: Circle())
                        }
                        .accessibilityLabel("Настройки воспроизведения")
                        .accessibilityIdentifier("playerSettingsButton")
                    }
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    // Keep clear of AVKit's own close/more controls in landscape.
                    .padding(.top, 48)
                    .background(alignment: .top) {
                        LinearGradient(colors: [.black.opacity(0.38), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 70)
                            .allowsHitTesting(false)
                    }
                    .opacity(playerActionsVisible ? 1 : 0)
                    .allowsHitTesting(playerActionsVisible)
                    .animation(.easeInOut(duration: 0.22), value: playerActionsVisible)
                    Spacer(minLength: 0)
                }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .onAppear { if !usePlayerV2 { showPlayerActionsTemporarily() } }
            .alert("Следующая серия недоступна", isPresented: $nextEpisodeUnavailable) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text("У текущего источника не удалось получить поток следующей серии с выбранной озвучкой.")
            }
            .onDisappear {
                hidePlayerActionsTask?.cancel()
                hidePlayerActionsTask = nil
            }
        }
        .background {
            // Keep the shared Lampa runtime attached while using native navigation.
            LampaHostContainerView()
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
        }
        .onAppear {
            LampaHeadlessHost.shared.onPlayRequest = { payload in
                self.startPlayback(payload)
            }
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--test-hls") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.launchTestHlsStream()
                }
            }
        }
    }

    private func startPlayback(_ requestedPayload: PlayPayload) {
        nextEpisodeResolutionTask?.cancel()
        nextEpisodeResolutionTask = nil
        isResolvingNextEpisode = false
        nextEpisodeUnavailable = false
        var payload = requestedPayload
        if let selected = payload.availableStudios?.first(where: { $0.id == payload.currentStudio }) {
            payload.currentStudioName = selected.name
        }
        do {
            let url = try SourceManager.shared.sanitizeStreamUrl(payload.url)
            if ["infuse", "open-vidhub"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
                return
            }
        } catch {
            playbackRequestError = error.localizedDescription
            return
        }
        self.playbackDiagnosis = nil
        // Coalesce requests received during the same dismissal, rather than presenting over a closing sheet.
        guard playbackPresentation.request(payload) else { return }
        // SwiftUI cannot reliably present the root cover while its detail/Lampa sheet is still presented.
        // Dismiss that entire presentation chain, then present in UIKit's actual completion (no delay heuristic).
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        if activePayload == nil, let root, root.presentedViewController != nil {
            let presentationID = playbackPresentation.beginDismissal()
            root.dismiss(animated: true) {
                guard let pending = self.playbackPresentation.completeDismissal(id: presentationID) else { return }
                self.activePayload = pending
            }
        } else {
            self.activePayload = playbackPresentation.takeImmediate()
        }
    }

    private func dismissPlayer() {
        nextEpisodeResolutionTask?.cancel()
        nextEpisodeResolutionTask = nil
        isResolvingNextEpisode = false
        hidePlayerActionsTask?.cancel()
        hidePlayerActionsTask = nil
        playbackPresentation.cancel()
        cancelCountdown()
        PlayerPlaybackController.shared.pauseAndTeardown()
        LampaHeadlessHost.shared.clearActiveMediaContext()
        self.activePayload = nil
        self.playbackDiagnosis = nil
    }

    private func resumePlayback(from record: WatchHistoryRecord) {
        guard let streamUrl = record.url, !streamUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            playbackRequestError = "Ссылка в истории отсутствует. Откройте карточку и выберите источник заново."
            return
        }
        self.playbackDiagnosis = nil
        startPlayback(PlayPayload(
            action: "play",
            url: streamUrl,
            title: record.title ?? record.canonicalId,
            subtitle: record.season > 0 ? "Сезон \(record.season), Серия \(record.episode)" : nil,
            time: record.timecode,
            duration: record.duration,
            hash: record.canonicalId,
            canonicalId: record.canonicalId,
            mediaType: record.season > 0 ? "tv" : "movie",
            season: record.season > 0 ? record.season : nil,
            episode: record.episode > 0 ? record.episode : nil,
            currentQuality: record.quality,
            currentStudio: record.studio,
            availableQualities: nil,
            availableStudios: nil,
            availableSubtitles: nil,
            playlist: nil,
            pluginId: record.sourceId
        ))
    }

    /// Read the actual AVPlayer clock before replacing an item. The journal is
    /// only updated periodically and can lag several seconds behind user seeking.
    private func showPlayerActionsTemporarily() {
        hidePlayerActionsTask?.cancel()
        playerActionsVisible = true
        hidePlayerActionsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            playerActionsVisible = false
        }
    }

    /// A second tap hides our toolbar as AVKit hides its transport controls.
    /// AVKit does not expose a public playback-control visibility observation API.
    private func togglePlayerActionsOnTap() {
        if playerActionsVisible {
            hidePlayerActionsTask?.cancel()
            hidePlayerActionsTask = nil
            playerActionsVisible = false
        } else {
            showPlayerActionsTemporarily()
        }
    }

    private func currentPlaybackPosition(fallback: Double?) -> Double? {
        if let player = PlayerPlaybackController.shared.activePlayer {
            let seconds = CMTimeGetSeconds(player.currentTime())
            if seconds.isFinite, seconds >= 0 { return seconds }
        }
        if let fallback, fallback.isFinite, fallback >= 0 { return fallback }
        return nil
    }

    private func switchQuality(_ quality: QualityOption) {
        nextEpisodeResolutionTask?.cancel()
        nextEpisodeResolutionTask = nil
        isResolvingNextEpisode = false
        guard var payload = activePayload else { return }
        guard payload.url != quality.url else {
            payload.currentQuality = quality.label
            activePayload = payload
            return
        }
        payload.time = currentPlaybackPosition(fallback: payload.time)
        payload.url = quality.url
        payload.currentQuality = quality.label
        activePayload = payload
    }

    private func switchStudio(_ studio: AudioTrackOption) {
        nextEpisodeResolutionTask?.cancel()
        nextEpisodeResolutionTask = nil
        isResolvingNextEpisode = false
        guard var payload = activePayload else { return }
        if payload.url != studio.url {
            payload.time = currentPlaybackPosition(fallback: payload.time)
        }
        payload.url = studio.url
        payload.currentStudio = studio.id
        payload.currentStudioName = studio.name
        activePayload = payload
    }

    private func switchEpisode(_ item: PlaylistItem) {
        cancelCountdown()
        nextEpisodeResolutionTask?.cancel()
        nextEpisodeResolutionTask = nil
        isResolvingNextEpisode = false
        nextEpisodeUnavailable = false
        guard var payload = activePayload else { return }
        payload.url = item.url
        // Keep the session's media title; the episode identity is shown separately.
        payload.subtitle = nil
        payload.time = 0
        payload.duration = item.duration ?? 0
        payload.season = item.seasonNumber ?? payload.season
        payload.episode = item.episodeNumber
        payload.availableQualities = nil
        payload.availableStudios = nil
        // The next episode's URL does not establish which voice it contains.
        payload.currentStudioName = nil
        self.activePayload = payload
    }

    private func restartCurrentEpisode() {
        guard var payload = activePayload else { return }
        payload.time = 0
        activePayload = payload
        PlayerPlaybackController.shared.activePlayer?.seek(to: .zero)
        PlayerPlaybackController.shared.activePlayer?.play()
    }

    private func startAutoNextCountdown() {
        guard !isCountdownActive,
              let payload = activePayload,
              !payload.isDiagnostic,
              EpisodeQueue.nextEpisode(for: payload) != nil else { return }

        isCountdownActive = true
        countdownSeconds = 10

        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            // This timer is installed by the main actor on its run loop.
            MainActor.assumeIsolated {
            guard timer.isValid, self.isCountdownActive else { timer.invalidate(); return }
            if self.countdownSeconds > 1 {
                self.countdownSeconds -= 1
            } else {
                timer.invalidate()
                self.isCountdownActive = false
                self.advanceToNextEpisodeNow()
            }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isCountdownActive = false
    }

    private func advanceToNextEpisodeNow() {
        cancelCountdown()
        guard let payload = activePayload, !payload.isDiagnostic else { return }
        let nextItem: PlaylistItem
        switch EpisodeQueue.resolveNextEpisode(for: payload) {
        case .available(let item):
            nextItem = item
        case .unknown where payload.mediaType == "tv":
            resolveNextEpisodeFromProvider(for: payload)
            return
        case .unavailable where payload.mediaType == "tv":
            resolveNextEpisodeFromProvider(for: payload)
            return
        case .unavailable:
            nextEpisodeUnavailable = true
            DiagnosticsLogManager.shared.log(
                category: "[Player]",
                message: "В плейлисте текущего источника следующая серия отсутствует или имеет неверную ссылку",
                level: .warning
            )
            return
        case .lastEpisode, .unknown:
            // No warning for the last episode or when the playlist is unavailable.
            return
        }
        let playlist = payload.playlist
        var nextPayload = PlayPayload(
            action: "play",
            url: nextItem.url,
            title: payload.title,
            subtitle: nil,
            time: 0,
            duration: nextItem.duration ?? 0,
            hash: payload.hash,
            canonicalId: payload.canonicalId,
            mediaType: payload.mediaType,
            season: nextItem.seasonNumber ?? payload.season,
            episode: nextItem.episodeNumber ?? ((payload.episode ?? 1) + 1),
            currentQuality: payload.currentQuality,
            currentStudio: payload.currentStudio,
            currentStudioName: nil,
            availableQualities: nil,
            availableStudios: nil,
            availableSubtitles: payload.availableSubtitles,
            playlist: playlist,
            mediaLookupItem: payload.mediaLookupItem,
            customHeaders: payload.customHeaders,
            isDiagnostic: payload.isDiagnostic,
            plugin: payload.plugin,
            pluginId: payload.pluginId,
            requestId: payload.requestId,
            selectionContext: payload.selectionContext
        )
        nextPayload.diagnosticActionId = payload.diagnosticActionId
        self.activePayload = nextPayload
    }

    /// The native source picker does not always provide an episode playlist.
    /// Discover the NEXT episode using the same provider and voice; never replay
    /// the current stream or silently jump to a different source.
    private func resolveNextEpisodeFromProvider(for previous: PlayPayload) {
        guard !isResolvingNextEpisode, let currentSeason = previous.season,
              let currentEpisode = previous.episode, currentEpisode > 0,
              let item = episodeLookupItem(for: previous),
              (previous.plugin != nil || previous.pluginId != nil) else {
            nextEpisodeUnavailable = true
            return
        }

        isResolvingNextEpisode = true
        let requestedEpisode = currentEpisode + 1
        nextEpisodeResolutionTask = Task { @MainActor in
            let candidates = await SourceProviderEngine.shared.resolveSources(
                for: item, season: currentSeason, episode: requestedEpisode, forceRefresh: true
            )
            guard !Task.isCancelled, activePayload?.url == previous.url,
                  activePayload?.season == currentSeason,
                  activePayload?.episode == currentEpisode else { return }

            let chosenSource = EpisodeQueue.chooseNextSource(
                from: candidates, previous: previous, canonicalId: item.canonicalId,
                season: currentSeason, episode: requestedEpisode
            )

            guard let chosen = chosenSource else {
                DiagnosticsLogManager.shared.log(category: "[Player]",
                    message: "Next episode resolution found no matching provider/voice for season=\(currentSeason) episode=\(requestedEpisode)",
                    level: .warning)
                isResolvingNextEpisode = false
                nextEpisodeResolutionTask = nil
                nextEpisodeUnavailable = true
                return
            }

            do {
                var nextPayload: PlayPayload
                if chosen.streamUrl.isEmpty {
                    let host = LampaHeadlessHost.shared
                    guard let discovered = host.activeResolutionContext,
                          discovered.requestId == chosen.discoveryRequestId,
                          discovered.canonicalId == item.canonicalId,
                          discovered.season == currentSeason,
                          discovered.episode == requestedEpisode else {
                        throw NSError(domain: "NextEpisode", code: 409)
                    }
                    let context = MediaResolutionContext(
                        requestId: UUID(),
                        actionId: ActionCorrelationTracker.shared.startAction(name: "NextEpisode",
                            metadata: ["canonicalId": item.canonicalId]),
                        canonicalId: item.canonicalId,
                        title: item.displayTitle,
                        mediaType: "tv",
                        season: currentSeason,
                        episode: requestedEpisode,
                        balancer: chosen.studioName,
                        generation: host.currentGeneration,
                        revision: 1
                    )
                    nextPayload = try await SourceProviderEngine.shared.onlineModProvider.resolveStream(
                        for: chosen, context: context
                    )
                } else {
                    guard let url = URL(string: chosen.streamUrl),
                          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                          url.host != nil else { throw NSError(domain: "NextEpisode", code: 400) }
                    nextPayload = previous
                    nextPayload.url = chosen.streamUrl
                    nextPayload.hash = "\(item.canonicalId):s\(currentSeason):e\(requestedEpisode):\(chosen.id)"
                    nextPayload.currentStudio = chosen.studioId
                    nextPayload.currentStudioName = chosen.studioName
                    nextPayload.currentQuality = chosen.quality
                    nextPayload.plugin = chosen.providerId
                    nextPayload.pluginId = chosen.sourceKey
                }
                guard !Task.isCancelled, activePayload?.url == previous.url,
                      activePayload?.season == currentSeason,
                      activePayload?.episode == currentEpisode else { return }
                nextPayload.season = currentSeason
                nextPayload.episode = requestedEpisode
                nextPayload.time = 0
                nextPayload.duration = 0
                nextPayload.subtitle = nil
                nextPayload.playlist = nil
                nextPayload.mediaLookupItem = item
                nextPayload.availableQualities = nil
                nextPayload.availableStudios = nil
                nextPayload.selectionContext = "next_episode_source_resolution"
                nextPayload.isDiagnostic = false
                playbackDiagnosis = nil
                nextEpisodeUnavailable = false
                isResolvingNextEpisode = false
                nextEpisodeResolutionTask = nil
                activePayload = nextPayload
                DiagnosticsLogManager.shared.log(category: "[Player]",
                    message: "Next episode resolved from current provider: season=\(currentSeason) episode=\(requestedEpisode)",
                    level: .success)
            } catch {
                guard !Task.isCancelled else { return }
                DiagnosticsLogManager.shared.log(category: "[Player]",
                    message: "Next episode resolution failed, code=\((error as NSError).code)",
                    level: .warning)
                nextEpisodeResolutionTask = nil
                isResolvingNextEpisode = false
                nextEpisodeUnavailable = true
            }
        }
    }

    private func episodeLookupItem(for payload: PlayPayload) -> MediaItem? {
        if let item = payload.mediaLookupItem, item.canonicalType == "tv" { return item }
        guard payload.mediaType == "tv", let id = payload.canonicalId,
              id.hasPrefix("urn:media:tmdb:tv:"),
              let numericId = Int(id.split(separator: ":").last ?? "") else { return nil }
        return MediaItem(
            id: numericId, title: nil, name: payload.title,
            originalTitle: nil, originalName: nil, overview: nil,
            posterPath: nil, backdropPath: nil, mediaType: "tv",
            releaseDate: nil, firstAirDate: nil, voteAverage: nil,
            voteCount: nil, genreIds: nil
        )
    }

    private func handleEpisodeEnded() {
        if isCountdownActive {
            advanceToNextEpisodeNow()
        } else if let payload = activePayload, payload.isDiagnostic {
            // Diagnostic streams remain open so their state can be inspected.
            DiagnosticsLogManager.shared.log(
                category: "[Player]",
                message: "Диагностический поток завершил воспроизведение",
                level: .info
            )
        } else if let payload = activePayload {
            switch EpisodeQueue.resolveNextEpisode(for: payload) {
            case .available:
                advanceToNextEpisodeNow()
            case .unavailable:
                // A source claims more episodes, but the expected one cannot play.
                advanceToNextEpisodeNow()
            case .unknown where payload.mediaType == "tv":
                advanceToNextEpisodeNow()
            case .lastEpisode, .unknown:
                // Finishing the last available episode is normal, not an error.
                dismissPlayer()
            }
        } else {
            dismissPlayer()
        }
    }

    private func syncTimeToHistory(time: Double, duration: Double, hash: String?) {
        guard let payload = activePayload, !payload.isDiagnostic else { return }
        WatchHistoryManager.shared.saveTimecode(
            canonicalId: payload.canonicalId ?? hash ?? payload.title,
            season: payload.season ?? 0,
            episode: payload.episode ?? 0,
            time: time,
            duration: duration,
            title: payload.title,
            url: payload.url,
            studio: payload.currentStudio,
            quality: payload.currentQuality,
            source: payload.pluginId
        )
    }

    private func startCustomDirectPlayback(url: String, title: String, isDiagnostic: Bool) {
        self.playbackDiagnosis = nil
        startPlayback(PlayPayload(
            action: "play",
            url: url,
            title: title,
            subtitle: isDiagnostic ? "Диагностический прямой поток" : "Прямой поток",
            time: 0,
            duration: 1800,
            hash: "direct_\(url.hashValue)",
            canonicalId: isDiagnostic ? "diagnostic_direct_\(url.hashValue)" : "direct_\(url.hashValue)",
            mediaType: "movie",
            season: nil,
            episode: nil,
            currentQuality: "Auto",
            currentStudio: "original",
            availableQualities: nil,
            availableStudios: nil,
            availableSubtitles: nil,
            playlist: nil,
            isDiagnostic: isDiagnostic
        ))
    }

    private func launchTestHlsStream() {
        self.playbackDiagnosis = nil
        let testUrl = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"
        startPlayback(PlayPayload(
            action: "play",
            url: testUrl,
            title: "Apple HLS Test Stream",
            subtitle: "1080p / 720p / 480p Adaptive Master",
            time: 0,
            duration: 1800,
            hash: "apple_bipbop_test",
            canonicalId: "urn:media:test:apple:bipbop",
            mediaType: "movie",
            season: nil,
            episode: nil,
            currentQuality: "1080p",
            currentStudio: "original",
            availableQualities: [
                QualityOption(label: "1080p", url: testUrl, bitrate: 4500000),
                QualityOption(label: "720p", url: testUrl, bitrate: 2200000),
                QualityOption(label: "480p", url: testUrl, bitrate: 1100000)
            ],
            availableStudios: [
                AudioTrackOption(id: "original", name: "English (Original AAC)", url: testUrl, isOriginal: true, language: "en")
            ],
            availableSubtitles: nil,
            playlist: [
                PlaylistItem(index: 0, seasonNumber: 1, episodeNumber: 1, title: "Серия 1: Master HLS", url: testUrl, duration: 1800, timecode: 0),
                PlaylistItem(index: 1, seasonNumber: 1, episodeNumber: 2, title: "Серия 2: Secondary Stream", url: testUrl, duration: 1800, timecode: 0)
            ],
            isDiagnostic: true
        ))
    }
}
