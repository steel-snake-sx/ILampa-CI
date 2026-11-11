import Foundation

// Persistent manager for user bookmarks / favorites.
final class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()

    private let storageKey = "ilampa_user_favorites_v1"
    private let defaults = UserDefaults.standard

    @Published var favorites: [MediaItem] = []

    private init() {
        loadFavorites()
    }

    private func loadFavorites() {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) {
            self.favorites = decoded
        }
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(favorites) {
            defaults.set(encoded, forKey: storageKey)
        }
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        favorites.contains(where: { $0.id == item.id && $0.canonicalType == item.canonicalType })
    }

    func toggleFavorite(_ item: MediaItem) {
        if let idx = favorites.firstIndex(where: { $0.id == item.id && $0.canonicalType == item.canonicalType }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(item, at: 0)
        }
        persist()
    }

    func removeFavorite(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        persist()
    }

    func clearFavorites() {
        favorites.removeAll()
        defaults.removeObject(forKey: storageKey)
    }
}
