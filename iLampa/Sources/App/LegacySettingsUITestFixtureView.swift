#if DEBUG
import SwiftUI

/// Drives the real plugin detail view with an approved legacy JavaScript fixture.
@MainActor
struct LegacySettingsUITestFixtureView: View {
    private let owner = "https://fixture.invalid/legacy-settings-ui.js"
    @State private var suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    @State private var error = ""
    @State private var evidence = "Not read"
    @ObservedObject private var manager = PluginManager.shared
    @ObservedObject private var runtime = LampaHeadlessHost.shared

    var body: some View {
        NavigationStack {
            if let plugin = manager.installedPlugins.first(where: { $0.urlString == owner }) {
                NativePluginDetailView(pluginID: plugin.id)
            } else { Text("Waiting for fixture") }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Restart") { LampaHeadlessHost.shared.bootstrap() }
                    .accessibilityIdentifier("legacyFixtureRestart")
                Button("Toggle plugin") {
                    if let record = manager.installedPlugins.first(where: { $0.urlString == owner }) { manager.toggle(plugin: record) }
                }.accessibilityIdentifier("legacyFixtureToggle")
                Button("Remove") {
                    if let record = manager.installedPlugins.first(where: { $0.urlString == owner }) { manager.remove(plugin: record) }
                }.accessibilityIdentifier("legacyFixtureRemove")
                Button("Read evidence") { readEvidence() }
                    .accessibilityIdentifier("legacyFixtureReadEvidence")
                    .disabled(!runtime.isAppReady || !runtime.legacySettings.contains { $0.owner == owner })
            }.font(.caption).padding(8).background(Color(UIColor.systemBackground))
        }
        .overlay(alignment: .bottom) {
            // Read-only DEBUG evidence, not an alternate setting mutation path.
            VStack {
                Text(String(runtime.currentGeneration)).accessibilityIdentifier("legacyFixtureGeneration")
                Text(evidence).accessibilityIdentifier("legacyFixtureEvidence")
            }.font(.system(size: 6)).allowsHitTesting(false).offset(y: -45)
        }
        .overlay(alignment: .top) { if !error.isEmpty { Text(error) } }
        .background { LampaHostContainerView().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false) }
        .onAppear {
            if let record = manager.installedPlugins.first(where: { $0.urlString == owner }) { manager.remove(plugin: record) }
            let script = """
            Lampa.SettingsApi.addComponent({component:'fixture_\(suffix)',name:'Fixture settings'});
            Lampa.SettingsApi.addParam({component:'fixture_\(suffix)',param:{name:'ui_\(suffix)',type:'trigger',default:false},field:{name:'Fixture toggle'},onChange:function(v){window.__uiFixtureCallback=v;}});
            Lampa.SettingsApi.addParam({component:'fixture_\(suffix)',param:{name:'ui_select_\(suffix)',type:'select',values:{a:'Option A',b:'Option B'},default:'a'},field:{name:'Fixture select'},onChange:function(v){window.__uiFixtureSelect=v;window.__uiFixtureSelectStored=Lampa.Storage.get('ui_select_\(suffix)');window.__uiFixtureSelectionCallbacks=(window.__uiFixtureSelectionCallbacks||0)+1;}});
            Lampa.SettingsApi.addParam({component:'fixture_\(suffix)',param:{type:'title'},field:{name:'Fixture heading'}});
            Lampa.SettingsApi.addParam({component:'fixture_\(suffix)',param:{name:'ui_input_\(suffix)',type:'input',default:'initial'},field:{name:'Fixture input'},onChange:function(v){window.__uiFixtureInput=v;}});
            """
            manager.installPreparedScript(script, url: owner, name: "Legacy UI fixture")
            guard let record = manager.installedPlugins.first(where: { $0.urlString == owner }),
                  let hash = manager.cachedScriptSHA256(for: owner),
                  manager.approveCachedScript(pluginID: record.id, expectedSHA256: hash) else {
                error = "Fixture installation or approval failed"; return
            }
        }
    }

    private func readEvidence() {
        evidence = "Reading"
        let generation = runtime.currentGeneration
        let script = """
        JSON.stringify({select:Lampa.Storage.get('ui_select_\(suffix)'),
            input:Lampa.Storage.get('ui_input_\(suffix)'),toggle:Lampa.Storage.get('ui_\(suffix)'),
            callback:window.__uiFixtureSelect,storageDuringCallback:window.__uiFixtureSelectStored,
            selectionCallbacks:window.__uiFixtureSelectionCallbacks||0})
        """
        runtime.webView?.evaluateJavaScript(script) { result, failure in
            guard runtime.currentGeneration == generation else { return }
            evidence = (result as? String) ?? "Read failed: \(failure?.localizedDescription ?? "no result")"
        }
    }
}
#endif
