#if DEBUG
import SwiftUI

/// Debug-only driver. Data still travels through approved plugin execution,
/// the production WebKit host and the actual MediaDetailView.
@MainActor
struct MetadataUITestFixtureView: View {
    private let owner = "https://fixture.invalid/metadata-ui.js"
    @State private var movieID = 550
    @State private var installationError = ""
    @ObservedObject private var manager = PluginManager.shared
    private let script = """
    window.__metadataUITestExecuted = true;
    iLampaMetadata.register('ui_fixture', function(media, emit) {
      if (window.__metadataUITestEmit) window.__metadataUITestOldEmit = window.__metadataUITestEmit;
      window.__metadataUITestEmit = emit;
      window.__metadataUITestMedia = media;
      emit({title:'Fixture metadata', state:'ready', fields:[{label:'Media identity', value:media.canonicalId}]});
    });
    """

    private var item: MediaItem {
        MediaItem(id: movieID, title: "Fixture movie \(movieID)", name: nil, originalTitle: nil,
                  originalName: nil, overview: nil, posterPath: nil, backdropPath: nil,
                  mediaType: "movie", releaseDate: nil, firstAirDate: nil, voteAverage: nil,
                  voteCount: nil, genreIds: nil)
    }

    var body: some View {
        NavigationStack {
            MediaDetailView(item: item, onPlayRequest: { _ in })
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                HStack {
                    Button("Switch movie") { movieID = movieID == 550 ? 551 : 550 }
                        .accessibilityIdentifier("metadataFixtureSwitch")
                    Button("Update") {
                        evaluate("window.__metadataUITestEmit && window.__metadataUITestEmit({title:'Updated fixture metadata',state:'ready',fields:[{label:'Media identity',value:window.__metadataUITestMedia.canonicalId}]})")
                    }.accessibilityIdentifier("metadataFixtureUpdate")
                    Button("Late update") {
                        evaluate("window.__metadataUITestOldEmit && window.__metadataUITestOldEmit({title:'Stale update',state:'ready',fields:[]})")
                    }.accessibilityIdentifier("metadataFixtureLate")
                    Button("Wrong movie") {
                        evaluate("""
                        (function(){var m=window.__metadataUITestMedia;if(!m)return;
                        window.webkit.messageHandlers.lampaMetadata.postMessage({generation:window.__ilampaGeneration,
                        documentToken:window.__ilampaDocumentToken,owner:'\(owner)',id:'ui_fixture',action:'update',
                        requestId:m.requestId,dispatchId:m.dispatchId,canonicalId:'urn:media:tmdb:movie:550',
                        title:'Wrong movie',state:'ready',fields:[]});})()
                        """)
                    }.accessibilityIdentifier("metadataFixtureWrongMovie")
                }
                HStack {
                    Button("Restart") { LampaHeadlessHost.shared.bootstrap() }
                        .accessibilityIdentifier("metadataFixtureRestart")
                    Button("Toggle plugin") {
                        if let record = manager.installedPlugins.first(where: { $0.urlString == owner }) { manager.toggle(plugin: record) }
                    }.accessibilityIdentifier("metadataFixtureToggle")
                    Button("Remove plugin") {
                        if let record = manager.installedPlugins.first(where: { $0.urlString == owner }) { manager.remove(plugin: record) }
                    }.accessibilityIdentifier("metadataFixtureRemove")
                }
            }.font(.caption2).padding(8).background(Color(UIColor.systemBackground))
        }
        .overlay(alignment: .top) {
            if !installationError.isEmpty { Text(installationError).accessibilityIdentifier("metadataFixtureError") }
        }
        .background { LampaHostContainerView().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false) }
        .onAppear {
            if let record = manager.installedPlugins.first(where: { $0.urlString == owner }) { manager.remove(plugin: record) }
            manager.installPreparedScript(script, url: owner, name: "Metadata UI fixture")
            guard let record = manager.installedPlugins.first(where: { $0.urlString == owner }),
                  let hash = manager.cachedScriptSHA256(for: owner),
                  manager.approveCachedScript(pluginID: record.id, expectedSHA256: hash) else {
                installationError = "Fixture installation or approval failed"
                return
            }
        }
    }

    private func evaluate(_ script: String) {
        LampaHeadlessHost.shared.webView?.evaluateJavaScript(script, completionHandler: nil)
    }
}
#endif
