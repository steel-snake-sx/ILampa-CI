import UIKit
import WebKit
import XCTest
@testable import iLampa

/// Real WebKit + shipped executor + shipped bridge. The submission driver is
/// held explicitly, so invalidation always precedes JS execution, without sleeps.
@MainActor
final class RuntimeExecutionWebKitTests: XCTestCase, WKNavigationDelegate, WKUIDelegate {
    private var loaded: XCTestExpectation?
    private var executor: RuntimeJavaScriptExecutor!
    private var eligible = true
    private var promptCount = 0
    private var committedAtPrompt: (() -> Void)?
    private var previousKeyWindow: UIWindow?
    private var fixtureDirectory: URL?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.fulfill() }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        promptCount += 1
        guard prompt == RuntimeJavaScriptExecutor.prompt, frame.isMainFrame,
              let data = defaultText?.data(using: .utf8),
              let ticket = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = ticket["id"] as? String, let generation = ticket["generation"] as? Int,
              let token = ticket["documentToken"] as? String,
              executor.authorize(id: id, generation: generation, documentToken: token) else {
            completionHandler(nil); return
        }
        committedAtPrompt?()
        completionHandler(id)
    }

    private func makeWebView(mode: WebKitAttachmentMode = .attachedVisible) async throws -> (WKWebView, UIWindow) {
        eligible = true; promptCount = 0; committedAtPrompt = nil
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        webView.navigationDelegate = self; webView.uiDelegate = self
        let window: UIWindow
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first {
            previousKeyWindow = scene.windows.first(where: { $0.isKeyWindow })
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        } else { window = UIWindow(frame: webView.frame) }
        var fixtureReady = false
        defer { if !fixtureReady { finishFixture(webView, window: window) } }
        let controller = UIViewController()
        window.rootViewController = controller
        if mode != .detached { controller.view.addSubview(webView) }
        if mode == .attachedUnobtrusive {
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            webView.alpha = 0.01
            webView.isUserInteractionEnabled = false
        }
        window.makeKeyAndVisible()
        // Match the file-backed production WKWebView document instead of an
        // opaque remote loadHTMLString base URL. The latter can reject storage
        // with SecurityError on iOS 18 simulator runners.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ilampa-webkit-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fixtureDirectory = directory
        let fixtureURL = directory.appendingPathComponent("index.html")
        try "<html><body>Execution fixture</body></html>"
            .write(to: fixtureURL, atomically: true, encoding: .utf8)
        loaded = expectation(description: "fixture document loaded")
        webView.loadFileURL(fixtureURL, allowingReadAccessTo: directory)
        await fulfillment(of: [try XCTUnwrap(loaded)], timeout: 25)
        loaded = nil
        let path = try XCTUnwrap(Bundle.main.path(forResource: "lampa_bridge", ofType: "js"))
        let bridge = try String(contentsOfFile: path, encoding: .utf8)
            .replacingOccurrences(of: "window.LampaNativeBridge.init();", with: "")
        _ = try await webView.evaluateJavaScript("""
        window.__ilampaGeneration=1; window.__ilampaDocumentToken='doc'; window.__ilampaNativeManaged=true;
        window.events=[]; window.fixtureValue='false';
        window.Lampa={Lang:{translate:function(s){return s;}},
          SettingsApi:{addComponent:function(){},addParam:function(){},removeComponent:function(){},removeParams:function(){}},
          Storage:{field:function(){return window.fixtureValue;},set:function(k,v){window.fixtureValue=v;window.events.push('storage:'+v);}}};
        \(bridge)
        window.LampaNativeBridge.attachLegacySettingsHook();
        window.__ilampaExecutingPluginURL='owner';
        Lampa.SettingsApi.addParam({component:'fixture',param:{name:'key',type:'trigger'},field:{name:'Key'},
          onChange:function(v){window.events.push('callback:'+v);}});
        window.__ilampaExecutingPluginURL=null;
        // Storage persistence is tested by RealWebKitBootstrapTests with real Lampa.
        window.__fixtureGetItem=window.localStorage.getItem;
        Storage.prototype.getItem=function(k){return k==='key'?window.fixtureValue:window.__fixtureGetItem.call(this,k);};
        true;
        """)
        fixtureReady = true
        return (webView, window)
    }

    private func finishFixture(_ webView: WKWebView, window: UIWindow) {
        executor?.invalidate()
        webView.uiDelegate = nil
        window.isHidden = true
        previousKeyWindow?.makeKeyAndVisible()
        previousKeyWindow = nil
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
            self.fixtureDirectory = nil
        }
    }

    private func assertRendezvous(mode: WebKitAttachmentMode) async throws {
        let (webView, window) = try await makeWebView(mode: mode)
        defer { finishFixture(webView, window: window) }
        XCTAssertEqual(webView.window == nil, mode == .detached)
        executor = RuntimeJavaScriptExecutor { source, callback in webView.evaluateJavaScript(source, completionHandler: callback) }
        let result = try await executor.execute(
            body: "return window.LampaNativeBridge.changeLegacySetting('owner','1','true',1,'doc');",
            generation: 1, documentToken: "doc", eligible: { self.eligible }) as? [String: Any]
        XCTAssertEqual(result?["success"] as? Bool, true)
        XCTAssertEqual(promptCount, 1, "Must be delivered without user activation or a displayed dialog")
        let events = try await webView.evaluateJavaScript("window.events.join(',')") as? String
        XCTAssertEqual(events, "storage:true,callback:true")
    }

    func testRendezvousInVisibleSceneAttachedWebView() async throws { try await assertRendezvous(mode: .attachedVisible) }
    func testRendezvousInUnobtrusiveOnePointWebView() async throws { try await assertRendezvous(mode: .attachedUnobtrusive) }
    func testRendezvousInDetachedWebView() async throws { try await assertRendezvous(mode: .detached) }

    func testQueuedSettingsRejectedBeforeStorageAndCallbackInRealWebKit() async throws {
        let (webView, window) = try await makeWebView()
        defer { finishFixture(webView, window: window) }
        let submitted = expectation(description: "submission held before WebKit")
        var script: String?
        var completion: ((Any?, Error?) -> Void)?
        executor = RuntimeJavaScriptExecutor { source, callback in
            script = source; completion = callback; submitted.fulfill()
        }
        let action = Task { try await executor.execute(
            body: "return window.LampaNativeBridge.changeLegacySetting('owner','1','true',1,'doc');",
            generation: 1, documentToken: "doc", eligible: { self.eligible }) }
        await fulfillment(of: [submitted], timeout: 2)
        eligible = false
        executor.invalidate() // Native disable/remove/restart; document deliberately retained.
        let response = try await webView.evaluateJavaScript(try XCTUnwrap(script)) as? [String: Any]
        completion?(response, nil) // Late completion is also rejected by production executor.
        XCTAssertEqual(response?["success"] as? Bool, false)
        XCTAssertEqual(promptCount, 1)
        let events = try await webView.evaluateJavaScript("window.events.join(',')") as? String
        XCTAssertEqual(events, "")
        let value = try await webView.evaluateJavaScript("window.fixtureValue") as? String
        XCTAssertEqual(value, "false")
        do { _ = try await action.value; XCTFail("Revoked action succeeded") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testStartedTransactionMayFinishButCompletionCannotSurviveInvalidation() async throws {
        let (webView, window) = try await makeWebView()
        defer { finishFixture(webView, window: window) }
        executor = RuntimeJavaScriptExecutor { source, callback in webView.evaluateJavaScript(source, completionHandler: callback) }
        committedAtPrompt = { self.eligible = false; self.executor.invalidate() }
        do {
            _ = try await executor.execute(body: "return window.LampaNativeBridge.changeLegacySetting('owner','1','true',1,'doc');",
                                           generation: 1, documentToken: "doc", eligible: { self.eligible })
            XCTFail("Obsolete completion succeeded")
        } catch {
            guard let executionError = error as? RuntimeExecutionError, case .invalidatedAfterStart = executionError else {
                return XCTFail("Started transaction must not be reported as never executed: \(error)")
            }
        }
        // A subsequent WebKit evaluation observes the completed synchronous JS turn.
        let events = try await webView.evaluateJavaScript("window.events.join(',')") as? String
        XCTAssertEqual(events, "storage:true,callback:true")
        XCTAssertEqual(promptCount, 1)
    }
}
