import Foundation

/// Conservative UI analysis: observing a DOM node is NOT proof of a missing callback.
final class PluginUIProbe {
    static func analyze(
        rawReport: PluginProbeRawReport,
        pluginUrl: String,
        pluginName: String
    ) -> (components: [PluginLabUIComponentInfo], failures: [PluginLabRootCause], summaries: [String]) {
        var components: [PluginLabUIComponentInfo] = []
        var failures: [PluginLabRootCause] = []
        var summaries: [String] = []

        for comp in rawReport.registeredComponents {
            let actions = rawReport.domAdditions.compactMap { $0.action }.filter { !$0.isEmpty }
            let domCreated = rawReport.domAdditions.map { "<\($0.tag)> class=\"\($0.className)\"" }

            // Only verified callback failures can establish an absent handler. An arbitrary
            // data-action attribute may be handled entirely inside the plugin's JavaScript.
            let confirmedMissing = rawReport.uiFailures
                .filter { $0.type == "native_action_failed" || $0.type == "bridge_action_failed" }
                .map(\.component)
                .filter { actions.contains($0) }

            let status: String
            if !confirmedMissing.isEmpty {
                status = "Нативное действие: ошибка подтверждена"
            } else if comp.hasNativeRenderer {
                status = "Нативный рендерер заявлен; работа не проверена"
            } else {
                status = "Интерфейс не проверен; может требовать WebKit"
            }

            components.append(PluginLabUIComponentInfo(
                name: comp.name, isPlatform: comp.isPlatform,
                hasNativeRenderer: comp.hasNativeRenderer, nativeActionStatus: status,
                lifecycleMethods: comp.lifecycleMethods,
                instantiationSuccess: comp.instantiationSuccess,
                instantiationError: comp.instantiationError,
                actionHandlers: actions, missingActions: confirmedMissing,
                domElementsCreated: domCreated, platformDependencies: rawReport.platformQueries
            ))

            if !confirmedMissing.isEmpty {
                if !failures.contains(.missingNativeBridgeAction) { failures.append(.missingNativeBridgeAction) }
                summaries.append("Подтверждена ошибка действия: \(confirmedMissing.joined(separator: ", ")).")
            }
            if let error = comp.instantiationError {
                if !failures.contains(.callbackFailure) { failures.append(.callbackFailure) }
                summaries.append("Ошибка создания компонента \(comp.name): \(error)")
            }
        }

        for observed in rawReport.uiFailures {
            // Synthetic notices generated merely by registration are not runtime failures.
            if observed.type == "native_action_failed" || observed.type == "bridge_action_failed" {
                if !failures.contains(.missingNativeBridgeAction) { failures.append(.missingNativeBridgeAction) }
                summaries.append(observed.detail)
            } else if observed.type == "render_failed" {
                if !failures.contains(.unsupportedCustomUI) { failures.append(.unsupportedCustomUI) }
                summaries.append(observed.detail)
            }
        }

        // Platform.is("tizen") etc. are feature detection, NOT incompatibility.
        // Never infer failure from a platform name that the script merely queried.
        return (components, failures, summaries)
    }
}
