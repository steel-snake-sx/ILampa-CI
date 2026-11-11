import Foundation

/// Classified candidate status parsed from raw batch import text
enum BatchCandidateStatus: Equatable {
    case pluginScript(cleanUrl: String)
    case directMediaStream(cleanUrl: String, format: String)
    case providerEndpoint(cleanUrl: String, endpointType: String)
    case unsupportedWebpage(cleanUrl: String, reason: String)
    case duplicate(cleanUrl: String, isAlreadyInstalled: Bool)
    case invalid(rawText: String, reason: String)
}

struct BatchImportCandidate: Identifiable, Equatable {
    let id: String
    let rawLine: String
    let status: BatchCandidateStatus
    var isSelectedForInstall: Bool
    var requiresApproval: Bool

    var cleanUrl: String? {
        switch status {
        case .pluginScript(let url): return url
        case .directMediaStream(let url, _): return url
        case .providerEndpoint(let url, _): return url
        case .unsupportedWebpage(let url, _): return url
        case .duplicate(let url, _): return url
        case .invalid: return nil
        }
    }

    var displayTitle: String {
        if let clean = cleanUrl {
            return clean
        }
        return rawLine
    }

    var categoryLabel: String {
        switch status {
        case .pluginScript:
            return "JS Плагин"
        case .directMediaStream(_, let format):
            return "Медиа-поток (\(format.uppercased()))"
        case .providerEndpoint(_, let type):
            return "Эндпоинт (\(type))"
        case .unsupportedWebpage:
            return "Веб-страница (Отклонено)"
        case .duplicate:
            return "Дубликат"
        case .invalid:
            return "Некорректная запись"
        }
    }

    var statusDescription: String {
        switch status {
        case .pluginScript:
            return "Готов к установке (требует подтверждения)"
        case .directMediaStream(_, let format):
            return "Поток \(format.uppercased()): добавьте в разделе «Источники»"
        case .providerEndpoint(_, let type):
            return "Конфигурация провайдера (\(type)): настройте в разделе «Источники»"
        case .unsupportedWebpage(_, let reason):
            return "Отклонено: \(reason)"
        case .duplicate(_, let alreadyInstalled):
            return alreadyInstalled ? "Уже установлен" : "Дубликат в текущем списке"
        case .invalid(_, let reason):
            return "Ошибка: \(reason)"
        }
    }

    var isInstallable: Bool {
        switch status {
        case .pluginScript:
            return true
        case .directMediaStream, .providerEndpoint, .unsupportedWebpage, .duplicate, .invalid:
            return false
        }
    }
}

enum BatchImportOutcome: Equatable {
    case complete
    case partial
    case canceled
}

struct BatchImportResult: Equatable {
    let totalLines: Int
    let validCount: Int
    let duplicateCount: Int
    let invalidCount: Int
    let installedSuccessfully: [String]
    let failedInstallations: [String: String] // url -> error message
    let canceledInstallations: [String]
    let outcome: BatchImportOutcome

    var hasFailures: Bool { !failedInstallations.isEmpty }
    var wasCanceled: Bool { outcome == .canceled || !canceledInstallations.isEmpty }
}

/// Batch Import Engine for Plugins, Streams, and Provider Configurations.
/// Enforces:
/// - RFC 3986 URL normalization
/// - Strict classification (Plugin vs Direct Stream vs Provider Endpoint vs Unsupported Webpage)
/// - Rejection of arbitrary website URLs
/// - Intra-batch and persistent deduplication
/// - Explicit user confirmation (no automatic execution of imported scripts)
final class BatchPluginImporter {
    static let shared = BatchPluginImporter()

    private init() {}

    // Parses raw multiline text into classified import candidates
    func parse(rawText: String, currentlyInstalledUrls: Set<String> = []) -> [BatchImportCandidate] {
        let lines = rawText.components(separatedBy: .newlines)
        var candidates: [BatchImportCandidate] = []
        var seenInBatch: Set<String> = []

        let normalizedInstalled = Set(currentlyInstalledUrls.map { raw in
            URL(string: raw).map(normalizeUrl) ?? raw
        })
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            // Discard empty lines and comment lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }

            guard let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ilampa"].contains(scheme) else {
                candidates.append(BatchImportCandidate(
                    id: UUID().uuidString,
                    rawLine: trimmed,
                    status: .invalid(rawText: trimmed, reason: "Некорректный протокол или формат URL"),
                    isSelectedForInstall: false,
                    requiresApproval: true
                ))
                continue
            }

            guard let host = url.host, !host.isEmpty else {
                candidates.append(BatchImportCandidate(
                    id: UUID().uuidString,
                    rawLine: trimmed,
                    status: .invalid(rawText: trimmed, reason: "Отсутствует хост/домен"),
                    isSelectedForInstall: false,
                    requiresApproval: true
                ))
                continue
            }

            let normalizedUrl = normalizeUrl(url)

            if normalizedInstalled.contains(normalizedUrl) {
                candidates.append(BatchImportCandidate(
                    id: UUID().uuidString,
                    rawLine: trimmed,
                    status: .duplicate(cleanUrl: normalizedUrl, isAlreadyInstalled: true),
                    isSelectedForInstall: false,
                    requiresApproval: true
                ))
            } else if seenInBatch.contains(normalizedUrl) {
                candidates.append(BatchImportCandidate(
                    id: UUID().uuidString,
                    rawLine: trimmed,
                    status: .duplicate(cleanUrl: normalizedUrl, isAlreadyInstalled: false),
                    isSelectedForInstall: false,
                    requiresApproval: true
                ))
            } else {
                seenInBatch.insert(normalizedUrl)
                let classifiedStatus = classifyUrl(url, normalizedString: normalizedUrl)
                candidates.append(BatchImportCandidate(
                    id: UUID().uuidString,
                    rawLine: trimmed,
                    status: classifiedStatus,
                    isSelectedForInstall: false, // Disabled by default for user safety
                    requiresApproval: true
                ))
            }
        }

        return candidates
    }

    // Classifies candidate URL into specific supported types or rejects as unsupported webpage
    func classifyUrl(_ url: URL, normalizedString: String) -> BatchCandidateStatus {
        let pathLower = url.path.lowercased()
        let hostLower = (url.host ?? "").lowercased()

        if url.scheme?.lowercased() == "ilampa" {
            return .unsupportedWebpage(cleanUrl: normalizedString,
                reason: "Внутренние адреса нельзя загрузить через пакетный импорт")
        }

        // 1. Direct Media Streams (AVPlayer playable, not JS plugins)
        if pathLower.hasSuffix(".m3u8") {
            return .directMediaStream(cleanUrl: normalizedString, format: "HLS")
        } else if pathLower.hasSuffix(".mp4") {
            return .directMediaStream(cleanUrl: normalizedString, format: "MP4")
        } else if pathLower.hasSuffix(".mov") {
            return .directMediaStream(cleanUrl: normalizedString, format: "MOV")
        } else if pathLower.hasSuffix(".mkv") {
            return .directMediaStream(cleanUrl: normalizedString, format: "MKV")
        }

        // A registry is data, not executable plugin code, even on a known plugin host.
        // Do not stage a JSON catalog as JavaScript via the domain heuristics below.
        if pathLower.hasSuffix(".json") {
            return .unsupportedWebpage(cleanUrl: normalizedString,
                reason: "Каталог JSON не является исполняемым JS-плагином")
        }

        // 2. JavaScript Plugins (Include standard .js, .mjs, known plugin catalogs/endpoints like bwa.ad/rc)
        let isKnownPluginDomain = hostLower == "bwa.ad" || hostLower.contains("bylampa") || hostLower.contains("lampaplugins") || hostLower.contains("lampame")
        if pathLower.hasSuffix(".js") || pathLower.hasSuffix(".mjs") || url.scheme == "ilampa" || pathLower.contains("/plugin/") || pathLower.contains("/store/") || isKnownPluginDomain {
            return .pluginScript(cleanUrl: normalizedString)
        }

        // 3. Provider Endpoints (TorrServer, Proxy, etc.)
        if pathLower.contains("/ts") || pathLower.contains("/torrserver") {
            return .providerEndpoint(cleanUrl: normalizedString, endpointType: "TorrServer")
        } else if pathLower.contains("/api/extensions") || pathLower.contains("/cub") {
            return .providerEndpoint(cleanUrl: normalizedString, endpointType: "CUB Catalog")
        }

        // 4. Arbitrary webpage URLs are strictly rejected as unsupported video sources
        return .unsupportedWebpage(
            cleanUrl: normalizedString,
            reason: "Обычная веб-страница не является поддерживаемым видеопотоком или JS-плагином"
        )
    }

    // Normalizes URL string by stripping fragments and standardizing slashes
    func normalizeUrl(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    // Executes batch download and registration for user-approved candidates.
    // Each item commits its cache and disabled record together on the main actor.
    // Earlier commits remain installed if a later item fails or is canceled.
    @MainActor
    func executeBatchInstall(
        candidates: [BatchImportCandidate],
        isCancelled: (() -> Bool)? = nil,
        onProgress: ((Int, Int) -> Void)? = nil,
        manager: PluginManager = .shared,
        fetch: ((URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async -> BatchImportResult {
        let approved = candidates.filter { $0.isSelectedForInstall && $0.isInstallable }
        let installationEpoch = manager.installationEpoch
        var installed: [String] = []
        var failed: [String: String] = [:]
        var canceled: [String] = []
        var seen: Set<String> = []

        var completedCount = 0
        let totalCount = approved.count
        let correlationId = UUID().uuidString.prefix(8)

        DiagnosticsLogManager.shared.log(
            category: "[BatchImporter]",
            message: "[\(correlationId)] Начало транзакционного пакетного импорта: \(totalCount) выбранных плагинов",
            level: .info
        )

        for candidate in approved {
            guard let urlString = candidate.cleanUrl, let url = URL(string: urlString) else {
                completedCount += 1
                onProgress?(completedCount, totalCount)
                continue
            }

            if isCancelled?() == true || Task.isCancelled || manager.installationEpoch != installationEpoch {
                canceled.append(urlString)
                DiagnosticsLogManager.shared.log(
                    category: "[BatchImporter]",
                    message: "[\(correlationId)] Импорт отменен для: \(urlString)",
                    level: .info
                )
                completedCount += 1
                onProgress?(completedCount, totalCount)
                continue
            }

            do {
                switch candidate.status {
                case .directMediaStream:
                    throw NSError(domain: "BatchImporter", code: 400, userInfo: [NSLocalizedDescriptionKey: "Прямой поток HLS/MP4 не является JS-плагином; используйте раздел «Источники»"])

                case .providerEndpoint:
                    throw NSError(domain: "BatchImporter", code: 400, userInfo: [NSLocalizedDescriptionKey: "Конфигурация сервера настраивается в разделе «Источники»"])

                case .pluginScript:
                    guard seen.insert(normalizeUrl(url)).inserted else {
                        throw NSError(domain: "BatchImporter", code: 409, userInfo: [NSLocalizedDescriptionKey: "Дубликат в текущем списке"])
                    }
                    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        throw NSError(domain: "BatchImporter", code: 400, userInfo: [NSLocalizedDescriptionKey: "Для загрузки плагина требуется HTTP или HTTPS"])
                    }
                    try Task.checkCancellation()

                    var request = URLRequest(url: url)
                    request.timeoutInterval = 8.0
                    let (data, response): (Data, URLResponse)
                    if let fetch {
                        (data, response) = try await fetch(request)
                    } else {
                        (data, response) = try await URLSession.shared.data(for: request)
                    }
                    if isCancelled?() == true || manager.installationEpoch != installationEpoch { throw CancellationError() }
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse else {
                        throw NSError(domain: "BatchImporter", code: 500, userInfo: [NSLocalizedDescriptionKey: "Не удалось установить HTTP-соединение"])
                    }
                    guard (200...299).contains(http.statusCode) else {
                        throw NSError(domain: "BatchImporter", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                    }
                    guard let script = String(data: data, encoding: .utf8), !script.isEmpty else {
                        throw NSError(domain: "BatchImporter", code: 204, userInfo: [NSLocalizedDescriptionKey: "Сервер вернул пустой файл"])
                    }
                    let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lowerScript = trimmedScript.lowercased()
                    let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    if trimmedScript.isEmpty || lowerScript.hasPrefix("<!doctype") || lowerScript.hasPrefix("<html") || lowerScript.hasPrefix("<?xml") || contentType.contains("html") || contentType.contains("xml") || contentType.contains("json") {
                        throw NSError(domain: "BatchImporter", code: 422, userInfo: [NSLocalizedDescriptionKey: "Сервер вернул HTML-страницу ошибки"])
                    }

                    let hostName = url.host ?? "Custom Plugin"

                    // Stage record DISABLED BY DEFAULT!
                    var record = LampaPluginRecord(
                        id: UUID(),
                        url: url,
                        name: hostName,
                        version: "1.0.0",
                        author: "Batch Imported",
                        origin: .userCustom,
                        lifecycleState: .inactive, // Inactive by default!
                        registeredComponents: [],
                        providedSourceKeys: [],
                        installedAt: Date(),
                        lastValidatedAt: nil,
                        automaticRetryBlocked: false
                    )
                    record.desiredEnabled = false
                    try manager.commitBatchPlugin(record, script: script, expectedEpoch: installationEpoch)
                    installed.append(urlString)

                    DiagnosticsLogManager.shared.log(
                        category: "[BatchImporter]",
                        message: "[\(correlationId)] Успешно загружен \(urlString) (\(data.count) байт, отключен по умолчанию)",
                        level: .info
                    )

                default:
                    break
                }
            } catch {
                if Task.isCancelled || isCancelled?() == true || (error as? CancellationError) != nil || (error as? URLError)?.code == .cancelled {
                    canceled.append(urlString)
                } else {
                    failed[urlString] = error.localizedDescription
                    DiagnosticsLogManager.shared.log(
                        category: "[BatchImporter]",
                        message: "[\(correlationId)] Ошибка импорта \(urlString): \(error.localizedDescription)",
                        level: .warning
                    )
                }
            }

            completedCount += 1
            onProgress?(completedCount, totalCount)
        }

        let validCount = candidates.filter { $0.isInstallable }.count
        let duplicateCount = candidates.filter {
            if case .duplicate = $0.status { return true }
            return false
        }.count
        let invalidCount = candidates.filter {
            if case .invalid = $0.status { return true }
            if case .unsupportedWebpage = $0.status { return true }
            if case .directMediaStream = $0.status { return true }
            if case .providerEndpoint = $0.status { return true }
            return false
        }.count

        let outcome: BatchImportOutcome = {
            if !canceled.isEmpty {
                return .canceled
            } else if !failed.isEmpty {
                return .partial
            } else {
                return .complete
            }
        }()

        return BatchImportResult(
            totalLines: candidates.count,
            validCount: validCount,
            duplicateCount: duplicateCount,
            invalidCount: invalidCount,
            installedSuccessfully: installed,
            failedInstallations: failed,
            canceledInstallations: canceled,
            outcome: outcome
        )
    }
}
