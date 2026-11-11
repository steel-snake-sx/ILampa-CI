import Foundation
import Combine

enum MediaCategory: String, CaseIterable, Identifiable {
    case trending = "В тренде"
    case movies = "Фильмы"
    case tvSeries = "Сериалы"
    case anime = "Аниме"
    case cartoons = "Мультфильмы"

    var id: String { rawValue }

    var endpointPath: String {
        switch self {
        case .trending:
            return "trending/all/week"
        case .movies:
            return "movie/popular"
        case .tvSeries:
            return "tv/popular"
        case .anime:
            return "discover/tv?with_genres=16&with_original_language=ja&sort_by=popularity.desc"
        case .cartoons:
            return "discover/movie?with_genres=16&sort_by=popularity.desc"
        }
    }
}

// Native TMDB & Lampa Catalog data service.
final class TMDBService: ObservableObject {
    static let shared = TMDBService()

    private let apiKey = "4ef0d7355d9ffb5151e987764708ce96" // Standard Lampa TMDB key
    private let baseUrl = "https://api.themoviedb.org/3"
    private let session: URLSession
    private let catalogCachePrefix = "ilampa_catalog_cache_v1_"

    @Published var itemsByCategory: [MediaCategory: [MediaItem]] = [:]
    @Published var isLoading = false
    @Published var networkError: String?
    @Published var lastSearchError: String?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 20.0
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
    }

    // Loads catalog items for the given category with automatic fallback to deterministic fixtures.
    func loadCategory(_ category: MediaCategory, completion: (([MediaItem]) -> Void)? = nil) {
        let separator = category.endpointPath.contains("?") ? "&" : "?"
        let urlString = "\(baseUrl)/\(category.endpointPath)\(separator)api_key=\(apiKey)&language=ru-RU"

        guard let url = URL(string: urlString) else {
            let fallback = deterministicFixtures(for: category)
            self.itemsByCategory[category] = fallback
            completion?(fallback)
            return
        }

        self.isLoading = true
        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false

                if error == nil,
                   let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let data = data,
                   let decoded = try? JSONDecoder().decode(TMDBResponse.self, from: data) {
                    self.itemsByCategory[category] = decoded.results
                    if !decoded.results.isEmpty { self.saveCatalogCache(decoded.results, for: category) }
                    self.networkError = nil
                    completion?(decoded.results)
                } else {
                    // Never silently replace a successful catalog with unrelated results. Reuse
                    // only a prior response for this category; deterministic samples are clearly
                    // labeled as an offline first-launch fallback.
                    let cached = self.loadCatalogCache(for: category)
                    let fallback = cached ?? self.deterministicFixtures(for: category)
                    self.itemsByCategory[category] = fallback
                    self.networkError = cached == nil
                        ? "Каталог недоступен в этой сети. Показан автономный пример; потяните экран для повтора."
                        : "Каталог недоступен в этой сети. Показаны сохранённые данные; потяните экран для повтора."
                    let code = (error as NSError?)?.code
                    DiagnosticsLogManager.shared.log(category: "[Catalog]",
                        message: "TMDB catalogue fallback category=\(category.rawValue), host=api.themoviedb.org, errorCode=\(code.map { String($0) } ?? "none"), cache=\(cached != nil)",
                        level: .warning)
                    completion?(fallback)
                }
            }
        }.resume()
    }

    private func saveCatalogCache(_ items: [MediaItem], for category: MediaCategory) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: catalogCachePrefix + category.rawValue)
    }

    private func loadCatalogCache(for category: MediaCategory) -> [MediaItem]? {
        guard let data = UserDefaults.standard.data(forKey: catalogCachePrefix + category.rawValue),
              let items = try? JSONDecoder().decode([MediaItem].self, from: data), !items.isEmpty else { return nil }
        return items
    }

    // Searches movies and series across TMDB.
    func search(query: String, completion: @escaping ([MediaItem]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion([])
            return
        }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(baseUrl)/search/multi?api_key=\(apiKey)&query=\(encoded)&language=ru-RU") else {
            completion(searchFallbackFixtures(matching: trimmed))
            return
        }

        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if error == nil,
                   let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let data = data,
                   let decoded = try? JSONDecoder().decode(TMDBResponse.self, from: data) {
                    self?.lastSearchError = nil
                    completion(decoded.results)
                } else {
                    let fallback = self?.searchFallbackFixtures(matching: trimmed) ?? []
                    self?.lastSearchError = fallback.isEmpty
                        ? "Поиск TMDB недоступен в этой сети. Попробуйте ещё раз позже."
                        : "Поиск TMDB недоступен в этой сети. Показаны подходящие автономные записи."
                    let code = (error as NSError?)?.code
                    DiagnosticsLogManager.shared.log(category: "[Catalog]",
                        message: "TMDB search fallback host=api.themoviedb.org, errorCode=\(code.map { String($0) } ?? "none"), matchingFixtures=\(fallback.count)",
                        level: .warning)
                    completion(fallback)
                }
            }
        }.resume()
    }

    // Fetches full details for a movie or TV show.
    func loadDetails(id: Int, type: String, completion: @escaping (MediaDetail?) -> Void) {
        let path = (type == "tv") ? "tv" : "movie"
        let urlString = "\(baseUrl)/\(path)/\(id)?api_key=\(apiKey)&append_to_response=credits&language=ru-RU"

        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        session.dataTask(with: url) { data, response, error in
            DispatchQueue.main.async {
                if let data = data,
                   let detail = try? JSONDecoder().decode(MediaDetail.self, from: data) {
                    completion(detail)
                } else {
                    completion(nil)
                }
            }
        }.resume()
    }

    // Deterministic offline fixtures ensuring rich visual representation in any environment.
    private func deterministicFixtures(for category: MediaCategory) -> [MediaItem] {
        switch category {
        case .trending, .movies:
            return [
                MediaItem(
                    id: 693134,
                    title: "Дюна: Часть вторая",
                    name: nil,
                    originalTitle: "Dune: Part Two",
                    originalName: nil,
                    overview: "Герцог Пол Атрейдес присоединяется к племени фрименов, чтобы отомстить заговорщикам, уничтожившим его семью.",
                    posterPath: "/1pdfLvk8ke9mv17mXf2o9a6i33z.jpg",
                    backdropPath: "/xOMo8BRK7PfcJv9JCnx7s520DRq.jpg",
                    mediaType: "movie",
                    releaseDate: "2024-02-27",
                    firstAirDate: nil,
                    voteAverage: 8.3,
                    voteCount: 4500,
                    genreIds: [878, 12]
                ),
                MediaItem(
                    id: 1022789,
                    title: "Головоломка 2",
                    name: nil,
                    originalTitle: "Inside Out 2",
                    originalName: nil,
                    overview: "Радость, Печаль, Гнев, Страх и Брезгливость встречают новых обитателей головного мозга подростка Райли: Тревожность и Смущение.",
                    posterPath: "/vpnVM9B6NMmQpWeZvzLvDESb2QY.jpg",
                    backdropPath: "/stKGOmAUuvWs0yqfKLDdHkjyt0n.jpg",
                    mediaType: "movie",
                    releaseDate: "2024-06-11",
                    firstAirDate: nil,
                    voteAverage: 7.7,
                    voteCount: 3200,
                    genreIds: [16, 10751, 35]
                ),
                MediaItem(
                    id: 533535,
                    title: "Дэдпул и Росомаха",
                    name: nil,
                    originalTitle: "Deadpool & Wolverine",
                    originalName: nil,
                    overview: "Увядающий Уэйд Уилсон вынужден объединиться с ещё более нежелающим сотрудничать Росомахой, чтобы спасти мультивселенную.",
                    posterPath: "/8cdWjvZQUExUUTzyp4t6EDMubfO.jpg",
                    backdropPath: "/yDHYTfA3R0jFYba16jBB1jv8M9v.jpg",
                    mediaType: "movie",
                    releaseDate: "2024-07-24",
                    firstAirDate: nil,
                    voteAverage: 7.8,
                    voteCount: 3800,
                    genreIds: [28, 35, 878]
                ),
                MediaItem(
                    id: 823464,
                    title: "Годзилла и Конг: Новая империя",
                    name: nil,
                    originalTitle: "Godzilla x Kong: The New Empire",
                    originalName: nil,
                    overview: "Могущественный Конг и бесстрашный Годзилла противостоят новой колоссальной угрозе, скрытой глубоко в недрах Земли.",
                    posterPath: "/tMefBSflR6PGQLv7WvFPpKLZkyk.jpg",
                    backdropPath: "/qrGtVFxaD8c7et0j3sjYneodmRw.jpg",
                    mediaType: "movie",
                    releaseDate: "2024-03-27",
                    firstAirDate: nil,
                    voteAverage: 7.2,
                    voteCount: 2900,
                    genreIds: [28, 878, 12]
                ),
                MediaItem(
                    id: 945961,
                    title: "Чужой: Ромул",
                    name: nil,
                    originalTitle: "Alien: Romulus",
                    originalName: nil,
                    overview: "Исследуя заброшенную космическую станцию, группа молодых колонизаторов сталкивается лицом к лицу с самой ужасной формой жизни во вселенной.",
                    posterPath: "/b33nnKl1vvg6AqICRi128jh4t9x.jpg",
                    backdropPath: "/9SSEUrSqhljBMzRe4aB5Y1W57w8.jpg",
                    mediaType: "movie",
                    releaseDate: "2024-08-13",
                    firstAirDate: nil,
                    voteAverage: 7.3,
                    voteCount: 2100,
                    genreIds: [27, 878]
                ),
                MediaItem(
                    id: 802219,
                    title: "Боб Марли: Одна любовь",
                    name: nil,
                    originalTitle: "Bob Marley: One Love",
                    originalName: nil,
                    overview: "История преодоления невзгод и путь к легендарной революционной музыке Боба Марли.",
                    posterPath: "/192bC7W4N8k8pWp5d3M4M18N9eD.jpg",
                    backdropPath: "/mDeUmPe4MF35WW3PwrQ9ogq0ux3.jpg",
                    mediaType: "movie",
                    releaseDate: "2024-02-14",
                    firstAirDate: nil,
                    voteAverage: 7.0,
                    voteCount: 1100,
                    genreIds: [10402, 18]
                )
            ]

        case .tvSeries:
            return [
                MediaItem(
                    id: 94605,
                    title: nil,
                    name: "Аркейн",
                    originalTitle: nil,
                    originalName: "Arcane",
                    overview: "В разгар противостояния между городами-близнецами Пилтовер и Заун две сестры оказываются по разные стороны баррикад.",
                    posterPath: "/fqldf2t8ztc9aiwn396mlkjjbop.jpg",
                    backdropPath: "/uDgy6hyPd82kOHh6I95FLtLnj6p.jpg",
                    mediaType: "tv",
                    releaseDate: nil,
                    firstAirDate: "2021-11-06",
                    voteAverage: 8.7,
                    voteCount: 3900,
                    genreIds: [16, 10765, 18]
                ),
                MediaItem(
                    id: 1399,
                    title: nil,
                    name: "Игра престолов",
                    originalTitle: nil,
                    originalName: "Game of Thrones",
                    overview: "Борьба за Железный трон Семи Королевств разворачивается на фоне надвигающейся из-за Стены древней угрозы.",
                    posterPath: "/1XS1oqL89opfnbLl8WnZY1O1uJx.jpg",
                    backdropPath: "/2OMB0ynKlyIenMJWI2Dy9IWT4c.jpg",
                    mediaType: "tv",
                    releaseDate: nil,
                    firstAirDate: "2011-04-17",
                    voteAverage: 8.4,
                    voteCount: 24000,
                    genreIds: [10765, 18, 10759]
                ),
                MediaItem(
                    id: 119051,
                    title: nil,
                    name: "Сёгун",
                    originalTitle: nil,
                    originalName: "Shōgun",
                    overview: "В Японии 1600 года лорд Торанага ведет борьбу за выживание против объединившихся против него регентов, когда на берег выбрасывает английский корабль.",
                    posterPath: "/7O4iVfOMQmdCSxhOg1WnzG1AgYT.jpg",
                    backdropPath: "/zW0v2YT74C69cuYNflKRyGeBCU5.jpg",
                    mediaType: "tv",
                    releaseDate: nil,
                    firstAirDate: "2024-02-27",
                    voteAverage: 8.5,
                    voteCount: 1800,
                    genreIds: [18, 10768]
                ),
                MediaItem(
                    id: 100088,
                    title: nil,
                    name: "Одни из нас",
                    originalTitle: nil,
                    originalName: "The Last of Us",
                    overview: "Спустя 20 лет после краха цивилизации закаленный контрабандист Джоэл соглашается вывести 14-летнюю Элли из опасной зоны карантина.",
                    posterPath: "/uKvVjHNqB5VmOrdxqAt2V7JMrRI.jpg",
                    backdropPath: "/9zpaGw1U0v0WvJv9x0V2vF1u5w9.jpg",
                    mediaType: "tv",
                    releaseDate: nil,
                    firstAirDate: "2023-01-15",
                    voteAverage: 8.6,
                    voteCount: 4900,
                    genreIds: [18, 10765]
                )
            ]

        case .anime:
            return [
                MediaItem(
                    id: 1429,
                    title: nil,
                    name: "Атака титанов",
                    originalTitle: nil,
                    originalName: "Shingeki no Kyojin",
                    overview: "Человечество укрылось за колоссальными стенами от гигантских плотоядных гуманоидов. Эрен Йегер решает уничтожить всех титанов.",
                    posterPath: "/hTP1dtwGFamzeL2V9Qtwx4vd2um.jpg",
                    backdropPath: "/q8y1qN6P30vA5aJ0018P0N92V0Z.jpg",
                    mediaType: "tv",
                    releaseDate: nil,
                    firstAirDate: "2013-04-07",
                    voteAverage: 8.6,
                    voteCount: 6100,
                    genreIds: [16, 10765, 10759]
                ),
                MediaItem(
                    id: 85937,
                    title: nil,
                    name: "Клинок, рассекающий демонов",
                    originalTitle: nil,
                    originalName: "Kimetsu no Yaiba",
                    overview: "Тандзиро Камадо становится истребителем демонов, чтобы найти лекарство для своей сестры Незуко, превращенной в демона.",
                    posterPath: "/xUfRZu2mi8jH6SzQEJGP6tjBuYj.jpg",
                    backdropPath: "/nTvM4mhqZlHIghNGI2LJ40y5RjF.jpg",
                    mediaType: "tv",
                    releaseDate: nil,
                    firstAirDate: "2019-04-06",
                    voteAverage: 8.7,
                    voteCount: 3800,
                    genreIds: [16, 10759, 10765]
                ),
                MediaItem(
                    id: 37854,
                    title: nil,
                    name: "Ван-Пис",
                    originalTitle: nil,
                    originalName: "One Piece",
                    overview: "Манки Д. Луффи вместе со своей верной командой Соломенной Шляпы отправляется в опасное плавание по Гранд Лайн в поисках сокровища One Piece.",
                    posterPath: "/e3Nb52e55x12A9r7WvP4c20uH3a.jpg",
                    backdropPath: "/2rmK7mnchq9opmaIczdqYKqzufa.jpg",
                    mediaType: "tv",
                    releaseDate: nil,
                    firstAirDate: "1999-10-20",
                    voteAverage: 8.7,
                    voteCount: 4600,
                    genreIds: [16, 10759, 35]
                )
            ]

        case .cartoons:
            return [
                MediaItem(
                    id: 1022789,
                    title: "Головоломка 2",
                    name: nil,
                    originalTitle: "Inside Out 2",
                    originalName: nil,
                    overview: "Эмоции Райли сталкиваются с взрослением и новыми чувствами.",
                    posterPath: "/vpnVM9B6NMmQpWeZvzLvDESb2QY.jpg",
                    backdropPath: "/stKGOmAUuvWs0yqfKLDdHkjyt0n.jpg",
                    mediaType: "movie",
                    releaseDate: "2024-06-11",
                    firstAirDate: nil,
                    voteAverage: 7.7,
                    voteCount: 3200,
                    genreIds: [16, 10751, 35]
                ),
                MediaItem(
                    id: 569094,
                    title: "Человек-паук: Паутина вселенных",
                    name: nil,
                    originalTitle: "Spider-Man: Across the Spider-Verse",
                    originalName: nil,
                    overview: "Майлз Моралес отправляется в путешествие по мультивселенной вместе с Гвен Стейси.",
                    posterPath: "/8Vt6mWEReuy4Of61Lnj5Xj704m8.jpg",
                    backdropPath: "/4HodYYKEIsGOdinkGi2Ucz6X9i0.jpg",
                    mediaType: "movie",
                    releaseDate: "2023-05-31",
                    firstAirDate: nil,
                    voteAverage: 8.4,
                    voteCount: 6500,
                    genreIds: [16, 28, 12, 878]
                )
            ]
        }
    }

    private func searchFallbackFixtures(matching query: String) -> [MediaItem] {
        let clean = query.lowercased()
        let all = deterministicFixtures(for: .trending) +
                  deterministicFixtures(for: .tvSeries) +
                  deterministicFixtures(for: .anime)
        return all.filter { item in
            item.displayTitle.lowercased().contains(clean) ||
            (item.overview?.lowercased().contains(clean) ?? false)
        }
    }
}
