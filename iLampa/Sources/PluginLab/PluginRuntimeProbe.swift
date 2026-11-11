import Foundation
import WebKit
import UIKit

/// Raw report returned by the JavaScript diagnostic probe.
struct PluginProbeRawReport: Codable, Equatable {
    struct JSError: Codable, Equatable {
        let message: String
        let filename: String?
        let lineno: Int?
        let colno: Int?
        let stack: String?
    }

    struct RawComponent: Codable, Equatable {
        let name: String
        let isPlatform: Bool
        let hasNativeRenderer: Bool
        let lifecycleMethods: [String]
        let instantiationSuccess: Bool
        let instantiationError: String?
    }

    struct RawSource: Codable, Equatable {
        let id: String
        let name: String
        let hasResolve: Bool
        let hasSearch: Bool
        let hasNativeStream: Bool
        let isOperational: Bool
    }

    struct RawSetting: Codable, Equatable {
        let component: String
        let name: String
        let type: String
        let defaultValue: String
        let hasOnRender: Bool
        let options: [String]
    }

    struct RawDOMAddition: Codable, Equatable {
        let tag: String
        let action: String?
        let className: String
        let text: String
    }

    struct RawUIFailure: Codable, Equatable {
        let component: String
        let type: String
        let reason: String
        let detail: String
        let nativeAction: String
    }

    var events: [[String: String]] = []
    var jsErrors: [JSError] = []
    var registeredComponents: [RawComponent] = []
    var registeredSources: [RawSource] = []
    var registeredSettings: [RawSetting] = []
    var domAdditions: [RawDOMAddition] = []
    var platformQueries: [String] = []
    var networkRequests: [[String: String]] = []
    var uiFailures: [RawUIFailure] = []
    var apiTouches: [String: Int] = [:]
}

/// One-shot request gate prevents a stalled WebKit callback from blocking the whole campaign.
@MainActor
private final class PluginLabJavaScriptGate {
    var continuation: CheckedContinuation<Any, Error>?

    func finish(_ result: Result<Any, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Hosts and probes plugins in an isolated WebKit / JavaScriptCore runtime.
@MainActor
final class PluginRuntimeProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var webView: WKWebView?
    private var isCoreReady = false
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var loadTimeoutTask: Task<Void, Never>?
    private var collectedEvents: [PluginLabTimelineEvent] = []

    func drainCollectedEvents() -> [PluginLabTimelineEvent] {
        defer { collectedEvents.removeAll() }
        return collectedEvents
    }

    private func finishLoading(_ error: Error? = nil) {
        loadTimeoutTask?.cancel()
        loadTimeoutTask = nil
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
    private let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 10.0) {
        self.timeoutSeconds = timeoutSeconds
        super.init()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "pluginLabMessage", let dict = message.body as? [String: Any] {
            let level = dict["level"] as? String ?? "INFO"
            let category = dict["category"] as? String ?? "[Probe]"
            let msg = dict["message"] as? String ?? ""
            let meta = (dict["metadata"] as? [String: Any])?.mapValues { value in
                // JS ErrorEvent metadata also contains numeric line and column values.
                String(describing: value)
            }
            let evt = PluginLabTimelineEvent(
                stage: "probe",
                category: category,
                message: msg,
                level: level,
                metadata: meta
            )
            collectedEvents.append(evt)
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Poll for window.appready or timeout
        Task {
            var waited = 0.0
            while waited < 5.0 {
                if let ready = try? await evaluateBounded("window.appready === true", webView: webView) as? Bool, ready {
                    isCoreReady = true
                    finishLoading()
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
            finishLoading(NSError(domain: "PluginLab", code: 408, userInfo: [
                NSLocalizedDescriptionKey: "Lampa core не установил appready за 5 секунд"
            ]))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(error)
    }

    // MARK: - Runtime Preparation

    /// Prepares an isolated WebKit environment loaded with Lampa core, bridge, and diagnostic probe.
    func prepareRuntime() async throws {
        teardown()
        collectedEvents.removeAll()

        let config = WKWebViewConfiguration()
        // Isolate localStorage, IndexedDB, cookies and caches from the live app.
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let userController = WKUserContentController()
        userController.add(self, name: "pluginLabMessage")

        // Load probe script
        var probeCode = ""
        if let probePath = Bundle.main.path(forResource: "plugin_lab_probe", ofType: "js", inDirectory: "plugins"),
           let code = try? String(contentsOfFile: probePath, encoding: .utf8) {
            probeCode = code
        } else if let probePath = Bundle.main.path(forResource: "plugin_lab_probe", ofType: "js"),
                  let code = try? String(contentsOfFile: probePath, encoding: .utf8) {
            probeCode = code
        }

        guard !probeCode.isEmpty else {
            throw NSError(domain: "PluginLab", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Plugin Lab probe resource is missing"
            ])
        }

        // Bridge script
        var bridgeCode = ""
        if let bridgePath = Bundle.main.path(forResource: "lampa_bridge", ofType: "js"),
           let code = try? String(contentsOfFile: bridgePath, encoding: .utf8) {
            bridgeCode = code
        }

        let setupScript = """
        window.__ilampaGeneration = 9999;
        window.__ilampaDocumentToken = 'plugin-lab-\(UUID().uuidString)';
        window.__ilampaNativeManaged = true;
        """
        userController.addUserScript(WKUserScript(source: setupScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if !bridgeCode.isEmpty {
            userController.addUserScript(WKUserScript(source: bridgeCode, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if !probeCode.isEmpty {
            userController.addUserScript(WKUserScript(source: probeCode, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        config.userContentController = userController

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.readyContinuation = continuation
                self.loadTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.finishLoading(NSError(domain: "PluginLab", code: 408, userInfo: [
                        NSLocalizedDescriptionKey: "WebKit navigation timeout"
                    ]))
                }
                wv.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
            }
        } else {
            throw NSError(domain: "PluginLab", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Lampa www/index.html missing; a stub would invalidate results"
            ])
        }
    }

    /// WebKit API callbacks can stall after WebContent process failure.
    /// The timeout resumes native control without falsely reporting success.
    private func evaluateBounded(_ source: String, webView: WKWebView) async throws -> Any {
        let gate = PluginLabJavaScriptGate()
        return try await withCheckedThrowingContinuation { continuation in
            gate.continuation = continuation
            webView.evaluateJavaScript(source) { result, error in
                Task { @MainActor in
                    if let error {
                        gate.finish(.failure(error))
                    } else {
                        gate.finish(.success(result ?? NSNull()))
                    }
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                gate.finish(.failure(NSError(domain: "PluginLab", code: 408, userInfo: [
                    NSLocalizedDescriptionKey: "WebKit JavaScript evaluation timeout"
                ])))
            }
        }
    }

    // MARK: - Plugin Evaluation & Report Retrieval

    /// Evaluates a plugin script inside the probed runtime and collects the diagnostic report.
    func evaluatePlugin(script: String, url: String) async throws -> PluginProbeRawReport {
        guard let wv = webView, isCoreReady else {
            throw NSError(domain: "PluginLab", code: 503, userInfo: [
                NSLocalizedDescriptionKey: "Real Lampa WebKit runtime not ready; JSCore fallback is not representative"
            ])
        }
        return try await evaluateInWebKit(wv: wv, script: script, url: url)
    }

    private func evaluateInWebKit(wv: WKWebView, script: String, url: String) async throws -> PluginProbeRawReport {
        // Reset the probe and bind it to this exact plugin. No background
        // Lampa Core call is allowed to become evidence for this plugin.
        let beginLiteral = String(data: try JSONSerialization.data(withJSONObject: [url]), encoding: .utf8)!
        _ = try await evaluateBounded(
            "if (!window.__pluginLab) throw new Error('Probe missing'); window.__pluginLab.beginPlugin(\(beginLiteral)[0]);",
            webView: wv
        )

        // Encode both the code and URL as JSON strings; never interpolate arbitrary JS as source.
        let scriptLiteral = String(data: try JSONSerialization.data(withJSONObject: [script], options: [.fragmentsAllowed]), encoding: .utf8)!
        let urlLiteral = String(data: try JSONSerialization.data(withJSONObject: [url], options: [.fragmentsAllowed]), encoding: .utf8)!
        let injectionCode = """
        (function() {
            var source = \(scriptLiteral)[0];
            var pluginURL = \(urlLiteral)[0];
            window.__ilampaExecutingPluginURL = pluginURL;
            try {
                (0, eval)(source + "\\n//# sourceURL=" + pluginURL.replace(/[\\r\\n]/g, ""));
                return { success: true };
            } catch (ex) {
                return {
                    success: false,
                    error: (ex && ex.message) ? ex.message : String(ex),
                    stack: (ex && ex.stack) ? ex.stack : ''
                };
            } finally {
                window.__ilampaExecutingPluginURL = null;
                if (window.__pluginLab) window.__pluginLab.endPlugin();
            }
        })();
        """

        let evalResult = try await evaluateBounded(injectionCode, webView: wv)
        if let dict = evalResult as? [String: Any], dict["success"] as? Bool == false {
            let errMsg = dict["error"] as? String ?? "Execution error"
            let stack = dict["stack"] as? String ?? ""
            collectedEvents.append(PluginLabTimelineEvent(
                stage: "activating",
                category: "[JSError]",
                message: errMsg,
                level: "ERROR",
                metadata: ["stack": stack]
            ))
        }

        // Allow microtasks and DOM mutations to propagate
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Retrieve full report from JS probe
        let reportScript = """
        (function () {
            if (!window.__pluginLab || typeof window.__pluginLab.getReport !== 'function') {
                return JSON.stringify({ __probeError: 'Plugin Lab probe not installed' });
            }
            return JSON.stringify(window.__pluginLab.getReport());
        })();
        """
        guard let jsonString = try await evaluateBounded(reportScript, webView: wv) as? String,
              let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "PluginLab", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Plugin Lab probe did not return a JSON string"
            ])
        }
        if jsonString.contains("\"__probeError\"") {
            throw NSError(domain: "PluginLab", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Plugin Lab probe is not installed in WebKit"
            ])
        }

        let decodedReport: PluginProbeRawReport
        do {
            decodedReport = try JSONDecoder().decode(PluginProbeRawReport.self, from: data)
        } catch let DecodingError.typeMismatch(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw NSError(domain: "PluginLab", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Probe report schema mismatch at \(path): \(context.debugDescription)"
            ])
        } catch let DecodingError.keyNotFound(key, context) {
            let path = (context.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            throw NSError(domain: "PluginLab", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Probe report missing field: \(path)"
            ])
        } catch let DecodingError.valueNotFound(_, context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw NSError(domain: "PluginLab", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Probe report missing value at: \(path)"
            ])
        } catch {
            throw NSError(domain: "PluginLab", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Probe report decoding failed: \(error.localizedDescription)"
            ])
        }
        var decoded = decodedReport
        if let dict = evalResult as? [String: Any], dict["success"] as? Bool == false {
            decoded.jsErrors.append(PluginProbeRawReport.JSError(
                message: dict["error"] as? String ?? "Unknown JavaScript exception",
                filename: url, lineno: nil, colno: nil,
                stack: dict["stack"] as? String
            ))
        }
        return decoded
    }

    // MARK: - Snapshot Capture

    /// Captures a visual snapshot of the rendered WebKit view, if available.
    func captureSnapshot() async -> Data? {
        guard let wv = webView else { return nil }
        return await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            wv.takeSnapshot(with: config) { image, _ in
                let data = image?.pngData()
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Teardown

    func teardown() {
        finishLoading(NSError(domain: "PluginLab", code: -999, userInfo: [
            NSLocalizedDescriptionKey: "Runtime navigation cancelled"
        ]))
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "pluginLabMessage")
        webView = nil
        isCoreReady = false
        readyContinuation = nil
    }
}
