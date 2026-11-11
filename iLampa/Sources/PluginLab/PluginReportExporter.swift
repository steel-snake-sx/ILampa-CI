import Foundation
import UIKit

/// Generates the comprehensive diagnostic report ZIP archive according to the specification.
final class PluginReportExporter {

    /// Assembles all collected technical evidence and packages it into `PluginLab-Report.zip`.
    static func exportArchive(
        sessionID: UUID,
        environment: PluginLabEnvironment,
        inventory: [PluginLabItem],
        allEvidence: [PluginDiagnosticEvidence],
        duration: TimeInterval,
        outputDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        var zipEntries: [DiagnosticsZipArchiver.FileEntry] = []

        // Derive the duration from the same timestamps exported to environment.json.
        // This prevents a misleading summary when a checkpoint is resumed or shared.
        let effectiveDuration = max(0, (environment.finishedAt ?? environment.startedAt).timeIntervalSince(environment.startedAt))
        // Compute summary metrics
        let totalDiscovered = inventory.count
        let totalTested = inventory.filter { $0.stage == .completed || $0.stage == .failed }.count
        let passCount = inventory.filter { $0.status == .pass }.count
        let partialCount = inventory.filter { $0.status == .partial }.count
        let failCount = inventory.filter { $0.status == .fail }.count
        let inconclusiveCount = inventory.filter { $0.status == .blocked || $0.status == .untested }.count

        var rootCauseCounts: [String: Int] = [:]
        for item in inventory {
            if let cause = item.primaryRootCause {
                rootCauseCounts[cause.rawValue, default: 0] += 1
            }
        }

        // Shared architectural recommendations
        var recommendations: [String] = []
        if (rootCauseCounts[PluginLabRootCause.unsupportedCustomUI.rawValue] ?? 0) > 0 {
            recommendations.append("Добавить нативную поддержку HTML5/WebKit-холста для пользовательских меню и компонентов (затрагивает \(rootCauseCounts[PluginLabRootCause.unsupportedCustomUI.rawValue]!) плагинов).")
        }
        if (rootCauseCounts[PluginLabRootCause.missingNativeBridgeAction.rawValue] ?? 0) > 0 {
            recommendations.append("Зарегистрировать нативные обработчики для data-action кнопок (например, 'exit_r') в меню iLampa.")
        }
        if (rootCauseCounts[PluginLabRootCause.unsupportedPlatformFunctionality.rawValue] ?? 0) > 0 {
            recommendations.append("Предоставить безопасные заглушки для специфичных системных вызовов Tizen/WebOS/Android.")
        }
        if (rootCauseCounts[PluginLabRootCause.missingLampaApi.rawValue] ?? 0) > 0 {
            recommendations.append("Расширить покрытие Lampa API в lampa_bridge.js (Activity, Storage, Noty).")
        }

        let summary = PluginLabSummary(
            totalDiscovered: totalDiscovered,
            totalTested: totalTested,
            passCount: passCount,
            partialCount: partialCount,
            failCount: failCount,
            inconclusiveCount: inconclusiveCount,
            durationSeconds: effectiveDuration,
            topRootCauses: rootCauseCounts,
            architecturalRecommendations: recommendations
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        // 1. summary.json
        if let data = try? encoder.encode(summary) {
            zipEntries.append(.init(name: "summary.json", data: data))
        }

        // 2. summary.md
        let markdown = generateMarkdownSummary(summary: summary, environment: environment, inventory: inventory)
        if let data = markdown.data(using: .utf8) {
            zipEntries.append(.init(name: "summary.md", data: data))
        }

        // 3. environment.json
        if let data = try? encoder.encode(environment) {
            zipEntries.append(.init(name: "environment.json", data: data))
        }

        // 4. inventory.json
        if let data = try? encoder.encode(inventory) {
            zipEntries.append(.init(name: "inventory.json", data: data))
        }

        // 5. compatibility-matrix.csv
        let csv = generateCSVMatrix(inventory: inventory)
        if let data = csv.data(using: .utf8) {
            zipEntries.append(.init(name: "compatibility-matrix.csv", data: data))
        }

        // 6. failures/grouped-errors.json & root-causes.json
        var groupedFailures: [String: [String]] = [:]
        var rootCauseDocs: [String: [String: String]] = [:]

        for item in inventory {
            if let cause = item.primaryRootCause {
                groupedFailures[cause.rawValue, default: []].append(item.name)
                rootCauseDocs[cause.rawValue] = [
                    "name": cause.displayName,
                    "remediation": cause.suggestedRemediation
                ]
            }
        }

        if let data = try? encoder.encode(groupedFailures) {
            zipEntries.append(.init(name: "failures/grouped-errors.json", data: data))
        }
        if let data = try? encoder.encode(rootCauseDocs) {
            zipEntries.append(.init(name: "failures/root-causes.json", data: data))
        }

        // 7. plugins/<id>/...
        var allExecutionLogs: [String] = []

        for evidence in allEvidence {
            let pid = evidence.item.id
            let prefix = "plugins/\(pid)/"

            // metadata.json
            struct MetadataView: Codable {
                let id: String
                let name: String
                let url: String
                let author: String?
                let version: String?
                let sha256: String?
                let byteCount: Int?
                let downloadDurationMs: Double?
                let origin: String
                let isInstalled: Bool
            }
            let meta = MetadataView(
                id: evidence.item.id,
                name: evidence.item.name,
                url: evidence.item.url,
                author: evidence.item.author,
                version: evidence.item.version,
                sha256: evidence.item.sha256,
                byteCount: evidence.item.byteCount,
                downloadDurationMs: evidence.item.downloadDurationMs,
                origin: evidence.item.origin.rawValue,
                isInstalled: evidence.item.isInstalled
            )
            if let data = try? encoder.encode(meta) {
                zipEntries.append(.init(name: prefix + "metadata.json", data: data))
            }

            // result.json
            struct ResultView: Codable {
                let status: String
                let confidence: String
                let primaryRootCause: String?
                let failureSummary: String?
                let testedAt: Date?
            }
            let res = ResultView(
                status: evidence.item.status.rawValue,
                confidence: evidence.item.confidence.rawValue,
                primaryRootCause: evidence.item.primaryRootCause?.rawValue,
                failureSummary: evidence.item.failureSummary,
                testedAt: evidence.item.testedAt
            )
            if let data = try? encoder.encode(res) {
                zipEntries.append(.init(name: prefix + "result.json", data: data))
            }

            // timeline.jsonl
            let timelineLines = evidence.timeline.map { $0.toJSONL() }
            allExecutionLogs.append(contentsOf: timelineLines)
            let timelineStr = timelineLines.joined(separator: "\n") + "\n"
            if let data = timelineStr.data(using: .utf8) {
                zipEntries.append(.init(name: prefix + "timeline.jsonl", data: data))
            }

            // javascript-errors.json (only if present)
            if !evidence.jsErrors.isEmpty, let data = try? encoder.encode(evidence.jsErrors) {
                zipEntries.append(.init(name: prefix + "javascript-errors.json", data: data))
            }

            // native-errors.json (only if present)
            if !evidence.nativeErrors.isEmpty, let data = try? encoder.encode(evidence.nativeErrors) {
                zipEntries.append(.init(name: prefix + "native-errors.json", data: data))
            }

            // api-coverage.json
            if !evidence.apiCoverage.isEmpty, let data = try? encoder.encode(evidence.apiCoverage) {
                zipEntries.append(.init(name: prefix + "api-coverage.json", data: data))
            }

            // ui-components.json
            if !evidence.uiComponents.isEmpty, let data = try? encoder.encode(evidence.uiComponents) {
                zipEntries.append(.init(name: prefix + "ui-components.json", data: data))
            }

            // bridge-events.json
            if !evidence.bridgeEvents.isEmpty, let data = try? encoder.encode(evidence.bridgeEvents) {
                zipEntries.append(.init(name: prefix + "bridge-events.json", data: data))
            }

            // network-errors.json
            if !evidence.networkErrors.isEmpty, let data = try? encoder.encode(evidence.networkErrors) {
                zipEntries.append(.init(name: prefix + "network-errors.json", data: data))
            }

            // screenshots/
            if let img = evidence.screenshotData {
                zipEntries.append(.init(name: prefix + "screenshots/rendered.png", data: img))
            }
        }

        // 8. runner/session.json, execution-log.jsonl, interrupted-tests.json
        struct SessionMeta: Codable {
            let sessionID: String
            let startedAt: Date
            let durationSeconds: Double
            let totalDiscovered: Int
            let totalTested: Int
        }
        let sessionMeta = SessionMeta(
            sessionID: sessionID.uuidString,
            startedAt: environment.startedAt,
            durationSeconds: effectiveDuration,
            totalDiscovered: totalDiscovered,
            totalTested: totalTested
        )
        if let data = try? encoder.encode(sessionMeta) {
            zipEntries.append(.init(name: "runner/session.json", data: data))
        }

        let execLog = allExecutionLogs.joined(separator: "\n") + "\n"
        if let data = execLog.data(using: .utf8) {
            zipEntries.append(.init(name: "runner/execution-log.jsonl", data: data))
        }

        let interrupted = inventory.filter { $0.stage != .completed }
        if !interrupted.isEmpty, let data = try? encoder.encode(interrupted) {
            zipEntries.append(.init(name: "runner/interrupted-tests.json", data: data))
        }

        // Apply one final privacy boundary to every textual file in the ZIP.
        // Never export raw screenshots: they may include user credentials and accounts.
        let exportEntries = zipEntries.compactMap { entry -> DiagnosticsZipArchiver.FileEntry? in
            if entry.name.hasPrefix("plugins/") && entry.name.contains("/screenshots/") {
                return nil
            }
            if let string = String(data: entry.data, encoding: .utf8) {
                return .init(name: entry.name, data: Data(
                    PluginDiagnosticsRecorder.redactArchiveText(string).utf8
                ))
            }
            return entry
        }

        let destination = outputDirectory.appendingPathComponent("PluginLab-Report.zip")
        try? FileManager.default.removeItem(at: destination)
        try DiagnosticsZipArchiver.createZip(entries: exportEntries, destinationURL: destination)

        return destination
    }

    private static func generateCSVMatrix(inventory: [PluginLabItem]) -> String {
        var lines = ["Name,URL,Origin,Status,Confidence,PrimaryRootCause,FailureSummary"]
        for item in inventory {
            let name = "\"\(item.name.replacingOccurrences(of: "\"", with: "\"\""))\""
            let url = "\"\(item.url.replacingOccurrences(of: "\"", with: "\"\""))\""
            let origin = item.origin.rawValue
            let status = item.status.rawValue
            let conf = item.confidence.rawValue
            let cause = item.primaryRootCause?.rawValue ?? ""
            let summary = "\"\(item.failureSummary?.replacingOccurrences(of: "\"", with: "\"\"") ?? "")\""
            lines.append("\(name),\(url),\(origin),\(status),\(conf),\(cause),\(summary)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func generateMarkdownSummary(
        summary: PluginLabSummary,
        environment: PluginLabEnvironment,
        inventory: [PluginLabItem]
    ) -> String {
        var md = """
        # iLampa — Plugin Lab: Diagnostic Summary Report

        **Сгенерировано:** \(ISO8601DateFormatter().string(from: Date()))
        **Версия приложения:** \(environment.appVersion) (Build \(environment.buildNumber), Commit: \(environment.gitCommit.prefix(7)))
        **Окружение:** iOS \(environment.iosVersion) · \(environment.deviceModel)
        **Длительность кампании:** \(String(format: "%.1f", summary.durationSeconds)) с

        ---

        ## Сводка результатов

        | Показатель | Количество | Доля |
        |---|---|---|
        | **Всего обнаружено** | \(summary.totalDiscovered) | 100% |
        | **Протестировано** | \(summary.totalTested) | \(percent(summary.totalTested, summary.totalDiscovered)) |
        | 🟢 **Полностью совместимы (PASS)** | \(summary.passCount) | \(percent(summary.passCount, summary.totalTested)) |
        | 🟠 **Частично совместимы (PARTIAL)** | \(summary.partialCount) | \(percent(summary.partialCount, summary.totalTested)) |
        | 🔴 **Сбои выполнения (FAIL)** | \(summary.failCount) | \(percent(summary.failCount, summary.totalTested)) |
        | ⚪ **Заблокировано / Не тестировано** | \(summary.inconclusiveCount) | \(percent(summary.inconclusiveCount, summary.totalDiscovered)) |

        ---

        ## Матрица совместимости плагинов

        | Плагин | Источник | Статус | Уверенность | Основная причина |
        |---|---|---|---|---|

        """

        for item in inventory {
            let icon: String
            switch item.status {
            case .pass: icon = "🟢 PASS"
            case .partial: icon = "🟠 PARTIAL"
            case .fail: icon = "🔴 FAIL"
            case .blocked: icon = "🟣 BLOCKED"
            case .untested: icon = "⚪ UNTESTED"
            }
            let reason = item.primaryRootCause?.displayName ?? (item.failureSummary ?? "—")
            md += "| **\(item.name)** | \(item.origin.displayName) | \(icon) | \(item.confidence.displayName) | \(reason) |\n"
        }

        md += """

        ---

        ## Архитектурные рекомендации для массового исправления

        Следующие системные доработки позволят одновременно устранить сбои совместимости сразу у нескольких плагинов:

        """

        if summary.architecturalRecommendations.isEmpty {
            md += "Критических массовых блокировок не выявлено.\n"
        } else {
            for (idx, rec) in summary.architecturalRecommendations.enumerated() {
                md += "\(idx + 1). **\(rec)**\n"
            }
        }

        return md
    }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        guard whole > 0 else { return "0%" }
        return "\(Int(round(Double(part) / Double(whole) * 100.0)))%"
    }
}
