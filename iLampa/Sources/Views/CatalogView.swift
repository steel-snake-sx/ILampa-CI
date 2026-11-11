import SwiftUI

// Pure native catalog with categories, poster grid, and media details flow.
struct CatalogView: View {
    var onPlayRequest: (PlayPayload) -> Void
    var onSearchRequested: (String) -> Void = { _ in }

    @StateObject private var tmdbService = TMDBService.shared
    @State private var selectedCategory: MediaCategory = .trending
    @State private var catalogSearchText = ""
    @FocusState private var catalogSearchFocused: Bool
    @State private var selectedItemForDetail: MediaItem?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    private func submitCatalogSearch() {
        let submitted = catalogSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !submitted.isEmpty else { return }
        catalogSearchFocused = false
        onSearchRequested(submitted)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Edit the query without leaving the catalog.
                // Navigate to search results only when the user explicitly submits.
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Поиск фильмов, сериалов, аниме…", text: $catalogSearchText)
                        .focused($catalogSearchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { submitCatalogSearch() }
                        .accessibilityIdentifier("catalogSearchEntry")
                    if !catalogSearchText.isEmpty {
                        Button {
                            catalogSearchText = ""
                            catalogSearchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Очистить запрос")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

                // MARK: - Category Segmented Selector
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MediaCategory.allCases) { cat in
                            Button(action: {
                                selectedCategory = cat
                                tmdbService.loadCategory(cat)
                            }) {
                                Text(cat.rawValue)
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(selectedCategory == cat ? Color.blue : Color(UIColor.secondarySystemBackground))
                                    .foregroundColor(selectedCategory == cat ? .white : .primary)
                                    .cornerRadius(18)
                            }
                            .accessibilityIdentifier("category_\(cat.id)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .background(Color(UIColor.systemBackground))

                Divider()

                if let networkError = tmdbService.networkError {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundColor(.orange)
                        Text(networkError)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Повторить") {
                            tmdbService.loadCategory(selectedCategory)
                        }
                        .font(.caption.bold())
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }

                // MARK: - Content Grid
                let items = tmdbService.itemsByCategory[selectedCategory] ?? []

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(items) { item in
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
                                                case .empty:
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color(UIColor.secondarySystemBackground))
                                                        .aspectRatio(2/3, contentMode: .fit)
                                                        .overlay(
                                                            Image(systemName: "film")
                                                                .foregroundColor(.secondary)
                                                        )
                                                case .failure:
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color(UIColor.secondarySystemBackground))
                                                        .aspectRatio(2/3, contentMode: .fit)
                                                        .overlay {
                                                            VStack(spacing: 6) {
                                                                Image(systemName: "photo")
                                                                    .foregroundColor(.secondary)
                                                                Text("Постер недоступен")
                                                                    .font(.caption2)
                                                                    .foregroundColor(.secondary)
                                                                    .multilineTextAlignment(.center)
                                                            }
                                                            .padding(6)
                                                        }
                                                        .task { await ImageNetworkDiagnostics.inspectFailure(of: url) }
                                                @unknown default:
                                                    EmptyView()
                                                }
                                            }
                                        } else {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(Color(UIColor.secondarySystemBackground))
                                                .aspectRatio(2/3, contentMode: .fit)
                                                .overlay(
                                                    Image(systemName: "film")
                                                        .foregroundColor(.secondary)
                                                )
                                        }

                                        // Rating Pill
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
                            .accessibilityIdentifier("catalog_item_\(item.id)")
                        }
                    }
                    .padding(16)
                }
                .refreshable {
                    tmdbService.loadCategory(selectedCategory)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Каталог")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        catalogSearchFocused = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityIdentifier("catalogSearchToolbarButton")
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
                    Button("Готово") { catalogSearchFocused = false }
                }
            }
            .onAppear {
                if tmdbService.itemsByCategory[selectedCategory] == nil {
                    tmdbService.loadCategory(selectedCategory)
                }
            }
        }
    }
}
