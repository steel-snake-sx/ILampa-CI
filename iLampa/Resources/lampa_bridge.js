/**
 * iLampa Native iOS Bridge & Diagnostics Engine
 * Provides bridge communication, full-screen viewport layout enforcement,
 * runtime error capture, Safe Area handling, and native AVPlayer stream routing.
 */
(function () {
    'use strict';

    // Captured once per document. Never relabel callbacks with a later host generation.
    var generation = window.__ilampaGeneration;
    var documentToken = window.__ilampaDocumentToken;
    if (window.LampaNativeBridge && window.LampaNativeBridge.generation === generation &&
        window.LampaNativeBridge.documentToken === documentToken) return;
    var presented = false;
    var trustedDispatch = null;
    var pendingSelection = null;
    var resolverScope = null;
    var sequence = 0;
    var onlineModRows = typeof WeakMap === 'function' ? new WeakMap() : null;
    var discoveryRows = typeof WeakMap === 'function' ? new WeakMap() : null;
    var discoverySequence = 0;
    var activeSearchContext = null;
    var searchScope = null;
    var lastSnapshotSignature = '';
    var componentOwners = Object.create(null);
    var folderScope = null;
    var folderOperation = null;
    var folderRows = typeof WeakMap === 'function' ? new WeakMap() : null;
    var nativeAction = null;
    // Playlist callbacks belong to this exact document and selected playback session.
    // Only serializable item descriptors cross into Swift.
    var activePlaylistSession = null;
    function isStreamUrl(url) {
        return typeof url === 'string' && /^https?:\/\//i.test(url) &&
            !/sylvan\.apple\.com|orangejedi\/aerial|\/videos\/aerial/i.test(url);
    }
    function playlistDescriptors(items, requestId) {
        if (!Array.isArray(items)) return [];
        return items.map(function (entry, index) {
            if (!entry || (!isStreamUrl(entry.url) && typeof entry.url !== 'function')) return null;
            return {
                index: index,
                itemId: requestId + ':' + index,
                deferred: typeof entry.url === 'function',
                url: isStreamUrl(entry.url) ? entry.url : '',
                seasonNumber: entry.season == null ? null : entry.season,
                episodeNumber: entry.episode == null ? index + 1 : entry.episode,
                title: entry.title || ('Серия ' + (index + 1)),
                duration: entry.duration || null,
                timecode: entry.time || null
            };
        }).filter(Boolean);
    }
    function observeLatePlaylist(player) {
        if (!player || typeof player.playlist !== 'function' || player.__ilampaPlaylistObserved) return;
        var original = player.playlist;
        player.playlist = function (entries) {
            var result = original.apply(this, arguments);
            var session = activePlaylistSession;
            if (!session || !Array.isArray(entries) ||
                window.__ilampaGeneration !== generation || window.__ilampaDocumentToken !== documentToken ||
                (resolverScope && resolverScope.intent && resolverScope.intent.requestId !== session.id)) return result;
            var identity = activityIdentity();
            if (identity && (identity.canonicalId !== session.canonicalId ||
                identity.mediaType !== session.mediaType)) return result;
            session.items = entries.slice();
            post('lampaPlaylist', {
                requestId: session.id,
                playlistId: session.id,
                playlist: playlistDescriptors(session.items, session.id)
            });
            return result;
        };
        player.__ilampaPlaylistObserved = true;
    }
    function resolvePlaylistItem(requestId, itemId) {
        var session = activePlaylistSession;
        if (!session || session.id !== requestId || typeof itemId !== 'string' ||
            window.__ilampaGeneration !== generation || window.__ilampaDocumentToken !== documentToken)
            return Promise.resolve({ success: false, error: 'stale-session' });
        var index = Number(itemId.slice(requestId.length + 1));
        if (itemId !== requestId + ':' + index || !Number.isInteger(index) || index < 0 ||
            index >= session.items.length)
            return Promise.resolve({ success: false, error: 'invalid-playlist-item' });
        var entry = session.items[index];
        if (!entry) return Promise.resolve({ success: false, error: 'missing-playlist-item' });
        if (isStreamUrl(entry.url)) return Promise.resolve({ success: true, url: entry.url });
        if (typeof entry.url !== 'function')
            return Promise.resolve({ success: false, error: 'invalid-stream' });
        return new Promise(function (resolve) {
            var settled = false;
            var timer = setTimeout(function () { finish(null, 'resolver-timeout'); }, 12000);
            function finish(value, reason) {
                if (settled) return;
                settled = true;
                if (typeof clearTimeout === 'function') clearTimeout(timer);
                if (activePlaylistSession !== session || window.__ilampaGeneration !== generation ||
                    window.__ilampaDocumentToken !== documentToken)
                    return resolve({ success: false, error: 'stale-session' });
                var url = typeof value === 'string' ? value :
                    value && typeof value.url === 'string' ? value.url : entry.url;
                resolve(isStreamUrl(url) ? { success: true, url: url } :
                    { success: false, error: reason || 'deferred-url-unavailable' });
            }
            try {
                var outcome = entry.url(function (value) { finish(value); });
                if (outcome && typeof outcome.then === 'function')
                    outcome.then(function (value) { if (value) finish(value); },
                        function () { finish(null, 'resolver-error'); });
            } catch (error) { finish(null, 'resolver-error'); }
        });
    }
    var nativePrompt = typeof window.prompt === 'function' ? window.prompt.bind(window) : null;
    function executeNativeAction(ticket, action) {
        if (!ticket || ticket.generation !== generation || ticket.documentToken !== documentToken ||
            window.__ilampaGeneration !== generation || window.__ilampaDocumentToken !== documentToken ||
            !nativePrompt || nativeAction) return { success: false, error: 'stale runtime' };
        // Synchronous native rendezvous. No promise, timer or second WebKit call
        // separates the eligibility decision from this synchronous JS transaction.
        if (nativePrompt('__ilampa_execute_v1__', JSON.stringify(ticket)) !== ticket.id)
            return { success: false, error: 'execution revoked' };
        nativeAction = ticket;
        try { return action(); }
        finally { nativeAction = null; }
    }

    // Entries and callbacks never leave this document. Native receives only descriptors.
    var legacySettings = [];
    var legacyComponents = Object.create(null);
    var legacySequence = 0;
    var legacyRevision = 0;
    function legacyOwner() {
        return typeof window.__ilampaExecutingPluginURL === 'string' ? window.__ilampaExecutingPluginURL : '';
    }
    function legacyDescriptor(entry) {
        var data = entry.data, param = data.param || {}, field = data.field || {};
        var type = param.type;
        if (['trigger', 'select', 'input', 'title'].indexOf(type) < 0 ||
            typeof field.name !== 'string' || !field.name ||
            (type !== 'title' && (typeof param.name !== 'string' || !param.name))) return null;
        var options = [];
        if (type === 'select') {
            if (!param.values || typeof param.values !== 'object') return null;
            Object.keys(param.values).forEach(function (key) {
                var label = param.values[key];
                if (typeof label === 'string' || typeof label === 'number') {
                    options.push({ value: key, label: String(Lampa.Lang.translate(String(label))) });
                }
            });
            if (!options.length) return null;
        }
        var value = type === 'title' ? '' : String(Lampa.Storage.field(param.name));
        var component = legacyComponents[entry.owner + '\n' + data.component];
        return { id: entry.id, owner: entry.owner, generation: generation, component: String(data.component),
            componentName: component || String(data.component), type: type, name: field.name,
            description: typeof field.description === 'string' ? field.description : '',
            defaultValue: param.default == null ? '' : String(param.default),
            placeholder: typeof param.placeholder === 'string' ? param.placeholder : '',
            value: value, options: options, onRender: typeof data.onRender === 'function' };
    }
    function legacySnapshot(owner) {
        return legacySettings.filter(function (entry) { return entry.owner === owner; })
            .map(legacyDescriptor).filter(Boolean);
    }
    function publishLegacy(owner) {
        try { if (owner) post('lampaSettings', { owner: owner, revision: ++legacyRevision, settings: legacySnapshot(owner) }); }
        catch (error) { /* A native observer must not break upstream registration or storage. */ }
    }
    function attachLegacySettingsHook() {
        function bind() {
            if (typeof Lampa === 'undefined' || !Lampa.SettingsApi || !Lampa.Storage || !Lampa.Lang) return false;
            var api = Lampa.SettingsApi;
            if (api.__ilampaSettingsBound) return true;
            ['addComponent', 'addParam', 'removeComponent', 'removeParams'].forEach(function (method) {
                var original = api[method];
                if (typeof original !== 'function') return;
                api[method] = function (data) {
                    var owner = legacyOwner();
                    var result = original.apply(this, arguments);
                    if (method === 'addComponent' && owner && data && typeof data.component === 'string') {
                        legacyComponents[owner + '\n' + data.component] = typeof data.name === 'string' ? data.name : data.component;
                        publishLegacy(owner);
                    } else if (method === 'addParam' && owner && data && typeof data.component === 'string') {
                        legacySettings.push({ owner: owner, id: String(++legacySequence), data: data });
                        publishLegacy(owner);
                    } else if ((method === 'removeComponent' || method === 'removeParams') && typeof data === 'string') {
                        var affected = Object.create(null);
                        legacySettings = legacySettings.filter(function (entry) {
                            if (entry.data.component !== data) return true;
                            affected[entry.owner] = true; return false;
                        });
                        Object.keys(affected).forEach(publishLegacy);
                    }
                    return result;
                };
            });
            api.__ilampaSettingsBound = true;
            if (Lampa.Storage.listener && typeof Lampa.Storage.listener.follow === 'function') {
                Lampa.Storage.listener.follow('change', function (event) {
                    var owners = Object.create(null);
                    legacySettings.forEach(function (entry) {
                        if (entry.data.param && entry.data.param.name === event.name) owners[entry.owner] = true;
                    });
                    Object.keys(owners).forEach(publishLegacy);
                });
            }
            return true;
        }
        if (bind()) return true;
        var check = setInterval(function () { if (bind()) clearInterval(check); }, 50);
        return false;
    }
    function changeLegacySetting(owner, id, value, expectedGeneration, expectedToken) {
        if (window.__ilampaNativeManaged === true && !nativeAction)
            return { success: false, error: 'native execution ticket required' };
        if (generation !== expectedGeneration || documentToken !== expectedToken ||
            window.__ilampaGeneration !== generation || window.__ilampaDocumentToken !== documentToken)
            return { success: false, error: 'stale runtime' };
        var entry = legacySettings.find(function (item) { return item.owner === owner && item.id === id; });
        if (!entry) return { success: false, error: 'setting unavailable' };
        var descriptor = legacyDescriptor(entry), param = entry.data.param;
        if (!descriptor || ['trigger', 'select', 'input'].indexOf(descriptor.type) < 0 || typeof value !== 'string' ||
            (descriptor.type === 'trigger' && value !== 'true' && value !== 'false') ||
            (descriptor.type === 'select' && !descriptor.options.some(function (option) { return option.value === value; })))
            return { success: false, error: 'invalid setting value' };
        var previous = window.__ilampaExecutingPluginURL;
        window.__ilampaExecutingPluginURL = owner;
        try {
            var storageError = null;
            Lampa.Storage.set(param.name, value, false, function (error) { storageError = error; });
            if (storageError || window.localStorage.getItem(param.name) !== value)
                return { success: false, error: 'storage write failed', revision: ++legacyRevision, settings: legacySnapshot(owner) };
            var onChange = entry.data.onChange;
            if (typeof onChange === 'function') onChange(value);
            return { success: true, revision: ++legacyRevision, settings: legacySnapshot(owner) };
        } catch (error) {
            return { success: false, error: String(error && error.message || error), revision: ++legacyRevision, settings: legacySnapshot(owner) };
        } finally { window.__ilampaExecutingPluginURL = previous; }
    }

    function validFolderOperation(op) {
        if (!op || folderOperation !== op || activeSearchContext !== op.root) return false;
        var identity = activityIdentity();
        var active = typeof Lampa !== 'undefined' && Lampa.Activity.active();
        return !!identity && !!active && String(identity.id) === String(op.root.id) &&
            identity.canonicalId === op.root.canonicalId && identity.mediaType === op.root.mediaType &&
            identity.season === op.root.season && identity.episode === op.root.episode &&
            (!active.search || active.search === op.root.title) &&
            active.component === 'online_mod' && componentOwners.online_mod === op.owner;
    }

    function post(name, body) {
        if (typeof generation !== 'number' || !isFinite(generation) || Math.floor(generation) !== generation ||
            typeof documentToken !== 'string' || !documentToken) return false;
        var handlers = window.webkit && window.webkit.messageHandlers;
        if (!handlers || !handlers[name]) return false;
        var envelope = Object.assign({}, body, { generation: generation, documentToken: documentToken });
        try { handlers[name].postMessage(envelope); return true; } catch (e) { return false; }
    }

    // Explicit semantic providers only. Ownership is captured during the host's
    // approved synchronous plugin evaluation, never inferred from the DOM.
    var metadataProviders = Object.create(null);
    var metadataRequest = null;
    window.iLampaMetadata = Object.freeze({
        register: function (id, provider) {
            var owner = window.__ilampaExecutingPluginURL;
            if (typeof owner !== 'string' || !owner || typeof id !== 'string' ||
                !/^[a-zA-Z0-9_.-]{1,80}$/.test(id) || typeof provider !== 'function') return false;
            var key = owner + '\n' + id;
            if (metadataProviders[key]) return false;
            metadataProviders[key] = provider;
            post('lampaMetadata', { action: 'register', owner: owner, id: id, type: 'mediaDetail' });
            return true;
        }
    });

    function requestMetadata(request, allowed) {
        metadataRequest = request;
        allowed.forEach(function (entry) {
            var provider = metadataProviders[entry.owner + '\n' + entry.id];
            if (!provider) return;
            function emit(data) {
                if (metadataRequest !== request || !data || typeof data !== 'object') return false;
                return post('lampaMetadata', { action: 'update', owner: entry.owner, id: entry.id,
                    requestId: request.requestId, canonicalId: request.canonicalId,
                    dispatchId: request.dispatchId,
                    title: data.title, state: data.state, fields: data.fields || [] });
            }
            emit.remove = function () {
                if (metadataRequest !== request) return false;
                return post('lampaMetadata', { action: 'remove', owner: entry.owner, id: entry.id,
                    requestId: request.requestId, canonicalId: request.canonicalId, dispatchId: request.dispatchId });
            };
            try { provider(Object.freeze(Object.assign({}, request)), emit); }
            catch (e) { emit({ title: entry.id, state: 'error', fields: [] }); }
        });
    }

    function snapshot(value) {
        return value == null ? null : JSON.parse(JSON.stringify(value));
    }

    function invalidateSelection() {
        pendingSelection = null;
        trustedDispatch = null;
    }

    function eligibleDispatch(selector) {
        return presented && !document.hidden && window.appready === true && trustedDispatch &&
            trustedDispatch.event.eventPhase !== 0 &&
            trustedDispatch.target && trustedDispatch.target.closest && trustedDispatch.target.closest(selector);
    }

    function activityIdentity() {
        var active = typeof Lampa !== 'undefined' && Lampa.Activity && Lampa.Activity.active && Lampa.Activity.active();
        var movie = active && (active.movie || active.card);
        if (!movie || !movie.id) return null;
        if ((active.source || movie.source) && (active.source || movie.source) !== 'tmdb') return null;
        var mediaType = active.mediaType || movie.mediaType || movie.media_type;
        if (active.mediaType && movie.media_type && active.mediaType !== movie.media_type) return null;
        if (!mediaType) mediaType = movie.first_air_date ? 'tv' : movie.release_date ? 'movie' : null;
        if (mediaType !== 'movie' && mediaType !== 'tv') return null;
        return {
            id: movie.id,
            canonicalId: active.canonicalId || movie.canonicalId || 'urn:media:tmdb:' + mediaType + ':' + movie.id,
            mediaType: mediaType,
            season: active.season == null ? null : active.season,
            episode: active.episode == null ? null : active.episode
        };
    }

    function selectedOnlineModRow(target) {
        if (!onlineModRows || !target) return null;
        var row = target.closest && target.closest('.online.selector');
        return row && onlineModRows.get(row) || null;
    }

    // The bundled plugin's online_mod_folder template renders only
    // "online selector"; it does not add an online_folder CSS class.
    function isOnlineFolder(target) {
        var data = selectedOnlineModRow(target);
        // Filmix uses .online-prestige--folder.selector rather than
        // Online Mod's .online_folder. Check the actual selected row even
        // when the trusted click happened on a nested image or title.
        var row = target && target.closest && target.closest('.selector');
        return !!(data && data.isFolder) || !!(row && row.classList &&
            (row.classList.contains('online_folder') ||
             row.classList.contains('online-prestige--folder')));
    }

    function beginSelection(identity, pluginId, selectionContext) {
        if (!identity || !presented || !trustedDispatch || document.hidden || window.appready !== true) return null;
        if (trustedDispatch.intent) return trustedDispatch.intent;
        var intent = Object.freeze(Object.assign({}, identity, {
            requestId: documentToken + ':' + (++sequence),
            pluginId: pluginId,
            selectionContext: selectionContext,
            translateVoice: trustedDispatch.translateVoice || null,
            expiresAt: Date.now() + 30000
        }));
        trustedDispatch.intent = intent;
        pendingSelection = intent;
        if (!post('lampaSelection', {
            requestId: intent.requestId, canonicalId: intent.canonicalId, mediaType: intent.mediaType,
            pluginId: intent.pluginId, selectionContext: intent.selectionContext,
            season: intent.season == null ? null : intent.season,
            episode: intent.episode == null ? null : intent.episode,
            audio: intent.translateVoice
        })) { pendingSelection = null; return null; }
        return intent;
    }

    function capturePlayerSelection(data) {
        // Preserve the original Online Mod attribution rules. Other plugin
        // components may render their own .selector rows instead of .online.
        // Only a real gesture inside the selected row can authorize playback.
        if (resolverScope) return resolverScope.intent;
        var row = eligibleDispatch('.selector');
        if (!row || isOnlineFolder(row)) return null;
        var identity = activityIdentity();
        var active = typeof Lampa !== 'undefined' && Lampa.Activity.active();
        var rowData = selectedOnlineModRow(trustedDispatch.target);
        if (identity && identity.mediaType === 'tv') {
            if (rowData && rowData.hasEpisode) {
                identity.season = rowData.season;
                identity.episode = rowData.episode;
            } else if (data && Number.isInteger(data.season) && Number.isInteger(data.episode) &&
                       data.season > 0 && data.episode > 0) {
                // Generic providers may supply exact episode data directly in
                // Player.create; never infer it from the card's default episode.
                identity.season = data.season;
                identity.episode = data.episode;
            } else if (active && active.component !== 'online_mod' && active.component !== 'online') {
                // Third-party source components such as Filmix call
                // Player.play({title,url,timeline,callback}) without episode
                // identity. A genuinely tapped media row may play, but we
                // explicitly erase the native card's default episode so it
                // is never mistaken for the user's selected episode.
                identity.season = null;
                identity.episode = null;
            } else return null;
        }
        if (rowData && rowData.translateVoice) trustedDispatch.translateVoice = rowData.translateVoice;
        return beginSelection(identity, active && active.component || 'lampa_player', 'lampa_player_create');
    }

    function routeSelectedPlayback(payload, intent) {
        if (!intent || pendingSelection !== intent) return false;
        var isHeadlessAllowed = intent.selectionContext === 'headless_native_bridge';
        if (!isHeadlessAllowed && (!presented || document.hidden)) return false;
        if (window.appready !== true || Date.now() > intent.expiresAt) return false;
        if (intent.mediaType === 'movie' || intent.mediaType === 'tv') {
            var current = activityIdentity();
            if (current && intent.id && (String(current.id) !== String(intent.id) ||
                current.canonicalId !== intent.canonicalId || current.mediaType !== intent.mediaType)) return false;
        }
        if (activeSearchContext && intent.selectionContext === 'headless_native_bridge') {
            if (intent.canonicalId && intent.canonicalId !== activeSearchContext.canonicalId) return false;
            if (intent.selectionContext === 'headless_native_bridge' && activeSearchContext.mediaType === 'tv') {
                if (intent.season != null && activeSearchContext.season != null && intent.season !== activeSearchContext.season) return false;
                if (intent.episode != null && activeSearchContext.episode != null && intent.episode !== activeSearchContext.episode) return false;
            }
        }
        if (!payload || typeof payload.url !== 'string' || !/^https?:\/\//i.test(payload.url) ||
            /sylvan\.apple\.com|orangejedi\/aerial|\/videos\/aerial/i.test(payload.url)) return false;
        // Consume before posting; even duplicate resolver callbacks cannot replay this intent.
        pendingSelection = null;
        return post('lampaNative', Object.assign({}, payload, {
            action: 'play', isDiagnostic: false,
            requestId: intent.requestId, canonicalId: intent.canonicalId, mediaType: intent.mediaType,
            pluginId: intent.pluginId, selectionContext: intent.selectionContext,
            season: payload.season == null ? (intent.season == null ? null : intent.season) : payload.season,
            episode: payload.episode == null ? (intent.episode == null ? null : intent.episode) : payload.episode
        }));
    }

    window.LampaNativeBridge = {
        executeNativeAction: executeNativeAction,
        resolvePlaylistItem: resolvePlaylistItem,
        changeLegacySetting: changeLegacySetting,
        attachLegacySettingsHook: attachLegacySettingsHook,
        requestMetadata: requestMetadata,
        clearMetadata: function (requestId) {
            if (metadataRequest && metadataRequest.requestId === requestId) metadataRequest = null;
        },
        generation: generation,
        documentToken: documentToken,
        activeItem: null,
        heartbeatTicks: 0,
        isAppReadyReported: false,

        init: function () {
            this.setupDiagnostics();
            this.injectMobileStyles();
            this.reportLayoutMetrics();
            this.disableScreensaver();
            this.attachRequestHook();
            this.attachOnlineModTemplateHook();
            this.attachPlayerHook();
            this.attachSomaFMAdapter();
            this.attachAppReadyHook();
            this.startSchedulingHeartbeat();
            this.attachComponentHook();
            this.attachLegacySettingsHook();
            this.attachSourceDiscoveryHook();
            this.attachTrustedSelectionHook();

            // Observe window resize/orientation changes and update metrics
            window.addEventListener('resize', function () {
                window.LampaNativeBridge.reportLayoutMetrics();
            });
        },

        attachRequestHook: function () {
            // Original Reguest.native/silent signatures are (url, success, error, data, options).
            // Wrap only Lampa's request objects, not global promises/timers/HTML media APIs.
            function bind() {
                if (typeof Lampa === 'undefined' || typeof Lampa.Reguest !== 'function') return false;
                var Original = Lampa.Reguest;
                if (Original.__ilampaSelectionBound) return true;
                function AttributedRequest() {
                    var request = Reflect.construct(Original, Array.prototype.slice.call(arguments));
                    var requestSearch = searchScope;
                    ['native', 'silent'].forEach(function (name) {
                        var original = request[name];
                        if (typeof original !== 'function') return;
                        request[name] = function () {
                            var args = Array.prototype.slice.call(arguments);
                            var scope = { intent: capturePlayerSelection() };
                            // Root search callbacks have no playback intent, but still own
                            // their DOM effects. Never relabel an old root's rows at observer time.
                            var search = searchScope || requestSearch;
                            var operation = folderScope;
                            if (operation) operation.requests++;
                            [1, 2].forEach(function (index) {
                                var callback = args[index];
                                if (typeof callback !== 'function') return;
                                args[index] = function () {
                                    // Suppress superseded provider completions before they can
                                    // reset or append to the new stage's shared DOM.
                                    if (search && activeSearchContext !== search) return;
                                    if (operation && !validFolderOperation(operation)) return;
                                    var previous = resolverScope;
                                    var previousFolder = folderScope;
                                    var previousSearch = searchScope;
                                    resolverScope = scope;
                                    folderScope = operation;
                                    searchScope = search;
                                    try { return callback.apply(this, arguments); }
                                    finally {
                                        if (operation) operation.callbacks++;
                                        folderScope = previousFolder;
                                        searchScope = previousSearch;
                                        resolverScope = previous;
                                    }
                                };
                            });
                            return original.apply(this, args);
                        };
                    });
                    return request;
                }
                AttributedRequest.prototype = Original.prototype;
                Object.setPrototypeOf(AttributedRequest, Original);
                AttributedRequest.__ilampaSelectionBound = true;
                Lampa.Reguest = AttributedRequest;
                return true;
            }
            if (bind()) return;
            var check = setInterval(function () { if (bind()) clearInterval(check); }, 50);
        },

        attachOnlineModTemplateHook: function () {
            if (!onlineModRows) return;
            function bind() {
                if (typeof Lampa === 'undefined' || !Lampa.Template || typeof Lampa.Template.get !== 'function') return false;
                var template = Lampa.Template;
                var original = template.get;
                if (original.__ilampaOnlineModBound) return true;
                function get(name, data) {
                    var result = original.apply(this, arguments);
                    if ((name === 'online_mod' || name === 'online_mod_folder') && data && result) {
                        var row = result.nodeType ? result : result[0] || (result.closest ? result : null);
                        if (row && typeof row === 'object') {
                            if (folderScope && folderRows && validFolderOperation(folderScope)) folderRows.set(row, folderScope);
                            if (name === 'online_mod_folder') {
                                // The bundled component creates "show more" with this
                                // marker; all other similars are unverified provider titles.
                                onlineModRows.set(row, { isFolder: true,
                                    pagination: data.quality === '...' && !data.id && !data.link && !data.kp_id && !data.imdb_id });
                                return result;
                            }
                            var season = Number(data.season);
                            var episode = Number(data.episode);
                            var hasEpisode = data.season != null && data.episode != null &&
                                Number.isInteger(season) && season >= 0 && Number.isInteger(episode) && episode > 0;
                            // CDNVideoHub puts the actual voice in the underlying media,
                            // while other Online Mod adapters may expose translate_voice.
                            // Do not infer a voice from the balancer or the row title.
                            var media = data.media && typeof data.media === 'object' ? data.media : null;
                            var voice = typeof data.translate_voice === 'string' && data.translate_voice.trim() ? data.translate_voice :
                                media && typeof media.voiceStudio === 'string' && media.voiceStudio.trim() ? media.voiceStudio :
                                media && typeof media.voiceType === 'string' && media.voiceType.trim() ? media.voiceType :
                                media && typeof media.translation_name === 'string' && media.translation_name.trim() ? media.translation_name :
                                media && typeof media.voice_name === 'string' && media.voice_name.trim() ? media.voice_name : null;
                            onlineModRows.set(row, {
                                hasEpisode: hasEpisode,
                                season: hasEpisode ? season : null,
                                episode: hasEpisode ? episode : null,
                                translateVoice: voice ? voice.trim().slice(0, 200) : null
                            });
                        }
                    }
                    return result;
                }
                get.__ilampaOnlineModBound = true;
                template.get = get;
                return true;
            }
            if (bind()) return;
            var check = setInterval(function () { if (bind()) clearInterval(check); }, 50);
        },

        setPresentation: function (visible) {
            presented = visible === true;
            if (!presented) {
                invalidateSelection();
                this.activeItem = null;
            }
            return { success: true };
        },

        attachTrustedSelectionHook: function () {
            function capture(event) {
                if (!event || event.isTrusted !== true) return;
                invalidateSelection();
                if (!presented || document.hidden || window.appready !== true) return;
                if (event.type === 'keydown' && event.key !== 'Enter') return;
                var target = event.target;
                if (event.type === 'keydown' && (!target || !target.closest || !target.closest('.selector'))) {
                    target = document.querySelector('.selector.focus');
                }
                // eventPhase becomes NONE (0) when real dispatch ends. Do not clear in a microtask:
                // browsers may run a microtask checkpoint between capture and bubbling listeners.
                // Plugin-specific async adapters capture an intent while this event is dispatching.
                trustedDispatch = { target: target, event: event };
            }
            document.addEventListener('click', capture, true);
            document.addEventListener('keydown', capture, true);
            document.addEventListener('pointerdown', function (event) {
                if (event.isTrusted) invalidateSelection();
            }, true);
            document.addEventListener('visibilitychange', function () {
                if (document.hidden) invalidateSelection();
            });
            window.addEventListener('pagehide', invalidateSelection);
        },

        // MARK: - Screensaver Suppression (Headless Stability Guard)
        disableScreensaver: function () {
            try {
                if (typeof localStorage !== 'undefined') {
                    localStorage.setItem('screensaver', 'false');
                    localStorage.setItem('screensaver_type', 'none');
                }
                if (typeof Lampa !== 'undefined' && Lampa.Screensaver) {
                    if (typeof Lampa.Screensaver.enable === 'function') Lampa.Screensaver.enable(false);
                    if (typeof Lampa.Screensaver.stop === 'function') Lampa.Screensaver.stop();
                }
            } catch (e) {}
        },

        // MARK: - App Ready & Heartbeat Hooks
        attachAppReadyHook: function () {
            var self = this;
            var checkApp = setInterval(function () {
                if (typeof Lampa !== 'undefined' && Lampa.Listener) {
                    if (!Lampa.Listener.__ilampaAppReadyBound) {
                        Lampa.Listener.__ilampaAppReadyBound = true;
                        Lampa.Listener.follow('app', function (e) {
                            if (e && e.type === 'ready') self.notifyAppReady();
                        });
                    }
                    if (window.appready) {
                        self.notifyAppReady();
                    }
                    if (self.isAppReadyReported) clearInterval(checkApp);
                }
            }, 100);
        },

        // Native-managed plugins execute after Lampa's original app:ready
        // event. Older extensions (e.g. Radio Record) subscribe to that event
        // without checking window.appready, so their menus never initialize.
        // Replay readiness only to the managed plugin's *new* subscription.
        // Existing core listeners are left untouched.
        attachLatePluginReadyHook: function () {
            if (!Lampa.Listener || typeof Lampa.Listener.follow !== 'function') return;
            var bus = Lampa.Listener;
            var original = bus.follow;
            if (original.__ilampaLateReadyHook) return;
            function follow(eventName, callback) {
                var result = original.apply(this, arguments);
                var owner = typeof window.__ilampaExecutingPluginURL === 'string' ?
                    window.__ilampaExecutingPluginURL : '';
                if (eventName === 'app' && typeof callback === 'function' && owner &&
                    window.__ilampaNativeManaged === true && window.appready === true &&
                    window.LampaNativeBridge && window.LampaNativeBridge.isAppReadyReported) {
                    var dispatch = function () {
                        if (window.__ilampaGeneration !== generation ||
                            window.__ilampaDocumentToken !== documentToken ||
                            window.appready !== true) return;
                        var previous = window.__ilampaExecutingPluginURL;
                        window.__ilampaExecutingPluginURL = owner;
                        try { callback({ type: 'ready' }); }
                        catch (e) { window.LampaNativeBridge.log('error', 'Late app-ready plugin callback failed'); }
                        finally { window.__ilampaExecutingPluginURL = previous; }
                    };
                    // Do not invoke inside follow(): plugins may define variables
                    // immediately after registering their ready callback.
                    if (typeof queueMicrotask === 'function') queueMicrotask(dispatch);
                    else Promise.resolve().then(dispatch);
                }
                return result;
            }
            follow.__ilampaLateReadyHook = true;
            bus.follow = follow;
        },

        notifyAppReady: function () {
            if (this.isAppReadyReported || window.appready !== true || typeof Lampa === 'undefined' ||
                !Lampa.Plugins || !Lampa.Player || !Lampa.Player.listener ||
                typeof Lampa.Reguest !== 'function' || !Lampa.Template || typeof Lampa.Template.get !== 'function' ||
                typeof $ === 'undefined') return;
            // The handshake, not didFinish, owns restoration. Bind synchronously before
            // native can evaluate a plugin that constructs request objects or source rows.
            this.attachRequestHook();
            this.attachOnlineModTemplateHook();
            this.bindPlayerListener();
            if (!this.attachComponentHook()) return;
            this.attachLatePluginReadyHook();
            this.isAppReadyReported = true;
            this.log('info', 'Lampa runtime appready: true, DOM ready, jQuery active');
            post('lampaLifecycle', {
                status: 'ready',
                hasLampa: typeof Lampa !== 'undefined',
                hasJQuery: typeof $ !== 'undefined',
                hasPlugins: typeof Lampa !== 'undefined' && typeof Lampa.Plugins !== 'undefined',
                hasPlayer: typeof Lampa !== 'undefined' && typeof Lampa.Player !== 'undefined'
            });
        },

        startSchedulingHeartbeat: function () {
            var self = this;
            setInterval(function () {
                self.heartbeatTicks++;
                post('lampaHeartbeat', {
                    ticks: self.heartbeatTicks,
                    timestamp: Date.now()
                });
            }, 500);
        },

        // MARK: - Diagnostics & Logging
        setupDiagnostics: function () {
            var self = this;

            window.onerror = function (msg, url, line, col, error) {
                var cleanMsg = self.sanitizeLog(String(msg));
                var cleanUrl = self.sanitizeLog(String(url));
                self.log('error', 'JS Error: ' + cleanMsg + ' (' + cleanUrl + ':' + line + ':' + col + ')');
                post('lampaError', {
                    message: cleanMsg,
                    source: cleanUrl,
                    line: line || 0,
                    col: col || 0,
                    stack: (error && error.stack) ? self.sanitizeLog(error.stack) : ''
                });
            };

            window.addEventListener('unhandledrejection', function (event) {
                var reason = event.reason ? (event.reason.message || event.reason) : 'unknown';
                var cleanReason = self.sanitizeLog(String(reason));
                self.log('error', 'Unhandled Promise Rejection: ' + cleanReason);
                post('lampaError', {
                    message: 'Unhandled Promise Rejection: ' + cleanReason,
                    source: 'Promise',
                    line: 0,
                    col: 0,
                    stack: (event.reason && event.reason.stack) ? self.sanitizeLog(event.reason.stack) : ''
                });
            });

            var originalConsoleError = console.error;
            console.error = function () {
                var args = Array.prototype.slice.call(arguments);
                var formatted = args.map(function (a) {
                    return typeof a === 'object' ? JSON.stringify(a) : String(a);
                }).join(' ');
                self.log('error', self.sanitizeLog(formatted));
                originalConsoleError.apply(console, arguments);
            };
        },

        log: function (level, message) {
            post('lampaLog', {
                level: level || 'info',
                message: this.sanitizeLog(message || '')
            });
        },

        sanitizeLog: function (str) {
            if (!str || typeof str !== 'string') return '';
            // Strip potential auth tokens, bearer headers, or credentials
            return str
                .replace(/([?&](token|key|auth|secret|pass)=)[^&#\s]+/gi, '$1[REDACTED]')
                .replace(/(Bearer\s+)[A-Za-z0-9_\-\.]+/gi, '$1[REDACTED]');
        },

        reportLayoutMetrics: function () {
            var metrics = {
                innerWidth: window.innerWidth,
                innerHeight: window.innerHeight,
                clientWidth: document.documentElement ? document.documentElement.clientWidth : 0,
                clientHeight: document.documentElement ? document.documentElement.clientHeight : 0,
                devicePixelRatio: window.devicePixelRatio || 1,
                orientation: window.innerWidth > window.innerHeight ? 'landscape' : 'portrait'
            };

            post('lampaMetrics', metrics);
        },

        // MARK: - Full-Screen Viewport & Safe Area Styling
        injectMobileStyles: function () {
            var vp = document.querySelector('meta[name="viewport"]');
            if (vp) {
                var content = vp.getAttribute('content') || '';
                if (content.indexOf('viewport-fit=cover') === -1) {
                    vp.setAttribute('content', content + ', viewport-fit=cover');
                }
            } else {
                var meta = document.createElement('meta');
                meta.name = 'viewport';
                meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover';
                document.head.appendChild(meta);
            }

            var style = document.createElement('style');
            style.id = 'ilampa-layout-overrides';
            style.innerHTML = `
                :root {
                    --sat: env(safe-area-inset-top, 0px);
                    --sab: env(safe-area-inset-bottom, 0px);
                    --sal: env(safe-area-inset-left, 0px);
                    --sar: env(safe-area-inset-right, 0px);
                }
                html, body {
                    width: 100% !important;
                    height: 100% !important;
                    min-width: 100vw !important;
                    min-height: 100vh !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    position: fixed !important;
                    left: 0 !important;
                    top: 0 !important;
                    right: 0 !important;
                    bottom: 0 !important;
                    overflow: hidden !important;
                    background: #1d1f20 !important;
                    -webkit-user-select: none !important;
                    user-select: none !important;
                }
                #app {
                    width: 100% !important;
                    height: 100% !important;
                }
                .wrap {
                    width: 100% !important;
                    height: 100% !important;
                }
                .wrap__content {
                    width: 100% !important;
                    max-width: 100vw !important;
                }
                .head__body {
                    padding-top: calc(0.5em + var(--sat)) !important;
                }
                .navigation-bar {
                    padding-bottom: calc(0.8em + var(--sab)) !important;
                }
                body.orientation--landscape .wrap__content {
                    padding-left: var(--sal) !important;
                    padding-right: var(--sar) !important;
                }
                .simple-keyboard {
                    display: none !important;
                }
            `;
            document.head.appendChild(style);
        },

        // MARK: - Stream Resolution
        resolveBestUrl: function (data) {
            // Player's explicit URL is authoritative. A quality catalogue is not a selection.
            return data && typeof data.url === 'string' ? data.url : '';
        },

        parseAvailableQualities: function (data) {
            var qualities = [];
            if (data && data.quality && typeof data.quality === 'object') {
                for (var key in data.quality) {
                    var val = data.quality[key];
                    var u = typeof val === 'object' ? (val.url || val.file) : val;
                    if (u && typeof u === 'string') {
                        qualities.push({
                            label: String(key).toUpperCase(),
                            url: u,
                            bitrate: parseInt(key, 10) ? parseInt(key, 10) * 1000 : null
                        });
                    }
                }
            }
            return qualities.length > 0 ? qualities : null;
        },

        parseAvailableStudios: function (data) {
            var studios = [];
            if (data && Array.isArray(data.voices)) {
                data.voices.forEach(function (v) {
                    if (v && (v.url || v.file)) {
                        studios.push({
                            id: String(v.id || v.name || '').toLowerCase().replace(/[^a-z0-9]/gi, ''),
                            name: v.name || v.title || 'Студия',
                            url: v.url || v.file,
                            isOriginal: Boolean(v.original),
                            language: v.lang || 'ru'
                        });
                    }
                });
            }
            return studios.length > 0 ? studios : null;
        },

        // MARK: - Central Native Stream Router & Attribution Guard
        routePlaybackToNative: function (payload) {
            // Deliberately not a public authorization API. Only private adapter closures own intents.
            this.log('warn', 'Rejected unattributed playback; use a trusted visible Lampa selection');
            return false;
        },

        // MARK: - Dedicated Plugin Integration Adapters (SomaFM Radio)
        attachSomaFMAdapter: function () {
            var self = this;

            function reportSomaIssue(message) {
                self.log('error', 'SomaFM: ' + message);
                try {
                    if (typeof Lampa !== 'undefined' && Lampa.Noty && typeof Lampa.Noty.show === 'function') {
                        Lampa.Noty.show(message);
                    }
                } catch (e) {}
            }

            function hookSomaPlayer(player) {
                if (!player || typeof player.play !== 'function' || player.__nativeAdapterBound) return;
                player.__nativeAdapterBound = true;
                self.log('info', 'Attached dedicated attributable adapter to SomaFM Player');

                player.play = function (station) {
                    if (!station || !station.id || !station.stream || !eligibleDispatch('.somafm-item.selector')) return;
                    var intent = beginSelection({ canonicalId: 'somafm_' + station.id, mediaType: 'audio' },
                        'somafm_radio', 'user_station_select');
                    if (!intent) return;
                    // Snapshot before awaiting: neither mutable station objects nor a newer click own this callback.
                    var title = 'SomaFM: ' + (station.title || station.id);
                    var subtitle = station.genre || station.description || '';
                    var headers = snapshot(station.stream.headers);
                    // soma.js:883-934 starts private HTML5 audio asynchronously. Do NOT call origPlay:
                    // stopAudio is private, and a delayed player.stopAudio() cannot suppress that path.
                    if (typeof player.destroy === 'function') player.destroy();
                    Promise.resolve(station.stream.urls).then(function (urls) {
                        // The original plugin's user action selects a station, while its playlist
                        // supplies one or more equivalent station mirrors. Preserve provider order
                        // rather than making a random URL choice; every accepted candidate is an
                        // explicit HTTP(S) stream returned for that selected station.
                        var candidates = Array.isArray(urls) ? urls.filter(function (url, index, all) {
                            return typeof url === 'string' && /^https?:\/\//i.test(url) && all.indexOf(url) === index;
                        }) : [];
                        if (!candidates.length) {
                            reportSomaIssue('не удалось получить поток выбранной станции');
                            if (pendingSelection === intent) pendingSelection = null;
                            return;
                        }
                        if (candidates.length > 1) {
                            self.log('info', 'SomaFM: получено ' + candidates.length + ' зеркал выбранной станции; используется основной адрес от провайдера');
                        }
                        if (!routeSelectedPlayback({ url: candidates[0], title: title, subtitle: subtitle, time: 0,
                            duration: 0, plugin: 'somafm', customHeaders: headers }, intent)) {
                            reportSomaIssue('выбранный поток больше не действителен; выберите станцию ещё раз');
                        }
                    }).catch(function (err) {
                        if (pendingSelection === intent) pendingSelection = null;
                        reportSomaIssue('ошибка получения потока станции');
                        self.log('error', 'SomaFM stream resolution detail: ' + String(err && err.message || err));
                    });
                };
            }

            if (typeof window.somafm_player !== 'undefined') {
                hookSomaPlayer(window.somafm_player);
            }

            var _currentSoma = window.somafm_player;
            try {
                Object.defineProperty(window, 'somafm_player', {
                    configurable: true,
                    enumerable: true,
                    get: function () { return _currentSoma; },
                    set: function (newVal) {
                        _currentSoma = newVal;
                        if (newVal) hookSomaPlayer(newVal);
                    }
                });
            } catch (e) {}
        },

        // MARK: - Hook Player
        attachPlayerHook: function () {
            var checkInterval = setInterval(function () {
                if (typeof Lampa !== 'undefined' && Lampa.Player && Lampa.Player.listener) {
                    clearInterval(checkInterval);
                    window.LampaNativeBridge.bindPlayerListener();
                }
            }, 100);
        },

        bindPlayerListener: function () {
            var self = this;
            if (this.isPlayerListenerBound) return;
            this.isPlayerListenerBound = true;
            observeLatePlaylist(Lampa.Player);
            this.log('info', 'Attached native player listener to Lampa.Player');

            Lampa.Player.listener.follow('create', function (e) {
                if (!e || !e.data) return;
                // Verified original Player.play: listener.send('create', {data, abort: () => run = false}).
                // Abort rejected requests too: headless fallback must never start WebKit media.
                if (typeof e.abort !== 'function') return;
                e.abort();
                var data = e.data;
                // A pending intent is not callback provenance. In particular, a
                // null-intent Reguest callback or an unadapted timer must not borrow
                // a newer selection (whose episode/card may be omitted by Player).
                var intent = capturePlayerSelection(data);
                if (!intent || pendingSelection !== intent) return;
                var card = data.movie || data.card;
                if (card && (String(card.id) !== String(intent.id) ||
                    (card.media_type && card.media_type !== intent.mediaType))) return;
                if ((data.season != null && intent.season != null && data.season !== intent.season) ||
                    (data.episode != null && intent.episode != null && data.episode !== intent.episode)) return;
                var streamUrl = self.resolveBestUrl(data);
                if (!streamUrl) {
                    self.log('warn', 'No explicit selected URL; quality-only playback is unsupported');
                    return;
                }
                var timecode = 0;
                var duration = 0;
                var hash = '';

                if (data.timeline) {
                    timecode = data.timeline.time || 0;
                    duration = data.timeline.duration || 0;
                    hash = data.timeline.hash || '';
                }

                var sourcePlaylist = Array.isArray(data.playlist) ? data.playlist : [];
                var playlist = playlistDescriptors(sourcePlaylist, intent.requestId);

                var payload = {
                    action: 'play',
                    url: streamUrl,
                    title: data.title || '',
                    subtitle: data.subtitle || '',
                    time: timecode,
                    duration: duration,
                    hash: hash,
                    currentQuality: data.currentQuality || null,
                    season: data.season == null ? null : data.season,
                    episode: data.episode == null ? null : data.episode,
                    currentStudio: data.voice || intent.translateVoice || null,
                    availableQualities: self.parseAvailableQualities(data),
                    availableStudios: self.parseAvailableStudios(data),
                    playlist: playlist.length > 0 ? playlist : null,
                    customHeaders: (data.headers && typeof data.headers === 'object') ? snapshot(data.headers) : null,
                    availableSubtitles: Array.isArray(data.subtitles) ? snapshot(data.subtitles) : null,
                    plugin: intent.pluginId,
                    runtimeOrigin: 'lampa_core',
                    providerId: intent.pluginId,
                    playlistId: intent.requestId,
                    isDiagnostic: false
                };

                if (routeSelectedPlayback(payload, intent)) {
                    activePlaylistSession = {
                        id: intent.requestId, canonicalId: intent.canonicalId, mediaType: intent.mediaType,
                        items: sourcePlaylist.slice()
                    };
                    self.activeItem = data;
                }
            });
        },

        syncTimecode: function (hash, time, duration) {
            var percent = duration > 0 ? Math.round((time / duration) * 100) : 0;

            if (this.activeItem && this.activeItem.timeline) {
                var tl = this.activeItem.timeline;
                tl.time = time;
                tl.duration = duration;
                tl.percent = percent;
                if (typeof tl.handler === 'function') {
                    tl.handler(percent, time, duration);
                }
            }

            if (typeof Lampa !== 'undefined' && Lampa.Timeline && hash) {
                Lampa.Timeline.view(hash, {
                    time: Math.floor(time),
                    duration: Math.floor(duration),
                    percent: percent
                });
            }
        },

        // Stop all WebKit HTML5 video/audio elements to guarantee no background audio leaks
        stopAllMedia: function () {
            try {
                var mediaElements = document.querySelectorAll('video, audio');
                for (var i = 0; i < mediaElements.length; i++) {
                    var el = mediaElements[i];
                    el.pause();
                    el.removeAttribute('src');
                    el.load();
                }
                if (typeof Lampa !== 'undefined' && Lampa.Player && typeof Lampa.Player.stop === 'function') {
                    Lampa.Player.stop();
                }
                this.log('info', 'Stopped and released all WebKit media elements');
            } catch (e) {
                this.log('error', 'Error in stopAllMedia: ' + e.message);
            }
        },

        // MARK: - Native Plugin Management
        getPlugins: function () {
            var result = [];
            try {
                if (typeof Lampa !== 'undefined' && Lampa.Plugins && typeof Lampa.Plugins.get === 'function') {
                    var list = Lampa.Plugins.get();
                    if (Array.isArray(list)) {
                        result = list.filter(function (p) {
                            return p && typeof p.url === 'string' && p.url.trim().length > 0 && p.url !== 'undefined' && p.url !== 'null';
                        }).map(function (p) {
                            return {
                                url: p.url.trim(),
                                name: p.name || p.title || p.url || 'Плагин',
                                author: p.author || '',
                                status: (typeof p.status !== 'undefined') ? p.status : 1
                            };
                        });
                    }
                }
            } catch (e) {
                this.log('error', 'Error reading plugins: ' + e.message);
            }
            post('lampaPluginsList', { plugins: result });
            return result;
        },

        addPlugin: function (url, name) {
            if (window.__ilampaNativeManaged === true) return { success: false, error: 'native-managed' };
            try {
                if (!url || typeof url !== 'string' || url === 'undefined' || url === 'null' || url.trim().length === 0) return;
                var cleanUrl = url.trim();
                if (typeof Lampa !== 'undefined' && Lampa.Plugins) {
                    var newPlugin = {
                        url: cleanUrl,
                        status: 1,
                        name: name || cleanUrl
                    };
                    if (typeof Lampa.Plugins.add === 'function') {
                        Lampa.Plugins.add(newPlugin);
                    }
                    if (typeof Lampa.Plugins.save === 'function') {
                        Lampa.Plugins.save();
                    }
                    this.log('info', 'Added plugin: ' + cleanUrl);
                    this.getPlugins();
                }
            } catch (e) {
                this.log('error', 'Error adding plugin: ' + e.message);
            }
        },

        removePlugin: function (url) {
            if (window.__ilampaNativeManaged === true) return { success: false, error: 'native-managed' };
            try {
                if (!url || typeof url !== 'string' || url === 'undefined' || url === 'null' || url.trim().length === 0) {
                    this.log('warn', 'Ignored removePlugin for invalid URL: ' + url);
                    return;
                }
                var cleanUrl = url.trim();
                if (typeof Lampa !== 'undefined' && Lampa.Plugins && typeof Lampa.Plugins.get === 'function') {
                    var list = Lampa.Plugins.get();
                    var item = list.find(function (p) { return p && p.url === cleanUrl; });
                    if (item && typeof Lampa.Plugins.remove === 'function') {
                        Lampa.Plugins.remove(item);
                        if (typeof Lampa.Plugins.save === 'function') {
                            Lampa.Plugins.save();
                        }
                        this.log('info', 'Removed plugin: ' + cleanUrl);
                        this.getPlugins();
                    }
                }
            } catch (e) {
                this.log('error', 'Error removing plugin: ' + e.message);
            }
        },

        togglePlugin: function (url, enabled) {
            if (window.__ilampaNativeManaged === true) return { success: false, error: 'native-managed' };
            try {
                if (!url || typeof url !== 'string' || url === 'undefined' || url === 'null' || url.trim().length === 0) {
                    this.log('warn', 'Ignored togglePlugin for invalid URL: ' + url);
                    return;
                }
                var cleanUrl = url.trim();
                if (typeof Lampa !== 'undefined' && Lampa.Plugins && typeof Lampa.Plugins.get === 'function') {
                    var list = Lampa.Plugins.get();
                    var item = list.find(function (p) { return p && p.url === cleanUrl; });
                    if (item) {
                        item.status = enabled ? 1 : 0;
                        if (typeof Lampa.Plugins.save === 'function') {
                            Lampa.Plugins.save();
                        }
                        this.log('info', 'Toggled plugin ' + cleanUrl + ' to status ' + (enabled ? 1 : 0));
                        this.getPlugins();
                    }
                }
            } catch (e) {
                this.log('error', 'Error toggling plugin: ' + e.message);
            }
        },

        performSearch: function (query) {
            try {
                if (typeof Lampa !== 'undefined' && Lampa.Activity && query) {
                    Lampa.Activity.push({
                        url: '',
                        title: 'Поиск: ' + query,
                        component: 'search',
                        search: query,
                        page: 1
                    });
                    this.log('info', 'Performed search: ' + query);
                }
            } catch (e) {
                this.log('error', 'Error triggering search: ' + e.message);
            }
        },

        triggerMovieSearch: function (params) {
            invalidateSelection();
            try {
                if (!params || !Number.isInteger(params.id) || params.id <= 0 ||
                    typeof params.title !== 'string' || !params.title.trim() ||
                    (params.mediaType !== 'movie' && params.mediaType !== 'tv') ||
                    typeof params.canonicalId !== 'string' || !params.canonicalId) {
                    return { success: false, error: 'invalid-identity' };
                }
                var slides = document.querySelector('.activitys__slides');
                if (typeof Lampa === 'undefined' || !Lampa.Activity || !window.appready || !slides) {
                    return { success: false, error: 'not-ready' };
                }
                // Resolve genuine registered Lampa component (e.g. 'online_mod' or 'online')
                var compName = params.component;
                if (!compName || typeof Lampa === 'undefined' || !Lampa.Component || !Lampa.Component.get || !Lampa.Component.get(compName)) {
                    compName = (typeof Lampa !== 'undefined' && Lampa.Component && Lampa.Component.get && Lampa.Component.get('online_mod')) ? 'online_mod' : 'online';
                }
                if (typeof compName !== 'string' || !Lampa.Component || !Lampa.Component.get ||
                    !Lampa.Component.get(compName)) return { success: false, error: 'missing-component', component: compName };

                // Set balancer if specified (e.g. cdnvideohub, rezka2, collaps, filmix)
                var balancer = params.balancer || params.balanser;
                if (typeof balancer === 'string' && balancer.trim() && typeof Lampa !== 'undefined' && Lampa.Storage && typeof Lampa.Storage.set === 'function') {
                    Lampa.Storage.set('online_mod_balanser', balancer.trim().toLowerCase());
                }

                activeSearchContext = {
                    id: params.id,
                    canonicalId: params.canonicalId,
                    requestId: params.requestId || null,
                    actionId: params.actionId || null,
                    mediaType: params.mediaType,
                    title: params.title,
                    season: params.season == null ? null : params.season,
                    episode: params.episode == null ? null : params.episode
                };
                folderOperation = null;
                lastSnapshotSignature = '';

                // Prevent DOM accumulation across repeated searches (e.g. 16 -> 32 -> 48)
                try {
                    var staleSelectors = document.querySelectorAll('.online.selector');
                    for (var sIdx = 0; sIdx < staleSelectors.length; sIdx++) {
                        staleSelectors[sIdx].parentNode && staleSelectors[sIdx].parentNode.removeChild(staleSelectors[sIdx]);
                    }
                } catch (domErr) {}

                var movieObj = {
                    id: params.id,
                    media_type: params.mediaType,
                    source: 'tmdb',
                    canonicalId: params.canonicalId
                };
                if (params.mediaType === 'tv') {
                    movieObj.name = params.title;
                    movieObj.original_name = params.original_name || params.original_title || params.title;
                    if (params.first_air_date) movieObj.first_air_date = params.first_air_date;
                } else {
                    movieObj.title = params.title;
                    movieObj.original_title = params.original_title || params.title;
                    if (params.release_date) movieObj.release_date = params.release_date;
                }
                var previousSearch = searchScope;
                searchScope = activeSearchContext;
                try { Lampa.Activity.push({
                    url: '',
                    title: params.title,
                    source: 'tmdb',
                    component: compName,
                    mediaType: params.mediaType,
                    canonicalId: params.canonicalId,
                    requestId: params.requestId || null,
                    season: params.season == null ? null : params.season,
                    episode: params.episode == null ? null : params.episode,
                    search: params.title,
                    search_one: params.title,
                    search_two: params.original_title || params.original_name || params.title,
                    movie: movieObj,
                    page: 1
                }); } finally { searchScope = previousSearch; }
                this.log('info', 'Triggered movie search for component ' + compName + ': ' + params.title + ' [canonicalId=' + params.canonicalId + ']');
                return { success: true };
            } catch (e) {
                this.log('error', 'Error in triggerMovieSearch: ' + e.message);
                return { success: false, error: 'search-failed' };
            }
        },

        testTimer: function (delayMs, callbackId) {
            var start = Date.now();
            setTimeout(function () {
                var elapsed = (Date.now() - start) / 1000.0;
                post('lampaLifecycle', {
                    status: 'timerCompleted',
                    elapsed: elapsed,
                    callbackId: callbackId
                });
            }, delayMs);
        },

        attachComponentHook: function () {
            var self = this;
            this.attachAsyncAttributionHook();
            function bind() {
                if (typeof Lampa === 'undefined' || !Lampa.Component || typeof Lampa.Component.add !== 'function') return false;
                var origAdd = Lampa.Component.add;
                if (origAdd.__ilampaComponentHook) return true;
                function add(name, componentClass) {
                    var isPlatform = typeof name === 'string' && (name.indexOf('cub_') === 0 || name.indexOf('shots_') === 0 || name === 'main' || name === 'settings' || name === 'head' || name === 'menu');
                    // Generalized async attribution: strictly use active execution context, never falling back to last loaded file
                    var pluginUrl = isPlatform ? null : (typeof window.__ilampaExecutingPluginURL === 'string' ? window.__ilampaExecutingPluginURL : null);
                    // Do not advertise a capability if the upstream registration throws.
                    var result = origAdd.apply(this, arguments);
                    if (typeof name === 'string') componentOwners[name] = pluginUrl;
                    self.log('info', 'Component registered in Lampa: ' + name + (isPlatform ? ' (platform component)' : (pluginUrl ? ' owner=identified' : ' owner=unknown')));
                    post('lampaComponentRegistered', {
                        name: name,
                        pluginUrl: isPlatform ? null : pluginUrl,
                        isPlatform: isPlatform,
                        timestamp: Date.now()
                    });
                    return result;
                }
                add.__ilampaComponentHook = true;
                Lampa.Component.add = add;
                return true;
            }
            if (bind()) return true;
            var check = setInterval(function () { if (bind()) clearInterval(check); }, 50);
            return false;
        },

        attachAsyncAttributionHook: function () {
            if (window.__ilampaAsyncHookBound) return;
            window.__ilampaAsyncHookBound = true;

            function wrapCallback(fn, contextUrl) {
                if (typeof fn !== 'function' || !contextUrl) return fn;
                return function () {
                    var prev = window.__ilampaExecutingPluginURL;
                    window.__ilampaExecutingPluginURL = contextUrl;
                    try {
                        return fn.apply(this, arguments);
                    } finally {
                        window.__ilampaExecutingPluginURL = prev;
                    }
                };
            }

            var origSetTimeout = window.setTimeout;
            if (typeof origSetTimeout === 'function') {
                window.setTimeout = function (fn, delay) {
                    var currentContext = window.__ilampaExecutingPluginURL;
                    // Diagnostic tracking: keep record of last active plugin URL without using it for blind component attribution
                    if (currentContext) window.__ilampaLastPluginURL = currentContext;
                    if (currentContext && typeof fn === 'function') {
                        var wrapped = wrapCallback(fn, currentContext);
                        return origSetTimeout.apply(this, [wrapped, delay].concat(Array.prototype.slice.call(arguments, 2)));
                    }
                    return origSetTimeout.apply(this, arguments);
                };
            }

            var origSetInterval = window.setInterval;
            if (typeof origSetInterval === 'function') {
                window.setInterval = function (fn, delay) {
                    var currentContext = window.__ilampaExecutingPluginURL;
                    if (currentContext && typeof fn === 'function') {
                        return origSetInterval.apply(this, [wrapCallback(fn, currentContext), delay].concat(Array.prototype.slice.call(arguments, 2)));
                    }
                    return origSetInterval.apply(this, arguments);
                };
            }

            if (typeof Promise !== 'undefined' && Promise.prototype && typeof Promise.prototype.then === 'function') {
                var origThen = Promise.prototype.then;
                Promise.prototype.then = function (onFulfilled, onRejected) {
                    var currentContext = window.__ilampaExecutingPluginURL;
                    if (currentContext) {
                        return origThen.call(this, wrapCallback(onFulfilled, currentContext), wrapCallback(onRejected, currentContext));
                    }
                    return origThen.apply(this, arguments);
                };
            }

            if (typeof queueMicrotask === 'function') {
                var origMicrotask = window.queueMicrotask;
                window.queueMicrotask = function (fn) {
                    var currentContext = window.__ilampaExecutingPluginURL;
                    if (currentContext && typeof fn === 'function') {
                        return origMicrotask.call(this, wrapCallback(fn, currentContext));
                    }
                    return origMicrotask.apply(this, arguments);
                };
            }
        },

        attachSourceDiscoveryHook: function () {
            if (typeof MutationObserver === 'undefined') return;
            function inspect() {
                if (!activeSearchContext) return;
                // Navigation stages use operation-bound request callbacks, never
                // observer-time attribution to the currently active request.
                if (folderOperation) return;
                var items = [];
                document.querySelectorAll('.online.selector').forEach(function (el, idx) {
                    var titleEl = el.querySelector('.online__title');
                    var qualityEl = el.querySelector('.online__quality');
                    var infoEl = el.querySelector('.online__info');
                    if (titleEl) {
                        var rowData = selectedOnlineModRow(el);
                        items.push({
                            index: idx,
                            rowToken: (function () {
                                if (!discoveryRows) return '';
                                var token = discoveryRows.get(el);
                                if (!token) { token = String(++discoverySequence); discoveryRows.set(el, token); }
                                return token;
                            })(),
                            title: (titleEl.innerText || '').trim(),
                            quality: qualityEl ? (qualityEl.innerText || '').trim() : '',
                            info: infoEl ? (infoEl.innerText || '').trim() : '',
                            voice: rowData && rowData.translateVoice || '',
                            isAlternative: !!(rowData && rowData.isFolder && !rowData.pagination),
                            isFolder: isOnlineFolder(el)
                        });
                    }
                });
                var emptyEl = document.querySelector('.empty__descr, .list_empty .empty__descr, .empty');
                var emptyReason = emptyEl ? (emptyEl.innerText || '').trim() : '';
                var currentBalancer = (typeof Lampa !== 'undefined' && Lampa.Storage && Lampa.Storage.get('online_mod_balanser')) || '';

                var sig = JSON.stringify([currentBalancer, emptyReason, items]);
                if (sig === lastSnapshotSignature) return;
                lastSnapshotSignature = sig;

                // Navigation labels only: DOM presence is not evidence of a playable stream.
                post('lampaSourcesDiscovered', {
                    balancer: currentBalancer,
                    emptyReason: emptyReason,
                    count: items.length,
                    canonicalId: activeSearchContext.canonicalId,
                    requestId: activeSearchContext.requestId,
                    mediaType: activeSearchContext.mediaType,
                    season: activeSearchContext.season,
                    episode: activeSearchContext.episode,
                    navigationOnly: true,
                    sources: items.slice(0, 50).map(function (item) {
                        item.navigationOnly = true;
                        return item;
                    })
                });
            }
            var observer = new MutationObserver(inspect);
            if (document.body) {
                observer.observe(document.body, { childList: true, subtree: true });
            } else {
                window.addEventListener('DOMContentLoaded', function () {
                    if (document.body) observer.observe(document.body, { childList: true, subtree: true });
                });
            }
        },

        switchBalancer: function (name) {
            try {
                if (typeof Lampa === 'undefined') return { success: false, error: 'no-lampa' };
                if (Lampa.Storage && typeof Lampa.Storage.set === 'function') {
                    Lampa.Storage.set('online_mod_balanser', name);
                }
                var active = Lampa.Activity && Lampa.Activity.active && Lampa.Activity.active();
                var comp = active && active.activity && active.activity.component;
                if (comp && typeof comp.changeBalanser === 'function') {
                    comp.changeBalanser(name);
                    return { success: true, balancer: name };
                }
                return { success: false, error: 'no-active-component' };
            } catch (e) {
                return { success: false, error: e.message };
            }
        },

        clearActiveSearchContext: function () {
            folderOperation = null;
            activeSearchContext = null;
            lastSnapshotSignature = '';
            invalidateSelection();
            try {
                var staleSelectors = document.querySelectorAll('.online.selector');
                for (var sIdx = 0; sIdx < staleSelectors.length; sIdx++) {
                    staleSelectors[sIdx].parentNode && staleSelectors[sIdx].parentNode.removeChild(staleSelectors[sIdx]);
                }
            } catch (e) {}
            return { success: true };
        },

        selectDiscoveredSource: function (index) {
            // A synthetic DOM click cannot become trusted native playback intent.
            return { success: false, error: 'trusted-selection-required' };
        },

        // Navigation is not playback authorization. The caller must still select a
        // newly discovered row explicitly before any Player.play handoff is accepted.
        navigateHeadlessFolder: function (index, searchId, rowToken, operationId, owner) {
            try {
                if (!activeSearchContext || activeSearchContext.requestId !== searchId || !discoveryRows || !rowToken) {
                    return { success: false, error: 'search-context-mismatch' };
                }
                var items = document.querySelectorAll('.online.selector');
                if (!items || index < 0 || index >= items.length) return { success: false, error: 'index-out-of-bounds' };
                var target = items[index];
                if (discoveryRows.get(target) !== rowToken) return { success: false, error: 'source-changed' };
                if (folderOperation && (!validFolderOperation(folderOperation) || folderRows.get(target) !== folderOperation)) return { success: false, error: 'source-changed' };
                if (!isOnlineFolder(target)) return { success: false, error: 'not-a-folder' };
                var folderData = selectedOnlineModRow(target);
                if (folderData && !folderData.pagination) return { success: false, error: 'alternative-unverified' };
                var identity = activityIdentity();
                if (!identity || String(identity.id) !== String(activeSearchContext.id) ||
                    identity.canonicalId !== activeSearchContext.canonicalId || identity.mediaType !== activeSearchContext.mediaType ||
                    (identity.mediaType === 'tv' && (identity.season !== activeSearchContext.season || identity.episode !== activeSearchContext.episode)) ||
                    (Lampa.Activity.active().search && Lampa.Activity.active().search !== activeSearchContext.title)) {
                    return { success: false, error: 'search-context-mismatch' };
                }
                invalidateSelection();
                var previousRows = Array.prototype.slice.call(items);
                var operation = null;
                if (operationId && owner && componentOwners.online_mod === owner && folderData && folderData.pagination) {
                    operation = { id: operationId, owner: owner, root: activeSearchContext,
                        parent: folderOperation ? folderOperation.id : searchId, requests: 0, callbacks: 0 };
                    folderOperation = operation;
                }
                var priorScope = folderScope;
                folderScope = operation;
                try {
                    if (typeof $ !== 'undefined') $(target).trigger('hover:enter');
                    else target.click();
                } finally { folderScope = priorScope; }
                // Online Mod may change the search term without changing Activity.movie.
                // Never label that search as the original TMDB identity.
                var after = activityIdentity();
                var active = Lampa.Activity.active();
                if (!after || String(after.id) !== String(activeSearchContext.id) ||
                    after.canonicalId !== activeSearchContext.canonicalId || after.mediaType !== activeSearchContext.mediaType ||
                    after.season !== activeSearchContext.season || after.episode !== activeSearchContext.episode ||
                    (active.search && active.search !== activeSearchContext.title)) {
                    discoveryRows = new WeakMap();
                    folderOperation = null;
                    return { success: false, error: 'identity-changed' };
                }
                // Only synchronous, entirely new rows have a provable relationship to
                // this callback. MutationObserver messages have no operation provenance.
                var fresh = Array.prototype.slice.call(document.querySelectorAll('.online.selector'));
                discoveryRows = new WeakMap();
                if (!fresh.length || fresh.some(function (row) { return previousRows.indexOf(row) !== -1; })) {
                    if (operation && operation.requests && validFolderOperation(operation)) {
                        return { success: true, pending: true, operationId: operation.id };
                    }
                    folderOperation = null;
                    return { success: false, error: 'unverified-async-navigation' };
                }
                var children = fresh.map(function (el, idx) {
                    var title = el.querySelector('.online__title');
                    var quality = el.querySelector('.online__quality');
                    var data = selectedOnlineModRow(el);
                    var token = String(++discoverySequence);
                    discoveryRows.set(el, token);
                    return { index: idx, rowToken: token, title: title ? (title.innerText || '').trim() : '',
                        quality: quality ? (quality.innerText || '').trim() : '',
                        voice: data && data.translateVoice || '', isFolder: isOnlineFolder(el),
                        isAlternative: !!(data && data.isFolder && !data.pagination) };
                });
                if (operation) folderOperation = null;
                return { success: true, sources: children };
            } catch (e) {
                return { success: false, error: 'navigation-failed' };
            }
        },

        folderOperationSnapshot: function (operationId) {
            var op = folderOperation;
            if (!op || op.id !== operationId || !validFolderOperation(op)) return { error: 'operation-invalid' };
            var rows = Array.prototype.slice.call(document.querySelectorAll('.online.selector'));
            if (!op.callbacks || !rows.length) return { pending: true };
            if (rows.some(function (row) { return folderRows.get(row) !== op; })) return { error: 'unattributed-rows' };
            var children = rows.map(function (el, idx) {
                var title = el.querySelector('.online__title'), quality = el.querySelector('.online__quality');
                var data = selectedOnlineModRow(el), token = discoveryRows.get(el);
                if (!token) { token = String(++discoverySequence); discoveryRows.set(el, token); }
                return { index: idx, rowToken: token, title: title ? (title.innerText || '').trim() : '',
                    quality: quality ? (quality.innerText || '').trim() : '',
                    voice: data && data.translateVoice || '', isFolder: isOnlineFolder(el),
                    isAlternative: !!(data && data.isFolder && !data.pagination) };
            });
            return { success: true, operationId: op.id, parent: op.parent, owner: op.owner, sources: children };
        },

        cancelFolderOperation: function (operationId) {
            if (folderOperation && folderOperation.id === operationId) {
                folderOperation = null;
                discoveryRows = new WeakMap();
            }
        },

        selectHeadlessSource: function (index, reqId, searchId, rowToken) {
            try {
                if (!activeSearchContext || activeSearchContext.requestId !== searchId || !discoveryRows || !rowToken) {
                    return { success: false, error: 'search-context-mismatch' };
                }
                var items = document.querySelectorAll('.online.selector');
                if (!items || index < 0 || index >= items.length) {
                    return { success: false, error: 'index-out-of-bounds' };
                }
                var target = items[index];
                if (discoveryRows.get(target) !== rowToken) return { success: false, error: 'source-changed' };
                if (folderOperation && (!validFolderOperation(folderOperation) || folderRows.get(target) !== folderOperation)) return { success: false, error: 'source-changed' };
                if (isOnlineFolder(target)) return { success: false, error: 'folder-not-playable' };
                var identity = activityIdentity() || {};
                var currentActivity = Lampa.Activity.active();
                if (!identity.id || String(identity.id) !== String(activeSearchContext.id) ||
                    identity.canonicalId !== activeSearchContext.canonicalId || identity.mediaType !== activeSearchContext.mediaType ||
                    (identity.mediaType === 'tv' && (identity.season !== activeSearchContext.season || identity.episode !== activeSearchContext.episode)) ||
                    (currentActivity.search && currentActivity.search !== activeSearchContext.title)) {
                    return { success: false, error: 'search-context-mismatch' };
                }
                if (activeSearchContext) {
                    if (identity.canonicalId && identity.canonicalId !== activeSearchContext.canonicalId) {
                        return { success: false, error: 'search-context-mismatch' };
                    }
                    identity.canonicalId = identity.canonicalId || activeSearchContext.canonicalId;
                    identity.mediaType = identity.mediaType || activeSearchContext.mediaType;
                    if (activeSearchContext.mediaType === 'tv') {
                        identity.season = activeSearchContext.season;
                        identity.episode = activeSearchContext.episode;
                    }
                }
                var active = typeof Lampa !== 'undefined' && Lampa.Activity.active();
                var rowData = selectedOnlineModRow(target);
                if (identity && identity.mediaType === 'tv') {
                    if (!rowData || !rowData.hasEpisode || rowData.season !== activeSearchContext.season || rowData.episode !== activeSearchContext.episode) {
                        return { success: false, error: 'episode-mismatch' };
                    }
                    identity.season = rowData.season;
                    identity.episode = rowData.episode;
                }
                var pluginId = active && active.component || 'online_mod';
                var intent = Object.freeze(Object.assign({}, identity, {
                    requestId: reqId || (documentToken + ':' + (++sequence)),
                    pluginId: pluginId,
                    selectionContext: 'headless_native_bridge',
                    translateVoice: (rowData && rowData.translateVoice) || null,
                    expiresAt: Date.now() + 30000
                }));
                pendingSelection = intent;
                if (!post('lampaSelection', {
                    requestId: intent.requestId,
                    canonicalId: intent.canonicalId || ('urn:media:' + intent.pluginId),
                    mediaType: intent.mediaType || 'movie',
                    pluginId: intent.pluginId,
                    selectionContext: intent.selectionContext,
                    season: intent.season,
                    episode: intent.episode,
                    audio: intent.translateVoice
                })) { pendingSelection = null; return { success: false, error: 'bridge-unavailable' }; }

                // Programmatic selection of item
                var previousScope = resolverScope;
                resolverScope = { intent: intent };
                try {
                    if (typeof $ !== 'undefined') $(target).trigger('hover:enter');
                    else target.click();
                } finally { resolverScope = previousScope; }
                return { success: true, requestId: intent.requestId };
            } catch (e) {
                return { success: false, error: e.message };
            }
        },
        cancelHeadlessSelection: function (reqId) {
            if (pendingSelection && pendingSelection.selectionContext === 'headless_native_bridge' && pendingSelection.requestId === reqId) {
                pendingSelection = null;
            }
        }
    };

    window.LampaNativeBridge.init();
})();
