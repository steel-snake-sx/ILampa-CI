import SwiftUI

// Pure native user library: Continue Watching, Favorites/Bookmarks, and Watch History.
struct MyLibraryView: View {
    var onResumePlayback: ((WatchHistoryRecord) -> Void)?
    var onSelectMediaItem: ((MediaItem) -> Void)?
    var onPlayRequest: ((PlayPayload) -> Void)?

    @StateObject private var favoritesManager = FavoritesManager.shared
    @State private var historyRecords: [WatchHistoryRecord] = []
    @State private var showClearAlert = false
    @State private var selectedItemForDetail: MediaItem?
    @State private var showPlaybackUnavailable = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Continue Watching
                let inProgress = historyRecords.filter { $0.percent > 2 && $0.percent < 92 }
                if !inProgress.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(inProgress) { record in
                                    VStack(alignment: .leading, spacing: 6) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 10)
                                                .fill(Color(UIColor.secondarySystemBackground))
                                                .frame(width: 160, height: 95)

                                            Image(systemName: "play.circle.fill")
                                                .font(.system(size: 32))
                                                .foregroundColor(.white.opacity(0.85))

                                            VStack {
                                                Spacer()
                                                ProgressView(value: Double(record.percent), total: 100.0)
                                                    .tint(.blue)
                                                    .padding(.horizontal, 8)
                                                    .padding(.bottom, 6)
                                            }
                                        }

                                        Text(record.title ?? record.canonicalId)
                                            .font(.caption.bold())
                                            .lineLimit(1)
                                            .frame(width: 160, alignment: .leading)

                                        HStack {
                                            if record.season > 0 {
                                                Text("С\(record.season) Э\(record.episode)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Text("\(record.percent)%")
                                                .font(.caption2)
                                                .foregroundColor(.blue)
                                        }
                                        .frame(width: 160)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onResumePlayback?(record)
                                    }
                                    .accessibilityIdentifier("continue_record_\(record.id)")
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    } header: {
                        Label("Продолжить просмотр", systemImage: "play.circle.fill")
                    }
                }

                // MARK: - Favorites / Bookmarks
                Section {
                    if favoritesManager.favorites.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "bookmark")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("В избранном пока ничего нет")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("Нажмите значок закладки на странице фильма или сериала, чтобы сохранить его здесь.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.vertical, 12)
                            Spacer()
                        }
                    } else {
                        ForEach(favoritesManager.favorites) { fav in
                            Button(action: {
                                selectedItemForDetail = fav
                            }) {
                                HStack(spacing: 12) {
                                    if let url = fav.posterUrl {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case .success(let img):
                                                img.resizable()
                                                    .aspectRatio(2/3, contentMode: .fill)
                                                    .frame(width: 44, height: 66)
                                                    .cornerRadius(6)
                                            case .empty, .failure:
                                                RoundedRectangle(cornerRadius: 6)
                                                    .fill(Color(UIColor.secondarySystemBackground))
                                                    .frame(width: 44, height: 66)
                                            @unknown default:
                                                EmptyView()
                                            }
                                        }
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color(UIColor.secondarySystemBackground))
                                            .frame(width: 44, height: 66)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(fav.displayTitle)
                                            .font(.body.bold())
                                            .foregroundColor(.primary)
                                            .lineLimit(1)

                                        HStack(spacing: 6) {
                                            Text(fav.displayYear)
                                                .font(.caption)
                                                .foregroundColor(.secondary)

                                            if let vote = fav.voteAverage, vote > 0 {
                                                Text("•")
                                                    .foregroundColor(.secondary)
                                                Text("★ \(fav.ratingText)")
                                                    .font(.caption.bold())
                                                    .foregroundColor(.yellow)
                                            }
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: favoritesManager.removeFavorite)
                    }
                } header: {
                    Label("Избранное и закладки", systemImage: "bookmark.fill")
                }

                // MARK: - Watch History List
                Section {
                    if historyRecords.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.title2)
                                    .foregroundColor(.secondary)
                                Text("История просмотров пуста")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 12)
                            Spacer()
                        }
                    } else {
                        ForEach(historyRecords) { record in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.title ?? record.canonicalId)
                                        .font(.body)
                                    HStack(spacing: 8) {
                                        if record.season > 0 {
                                            Text("Сезон \(record.season), Серия \(record.episode)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        if let studio = record.studio, !studio.isEmpty {
                                            Text("•  \(studio)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatTime(record.timecode))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.primary)
                                    Text("\(record.percent)%")
                                        .font(.caption2)
                                        .foregroundColor(record.percent >= 90 ? .green : .blue)
                                }
                            }
                        }
                        .onDelete(perform: deleteHistoryItem)

                        Button(role: .destructive, action: { showClearAlert = true }) {
                            HStack {
                                Spacer()
                                Text("Очистить всю историю")
                                    .font(.subheadline)
                                Spacer()
                            }
                        }
                    }
                } header: {
                    Label("История просмотров", systemImage: "clock.fill")
                }
            }
            .navigationTitle("Моё")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: reloadHistory) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .navigationDestination(item: $selectedItemForDetail) { item in
                MediaDetailView(
                    item: item,
                    onPlayRequest: { payload in
                        guard let onPlayRequest else {
                            showPlaybackUnavailable = true
                            return
                        }
                        onPlayRequest(payload)
                    }
                )
                .alert("Воспроизведение недоступно", isPresented: $showPlaybackUnavailable) {
                    Button("Понятно", role: .cancel) {}
                } message: {
                    Text("Не удалось открыть проигрыватель.")
                }
            }
            .onAppear(perform: reloadHistory)
            .alert("Очистить историю?", isPresented: $showClearAlert) {
                Button("Отмена", role: .cancel) {}
                Button("Очистить", role: .destructive) {
                    WatchHistoryManager.shared.clearHistory()
                    reloadHistory()
                }
            } message: {
                Text("Все сохраненные позиции просмотра и история будут удалены.")
            }
        }
    }

    private func reloadHistory() {
        historyRecords = WatchHistoryManager.shared.getAllRecords()
    }

    private func deleteHistoryItem(at offsets: IndexSet) {
        for index in offsets {
            let record = historyRecords[index]
            WatchHistoryManager.shared.deleteRecord(
                canonicalId: record.canonicalId,
                season: record.season,
                episode: record.episode
            )
        }
        reloadHistory()
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        let m = s / 60
        let h = m / 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m % 60, s % 60)
        } else {
            return String(format: "%02d:%02d", m, s % 60)
        }
    }
}
