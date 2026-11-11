import Foundation
import JavaScriptCore

// Sandboxed JavaScript runtime hosting and executing Lampa plugins via JavaScriptCore.
@MainActor
final class PluginRuntimeHost {
    static let shared = PluginRuntimeHost()

    private let virtualMachine = JSVirtualMachine()
    private var activeContexts: [String: JSContext] = [:] // pluginUrl -> JSContext

    private init() {}

    // Prepares an isolated JSContext pre-populated with the Lampa compatibility bridge.
    private func createContext(for pluginUrl: String) -> JSContext? {
        guard let context = JSContext(virtualMachine: virtualMachine) ?? JSContext() else {
            return nil
        }

        context.exceptionHandler = { _, exception in
            let errMsg = exception?.toString() ?? "Unknown JS Error"
            print("[PluginRuntimeHost][\(pluginUrl)] JS Exception: \(errMsg)")
        }

        // Window self-reference
        context.evaluateScript("var window = this; var global = this;")

        // Console logger
        let consoleLog: @convention(block) (String) -> Void = { msg in
            print("[PluginJS][\(pluginUrl)] INFO: \(msg)")
        }
        let consoleWarn: @convention(block) (String) -> Void = { msg in
            print("[PluginJS][\(pluginUrl)] WARN: \(msg)")
        }
        let consoleError: @convention(block) (String) -> Void = { msg in
            print("[PluginJS][\(pluginUrl)] ERROR: \(msg)")
        }
        let consoleObj = JSValue(newObjectIn: context)
        consoleObj?.setValue(consoleLog, forProperty: "log")
        consoleObj?.setValue(consoleWarn, forProperty: "warn")
        consoleObj?.setValue(consoleError, forProperty: "error")
        context.setObject(consoleObj, forKeyedSubscript: "console" as NSString)

        // Lampa Global Namespace
        let lampaObj = JSValue(newObjectIn: context)

        // Lampa.Plugins.add
        let pluginsAdd: @convention(block) (JSValue) -> Void = { info in
            let name = info.forProperty("name")?.toString() ?? "Unnamed Plugin"
            let author = info.forProperty("author")?.toString() ?? "Community"
            let version = info.forProperty("version")?.toString() ?? "1.0"
            let type = info.forProperty("type")?.toString() ?? "general"
            print("[PluginRuntimeHost] Plugin registered: \(name) v\(version) (\(author)) type=\(type)")

            if type == "source" || info.hasProperty("source") {
                let hasResolver = info.hasProperty("resolve") || info.hasProperty("search")
                PluginCapabilityRegistry.shared.registerSource(
                    pluginUrl: pluginUrl,
                    id: "\(pluginUrl)#source",
                    name: name,
                    description: info.forProperty("description")?.toString(),
                    hasExecutableResolver: hasResolver,
                    capability: hasResolver ? .mediaSource : .interactiveComponent,
                    operationalStatus: hasResolver ? .initialized : .interfaceOnly
                )
            }
        }
        let lampaPlugins = JSValue(newObjectIn: context)
        lampaPlugins?.setValue(pluginsAdd, forProperty: "add")
        lampaObj?.setValue(lampaPlugins, forProperty: "Plugins")

        // Lampa.Sources.add
        let sourcesAdd: @convention(block) (JSValue) -> Void = { sourceObj in
            let srcId = sourceObj.forProperty("id")?.toString() ?? UUID().uuidString
            let srcName = sourceObj.forProperty("name")?.toString() ?? "Custom Source"
            let srcDesc = sourceObj.forProperty("description")?.toString()
            let hasResolver = sourceObj.hasProperty("resolve") || sourceObj.hasProperty("search")
            print("[PluginRuntimeHost] Source provider registered: \(srcName) [\(srcId)] (hasResolver=\(hasResolver))")

            PluginCapabilityRegistry.shared.registerSource(
                pluginUrl: pluginUrl,
                id: srcId,
                name: srcName,
                description: srcDesc,
                hasExecutableResolver: hasResolver,
                capability: .interactiveComponent,
                operationalStatus: hasResolver ? .initialized : .registered
            )
        }
        let lampaSources = JSValue(newObjectIn: context)
        lampaSources?.setValue(sourcesAdd, forProperty: "add")
        lampaObj?.setValue(lampaSources, forProperty: "Sources")

        // Lampa.Storage bridge to UserDefaults
        let storageGet: @convention(block) (String, JSValue) -> JSValue? = { key, defaultVal in
            let stored = UserDefaults.standard.string(forKey: "lampa_storage_\(key)")
            if let stored = stored {
                return JSValue(object: stored, in: JSContext.current())
            }
            return defaultVal
        }
        let storageSet: @convention(block) (String, JSValue) -> Void = { key, val in
            let str = val.toString() ?? ""
            UserDefaults.standard.set(str, forKey: "lampa_storage_\(key)")
        }
        let lampaStorage = JSValue(newObjectIn: context)
        lampaStorage?.setValue(storageGet, forProperty: "get")
        lampaStorage?.setValue(storageSet, forProperty: "set")
        lampaObj?.setValue(lampaStorage, forProperty: "Storage")

        // Lampa.Listener event bus
        let listenerFollow: @convention(block) (String, JSValue) -> Void = { event, callback in
            print("[PluginRuntimeHost] Follow event: \(event)")
            PluginCapabilityRegistry.shared.registerHook(pluginUrl: pluginUrl, event: event)
            if event == "app" || event == "full" {
                // Immediately notify ready event
                let readyObj = JSValue(newObjectIn: JSContext.current())
                readyObj?.setValue("ready", forProperty: "type")
                callback.call(withArguments: [readyObj as Any])
            }
        }
        let lampaListener = JSValue(newObjectIn: context)
        lampaListener?.setValue(listenerFollow, forProperty: "follow")
        lampaObj?.setValue(lampaListener, forProperty: "Listener")

        // Lampa.Component registry
        let componentAdd: @convention(block) (String, JSValue) -> Void = { name, compObj in
            print("[PluginRuntimeHost] Component added: \(name)")
            if name == "online" || name.contains("balancer") || name.contains("source") {
                let hasResolver = compObj.hasProperty("resolve") || compObj.hasProperty("search")
                PluginCapabilityRegistry.shared.registerSource(
                    pluginUrl: pluginUrl,
                    id: "\(pluginUrl)#\(name)",
                    name: "Балансер: \(name.capitalized)",
                    description: hasResolver ? "Компонент онлайн-источника с резолвером" : "Компонент интерфейса (требуется нативный адаптер)",
                    hasExecutableResolver: hasResolver,
                    capability: hasResolver ? .mediaSource : .interactiveComponent,
                    operationalStatus: hasResolver ? .initialized : .adapterRequired
                )
            }
        }
        let lampaComponent = JSValue(newObjectIn: context)
        lampaComponent?.setValue(componentAdd, forProperty: "add")
        lampaObj?.setValue(lampaComponent, forProperty: "Component")

        // Additional Lampa metadata shims
        lampaObj?.setValue(JSValue(object: ["cub_domain": "cub.best", "app_digital": 100], in: context), forProperty: "Manifest")
        lampaObj?.setValue(JSValue(newObjectIn: context), forProperty: "Params")

        context.setObject(lampaObj, forKeyedSubscript: "Lampa" as NSString)

        // Set app ready state
        context.evaluateScript("window.appready = true; window.lampa_installed = true;")

        return context
    }

    // Evaluates a plugin script inside an isolated JS environment.
    @discardableResult
    func evaluate(pluginUrl: String, script: String) -> (success: Bool, error: String?) {
        guard PluginManager.shared.isApproved(script: script, for: pluginUrl) else {
            return (false, PluginTrustError.approvalRequired.localizedDescription)
        }
        // Clean up previous context if re-evaluating
        activeContexts[pluginUrl] = nil
        PluginCapabilityRegistry.shared.unregisterAll(for: pluginUrl)

        guard let context = createContext(for: pluginUrl) else {
            return (false, "Could not initialize JSContext")
        }
        activeContexts[pluginUrl] = context

        // Execute plugin script
        _ = context.evaluateScript(script)

        if let exception = context.exception {
            let errMsg = exception.toString() ?? "Execution exception"
            print("[PluginRuntimeHost] Execution error in \(pluginUrl): \(errMsg)")
            return (false, errMsg)
        }

        print("[PluginRuntimeHost] Plugin evaluated successfully: \(pluginUrl)")
        return (true, nil)
    }

    // Unregisters capabilities and frees the JSContext for a disabled or deleted plugin.
    func teardown(pluginUrl: String) {
        activeContexts[pluginUrl] = nil
        PluginCapabilityRegistry.shared.unregisterAll(for: pluginUrl)
        print("[PluginRuntimeHost] Plugin runtime torn down: \(pluginUrl)")
    }

    // Checks whether a plugin currently has an active running context.
    func isRunning(pluginUrl: String) -> Bool {
        return activeContexts[pluginUrl] != nil
    }

    // Clears all running contexts and capabilities.
    func reset() {
        activeContexts.removeAll()
        PluginCapabilityRegistry.shared.clear()
    }
}
