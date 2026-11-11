import Foundation

// Core media item representing a movie, tv show, or anime in the catalog and search results.
struct MediaItem: Identifiable, Codable, Hashable {
    let id: Int
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let mediaType: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let genreIds: [Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case originalTitle = "original_title"
        case originalName = "original_name"
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case mediaType = "media_type"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case genreIds = "genre_ids"
    }

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? "Без названия"
    }

    var displayYear: String {
        let dateStr = releaseDate ?? firstAirDate ?? ""
        if dateStr.count >= 4 {
            return String(dateStr.prefix(4))
        }
        return ""
    }

    var ratingText: String {
        guard let rating = voteAverage, rating > 0 else { return "—" }
        return String(format: "%.1f", rating)
    }

    var posterUrl: URL? {
        guard let path = posterPath, !path.isEmpty else { return nil }
        if path.hasPrefix("http") {
            return URL(string: path)
        }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    var backdropUrl: URL? {
        guard let path = backdropPath, !path.isEmpty else { return posterUrl }
        if path.hasPrefix("http") {
            return URL(string: path)
        }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
    }

    var canonicalType: String {
        if let type = mediaType {
            return type
        }
        if firstAirDate != nil || name != nil {
            return "tv"
        }
        return "movie"
    }

    var canonicalId: String {
        "urn:media:tmdb:\(canonicalType):\(id)"
    }
}

// Detailed metadata for an opened movie or series.
struct MediaDetail: Identifiable, Codable {
    let id: Int
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let voteCount: Int?
    let runtime: Int?
    let numberOfSeasons: Int?
    let numberOfEpisodes: Int?
    let genres: [GenreItem]?
    let credits: CreditsResponse?
    let seasons: [SeasonSummary]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case originalTitle = "original_title"
        case originalName = "original_name"
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case runtime
        case numberOfSeasons = "number_of_seasons"
        case numberOfEpisodes = "number_of_episodes"
        case genres
        case credits
        case seasons
    }

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? "Без названия"
    }

    var displayYear: String {
        let dateStr = releaseDate ?? firstAirDate ?? ""
        if dateStr.count >= 4 {
            return String(dateStr.prefix(4))
        }
        return ""
    }

    var durationOrSeasonsText: String {
        if let rt = runtime, rt > 0 {
            let h = rt / 60
            let m = rt % 60
            return h > 0 ? "\(h) ч \(m) мин" : "\(m) мин"
        }
        if let ns = numberOfSeasons, ns > 0 {
            return "\(ns) \(pluralizeSeasons(ns))"
        }
        return ""
    }

    private func pluralizeSeasons(_ n: Int) -> String {
        let rem10 = n % 10
        let rem100 = n % 100
        if rem10 == 1 && rem100 != 11 { return "сезон" }
        if rem10 >= 2 && rem10 <= 4 && (rem100 < 10 || rem100 >= 20) { return "сезона" }
        return "сезонов"
    }

    var posterUrl: URL? {
        guard let path = posterPath, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(path)")
    }

    var backdropUrl: URL? {
        guard let path = backdropPath, !path.isEmpty else { return posterUrl }
        return URL(string: "https://image.tmdb.org/t/p/w1280\(path)")
    }
}

struct GenreItem: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
}

struct SeasonSummary: Identifiable, Codable, Hashable {
    let id: Int
    let seasonNumber: Int
    let name: String?
    let episodeCount: Int?
    let posterPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case seasonNumber = "season_number"
        case name
        case episodeCount = "episode_count"
        case posterPath = "poster_path"
    }
}

struct CreditsResponse: Codable {
    let cast: [CastItem]?
}

struct CastItem: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case character
        case profilePath = "profile_path"
    }

    var profileUrl: URL? {
        guard let path = profilePath, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w185\(path)")
    }
}

struct TMDBResponse: Codable {
    let page: Int?
    let results: [MediaItem]
    let totalPages: Int?
    let totalResults: Int?

    enum CodingKeys: String, CodingKey {
        case page
        case results
        case totalPages = "total_pages"
        case totalResults = "total_results"
    }
}
