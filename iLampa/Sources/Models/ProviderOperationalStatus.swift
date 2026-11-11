import Foundation

// Strictly separates verified operational stages from preliminary registration callbacks.
enum ProviderOperationalStatus: String, Codable, CaseIterable {
    // Primary truthful lifecycle cases
    case unconfigured = "Не настроен"
    case connectionFailed = "Ошибка подключения"
    case initialized = "Инициализирован"
    case searchAvailable = "Поиск доступен"
    case noMatchingTitles = "Совпадений не найдено"
    case resultsFound = "Результаты найдены"
    case streamResolved = "Поток получен"
    case playbackVerified = "Воспроизведение проверено"

    // Backward compatibility and plugin registration states
    case registered = "Зарегистрирован"
    case radioReady = "Радио готово"
    case interfaceOnly = "Интерфейс"
    case adapterRequired = "Требуется адаптер"
    case authRequired = "Требуется авторизация"
    case loaded = "Скрипт загружен"
    case executed = "Скрипт выполнен"

    // Aliases for compatibility
    static let notInstalled: ProviderOperationalStatus = .unconfigured
    static let failed: ProviderOperationalStatus = .connectionFailed
    static let temporarilyUnavailable: ProviderOperationalStatus = .connectionFailed
    static let searchVerified: ProviderOperationalStatus = .searchAvailable
    static let resolutionVerified: ProviderOperationalStatus = .streamResolved

    var isFunctionallyOperational: Bool {
        self == .streamResolved || self == .playbackVerified || self == .radioReady
    }

    var badgeColorName: String {
        switch self {
        case .playbackVerified:
            return "green"
        case .streamResolved, .resultsFound, .radioReady:
            return "teal"
        case .searchAvailable, .initialized, .noMatchingTitles:
            return "blue"
        case .interfaceOnly:
            return "purple"
        case .registered, .adapterRequired, .executed, .loaded, .authRequired:
            return "orange"
        case .unconfigured, .connectionFailed:
            return "red"
        }
    }
}
