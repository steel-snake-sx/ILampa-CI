import SwiftUI

// Pure native search with instant results grid, suggestions, and history.
struct SearchView: View {
    var onPlayRequest: (PlayPayload) -> Void
    var initialQuery: String = ""

    @AppStorage("save_search_history") private var saveSearchHistory = true
    @State private var query = ""
    @FocusState private var isSearchFieldFocused: Bool
    @State private var searchResults: [MediaItem] = []
    @State private var recentSearches: [String] = []
    @State private var isSearching = false
    @State private var selectedItemForDetail: MediaItem?
    @StateObject private var tmdbService = TMDBService.shared

    private let suggestions = [
        "Фильмы 2026",
        "Топ сериалов",
        "Новинки недели",
        "Marvel",
        "Аниме",
        "Детективы",
        "Фантастика"
    ]

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Фильмы, сериалы, персоны...", text: $query)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        isSearchFieldFocused = false
                        performSearch(query)
                    }
                    .accessibilityIdentifier("catalogSearchInput")
                    .onChange(of: initialQuery) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        query = newValue
                        performSearch(newValue)
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                        isSearchFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Очистить поиск")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)

            Group {
                if !searchResults.isEmpty {
                    VStack(spacing: 0) {
                    if let error = tmdbService.lastSearchError {
                        networkNotice(error)
                    }
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(searchResults) { item in
                                Button(action: {
                                    selectedItemForDetail = item
                                }) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        ZStack(alignment: .topTrailing) {
                                            if let url = item.posterUrl {
                                                AsyncImage(url: url) { phase in
                                                    switch phase {
                                                    case .success(let image):
                                                        image
                                                            .resizable()
                                                            .aspectRatio(2/3, contentMode: .fill)
                                                            .cornerRadius(8)
                                                    case .empty, .failure:
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .fill(Color(UIColor.secondarySystemBackground))
                                                            .aspectRatio(2/3, contentMode: .fit)
                                                            .overlay(Image(systemName: "film").foregroundColor(.secondary))
                                                    @unknown default:
                                                        EmptyView()
                                                    }
                                                }
                                            } else {
                                                RoundedRectangle(cornerRadius: 8)
                                                    .fill(Color(UIColor.secondarySystemBackground))
                                                    .aspectRatio(2/3, contentMode: .fit)
                                                    .overlay(Image(systemName: "film").foregroundColor(.secondary))
                                            }

                                            if let vote = item.voteAverage, vote > 0 {
                                                Text(item.ratingText)
                                                    .font(.caption2.bold())
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 2)
                                                    .background(Color.black.opacity(0.75))
                                                    .foregroundColor(.yellow)
                                                    .cornerRadius(4)
                                                    .padding(4)
                                            }
                                        }

                                        Text(item.displayTitle)
                                            .font(.caption.bold())
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        Text(item.displayYear)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("search_item_\(item.id)")
                            }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    }
                } else {
                    List {
                        if let error = tmdbService.lastSearchError, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Section {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(error, systemImage: "wifi.exclamationmark")
                                        .font(.subheadline)
                                        .foregroundColor(.orange)
                                    Button("Повторить поиск") { performSearch(query) }
                                        .font(.caption.bold())
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        Section("Быстрый выбор") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(suggestions, id: \.self) { item in
                                        Button(action: {
                                            query = item
                                            performSearch(item)
                                        }) {
                                            Text(item)
                                                .font(.subheadline)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .background(Color(UIColor.secondarySystemBackground))
                                                .foregroundColor(.primary)
                                                .cornerRadius(16)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }

                        Section("История поиска") {
                            Toggle("Сохранять запросы", isOn: $saveSearchHistory)
                            if saveSearchHistory && !recentSearches.isEmpty {
                                ForEach(recentSearches, id: \.self) { item in
                                    Button(action: {
                                        query = item
                                        performSearch(item)
                                    }) {
                                        HStack {
                                            Image(systemName: "clock")
                                                .foregroundColor(.secondary)
                                            Text(item)
                                                .foregroundColor(.primary)
                                            Spacer()
                                            Image(systemName: "arrow.up.left")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .onDelete(perform: deleteRecent)

                                Button(role: .destructive, action: clearRecent) {
                                    HStack {
                                        Spacer()
                                        Text("Очистить историю поиска")
                                            .font(.caption)
                                        Spacer()
                                    }
                                }
                            }
                        }

                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Поиск в каталоге iLampa", systemImage: "sparkle.magnifyingglass")
                                    .font(.headline)
                                Text("Поиск осуществляется по базе TMDB среди фильмов, сериалов и аниме с поддержкой русскоязычных названий.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
            .navigationTitle("Поиск")
            .onChange(of: saveSearchHistory) { _, enabled in
                if !enabled {
                    recentSearches.removeAll()
                    UserDefaults.standard.removeObject(forKey: "ilampa_recent_searches")
                } else {
                    loadRecent()
                }
            }
            .onChange(of: query) { newQuery in
                if newQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchResults = []
                }
            }
            .navigationDestination(item: $selectedItemForDetail) { item in
                MediaDetailView(
                    item: item,
                    onPlayRequest: onPlayRequest
                )
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { isSearchFieldFocused = false }
                }
            }
            .onAppear {
                loadRecent()
                if !initialQuery.isEmpty {
                    query = initialQuery
                    performSearch(initialQuery)
                }
            }
    }

    private func networkNotice(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundColor(.orange)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Повторить") { performSearch(query) }
                .font(.caption.bold())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    private func performSearch(_ text: String) {
        isSearchFieldFocused = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if saveSearchHistory && !recentSearches.contains(trimmed) {
            recentSearches.insert(trimmed, at: 0)
            if recentSearches.count > 10 {
                recentSearches.removeLast()
            }
            saveRecent()
        }

        isSearching = true
        TMDBService.shared.search(query: trimmed) { results in
            self.searchResults = results
            self.isSearching = false
        }
    }

    private func loadRecent() {
        guard saveSearchHistory else { recentSearches.removeAll(); return }
        if let saved = UserDefaults.standard.stringArray(forKey: "ilampa_recent_searches") {
            recentSearches = saved
        }
    }

    private func saveRecent() {
        guard saveSearchHistory else { return }
        UserDefaults.standard.set(recentSearches, forKey: "ilampa_recent_searches")
    }

    private func deleteRecent(at offsets: IndexSet) {
        recentSearches.remove(atOffsets: offsets)
        saveRecent()
    }

    private func clearRecent() {
        recentSearches.removeAll()
        saveRecent()
    }
}
