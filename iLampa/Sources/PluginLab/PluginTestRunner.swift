import Foundation
import CryptoKit

/// Executes the complete 18-step diagnostic lifecycle for a single plugin in isolation.
@MainActor
final class PluginTestRunner {
    private let session: URLSession
    private let stageTimeoutSeconds: TimeInterval

    init(
        session: URLSession = .shared,
        stageTimeoutSeconds: TimeInterval = 10.0
    ) {
        self.session = session
        self.stageTimeoutSeconds = stageTimeoutSeconds
    }

    /// Runs the diagnostic lifecycle for a single plugin, capturing technical evidence and recovering from faults.
    func runDiagnostic(
        item: PluginLabItem,
        runtimeProbe: PluginRuntimeProbe,
        onStageChanged: @escaping (PluginLabTestStage, String) -> Void
    ) async -> PluginLabItem {
        var updatedItem = item
        updatedItem.testedAt = Date()
        var timeline: [PluginLabTimelineEvent] = []
        var nativeErrors: [String] = []

        func logEvent(_ level: String, _ category: String, _ message: String, _ metadata: [String: String]? = nil) {
            let evt = PluginLabTimelineEvent(
                stage: updatedItem.stage.rawValue,
                category: category,
                message: PluginDiagnosticsRecorder.redactSensitiveData(message),
                level: level,
                metadata: metadata?.mapValues { PluginDiagnosticsRecorder.redactSensitiveData($0) }
            )
            timeline.append(evt)
        }

        // MARK: - Step 1-4: Download & Validation
        onStageChanged(.downloading, "Загрузка кода плагина...")
        updatedItem.stage = .downloading
        logEvent("INFO", "[Lifecycle]", "Starting diagnostic lifecycle for \(item.name) (\(item.url))")

        let downloadStart = Date()
        var scriptContent: String?
        var downloadErrorStr: String?

        do {
            if item.url.hasPrefix("bundled://") {
                let filename = item.url.replacingOccurrences(of: "bundled://plugins/", with: "")
                    .replacingOccurrences(of: "bundled://", with: "")
                let basename = filename.replacingOccurrences(of: ".js", with: "")
                if let path = Bundle.main.path(forResource: basename, ofType: "js", inDirectory: "plugins"),
                   let code = try? String(contentsOfFile: path, encoding: .utf8) {
                    scriptContent = code
                } else if let path = Bundle.main.path(forResource: basename, ofType: "js"),
                          let code = try? String(contentsOfFile: path, encoding: .utf8) {
                    scriptContent = code
                } else {
                    throw NSError(domain: "PluginLab", code: 404, userInfo: [NSLocalizedDescriptionKey: "Встроенный файл \(filename) не найден в ресурсах"])
                }
            } else if let url = URL(string: item.url) {
                var request = URLRequest(url: url)
                request.timeoutInterval = stageTimeoutSeconds
                request.setValue("iLampa-PluginLab/2.0", forHTTPHeaderField: "User-Agent")

                let (data, response) = try await session.data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                    throw NSError(domain: "HTTP", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode)"])
                }

                guard data.count <= 2_000_000 else {
                    throw NSError(domain: "PluginLab", code: -1, userInfo: [NSLocalizedDescriptionKey: "Превышен максимальный размер файла (2 МБ)"])
                }

                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf8) else {
                    throw NSError(domain: "PluginLab", code: -2, userInfo: [NSLocalizedDescriptionKey: "Не удалось декодировать UTF-8 текст"])
                }

                if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!DOCTYPE") ||
                   text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<html") {
                    throw NSError(domain: "PluginLab", code: -3, userInfo: [NSLocalizedDescriptionKey: "Ответ сервера содержит HTML страницу вместо JavaScript"])
                }

                scriptContent = text
            }
        } catch {
            downloadErrorStr = error.localizedDescription
            nativeErrors.append("Download error: \(error.localizedDescription)")
            logEvent("ERROR", "[Download]", "Failed to retrieve script: \(error.localizedDescription)")
        }

        updatedItem.downloadDurationMs = Date().timeIntervalSince(downloadStart) * 1000.0

        // If download failed, record blocked status immediately and return
        guard let code = scriptContent else {
            let analysis = PluginCapabilityAnalyzer.analyze(
                item: updatedItem,
                rawReport: PluginProbeRawReport(),
                uiComponents: [],
                uiFailures: [.networkFailure],
                uiSummaries: [downloadErrorStr ?? "Ошибка загрузки"],
                downloadError: downloadErrorStr
            )
            updatedItem.status = analysis.status
            updatedItem.confidence = analysis.confidence
            updatedItem.primaryRootCause = analysis.primaryRootCause
            updatedItem.failureSummary = analysis.failureSummary
            updatedItem.stage = .failed

            let evidence = PluginDiagnosticEvidence(
                item: updatedItem,
                timeline: timeline,
                jsErrors: [],
                nativeErrors: nativeErrors,
                uiComponents: [],
                apiCoverage: [],
                bridgeEvents: [],
                networkErrors: [downloadErrorStr ?? "Сетевая ошибка"],
                screenshotData: nil
            )
            PluginDiagnosticsRecorder.shared.recordEvidence(evidence)
            return updatedItem
        }

        // Record content metadata & hash
        let sha = SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
        updatedItem.sha256 = sha
        updatedItem.byteCount = code.utf8.count
        logEvent("SUCCESS", "[Validation]", "Script retrieved (\(code.utf8.count) bytes, SHA-256: \(sha.prefix(12))...)")

        // MARK: - Step 5: Static Analysis
        onStageChanged(.staticAnalysis, "Статический анализ API...")
        updatedItem.stage = .staticAnalysis

        var detectedAPIs: [String] = []
        let apiPatterns = [
            "Lampa.Plugins", "Lampa.Component", "Lampa.Sources", "Lampa.SettingsApi",
            "Lampa.Listener", "Lampa.Storage", "Lampa.Platform", "Lampa.Activity",
            "Lampa.Reguest", "Lampa.Request", "Lampa.Template", "Lampa.Lang",
            "Lampa.Select", "Lampa.Modal", "Lampa.Noty"
        ]
        for api in apiPatterns {
            if code.contains(api) { detectedAPIs.append(api) }
        }
        if code.contains("$(") || code.contains("jQuery") { detectedAPIs.append("jQuery") }
        if code.contains("document.") { detectedAPIs.append("DOM") }
        updatedItem.detectedAPIs = detectedAPIs
        logEvent("INFO", "[StaticAnalysis]", "Detected APIs: \(detectedAPIs.joined(separator: ", "))")

        // MARK: - Step 6-10: Runtime Activation & Probe Execution
        onStageChanged(.runtimeInit, "Подготовка изолированного рантайма...")
        updatedItem.stage = .runtimeInit

        var runtimeReady = false
        do {
            try await runtimeProbe.prepareRuntime()
            runtimeReady = true
            logEvent("SUCCESS", "[RuntimeInit]", "Isolated test runtime initialized")
        } catch {
            logEvent("ERROR", "[RuntimeInit]", "Failed to initialize runtime: \(error.localizedDescription)")
            nativeErrors.append("Runtime init failed: \(error.localizedDescription)")
        }

        onStageChanged(.activating, "Выполнение скрипта плагина...")
        updatedItem.stage = .activating

        var rawReport = PluginProbeRawReport()
        var probeBlocked = !runtimeReady
        if runtimeReady {
        do {
            rawReport = try await runtimeProbe.evaluatePlugin(script: code, url: item.url)
            logEvent("INFO", "[Activation]", "Plugin script executed in probe sandbox")
        } catch {
            logEvent("ERROR", "[Activation]", "Plugin probe failed: \(error.localizedDescription)")
            let nsError = error as NSError
            // A stalled/unavailable diagnostic WebKit runtime does not establish a plugin bug.
            if nsError.domain == "PluginLab" && [408, 422, 503].contains(nsError.code) {
                probeBlocked = true
                nativeErrors.append("Probe limitation: \(error.localizedDescription)")
            } else {
                rawReport.jsErrors.append(PluginProbeRawReport.JSError(
                    message: error.localizedDescription,
                    filename: item.url,
                    lineno: 0,
                    colno: 0,
                    stack: ""
                ))
            }
        }

        } else {
            rawReport.jsErrors.append(PluginProbeRawReport.JSError(
                message: "Lampa runtime unavailable: test blocked", filename: item.url,
                lineno: nil, colno: nil, stack: nil
            ))
        }

        // MARK: - Step 11-13: UI & Action Probing
        onStageChanged(.probingUI, "Анализ интерфейса и нативных действий...")
        updatedItem.stage = .probingUI

        let (uiComponents, uiFailures, uiSummaries) = PluginUIProbe.analyze(
            rawReport: rawReport,
            pluginUrl: item.url,
            pluginName: item.name
        )

        for comp in uiComponents {
            logEvent("INFO", "[UIProbe]", "Component «\(comp.name)»: \(comp.nativeActionStatus)")
        }

        // MARK: - Step 14: Settings Probing
        if !rawReport.registeredSettings.isEmpty {
            onStageChanged(.probingSettings, "Проверка настроек...")
            updatedItem.stage = .probingSettings
            for s in rawReport.registeredSettings {
                logEvent("INFO", "[SettingsProbe]", "Setting param: \(s.name) (\(s.type)), default=\(s.defaultValue)")
            }
        }

        // MARK: - Step 15: Source & Resolver Probing
        if !rawReport.registeredSources.isEmpty {
            onStageChanged(.probingResolvers, "Проверка источников и резолверов...")
            updatedItem.stage = .probingResolvers
            for src in rawReport.registeredSources {
                logEvent("INFO", "[SourceProbe]", "Source provider: \(src.name) (operational=\(src.isOperational))")
            }
        }

        // MARK: - Step 16-17: Visual Snapshot & Cleanup
        onStageChanged(.cleanup, "Очистка рантайма...")
        updatedItem.stage = .cleanup

        // Snapshots may contain credentials/account data. Do not export them without redaction.
        let screenshotData: Data? = nil
        let observedNativeEvents = runtimeProbe.drainCollectedEvents()
        timeline.append(contentsOf: observedNativeEvents)
        logEvent("INFO", "[Cleanup]", "Runtime will be destroyed before the next plugin; no live user settings were modified")

        // MARK: - Step 18: Verdict Analysis & Evidence Persistence
        let analysis = PluginCapabilityAnalyzer.analyze(
            item: updatedItem,
            rawReport: rawReport,
            uiComponents: uiComponents,
            uiFailures: uiFailures,
            uiSummaries: uiSummaries,
            downloadError: nil
        )

        updatedItem.status = probeBlocked ? .blocked : analysis.status
        updatedItem.confidence = probeBlocked ? .high : analysis.confidence
        updatedItem.primaryRootCause = probeBlocked ? .unverifiedTestLimitation : analysis.primaryRootCause
        updatedItem.failureSummary = probeBlocked ? "Plugin execution could not be verified: diagnostic WebKit runtime blocked or timed out" : analysis.failureSummary
        updatedItem.stage = .completed

        onStageChanged(.completed, "Готово: \(updatedItem.status.displayName)")
        logEvent("INFO", "[Verdict]", "Final status: \(updatedItem.status.rawValue), Confidence: \(updatedItem.confidence.rawValue)")

        // Package evidence
        let evidence = PluginDiagnosticEvidence(
            item: updatedItem,
            timeline: timeline,
            jsErrors: rawReport.jsErrors,
            nativeErrors: nativeErrors,
            uiComponents: uiComponents,
            apiCoverage: analysis.apiCoverage,
            bridgeEvents: rawReport.events,
            // An observed request is not automatically a failed request.
            networkErrors: [],
            screenshotData: screenshotData
        )
        PluginDiagnosticsRecorder.shared.recordEvidence(evidence)

        return updatedItem
    }
}
