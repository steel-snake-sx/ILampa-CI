import Foundation
import SwiftUI
import CryptoKit

// MARK: - Status & Classifications

/// Final compatibility verdict for a plugin.
enum PluginLabStatus: String, Codable, CaseIterable, Equatable, Hashable {
    case pass = "PASS"
    case partial = "PARTIAL"
    case fail = "FAIL"
    case blocked = "BLOCKED"
    case untested = "UNTESTED"

    var displayName: String {
        switch self {
        case .pass: return "Совместим"
        case .partial: return "Частично"
        case .fail: return "Сбой"
        case .blocked: return "Заблокирован"
        case .untested: return "Не тестировался"
        }
    }

    var color: Color {
        switch self {
        case .pass: return .green
        case .partial: return .orange
        case .fail: return .red
        case .blocked: return .purple
        case .untested: return .secondary
        }
    }
}

/// Confidence in the depth and completeness of the diagnostic result.
enum PluginLabConfidence: String, Codable, CaseIterable, Equatable, Hashable {
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"

    var displayName: String {
        switch self {
        case .high: return "Высокая"
        case .medium: return "Средняя"
        case .low: return "Низкая"
        }
    }
}

/// Root-cause classification for compatibility failures.
enum PluginLabRootCause: String, Codable, CaseIterable, Equatable, Hashable {
    case missingLampaApi = "missing_lampa_api"
    case missingDomFunctionality = "missing_dom_functionality"
    case missingNativeBridgeAction = "missing_native_bridge_action"
    case unsupportedCustomUI = "unsupported_custom_ui"
    case pluginDependencyFailure = "plugin_dependency_failure"
    case networkFailure = "network_failure"
    case pluginScriptError = "plugin_script_error"
    case runtimeInitializationFailure = "runtime_initialization_failure"
    case webkitError = "webkit_error"
    case callbackFailure = "callback_failure"
    case unsupportedPlatformFunctionality = "unsupported_platform_functionality"
    case unverifiedTestLimitation = "unverified_test_limitation"

    var displayName: String {
        switch self {
        case .missingLampaApi: return "Отсутствует API Lampa"
        case .missingDomFunctionality: return "Отсутствует функция DOM"
        case .missingNativeBridgeAction: return "Отсутствует нативное действие"
        case .unsupportedCustomUI: return "Неподдерживаемый JS-интерфейс"
        case .pluginDependencyFailure: return "Ошибка внешней зависимости"
        case .networkFailure: return "Сетевая ошибка загрузки"
        case .pluginScriptError: return "Синтаксическая ошибка скрипта"
        case .runtimeInitializationFailure: return "Ошибка инициализации рантайма"
        case .webkitError: return "Сбой WebKit процесса"
        case .callbackFailure: return "Сбой обратного вызова"
        case .unsupportedPlatformFunctionality: return "Неподдерживаемая ОС (Tizen/WebOS/Android)"
        case .unverifiedTestLimitation: return "Ограничение тестового стенда"
        }
    }

    var suggestedRemediation: String {
        switch self {
        case .missingLampaApi:
            return "Добавить недостающий метод или пространство имён в lampa_bridge.js."
        case .missingDomFunctionality:
            return "Подключить реальный DOM-рантайм через WKWebView с Lampa core."
        case .missingNativeBridgeAction:
            return "Зарегистрировать обработчик действия в SwiftUI и связать с bridge prompt."
        case .unsupportedCustomUI:
            return "Реализовать нативный рендерер компонента в SwiftUI или отображать WebKit-холст."
        case .pluginDependencyFailure:
            return "Проверить доступность зависимых CDN/скриптов и добавить локальный кэш."
        case .networkFailure:
            return "Проверить корректность HTTPS URL, SSL-сертификат и статус HTTP сервера."
        case .pluginScriptError:
            return "Исправить синтаксическую ошибку в коде плагина."
        case .runtimeInitializationFailure:
            return "Проверить готовность Lampa core до инъекции плагина."
        case .webkitError:
            return "Изолировать выполнение плагина для предотвращения краша WebProcess."
        case .callbackFailure:
            return "Проверить совпадение параметров сигнатуры обратного вызова."
        case .unsupportedPlatformFunctionality:
            return "Заменить системные вызовы специфичных платформ на нативные механизмы iOS."
        case .unverifiedTestLimitation:
            return "Расширить возможности автоматического стенда для этого типа взаимодействия."
        }
    }
}

/// Catalog provenance of a discovered plugin.
enum PluginLabOrigin: String, Codable, CaseIterable, Equatable, Hashable {
    case installed = "installed"
    case curated = "curated"
    case catalog = "catalog"
    case bundled = "bundled"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .installed: return "Установлен"
        case .curated: return "Курируемый"
        case .catalog: return "Каталог"
        case .bundled: return "Встроенный"
        case .custom: return "Пользовательский"
        }
    }
}

/// Lifecycle stage for active plugin testing.
enum PluginLabTestStage: String, Codable, CaseIterable, Equatable, Hashable {
    case pending = "pending"
    case downloading = "downloading"
    case staticAnalysis = "static_analysis"
    case runtimeInit = "runtime_init"
    case activating = "activating"
    case probingUI = "probing_ui"
    case probingSettings = "probing_settings"
    case probingResolvers = "probing_resolvers"
    case cleanup = "cleanup"
    case completed = "completed"
    case failed = "failed"

    var displayName: String {
        switch self {
        case .pending: return "В очереди"
        case .downloading: return "Загрузка кода..."
        case .staticAnalysis: return "Статический анализ..."
        case .runtimeInit: return "Подготовка рантайма..."
        case .activating: return "Активация плагина..."
        case .probingUI: return "Проверка интерфейса..."
        case .probingSettings: return "Проверка настроек..."
        case .probingResolvers: return "Проверка резолверов..."
        case .cleanup: return "Очистка рантайма..."
        case .completed: return "Завершено"
        case .failed: return "Прервано с ошибкой"
        }
    }
}

// MARK: - Data Models

/// Deduplicated plugin diagnostic record.
struct PluginLabItem: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    let url: String
    var author: String?
    var version: String?
    var category: String?
    var origin: PluginLabOrigin
    var initialEnabledState: Bool
    var isInstalled: Bool
    var sha256: String?
    var byteCount: Int?
    var downloadDurationMs: Double?
    var status: PluginLabStatus = .untested
    var confidence: PluginLabConfidence = .low
    var primaryRootCause: PluginLabRootCause?
    var failureSummary: String?
    var stage: PluginLabTestStage = .pending
    var stageProgressText: String?
    var discoveredDependencies: [String] = []
    var detectedAPIs: [String] = []
    var declaredCapabilities: [String] = []
    var testedAt: Date?

    static func makeStableId(url: String, name: String) -> String {
        // Different URLs must NEVER collide in the evidence directory or ZIP path.
        // Swift hashValue is randomized per process; SHA-256 remains stable across restarts.
        let prefix = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        let hash = SHA256.hash(data: Data(url.utf8))
            .prefix(10).map { String(format: "%02x", $0) }.joined()
        return "\(String(prefix.prefix(30)))_\(hash)"
    }
}

/// Chronological diagnostic event.
struct PluginLabTimelineEvent: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    let timestamp: Date
    let stage: String
    let category: String
    let message: String
    let level: String
    var metadata: [String: String]?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stage: String,
        category: String,
        message: String,
        level: String = "INFO",
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stage = stage
        self.category = category
        self.message = message
        self.level = level
        self.metadata = metadata
    }

    func toJSONL() -> String {
        var dict: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "stage": stage,
            "category": category,
            "level": level,
            "message": message
        ]
        if let metadata, !metadata.isEmpty {
            dict["metadata"] = metadata
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"message\":\"\(message)\"}"
        }
        return str
    }
}

/// UI Component information discovered during probing.
struct PluginLabUIComponentInfo: Identifiable, Codable, Equatable {
    var id: String { name }
    let name: String
    var isPlatform: Bool
    var hasNativeRenderer: Bool
    var nativeActionStatus: String
    var lifecycleMethods: [String]
    var instantiationSuccess: Bool
    var instantiationError: String?
    var actionHandlers: [String]
    var missingActions: [String]
    var domElementsCreated: [String]
    var platformDependencies: [String]
}

/// API coverage entry.
struct PluginLabAPICoverage: Identifiable, Codable, Equatable {
    var id: String { apiName }
    let apiName: String
    var isReferenced: Bool
    var isUsedAtRuntime: Bool
    var isSupported: Bool
    var note: String?
}

/// Host test environment metadata.
struct PluginLabEnvironment: Codable, Equatable {
    let appVersion: String
    let buildNumber: String
    let gitCommit: String
    let iosVersion: String
    let deviceModel: String
    let runtimeType: String
    let webkitConfiguration: String
    let testRunnerVersion: String
    let startedAt: Date
    var finishedAt: Date?
}

/// High-level campaign summary.
struct PluginLabSummary: Codable, Equatable {
    let totalDiscovered: Int
    let totalTested: Int
    let passCount: Int
    let partialCount: Int
    let failCount: Int
    let inconclusiveCount: Int
    let durationSeconds: Double
    let topRootCauses: [String: Int]
    let architecturalRecommendations: [String]
}

/// Checkpoint state for persistent session recovery.
struct PluginLabSessionCheckpoint: Codable, Equatable {
    let sessionID: UUID
    let lastUpdated: Date
    let completedPluginIDs: [String]
    let items: [PluginLabItem]
}
