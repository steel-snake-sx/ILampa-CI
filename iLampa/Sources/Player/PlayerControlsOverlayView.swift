import SwiftUI
import AVKit

// Error and episode overlays, with application controls in a separate player toolbar.
struct PlayerControlsOverlayView: View {
    @Binding var payload: PlayPayload
    @Binding var isPresented: Bool
    @Binding var diagnosis: PlaybackDiagnosis?

    var onQualitySelected: (QualityOption) -> Void
    var onStudioSelected: (AudioTrackOption) -> Void
    var onEpisodeSelected: (PlaylistItem) -> Void
    var onRestartRequested: () -> Void
    var onOpenInInfuse: () -> Void
    var onNextEpisodeTriggered: () -> Void

    @Binding var showSettingsSheet: Bool
    @Binding var showEpisodesSheet: Bool
    @State private var showResumeToast = false
    @State private var resumeToastMessage = ""

    @Binding var countdownSecondsRemaining: Int
    @Binding var isCountdownActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showResumeToast {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(.yellow)
                    Text(resumeToastMessage)
                        .font(.subheadline)
                        .foregroundColor(.white)
                    Button("С начала") {
                        onRestartRequested()
                        withAnimation { showResumeToast = false }
                    }
                    .font(.subheadline.bold())
                    .foregroundColor(.yellow)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.8))
                .cornerRadius(18)
                .transition(.move(edge: .top).combined(with: .opacity))
                .padding(.top, 8)
            }

            Spacer()

            // Playback error diagnosis card
            if let diag = diagnosis {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.orange)

                    Text(diag.title)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(diag.message)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    HStack(spacing: 14) {
                        if diag.canOpenInExternalPlayer {
                            Button(action: onOpenInInfuse) {
                                Label("В Infuse", systemImage: "arrow.up.right.video")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.orange)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)
                            }
                        }

                        Button(action: { isPresented = false }) {
                            Text("Закрыть")
                                .font(.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.2))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                    }
                }
                .padding(22)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.black.opacity(0.9))
                        .shadow(radius: 12)
                )
                .padding(.horizontal, 30)
            }

            // Auto-next episode countdown card
            if isCountdownActive {
                HStack(spacing: 12) {
                    Image(systemName: "forward.end.fill")
                        .foregroundColor(.blue)

                    Text("Следующая серия через \(countdownSecondsRemaining) с")
                        .font(.caption.bold())
                        .foregroundColor(.white)

                    Button("Сейчас") {
                        onNextEpisodeTriggered()
                    }
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(6)

                    Button(action: { isCountdownActive = false }) {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.8))
                .cornerRadius(16)
                .shadow(radius: 8)
                .padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            NavigationStack {
                List {
                    if let qualities = payload.availableQualities, !qualities.isEmpty {
                        Section {
                            ForEach(qualities) { q in
                                Button(action: {
                                    onQualitySelected(q)
                                    showSettingsSheet = false
                                }) {
                                    HStack {
                                        Text(q.label)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if payload.currentQuality == q.label {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.blue)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("Качество от источника")
                        } footer: {
                            Text("Выбор меняет видеопоток. Доступные варианты предоставляет источник.")
                        }
                    }

                    if let studios = payload.availableStudios, !studios.isEmpty {
                        Section {
                            ForEach(studios) { s in
                                Button(action: {
                                    onStudioSelected(s)
                                    showSettingsSheet = false
                                }) {
                                    HStack {
                                        Text(s.name)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        if payload.currentStudio == s.id {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.blue)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("Озвучка от источника")
                        } footer: {
                            Text("Выбор меняет видеопоток, а не аудиодорожку внутри него.")
                        }
                    }

                    Section {
                        Label {
                            Text("Аудиодорожка и субтитры")
                        } icon: {
                            Image(systemName: "captions.bubble")
                        }
                        Text("Для дорожек внутри текущего потока используйте системные элементы плеера, если они доступны.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Section("Внешний плеер") {
                        Button(action: {
                            showSettingsSheet = false
                            onOpenInInfuse()
                        }) {
                            Label("Открыть в Infuse", systemImage: "arrow.up.right.video")
                        }
                    }
                }
                .navigationTitle("Параметры потока")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Готово") {
                            showSettingsSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showEpisodesSheet) {
            NavigationStack {
                List {
                    if let playlist = payload.playlist {
                        ForEach(playlist) { item in
                            Button(action: {
                                onEpisodeSelected(item)
                                showEpisodesSheet = false
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.body)
                                            .foregroundColor(.primary)
                                        if let season = item.seasonNumber, let episode = item.episodeNumber {
                                            Text("Сезон \(season), Серия \(episode)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if payload.url == item.url {
                                        Image(systemName: "play.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Серии")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Готово") {
                            showEpisodesSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            checkResumeToast()
        }
    }

    private func checkResumeToast() {
        if let canonicalId = payload.canonicalId,
           let season = payload.season,
           let episode = payload.episode {
            let resume = WatchHistoryManager.shared.getResumePosition(
                canonicalId: canonicalId,
                season: season,
                episode: episode
            )
            if resume.time > 10 {
                let minutes = Int(resume.time) / 60
                let seconds = Int(resume.time) % 60
                resumeToastMessage = String(format: "Возобновлено с %02d:%02d (%d%%)", minutes, seconds, resume.percent)
                showResumeToast = true

                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    withAnimation {
                        self.showResumeToast = false
                    }
                }
            }
        }
    }
}
