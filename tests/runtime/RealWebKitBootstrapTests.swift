import Combine
import CryptoKit
import WebKit
import XCTest
@testable import iLampa

/// Exercises the bundled core and production host in a real WKWebView. The
/// fixture is evaluated only in memory; this does not install a plugin or
/// claim to verify external providers, persistence or playback.
@MainActor
final class RealWebKitBootstrapTests: XCTestCase {
    func testUnmodifiedHeadFilterLegacyRegistrationInRealWebKit() async throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://raw.githubusercontent.com/and7ey/lampa/master/head_filter.js"))
        let (bytes, response) = try await URLSession.shared.data(from: sourceURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash, "26b28f7d8c4c9dddef88ac701f13b4f736cce3075ba2aa98d73c9c7505fb7f99", "Upstream bytes changed; review before using this fixture")
        let source = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        let host = LampaHeadlessHost.shared
        let manager = PluginManager.shared
        let owner = "https://fixture.invalid/unmodified-head-filter-\(UUID().uuidString).js"
        defer {
            if let record = manager.installedPlugins.first(where: { $0.urlString == owner }) { manager.remove(plugin: record) }
        }
        let ready = expectation(description: "unmodified plugin settings registered")
        let sub = Publishers.CombineLatest(host.$isAppReady, host.$legacySettings)
            .filter { $0.0 && $0.1.contains { $0.owner == owner && $0.component == "head_filter" && $0.type == "trigger" } }
            .prefix(1).sink { _ in ready.fulfill() }
        defer { sub.cancel() }
        manager.installPreparedScript(source, url: owner, name: "Unmodified head filter")
        let record = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == owner }))
        let approval = try XCTUnwrap(manager.cachedScriptSHA256(for: owner))
        XCTAssertTrue(manager.approveCachedScript(pluginID: record.id, expectedSHA256: approval))
        await fulfillment(of: [ready], timeout: 90)
        let settings = host.legacySettings.filter { $0.owner == owner }
        XCTAssertEqual(settings.filter { $0.type == "trigger" }.count, 12)
        let search = try XCTUnwrap(settings.first { $0.type == "trigger" && $0.component == "head_filter" })
        try await host.changeLegacySetting(search, value: "false")
        let webView = try XCTUnwrap(host.webView)
        let stored = try await webView.evaluateJavaScript("Lampa.Storage.get('head_filter_show_search', true)") as? Bool
        XCTAssertEqual(stored, false)
        // Re-enable the same approved bytes and verify that the real legacy
        // setting is reconstructed from persistent WebKit storage.
        let active = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == owner }))
        manager.toggle(plugin: active)
        XCTAssertFalse(host.legacySettings.contains { $0.owner == owner })
        let restored = expectation(description: "unmodified plugin restored after re-enable")
        let restoredSub = Publishers.CombineLatest(host.$isAppReady, host.$legacySettings)
            .filter { $0.0 && $0.1.contains { $0.owner == owner && $0.component == "head_filter" && $0.type == "trigger" && $0.value == "false" } }
            .prefix(1).sink { _ in restored.fulfill() }
        defer { restoredSub.cancel() }
        let disabled = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == owner }))
        manager.toggle(plugin: disabled)
        await fulfillment(of: [restored], timeout: 90)
        let reenabled = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == owner }))
        manager.remove(plugin: reenabled)
        XCTAssertFalse(host.legacySettings.contains { $0.owner == owner })
    }

    func testLegacySettingsInRealWebKit() async throws {
        let host = LampaHeadlessHost.shared
        let manager = PluginManager.shared
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url = "https://fixture.invalid/settings-\(suffix).js"
        let key = "ilampa_fixture_\(suffix)"
        let script = """
        window.__legacyEvents = [];
        Lampa.Storage.listener.follow('change', function(e) {
          if(e.name === '\(key)') window.__legacyEvents.push('storage:' + e.value);
        });
        Lampa.SettingsApi.addComponent({component:'fixture_\(suffix)',name:'Fixture settings'});
        Lampa.SettingsApi.addParam({component:'fixture_\(suffix)',param:{name:'\(key)',type:'trigger',default:false},
          field:{name:'Fixture toggle'},onChange:function(v){window.__legacyEvents.push('callback:' + v); if(window.__legacyThrow) throw new Error('fixture callback failure');}});
        Lampa.SettingsApi.addParam({component:'fixture_\(suffix)',param:{name:'\(key)_select',type:'select',values:{a:'Option A',b:'Option B'},default:'a'},field:{name:'Fixture select'}});
        Lampa.SettingsApi.addParam({component:'fixture_\(suffix)',param:{type:'title'},field:{name:'Fixture heading'}});
        Lampa.SettingsApi.addParam({component:'fixture_\(suffix)',param:{name:'\(key)_input',type:'input',default:'initial'},field:{name:'Fixture input'},onChange:function(v){window.__legacyEvents.push('input:' + v + ':' + window.__ilampaExecutingPluginURL);}});
        """
        defer {
            if let record = manager.installedPlugins.first(where: { $0.urlString == url }) { manager.remove(plugin: record) }
        }
        let ready = expectation(description: "legacy registrations")
        let readySub = Publishers.CombineLatest(host.$isAppReady, host.$legacySettings)
            .filter { $0.0 && $0.1.filter { $0.owner == url }.count == 4 }.prefix(1).sink { _ in ready.fulfill() }
        defer { readySub.cancel() }
        manager.installPreparedScript(script, url: url, name: "Legacy settings fixture")
        let record = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        let hash = try XCTUnwrap(manager.cachedScriptSHA256(for: url))
        XCTAssertTrue(manager.approveCachedScript(pluginID: record.id, expectedSHA256: hash))
        await fulfillment(of: [ready], timeout: 90)
        let toggle = try XCTUnwrap(host.legacySettings.first { $0.owner == url && $0.type == "trigger" })
        try await host.changeLegacySetting(toggle, value: "true")
        let webView = try XCTUnwrap(host.webView)
        let events = try await webView.evaluateJavaScript("window.__legacyEvents.join(',')") as? String
        XCTAssertEqual(events, "storage:true,callback:true")
        try await host.changeLegacySetting(toggle, value: "false")
        let bothValues = try await webView.evaluateJavaScript("window.__legacyEvents.join(',')") as? String
        XCTAssertEqual(bothValues, "storage:true,callback:true,storage:false,callback:false")
        _ = try await webView.evaluateJavaScript("window.__legacyThrow = true")
        do {
            try await host.changeLegacySetting(toggle, value: "true")
            XCTFail("Throwing callback must report failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("fixture callback failure")) }
        XCTAssertEqual(host.legacySettings.first { $0.owner == url && $0.type == "trigger" }?.value, "true")
        _ = try await webView.evaluateJavaScript("window.__legacyThrow = false")
        let select = try XCTUnwrap(host.legacySettings.first { $0.owner == url && $0.type == "select" })
        XCTAssertEqual(select.options.map(\.value), ["a", "b"])
        try await host.changeLegacySetting(select, value: "b")
        let input = try XCTUnwrap(host.legacySettings.first { $0.owner == url && $0.type == "input" })
        try await host.changeLegacySetting(input, value: "changed")
        let inputEvents = try await webView.evaluateJavaScript("window.__legacyEvents.join(',')") as? String
        XCTAssertEqual(inputEvents, "storage:true,callback:true,storage:false,callback:false,storage:true,callback:true,input:changed:\(url)")
        XCTAssertTrue(host.legacySettings.contains { $0.owner == url && $0.type == "title" && $0.name == "Fixture heading" })
        let generation = host.currentGeneration
        let restarted = expectation(description: "settings restored")
        let restartSub = Publishers.CombineLatest(host.$isAppReady, host.$legacySettings)
            .filter { $0.0 && $0.1.contains { $0.owner == url && $0.generation > generation && $0.value == "true" } }
            .prefix(1).sink { _ in restarted.fulfill() }
        defer { restartSub.cancel() }
        host.bootstrap()
        await fulfillment(of: [restarted], timeout: 90)
        XCTAssertTrue(host.legacySettings.contains { $0.owner == url && $0.type == "select" && $0.value == "b" })
        XCTAssertTrue(host.legacySettings.contains { $0.owner == url && $0.type == "input" && $0.value == "changed" })
        do {
            try await host.changeLegacySetting(toggle, value: "false")
            XCTFail("Stale generation accepted")
        } catch { }
        let current = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        manager.toggle(plugin: current)
        XCTAssertFalse(host.legacySettings.contains { $0.owner == url })
        do {
            try await host.changeLegacySetting(toggle, value: "false")
            XCTFail("Disabled plugin accepted")
        } catch { }
        let enabled = expectation(description: "settings return after enabling trusted plugin")
        let enabledSub = Publishers.CombineLatest(host.$isAppReady, host.$legacySettings)
            .filter { $0.0 && $0.1.contains { $0.owner == url && $0.value == "true" } }.prefix(1).sink { _ in enabled.fulfill() }
        defer { enabledSub.cancel() }
        let disabled = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        manager.toggle(plugin: disabled)
        await fulfillment(of: [enabled], timeout: 90)
        let active = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        manager.remove(plugin: active)
        XCTAssertFalse(host.legacySettings.contains { $0.owner == url })
    }

    func testManagedMetadataProviderInRealWebKit() async throws {
        let host = LampaHeadlessHost.shared
        let manager = PluginManager.shared
        let url = "https://fixture.invalid/metadata-\(UUID().uuidString).js"
        let script = """
        window.__metadataFixtureExecuted = true;
        iLampaMetadata.register('fixture', function(media, emit) {
            window.__metadataFixtureMedia = media;
            window.__metadataFixtureEmit = emit;
            emit({title:'Fixture metadata', state:'ready', fields:[{label:'Media', value:media.canonicalId}]});
        });
        """
        defer {
            if let record = manager.installedPlugins.first(where: { $0.urlString == url }) { manager.remove(plugin: record) }
        }
        let ready = expectation(description: "fixture is running")
        let readySub = Publishers.CombineLatest(host.$isAppReady, host.$runningPlugins)
            .filter { $0.0 && $0.1.contains(url) }.prefix(1).sink { _ in ready.fulfill() }
        defer { readySub.cancel() }
        manager.installPreparedScript(script, url: url, name: "Metadata fixture")
        let staged = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        let hash = try XCTUnwrap(manager.cachedScriptSHA256(for: url))
        XCTAssertTrue(manager.approveCachedScript(pluginID: staged.id, expectedSHA256: hash))
        await fulfillment(of: [ready], timeout: 90)
        let webView = try XCTUnwrap(host.webView)
        let executed = try await webView.evaluateJavaScript("window.__metadataFixtureExecuted")
        XCTAssertEqual(executed as? Bool, true)
        func item(_ id: Int) throws -> MediaItem {
            try JSONDecoder().decode(MediaItem.self, from: Data("{\"id\":\(id),\"title\":\"Fixture\",\"media_type\":\"movie\"}".utf8))
        }
        let first = try item(550)
        let delivered = expectation(description: "first movie metadata delivered")
        let deliveredSub = host.$metadataSections.filter { $0.contains { $0.canonicalId == first.canonicalId && $0.fields.first?.value == first.canonicalId } }.prefix(1).sink { _ in delivered.fulfill() }
        defer { deliveredSub.cancel() }
        let firstRequest = host.beginMetadata(for: first)
        await fulfillment(of: [delivered], timeout: 10)
        _ = try await webView.evaluateJavaScript("window.__oldMetadataEmit = window.__metadataFixtureEmit; true;")
        let second = try item(551)
        let changed = expectation(description: "second movie metadata delivered")
        let changedSub = host.$metadataSections.filter { $0.contains { $0.canonicalId == second.canonicalId } }.prefix(1).sink { _ in changed.fulfill() }
        defer { changedSub.cancel() }
        let secondRequest = host.beginMetadata(for: second)
        await fulfillment(of: [changed], timeout: 10)
        let oldAccepted = try await webView.evaluateJavaScript("window.__oldMetadataEmit({title:'Stale',state:'ready',fields:[]})")
        XCTAssertEqual(oldAccepted as? Bool, false)
        let rejected = expectation(description: "cross-media message rejected")
        rejected.isInverted = true
        let rejectedSub = host.$metadataSections.filter { $0.contains { $0.title == "Wrong movie" } }.sink { _ in rejected.fulfill() }
        defer { rejectedSub.cancel() }
        let ownerData = try JSONEncoder().encode(url)
        let ownerLiteral = try XCTUnwrap(String(data: ownerData, encoding: .utf8))
        _ = try await webView.evaluateJavaScript("""
        window.webkit.messageHandlers.lampaMetadata.postMessage({generation:window.__ilampaGeneration,
          documentToken:window.__ilampaDocumentToken, action:'update', owner:\(ownerLiteral), id:'fixture',
          requestId:'\(secondRequest)', dispatchId:window.__metadataFixtureMedia.dispatchId,
          canonicalId:'\(first.canonicalId)', title:'Wrong movie', state:'ready', fields:[]}); true;
        """)
        _ = try await webView.evaluateJavaScript("""
        window.webkit.messageHandlers.lampaMetadata.postMessage({generation:window.__ilampaGeneration,
          documentToken:window.__ilampaDocumentToken, action:'update', owner:\(ownerLiteral), id:'fixture',
          requestId:'\(secondRequest)', dispatchId:'obsolete-dispatch',
          canonicalId:'\(second.canonicalId)', title:'Wrong movie', state:'ready', fields:[]}); true;
        """)
        await fulfillment(of: [rejected], timeout: 1)
        host.endMetadata(requestId: firstRequest)
        XCTAssertEqual(host.metadataSections.first?.canonicalId, second.canonicalId)
        let updated = expectation(description: "provider update")
        let updateSub = host.$metadataSections.filter { $0.first?.title == "Updated" }.prefix(1).sink { _ in updated.fulfill() }
        defer { updateSub.cancel() }
        _ = try await webView.evaluateJavaScript("window.__metadataFixtureEmit({title:'Updated',state:'ready',fields:[]})")
        await fulfillment(of: [updated], timeout: 10)
        let removed = expectation(description: "provider removal")
        let removeSub = host.$metadataSections.dropFirst().filter { $0.isEmpty }.prefix(1).sink { _ in removed.fulfill() }
        defer { removeSub.cancel() }
        _ = try await webView.evaluateJavaScript("window.__metadataFixtureEmit.remove()")
        await fulfillment(of: [removed], timeout: 10)
        let restored = expectation(description: "provider repopulated")
        let restoreSub = host.$metadataSections.filter { $0.first?.title == "Restored" }.prefix(1).sink { _ in restored.fulfill() }
        defer { restoreSub.cancel() }
        _ = try await webView.evaluateJavaScript("window.__metadataFixtureEmit({title:'Restored',state:'ready',fields:[]})")
        await fulfillment(of: [restored], timeout: 10)
        let generation = host.currentGeneration
        let tokenResult = try await webView.evaluateJavaScript("window.__ilampaDocumentToken")
        let oldToken = try XCTUnwrap(tokenResult as? String)
        host.bootstrap()
        XCTAssertTrue(host.metadataSections.isEmpty)
        let restarted = expectation(description: "metadata restored in new generation")
        let restartSub = host.$metadataSections.filter { $0.contains { $0.capability.owner == url && $0.capability.generation > generation } }.prefix(1).sink { _ in restarted.fulfill() }
        defer { restartSub.cancel() }
        await fulfillment(of: [restarted], timeout: 90)
        let obsolete = expectation(description: "obsolete document rejected")
        obsolete.isInverted = true
        let obsoleteSub = host.$metadataSections.filter { $0.contains { $0.title == "Old document" } }.sink { _ in obsolete.fulfill() }
        defer { obsoleteSub.cancel() }
        _ = try await webView.evaluateJavaScript("""
        (function(){var m=window.__metadataFixtureMedia;
        window.webkit.messageHandlers.lampaMetadata.postMessage({generation:\(generation), documentToken:'\(oldToken)',
          action:'update', owner:\(ownerLiteral), id:'fixture', requestId:m.requestId, dispatchId:m.dispatchId,
          canonicalId:m.canonicalId, title:'Old document', state:'ready', fields:[]});return true;})()
        """)
        await fulfillment(of: [obsolete], timeout: 1)
        let record = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        manager.toggle(plugin: record)
        XCTAssertTrue(host.metadataSections.isEmpty)
        let reenabled = expectation(description: "metadata returns after enable")
        let reenabledSub = host.$metadataSections.filter { $0.contains { $0.capability.owner == url } }.prefix(1).sink { _ in reenabled.fulfill() }
        defer { reenabledSub.cancel() }
        let disabled = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        manager.toggle(plugin: disabled)
        await fulfillment(of: [reenabled], timeout: 90)
        let active = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        manager.remove(plugin: active)
        XCTAssertFalse(host.metadataSections.contains { $0.capability.owner == url })
        host.endMetadata(requestId: secondRequest)
    }
    func testDelayedFolderRequestProvenanceInRealWebKit() async throws {
        let host = LampaHeadlessHost.shared
        let ready = expectation(description: "runtime ready for delayed folder fixture")
        let subscription = host.$isAppReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [ready], timeout: 75)
        let webView = try XCTUnwrap(host.webView)
        let owner = "https://fixture.invalid/online_mod.js"
        _ = try await webView.evaluateJavaScript("""
        (function() {
          var f = window.__asyncFolderFixture = {push:Lampa.Activity.push, active:Lampa.Activity.active,
            get:Lampa.Component.get, ajax:$.ajax, pending:[], folder:Lampa.Template.string('online_mod_folder'),
            media:Lampa.Template.string('online_mod')};
          f.container = document.createElement('div'); document.body.appendChild(f.container);
          Lampa.Template.add('online_mod_folder','<div class="online selector"><span class="online__title">{title}</span></div>');
          Lampa.Template.add('online_mod','<div class="online selector"><span class="online__title">{title}</span></div>');
          window.__ilampaExecutingPluginURL = '\(owner)';
          Lampa.Component.add('online_mod', function() {});
          window.__ilampaExecutingPluginURL = null;
          Lampa.Component.get = function(name) { return name === 'online_mod' ? function() {} : f.get.apply(this, arguments); };
          Lampa.Activity.active = function() { return f.current; };
          $.ajax = function(options) { f.pending.push(options); };
          function row(label, depth) {
            var item = Lampa.Template.get(depth ? 'online_mod_folder' : 'online_mod',
              {title:label, quality:depth ? '...' : '1080p', translate_voice:'Fixture voice'});
            if (depth) item.on('hover:enter', function() {
              $(f.container).empty();
              new Lampa.Reguest().native('https://fixture.invalid/delayed', function() {
                $(f.container).append(row(depth === 2 ? 'Nested' : 'Final', depth - 1));
              });
            });
            return item;
          }
          Lampa.Activity.push = function(params) { f.current = params; $(f.container).empty().append(row('Root', 2)); };
        })();
        """)
        defer {
            host.clearActiveMediaContext()
            webView.evaluateJavaScript("""
            (function() { var f = window.__asyncFolderFixture; if (!f) return;
              Lampa.Activity.push=f.push; Lampa.Activity.active=f.active; Lampa.Component.get=f.get; $.ajax=f.ajax;
              Lampa.Template.add('online_mod_folder',f.folder); Lampa.Template.add('online_mod',f.media);
              f.container.remove(); delete window.__asyncFolderFixture; })();
            """, completionHandler: nil)
            // Component registration belongs to this document; reconstruct to remove it.
            host.bootstrap()
        }
        let request = UUID()
        host.triggerMovieSearch(context: MediaResolutionContext(requestId: request, actionId: UUID(),
            canonicalId: "urn:media:tmdb:movie:550", title: "Fixture", mediaType: "movie", season: nil,
            episode: nil, balancer: nil, generation: host.currentGeneration, revision: 1))
        let roots = await host.waitForSources(requestId: request.uuidString)
        let root = try XCTUnwrap(roots.first)
        let start = try await webView.evaluateJavaScript("window.LampaNativeBridge.navigateHeadlessFolder(\(root.index), '\(request.uuidString)', '\(root.rowToken)', 'fixture-stage-1', '\(owner)')") as? [String: Any]
        XCTAssertEqual(start?["pending"] as? Bool, true)
        _ = try await webView.evaluateJavaScript("window.__asyncFolderFixture.pending.shift().success({ok:true})")
        let firstResult = try await webView.evaluateJavaScript("window.LampaNativeBridge.folderOperationSnapshot('fixture-stage-1')")
        let first = try XCTUnwrap(firstResult as? [String: Any])
        let nested = try XCTUnwrap((first["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(nested["isFolder"] as? Bool, true)
        let token = try XCTUnwrap(nested["rowToken"] as? String)
        let next = try await webView.evaluateJavaScript("window.LampaNativeBridge.navigateHeadlessFolder(0, '\(request.uuidString)', '\(token)', 'fixture-stage-2', '\(owner)')") as? [String: Any]
        XCTAssertEqual(next?["pending"] as? Bool, true)
        _ = try await webView.evaluateJavaScript("window.__asyncFolderFixture.pending.shift().success({ok:true})")
        let secondResult = try await webView.evaluateJavaScript("window.LampaNativeBridge.folderOperationSnapshot('fixture-stage-2')")
        let second = try XCTUnwrap(secondResult as? [String: Any])
        let final = try XCTUnwrap((second["sources"] as? [[String: Any]])?.first)
        XCTAssertEqual(final["voice"] as? String, "Fixture voice")
        XCTAssertEqual(final["isFolder"] as? Bool, false)
        _ = try await webView.evaluateJavaScript("window.LampaNativeBridge.cancelFolderOperation('fixture-stage-2')")
        let cancelled = try await webView.evaluateJavaScript("window.LampaNativeBridge.folderOperationSnapshot('fixture-stage-2')") as? [String: Any]
        XCTAssertEqual(cancelled?["error"] as? String, "operation-invalid")
    }

    func testFolderSnapshotsUseFreshRowsInProductionHost() async throws {
        let host = LampaHeadlessHost.shared
        let ready = expectation(description: "runtime ready for navigation fixture")
        let subscription = host.$isAppReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [ready], timeout: 75)
        let webView = try XCTUnwrap(host.webView)
        // Use the production bridge and host with a deterministic in-memory component.
        // No remote plugin or stream is installed or contacted.
        _ = try await webView.evaluateJavaScript("""
        (function() {
          window.__folderFixture = { push: Lampa.Activity.push, active: Lampa.Activity.active, get: Lampa.Component.get };
          var fixture = window.__folderFixture;
          fixture.container = document.createElement('div'); document.body.appendChild(fixture.container);
          function row(label, folder, next) {
            var el = $('<div class="online selector' + (folder ? ' online_folder' : '') + '"><span class="online__title"></span></div>');
            el.find('.online__title').text(label);
            el.on('hover:enter', function() { $(fixture.container).empty().append(next()); });
            return el;
          }
          Lampa.Component.get = function(name) { return name === 'online_mod' ? function() {} : fixture.get.apply(this, arguments); };
          Lampa.Activity.active = function() { return fixture.current; };
          Lampa.Activity.push = function(params) {
            fixture.current = params;
            $(fixture.container).empty().append(row('Root', true, function() {
              return row('Nested', true, function() { return row('Final', false, function() {}); });
            }));
          };
        })();
        """)
        defer {
            host.clearActiveMediaContext()
            webView.evaluateJavaScript("""
            (function() { var f = window.__folderFixture; if (!f) return;
              Lampa.Activity.push = f.push; Lampa.Activity.active = f.active; Lampa.Component.get = f.get;
              f.container.remove(); delete window.__folderFixture; })();
            """, completionHandler: nil)
        }
        let request = UUID()
        let context = MediaResolutionContext(requestId: request, actionId: UUID(), canonicalId: "urn:media:tmdb:movie:550",
            title: "Fixture", mediaType: "movie", season: nil, episode: nil, balancer: nil,
            generation: host.currentGeneration, revision: 1)
        host.triggerMovieSearch(context: context)
        let roots = await host.waitForSources(requestId: request.uuidString)
        let root = try XCTUnwrap(roots.first)
        XCTAssertTrue(root.isFolder)
        guard case .success(let children) = await host.navigateFolderSnapshot(index: root.index, searchId: request, rowToken: root.rowToken) else {
            return XCTFail("Root folder did not produce a verified snapshot")
        }
        let nested = try XCTUnwrap(children.first)
        XCTAssertTrue(nested.isFolder)
        guard case .success(let final) = await host.navigateFolderSnapshot(index: nested.index, searchId: request, rowToken: nested.rowToken) else {
            return XCTFail("Nested folder did not produce a verified snapshot")
        }
        XCTAssertEqual(final.first?.title, "Final")
        XCTAssertFalse(try XCTUnwrap(final.first).isFolder)
        host.clearActiveMediaContext()
        guard case .failure = await host.navigateFolderSnapshot(index: nested.index, searchId: request, rowToken: nested.rowToken) else {
            return XCTFail("Cancelled navigation must fail")
        }
    }

    func testManagedFixtureInstallsRegistersActivatesAndCleansUpInRealWebKit() async throws {
        let host = LampaHeadlessHost.shared
        let manager = PluginManager.shared
        let registry = PluginCapabilityRegistry.shared
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let url = "https://fixture.invalid/ilampa-\(nonce).js"
        let component = "ilampa_fixture_\(nonce)"
        let script = "Lampa.Component.add('\(component)', function() {});"
        let originalIDs = Set(manager.installedPlugins.map(\.id))
        defer {
            if let record = manager.installedPlugins.first(where: { $0.urlString == url }) {
                manager.remove(plugin: record)
            }
        }

        let activated = expectation(description: "fixture executed in current ready generation")
        let registered = expectation(description: "bridge attributed fixture component")
        let activeSubscription = Publishers.CombineLatest(host.$isAppReady, host.$runningPlugins)
            .filter { $0.0 && $0.1.contains(url) }.prefix(1).sink { _ in activated.fulfill() }
        let registrySubscription = registry.$registeredSources
            .filter { $0.contains(where: { $0.pluginUrl == url && $0.name == component }) }
            .prefix(1).sink { _ in registered.fulfill() }
        defer { activeSubscription.cancel(); registrySubscription.cancel() }

        manager.installPreparedScript(script, url: url, name: "Isolated WebKit fixture")
        let record = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        let scriptURL = manager.scriptURL(for: url)
        XCTAssertEqual(try String(contentsOf: scriptURL, encoding: .utf8), script)
        let approvedHash = try XCTUnwrap(manager.cachedScriptSHA256(for: url))
        XCTAssertTrue(manager.approveCachedScript(pluginID: record.id, expectedSHA256: approvedHash))
        await fulfillment(of: [activated, registered], timeout: 90)
        let active = try XCTUnwrap(manager.installedPlugins.first(where: { $0.id == record.id }))
        XCTAssertEqual(active.lifecycleState, .active)
        XCTAssertTrue(active.registeredComponents.contains(component))
        let webView = try XCTUnwrap(host.webView)
        let exists = try await webView.evaluateJavaScript("typeof Lampa.Component.get('\(component)') === 'function'")
        XCTAssertEqual(exists as? Bool, true)

        let cleaned = expectation(description: "fixture removed from new runtime generation")
        let cleanupSubscription = Publishers.CombineLatest(host.$isAppReady, host.$runningPlugins)
            .filter { $0.0 && !$0.1.contains(url) }.prefix(1).sink { _ in cleaned.fulfill() }
        defer { cleanupSubscription.cancel() }
        manager.remove(plugin: active)
        XCTAssertEqual(Set(manager.installedPlugins.map(\.id)), originalIDs)
        XCTAssertFalse(registry.registeredSources.contains(where: { $0.pluginUrl == url }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptURL.path))
        await fulfillment(of: [cleaned], timeout: 90)
        let removed = try await webView.evaluateJavaScript("typeof Lampa.Component.get('\(component)') === 'function'")
        XCTAssertEqual(removed as? Bool, false)
    }

    func testBundledCoreBootstrapsAndEvaluatesBundledPluginFixture() async throws {
        let host = LampaHeadlessHost.shared
        let ready = expectation(description: "bundled runtime ready")
        let subscription = host.$isAppReady.filter { $0 }.prefix(1).sink { _ in ready.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [ready], timeout: 75)
        guard host.isAppReady else { return }

        let webView = try XCTUnwrap(host.webView)
        let bundle = Bundle.main
        let scriptURL = try XCTUnwrap(bundle.url(forResource: "sample_source_plugin", withExtension: "js", subdirectory: "plugins")
                                      ?? bundle.url(forResource: "sample_source_plugin", withExtension: "js"))
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let manager = PluginManager.shared
        let url = "https://fixture.invalid/bundled-sample-\(UUID().uuidString).js"
        defer {
            if let record = manager.installedPlugins.first(where: { $0.urlString == url }) { manager.remove(plugin: record) }
        }
        let activated = expectation(description: "approved bundled fixture executed")
        let activeSubscription = Publishers.CombineLatest(host.$isAppReady, host.$runningPlugins)
            .filter { $0.0 && $0.1.contains(url) }.prefix(1).sink { _ in activated.fulfill() }
        defer { activeSubscription.cancel() }
        manager.installPreparedScript(script, url: url, name: "Bundled fixture")
        let record = try XCTUnwrap(manager.installedPlugins.first(where: { $0.urlString == url }))
        let hash = try XCTUnwrap(manager.cachedScriptSHA256(for: url))
        XCTAssertTrue(manager.approveCachedScript(pluginID: record.id, expectedSHA256: hash))
        await fulfillment(of: [activated], timeout: 90)
        let result = try await webView.evaluateJavaScript("typeof Lampa.Component.get('sample_source') === 'function'")
        XCTAssertEqual(result as? Bool, true)

        // Registration is not functionality. Instantiate the actual shipped
        // component in the *real* selected core, ask it to build UI, and
        // require actionable source rows rather than just a function symbol.
        let rendered = try await webView.evaluateJavaScript("""
        (function() {
          var C = Lampa.Component.get('sample_source');
          var instance = new C({
            title: 'Reference film', mediaType: 'movie', source: 'tmdb',
            movie: { id: 550, title: 'Reference film', source: 'tmdb', media_type: 'movie' }
          });
          var ui = instance.create();
          var count = ui && ui.find ? ui.find('.sample-source-list .selector').length : 0;
          if (instance.destroy) instance.destroy();
          return count;
        })();
        """) as? Int
        XCTAssertEqual(rendered, 3,
            "A registered Lampa plugin must actually construct its source rows in WebKit")
    }
}
