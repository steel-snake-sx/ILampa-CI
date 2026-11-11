import Foundation

/// Conservative evidence-based classification. API registration is not proof of working functionality.
final class PluginCapabilityAnalyzer {
    struct AnalysisResult {
        let status: PluginLabStatus
        let confidence: PluginLabConfidence
        let primaryRootCause: PluginLabRootCause?
        let failureSummary: String?
        let apiCoverage: [PluginLabAPICoverage]
        let architecturalRemediation: String?
    }

    static func analyze(
        item: PluginLabItem,
        rawReport: PluginProbeRawReport,
        uiComponents: [PluginLabUIComponentInfo],
        uiFailures: [PluginLabRootCause],
        uiSummaries: [String],
        downloadError: String?
    ) -> AnalysisResult {
        let coverage = buildAPICoverage(rawReport: rawReport)

        if let downloadError {
            return AnalysisResult(
                status: .blocked, confidence: .high,
                primaryRootCause: .networkFailure,
                failureSummary: "Не удалось загрузить код: \(downloadError)",
                apiCoverage: coverage, architecturalRemediation: PluginLabRootCause.networkFailure.suggestedRemediation
            )
        }

        if let first = rawReport.jsErrors.first {
            let syntax = first.message.localizedCaseInsensitiveContains("syntax") ||
                first.message.localizedCaseInsensitiveContains("unexpected token")
            let cause: PluginLabRootCause = syntax ? .pluginScriptError : .runtimeInitializationFailure
            return AnalysisResult(
                status: .fail, confidence: .high, primaryRootCause: cause,
                failureSummary: "JavaScript: \(first.message)",
                apiCoverage: coverage, architecturalRemediation: cause.suggestedRemediation
            )
        }

        if let cause = uiFailures.first {
            return AnalysisResult(
                status: .partial, confidence: .medium, primaryRootCause: cause,
                failureSummary: uiSummaries.joined(separator: " ").isEmpty ?
                    "Обнаружены признаки несовместимости, требуется функциональная проверка." :
                    uiSummaries.joined(separator: " "),
                apiCoverage: coverage, architecturalRemediation: cause.suggestedRemediation
            )
        }

        // These indicate registration only; they do not verify callbacks, UI or streams.
        let registeredCount = rawReport.registeredSources.count +
            rawReport.registeredSettings.count + uiComponents.count
        if registeredCount > 0 {
            // A constructor plus create() yielding real DOM is stronger than
            // Component.add alone. It still proves neither click-handling nor
            // a stream handoff, so the verdict must remain PARTIAL.
            let constructedWebKitUI = uiComponents.contains {
                $0.instantiationSuccess && !$0.domElementsCreated.isEmpty
            }
            return AnalysisResult(
                status: .partial, confidence: constructedWebKitUI ? .medium : .low,
                primaryRootCause: .unverifiedTestLimitation,
                failureSummary: constructedWebKitUI
                    ? "WebKit создал интерфейс плагина. Нажатия, действия и воспроизведение ещё не проверены."
                    : "Обнаружены \(registeredCount) зарегистрированных возможностей, но их функциональность не подтверждена.",
                apiCoverage: coverage,
                architecturalRemediation: PluginLabRootCause.unverifiedTestLimitation.suggestedRemediation
            )
        }

        // No-op script, missing callbacks, or missing probe must NEVER become PASS.
        return AnalysisResult(
            status: .untested, confidence: .low,
            primaryRootCause: .unverifiedTestLimitation,
            failureSummary: "Скрипт выполнен, но работающие возможности не были подтверждены тестами.",
            apiCoverage: coverage,
            architecturalRemediation: PluginLabRootCause.unverifiedTestLimitation.suggestedRemediation
        )
    }

    /// A touch means only that a method was called; it never proves the method is supported.
    static func buildAPICoverage(rawReport: PluginProbeRawReport) -> [PluginLabAPICoverage] {
        let names = [
            "Lampa.Plugins.add", "Lampa.Component.add", "Lampa.Sources.add",
            "Lampa.SettingsApi.addComponent", "Lampa.SettingsApi.addParam",
            "Lampa.Listener.follow", "Lampa.Storage.set", "Lampa.Storage.get",
            "Lampa.Platform.is", "Lampa.Activity.push", "Lampa.Activity.out",
            "Lampa.Reguest", "Lampa.Template.add", "Lampa.Lang.add",
            "Lampa.Modal.open", "Lampa.Noty.show"
        ]
        return names.map { name in
            let count = rawReport.apiTouches[name] ?? 0
            return PluginLabAPICoverage(
                apiName: name,
                isReferenced: count > 0,
                isUsedAtRuntime: count > 0,
                isSupported: false, // Not verified by an actual end-to-end behavioral check.
                note: count > 0 ? "Наблюдалось вызовов: \(count); результат не проверен" : "Не наблюдалось"
            )
        }
    }
}
