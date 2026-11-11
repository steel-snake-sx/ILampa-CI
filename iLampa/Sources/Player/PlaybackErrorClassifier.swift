import Foundation
import AVFoundation

// Structured categorization of playback failures to distinguish codec/container limits from network/server issues.
struct PlaybackDiagnosis {
    enum Category: Equatable {
        case unsupportedContainer(format: String)
        case unsupportedAudioCodec(codec: String)
        case httpError(code: Int)
        case torrServerOffline(host: String)
        case networkUnreachable(details: String)
        case manifestError(details: String)
        case unknown(details: String)
    }

    let category: Category
    let title: String
    let message: String
    let canOpenInExternalPlayer: Bool
    let primaryActionTitle: String
    let isExternalFallbackRecommended: Bool
}

final class PlaybackErrorClassifier {
    static func diagnose(url: String, error: Error?, errorLog: AVPlayerItemErrorLog?) -> PlaybackDiagnosis {
        let cleanUrl = url.lowercased()

        // 1. Check for known unsupported containers in Apple AVPlayer
        if cleanUrl.hasSuffix(".mkv") || cleanUrl.contains(".mkv?") || cleanUrl.contains("container=mkv") {
            return PlaybackDiagnosis(
                category: .unsupportedContainer(format: "MKV"),
                title: "Формат контейнера (MKV)",
                message: "Контейнер Matroska (MKV) не поддерживается встроенным плеером iOS. Для воспроизведения этого релиза используйте Infuse или выберите источник в MP4 / HLS.",
                canOpenInExternalPlayer: true,
                primaryActionTitle: "В Infuse",
                isExternalFallbackRecommended: true
            )
        }

        if cleanUrl.hasSuffix(".avi") || cleanUrl.contains(".avi?") {
            return PlaybackDiagnosis(
                category: .unsupportedContainer(format: "AVI"),
                title: "Формат контейнера (AVI)",
                message: "Устаревший контейнер AVI не поддерживается нативным декодером iOS. Откройте поток во внешнем плеере Infuse.",
                canOpenInExternalPlayer: true,
                primaryActionTitle: "В Infuse",
                isExternalFallbackRecommended: true
            )
        }

        // 2. Check for TorrServer connection failure
        if cleanUrl.contains("127.0.0.1:8090") || cleanUrl.contains("localhost:8090") {
            return PlaybackDiagnosis(
                category: .torrServerOffline(host: "127.0.0.1:8090"),
                title: "TorrServer недоступен",
                message: "Локальный TorrServer на данном iPhone не запущен. Укажите IP-адрес домашнего сервера в настройках источников.",
                canOpenInExternalPlayer: false,
                primaryActionTitle: "Настроить сервер",
                isExternalFallbackRecommended: false
            )
        }

        // 3. Inspect AVPlayerItemErrorLog for HTTP error status codes and log granular details
        if let lastEvent = errorLog?.events.last {
            let code = lastEvent.errorStatusCode
            let uriHost = URL(string: lastEvent.uri ?? "")?.host ?? "unknown"
            let server = lastEvent.serverAddress ?? "n/a"
            let comment = sanitizedErrorComment(lastEvent.errorComment)

            DiagnosticsLogManager.shared.log(
                category: "[AVFoundation]",
                message: "Сбой AVPlayerItem: HTTP \(code), host=\(uriHost), сервер=\(server), комментарий=\(comment)",
                level: .error
            )

            if code == 403 {
                return PlaybackDiagnosis(
                    category: .httpError(code: 403),
                    title: "Доступ запрещен (HTTP 403)",
                    message: "Провайдер или CDN отклонил запрос к видеопотоку (HTTP 403). Сегменты защищены CDN или ограничены регионом. Попробуйте сменить источник или открыть в Infuse.",
                    canOpenInExternalPlayer: true,
                    primaryActionTitle: "Сменить источник",
                    isExternalFallbackRecommended: true
                )
            } else if code == 404 {
                return PlaybackDiagnosis(
                    category: .httpError(code: 404),
                    title: "Поток не найден (HTTP 404)",
                    message: "Файл видеопотока удален с сервера провайдера. Выберите другую озвучку или альтернативный источник.",
                    canOpenInExternalPlayer: false,
                    primaryActionTitle: "Выбрать другой релиз",
                    isExternalFallbackRecommended: false
                )
            } else if code >= 500 {
                return PlaybackDiagnosis(
                    category: .httpError(code: code),
                    title: "Ошибка сервера источника (\(code))",
                    message: "Сервер раздачи временно недоступен или перегружен. Попробуйте повторить попытку позже или сменить источник.",
                    canOpenInExternalPlayer: false,
                    primaryActionTitle: "Повторить",
                    isExternalFallbackRecommended: false
                )
            }
        }

        // 4. Inspect NSError domain and codes
        if let nsError = error as NSError? {
            // Network connection lost or timeout
            if nsError.domain == NSURLErrorDomain {
                if nsError.code == NSURLErrorTimedOut {
                    return PlaybackDiagnosis(
                        category: .networkUnreachable(details: "Timeout"),
                        title: "Превышено время ожидания",
                        message: "Сервер источника не ответил вовремя. Проверьте стабильность Wi-Fi или сотовой сети.",
                        canOpenInExternalPlayer: false,
                        primaryActionTitle: "Повторить попытку",
                        isExternalFallbackRecommended: false
                    )
                } else if nsError.code == NSURLErrorNotConnectedToInternet {
                    return PlaybackDiagnosis(
                        category: .networkUnreachable(details: "Offline"),
                        title: "Нет подключения к интернету",
                        message: "Устройство отключено от сети. Проверьте соединение с интернетом.",
                        canOpenInExternalPlayer: false,
                        primaryActionTitle: "Проверить сеть",
                        isExternalFallbackRecommended: false
                    )
                } else if nsError.code == NSURLErrorSecureConnectionFailed {
                    return PlaybackDiagnosis(
                        category: .networkUnreachable(details: "TLS"),
                        title: "Защищённое соединение недоступно",
                        message: "iOS не смогла проверить защищённое соединение с источником. Проверьте дату устройства, сеть/VPN/прокси и сертификат сервера; проверка TLS не отключалась.",
                        canOpenInExternalPlayer: false,
                        primaryActionTitle: "Сменить источник",
                        isExternalFallbackRecommended: false
                    )
                }
            }

            // CoreMedia decoding errors (unsupported audio or video profile)
            if nsError.domain == "AVFoundationErrorDomain" || nsError.domain == "CoreMediaErrorDomain" {
                if nsError.code == -11828 || nsError.code == -12881 {
                    return PlaybackDiagnosis(
                        category: .unsupportedAudioCodec(codec: "Audio/Video Profile"),
                        title: "Неподдерживаемый кодек",
                        message: "Звуковая дорожка (например, DTS/TrueHD) или профиль видео не поддерживаются системным AVPlayer. Рекомендуется просмотр через Infuse.",
                        canOpenInExternalPlayer: true,
                        primaryActionTitle: "В Infuse",
                        isExternalFallbackRecommended: true
                    )
                }
            }

            let desc = nsError.localizedDescription
            return PlaybackDiagnosis(
                category: .unknown(details: desc),
                title: "Сбой воспроизведения",
                message: "Не удалось воспроизвести поток: \(desc). Попробуйте сменить источник или открыть в Infuse.",
                canOpenInExternalPlayer: true,
                primaryActionTitle: "В Infuse",
                isExternalFallbackRecommended: false
            )
        }

        // Generic fallback
        return PlaybackDiagnosis(
            category: .unknown(details: "Неизвестная ошибка"),
            title: "Ошибка воспроизведения",
            message: "Не удалось загрузить или декодировать поток. Попробуйте выбрать другой вариант качества или источник.",
            canOpenInExternalPlayer: true,
            primaryActionTitle: "В Infuse",
            isExternalFallbackRecommended: false
        )
    }

    private static func sanitizedErrorComment(_ comment: String?) -> String {
        guard let comment, !comment.isEmpty else { return "n/a" }
        let withoutURLs = comment.replacingOccurrences(of: #"https?://[^\s\"']+"#, with: "[URL]", options: .regularExpression)
        return String(withoutURLs.prefix(240))
    }
}
