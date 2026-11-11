/** Behavioral tests run the shipped bridge and upstream Plugins module, not rewritten equivalents. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const bridgeCode = fs.readFileSync(path.join(root, 'iLampa/Resources/lampa_bridge.js'), 'utf8');
const appCode = fs.readFileSync(path.join(root, 'iLampa/Resources/www/app.min.js'), 'utf8');
const tests = [];
const test = (name, run) => tests.push({ name, run });
const plain = value => JSON.parse(JSON.stringify(value));

function subscribe() {
    const listeners = {};
    return {
        follow(name, callback) { (listeners[name] ||= []).push(callback); },
        send(name, body) { for (const callback of listeners[name] || []) callback(body); },
        count(name) { return (listeners[name] || []).length; }
    };
}

function element(kind = 'online') {
    const classes = new Set(kind === 'soma' ? ['selector', 'somafm-item'] : ['selector', 'online']);
    if (kind === 'folder') classes.add('online_folder');
    return {
        classes,
        classList: { contains: value => classes.has(value) },
        closest(selector) { return selector.split('.').filter(Boolean).every(c => classes.has(c)) ? this : null; },
        querySelector(selector) {
            return { innerText: selector === '.online__title' ? 'Navigation row' : '1080p' };
        },
        click() { throw new Error('Synthetic activation must not be used'); }
    };
}

function runtime(options = {}) {
    const messages = [];
    const documentListeners = {};
    const windowListeners = {};
    const intervals = new Map();
    const timeouts = new Map();
    const mutations = [];
    const requests = [];
    const clock = { now: 100000 };
    let timerId = 0;
    let active = null;
    const components = { online: {}, online_mod: {}, sample_source: {} };
    const node = () => ({ appendChild() {}, setAttribute() {}, getAttribute() { return ''; } });
    const document = {
        hidden: false,
        body: node(), head: node(), documentElement: { clientWidth: 390, clientHeight: 844 },
        createElement: node,
        addEventListener(name, listener) { (documentListeners[name] ||= []).push(listener); },
        querySelector(selector) {
            if (selector === '.activitys__slides') return options.noSlides ? null : node();
            if (selector === 'meta[name="viewport"]') return node();
            if (selector === '.selector.focus') return this.focused || null;
            return null;
        },
        querySelectorAll(selector) { return selector === '.online.selector' ? this.rows || [] : []; }
    };
    const listener = subscribe();
    const playerListener = subscribe();
    const Lampa = {
        Listener: listener,
        Plugins: { get: () => [{ url: 'https://plugins.test/p.js', status: 0 }] },
        Player: { listener: playerListener, stop() {}, playlist(items) { this.installedPlaylist = items; } },
        Activity: { push(value) { active = value; }, active() { return active; } },
        Component: { get: name => components[name], add(name, value) {
            if (options.rejectComponent === name) throw new Error('registration rejected');
            components[name] = value;
            return options.componentResult;
        } },
        Screensaver: { enable() {}, stop() {} }
    };
    Lampa.Template = { get(name, data) { return data && data.row || element(); } };
    Lampa.Reguest = function () {
        this.native = this.silent = function (url, success, error, data, options) {
            requests.push({ url, success, error, data, options });
            return this;
        };
        this.timeout = function () { return this; };
    };
    const context = {
        document, Lampa, $() {},
        console: { error() {}, log() {}, warn() {} },
        appready: options.ready !== false,
        __ilampaGeneration: options.generation === undefined ? 7 : options.generation,
        __ilampaDocumentToken: options.token === undefined ? 'document-A' : options.token,
        __ilampaNativeManaged: true,
        innerWidth: 390, innerHeight: 844, devicePixelRatio: 3,
        localStorage: { setItem() {} },
        setInterval(callback) { const id = ++timerId; intervals.set(id, callback); return id; },
        clearInterval(id) { intervals.delete(id); },
        setTimeout(callback) { const id = ++timerId; timeouts.set(id, callback); return id; },
        clearTimeout(id) { timeouts.delete(id); },
        MutationObserver: class {
            constructor(callback) { mutations.push(callback); }
            observe() {}
        },
        Date: class extends Date { static now() { return clock.now; } },
        addEventListener(name, callback) { (windowListeners[name] ||= []).push(callback); },
        webkit: { messageHandlers: {} }
    };
    context.window = context;
    for (const name of ['lampaSelection', 'lampaNative', 'lampaPlaylist', 'lampaLifecycle', 'lampaHeartbeat', 'lampaLog',
        'lampaMetrics', 'lampaError', 'lampaPluginsList', 'lampaComponentRegistered', 'lampaSourcesDiscovered']) {
        context.webkit.messageHandlers[name] = { postMessage(body) { messages.push({ name, body: plain(body) }); } };
    }
    const deferredModules = { Reguest: Lampa.Reguest, Template: Lampa.Template };
    if (options.deferResolverModules) {
        delete Lampa.Reguest;
        delete Lampa.Template;
    }
    vm.createContext(context);
    vm.runInContext(bridgeCode, context, { filename: 'lampa_bridge.js' });
    if (options.deferResolverModules) Object.assign(Lampa, deferredModules);
    const tick = () => { for (const callback of [...intervals.values()]) callback(); };
    if (options.autoTick !== false) tick();
    const bridge = context.LampaNativeBridge;
    function dispatch(target, callback, { trusted = true, type = 'click', key } = {}) {
        const event = { type, key, target, isTrusted: trusted, eventPhase: 1 };
        for (const listener of documentListeners[type] || []) listener(event);
        event.eventPhase = 3;
        try { if (callback) callback(); } finally { event.eventPhase = 0; }
    }
    function play(data, withAbort = true) {
        let aborted = false;
        const event = { data };
        if (withAbort) event.abort = () => { aborted = true; };
        playerListener.send('create', event);
        return aborted;
    }
    return {
        context, bridge, document, messages, tick, dispatch, play, listener, playerListener, requests, clock,
        timeouts, intervals, mutations, components,
        received: name => messages.filter(message => message.name === name).map(message => message.body),
        show() { bridge.setPresentation(true); },
        search(params = {}) { return bridge.triggerMovieSearch(Object.assign({
            id: 550, title: 'Fight Club', original_title: 'Fight Club', mediaType: 'movie',
            canonicalId: 'urn:media:tmdb:movie:550', release_date: '1999-10-15', component: 'online_mod'
        }, params)); },
        fireDocument(name) { for (const callback of documentListeners[name] || []) callback(); },
        onlineModRow(data) { return Lampa.Template.get('online_mod', Object.assign({ row: element() }, data)); },
        fireWindow(name, event = {}) { for (const callback of windowListeners[name] || []) callback(event); }
    };
}

function deferred() {
    let resolve;
    const promise = new Promise(done => { resolve = done; });
    return { promise, resolve };
}
async function flush() { await Promise.resolve(); await Promise.resolve(); await Promise.resolve(); }
function soma(r) {
    let originalCalls = 0;
    let destroyed = 0;
    const player = { play() { originalCalls++; }, destroy() { destroyed++; } };
    r.context.somafm_player = player;
    return { player, originalCalls: () => originalCalls, destroyed: () => destroyed };
}

test('ready is emitted once per document, including duplicate bridge injection', () => {
    const r = runtime();
    r.listener.send('app', { type: 'ready' });
    r.bridge.notifyAppReady();
    vm.runInContext(bridgeCode, r.context);
    r.tick();
    assert.equal(r.received('lampaLifecycle').filter(x => x.status === 'ready').length, 1);
    assert.equal(r.playerListener.count('create'), 1);
});

test('ready handshake binds playback and resolver ownership before native restoration without timer ordering', () => {
    const r = runtime({ autoTick: false, deferResolverModules: true });
    assert.equal(r.received('lampaLifecycle').length, 0);
    assert.equal(r.playerListener.count('create'), 0);
    assert.equal(r.context.Lampa.Reguest.__ilampaSelectionBound, undefined);
    assert.equal(r.context.Lampa.Template.get.__ilampaOnlineModBound, undefined);
    r.bridge.notifyAppReady();
    assert.equal(r.received('lampaLifecycle').filter(x => x.status === 'ready').length, 1);
    assert.equal(r.playerListener.count('create'), 1);
    assert.equal(r.context.Lampa.Reguest.__ilampaSelectionBound, true);
    assert.equal(r.context.Lampa.Template.get.__ilampaOnlineModBound, true);
    r.tick();
    assert.equal(r.playerListener.count('create'), 1);
    assert.equal(r.received('lampaLifecycle').filter(x => x.status === 'ready').length, 1);
});

test('pre-ready search is structured, queues no retry, and becomes ready only on real ready state', () => {
    const r = runtime({ ready: false });
    r.listener.send('app', { type: 'ready' });
    assert.equal(r.received('lampaLifecycle').length, 0);
    assert.deepEqual(plain(r.search()), { success: false, error: 'not-ready' });
    assert.equal(r.timeouts.size, 0);
    r.context.appready = true;
    r.listener.send('app', { type: 'ready' });
    assert.equal(r.received('lampaLifecycle').length, 1);
    assert.equal(r.search().success, true);
});

test('original Lampa Activity opens the selected installed plugin component, not forced Online Mod', () => {
    const r = runtime(); r.show();
    r.components.online_fxapi = {};
    const result = r.search({ component: 'online_fxapi' });
    assert.equal(result.success, true);
    assert.equal(r.context.Lampa.Activity.active().component, 'online_fxapi');
    // No playback before actual user selection.
    assert.equal(r.received('lampaNative').length, 0);
});

test('Filmix-style series playback without season and episode is explicitly unidentified', () => {
    const r = runtime(); r.show();
    r.search({ id: 1399, title: 'Show', mediaType: 'tv',
        canonicalId: 'urn:media:tmdb:tv:1399', season: 1, episode: 1 });
    r.context.Lampa.Activity.push({ component: 'online_fxapi', source: 'tmdb', mediaType: 'tv',
        canonicalId: 'urn:media:tmdb:tv:1399', season: 1, episode: 1,
        movie: { id: 1399, media_type: 'tv', name: 'Show' } });
    const filmixRow = element('filmix');
    filmixRow.classes.delete('online');
    filmixRow.classes.add('online-prestige');
    filmixRow.classes.add('online-prestige--full');
    r.dispatch(filmixRow, () => r.play({
        url: 'https://stream.test/filmix-series.m3u8', title: 'Episode 7',
        timeline: { time: 120, duration: 2400, hash: 'filmix-episode-7' }
    }));
    const selections = r.received('lampaSelection');
    const streams = r.received('lampaNative');
    assert.equal(selections.length, 1);
    assert.equal(streams.length, 1);
    assert.equal(streams[0].url, 'https://stream.test/filmix-series.m3u8');
    assert.equal(streams[0].pluginId, 'online_fxapi');
    assert.equal(streams[0].mediaType, 'tv');
    assert.equal(streams[0].season, null);
    assert.equal(streams[0].episode, null);
    assert.equal(streams[0].time, 120);
});

test('Filmix folder selectors are navigation, not media selection', () => {
    const r = runtime(); r.show(); r.search();
    r.context.Lampa.Activity.push({ component: 'online_fxapi', source: 'tmdb',
        mediaType: 'movie', canonicalId: 'urn:media:tmdb:movie:550',
        movie: { id: 550, media_type: 'movie' } });
    const folderRow = element('filmix');
    folderRow.classes.delete('online');
    folderRow.classes.add('online-prestige--folder');
    r.dispatch(folderRow, () => r.play({ url: 'https://stream.test/ambiguous-folder' }));
    assert.equal(r.received('lampaNative').length, 0);
});

test('generic plugin component selected by a trusted gesture reaches native playback', () => {
    const r = runtime(); r.show(); r.search();
    r.context.Lampa.Activity.push({ component: 'online_fxapi', source: 'tmdb',
        mediaType: 'movie', canonicalId: 'urn:media:tmdb:movie:550',
        movie: { id: 550, media_type: 'movie' } });
    const pluginRow = element('generic');
    pluginRow.classes.delete('online');
    r.dispatch(pluginRow, () => r.play({
        url: 'https://stream.test/filmix.m3u8', movie: { id: 550, media_type: 'movie' }
    }));
    assert.equal(r.received('lampaSelection').length, 1);
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(r.received('lampaNative')[0].url, 'https://stream.test/filmix.m3u8');
    assert.equal(r.received('lampaNative')[0].pluginId, 'online_fxapi');
});

test('generic plugin without a user gesture cannot start playback', () => {
    const r = runtime(); r.show(); r.search();
    r.context.Lampa.Activity.push({ component: 'online_fxapi', source: 'tmdb',
        mediaType: 'movie', canonicalId: 'urn:media:tmdb:movie:550',
        movie: { id: 550, media_type: 'movie' } });
    assert.equal(r.play({ url: 'https://stream.test/unsolicited' }), true);
    assert.equal(r.received('lampaNative').length, 0);
});

test('visible pre-ready playback cannot create selection intent or start native media', () => {
    const r = runtime({ ready: false }); r.show();
    r.context.Lampa.Activity.push({ component: 'online_mod', mediaType: 'movie',
        canonicalId: 'urn:media:tmdb:movie:550', movie: { id: 550, media_type: 'movie' } });
    r.dispatch(element(), () => r.play({ url: 'https://stream.test/pre-ready' }));
    assert.equal(r.received('lampaSelection').length, 0);
    assert.equal(r.received('lampaNative').length, 0);
});

test('movie identity is not converted into TV and carries TMDB metadata', () => {
    const r = runtime();
    assert.equal(r.search().success, true);
    const active = r.context.Lampa.Activity.active();
    assert.equal(active.movie.name, undefined);
    assert.equal(active.movie.title, 'Fight Club');
    assert.equal(active.movie.release_date, '1999-10-15');
    assert.equal(active.movie.source, 'tmdb');
    assert.equal(active.source, 'tmdb');
    assert.equal(active.canonicalId, 'urn:media:tmdb:movie:550');
});

test('TV identity carries original_name, first_air_date, season and episode', () => {
    const r = runtime();
    assert.equal(r.search({ id: 1399, title: 'Show', original_name: 'Original Show', mediaType: 'tv',
        canonicalId: 'urn:media:tmdb:tv:1399', first_air_date: '2011-04-17', season: 2, episode: 3 }).success, true);
    const active = r.context.Lampa.Activity.active();
    assert.equal(active.movie.name, 'Show');
    assert.equal(active.movie.original_name, 'Original Show');
    assert.equal(active.movie.title, undefined);
    assert.equal(active.movie.first_air_date, '2011-04-17');
    assert.equal(active.season, 2);
    assert.equal(active.episode, 3);
});

test('unadapted TV components cannot label an unknown selected episode with the native initial episode', () => {
    const r = runtime(); r.show();
    assert.equal(r.search({ component: 'online', mediaType: 'tv', canonicalId: 'urn:media:tmdb:tv:550', season: 1, episode: 1 }).success, true);
    r.dispatch(element(), () => r.play({ url: 'https://stream.test/unknown-selected-episode.m3u8' }));
    assert.equal(r.received('lampaSelection').length, 0);
    assert.equal(r.received('lampaNative').length, 0);
});

test('late OnlineMod playlist retains callback entries and resolves the second episode in its JS session', async () => {
    const r = runtime(); r.show();
    r.search({ id: 1399, title: 'Show', mediaType: 'tv',
        canonicalId: 'urn:media:tmdb:tv:1399', season: 1, episode: 1 });
    const row = r.onlineModRow({ season: 1, episode: 1, translate_voice: 'Studio Dub' });
    r.dispatch(row, () => r.play({ url: 'https://stream.test/show-episode-1.m3u8', season: 1, episode: 1 }));
    const play = r.received('lampaNative')[0];
    assert.equal(play.runtimeOrigin, 'lampa_core');
    assert.equal(play.providerId, 'online_mod');
    assert.equal(play.plugin, 'online_mod');
    assert.equal(play.playlist, null);
    const originalCallbackItem = {
        title: 'Episode 2', season: 1, episode: 2,
        url(callback) {
            this.url = 'https://stream.test/show-episode-2-new.m3u8';
            callback();
        }
    };
    r.context.Lampa.Player.playlist([
        { title: 'Episode 1', season: 1, episode: 1, url: play.url },
        originalCallbackItem
    ]);
    const updates = r.received('lampaPlaylist');
    assert.equal(updates.length, 1);
    assert.equal(updates[0].requestId, play.requestId);
    assert.equal(updates[0].playlist[1].deferred, true);
    assert.equal(updates[0].playlist[1].url, '');
    const resolved = await r.bridge.resolvePlaylistItem(play.requestId, updates[0].playlist[1].itemId);
    assert.deepEqual(plain(resolved), {
        success: true, url: 'https://stream.test/show-episode-2-new.m3u8'
    });
    assert.equal(originalCallbackItem.url, resolved.url);
});

test('stale deferred stream completion cannot migrate to a newer playback selection', async () => {
    const r = runtime(); r.show();
    r.search({ id: 1399, title: 'Show', mediaType: 'tv',
        canonicalId: 'urn:media:tmdb:tv:1399', season: 1, episode: 1 });
    const row = r.onlineModRow({ season: 1, episode: 1, translate_voice: 'Studio Dub' });
    r.dispatch(row, () => r.play({ url: 'https://stream.test/first.m3u8', season: 1, episode: 1 }));
    const initial = r.received('lampaNative')[0];
    let lateCallback;
    const stale = { season: 1, episode: 2, title: 'Episode 2',
        url(callback) { lateCallback = callback; } };
    r.context.Lampa.Player.playlist([{ url: initial.url, episode: 1 }, stale]);
    const itemId = r.received('lampaPlaylist')[0].playlist[1].itemId;
    const pending = r.bridge.resolvePlaylistItem(initial.requestId, itemId);
    r.dispatch(row, () => r.play({ url: 'https://stream.test/new-session.m3u8', season: 1, episode: 1 }));
    stale.url = 'https://stream.test/old-completion.m3u8';
    lateCallback();
    assert.deepEqual(plain(await pending), { success: false, error: 'stale-session' });
});

test('OnlineMod selected episode and voice override initial activity metadata and survive Player.play omission', () => {
    const r = runtime(); r.show();
    r.search({ id: 1399, title: 'Show', original_name: 'Original Show', mediaType: 'tv',
        canonicalId: 'urn:media:tmdb:tv:1399', season: 1, episode: 1 });
    const row = r.onlineModRow({ season: '3', episode: '7', translate_voice: 'Studio Dub' });
    r.dispatch(row, () => r.play({ url: 'https://stream.test/s03e07' }));
    const selection = r.received('lampaSelection')[0];
    const play = r.received('lampaNative')[0];
    assert.equal(selection.season, 3);
    assert.equal(selection.episode, 7);
    assert.equal(selection.audio, 'Studio Dub');
    assert.equal(play.season, 3);
    assert.equal(play.episode, 7);
    assert.equal(play.currentStudio, 'Studio Dub');
});

test('OnlineMod TV selection without exact episode row metadata fails closed', () => {
    const r = runtime(); r.show();
    r.search({ id: 1399, title: 'Show', mediaType: 'tv', canonicalId: 'urn:media:tmdb:tv:1399', season: 1, episode: 1 });
    const row = r.onlineModRow({ title: 'Episode-looking text only' });
    r.dispatch(row, () => r.play({ url: 'https://stream.test/ambiguous' }));
    assert.equal(r.received('lampaSelection').length, 0);
    assert.equal(r.received('lampaNative').length, 0);
});

test('stale OnlineMod resolver cannot relabel a newer episode or audio selection', () => {
    const r = runtime(); r.show();
    r.search({ id: 1399, title: 'Show', mediaType: 'tv', canonicalId: 'urn:media:tmdb:tv:1399' });
    const request = new r.context.Lampa.Reguest();
    r.dispatch(r.onlineModRow({ season: 2, episode: 4, translate_voice: 'Old Dub' }), () =>
        request.native('https://resolver.test/old', () => r.play({ url: 'https://stream.test/old' })));
    r.dispatch(r.onlineModRow({ season: 5, episode: 9, translate_voice: 'New Dub' }), () =>
        request.native('https://resolver.test/new', () => r.play({ url: 'https://stream.test/new' })));
    r.requests[0].success({});
    r.requests[1].success({});
    const play = r.received('lampaNative')[0];
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(play.url, 'https://stream.test/new');
    assert.equal(play.season, 5);
    assert.equal(play.episode, 9);
    assert.equal(play.currentStudio, 'New Dub');
});

test('default search prefers registered online_mod, then falls back to online without sample source', () => {
    const r = runtime();
    assert.equal(r.search({ component: undefined }).success, true);
    assert.equal(r.context.Lampa.Activity.active().component, 'online_mod');
    delete r.components.online_mod;
    assert.equal(r.search({ component: undefined }).success, true);
    assert.equal(r.context.Lampa.Activity.active().component, 'online');
});

test('missing component and invalid identity fail explicitly, with no sample-source preference', () => {
    const r = runtime();
    delete r.components.online;
    delete r.components.online_mod;
    assert.deepEqual(plain(r.search({ component: undefined })), {
        success: false, error: 'missing-component', component: 'online'
    });
    assert.equal(r.context.Lampa.Activity.active(), null);
    assert.equal(r.search({ mediaType: undefined }).error, 'invalid-identity');
    assert.equal(r.search({ id: 0 }).error, 'invalid-identity');
});

test('background and forged public-route requests cannot start native playback', () => {
    const r = runtime();
    r.search();
    r.dispatch(element(), () => assert.equal(r.play({ url: 'https://stream.test/movie.m3u8' }), true));
    r.show();
    assert.equal(r.bridge.routePlaybackToNative({ url: 'https://stream.test/forged', requestId: 'forged' }), false);
    assert.equal(r.received('lampaSelection').length, 0);
    assert.equal(r.received('lampaNative').length, 0);
});

test('synthetic clicks and DOM navigation rows are not stream authorization', () => {
    const r = runtime(); r.show(); r.search();
    r.dispatch(element(), () => r.play({ url: 'https://stream.test/movie' }), { trusted: false });
    assert.equal(r.received('lampaNative').length, 0);
    assert.equal(r.bridge.selectDiscoveredSource(0).error, 'trusted-selection-required');
    r.document.rows = [element()];
    r.mutations[0]();
    const discovery = r.received('lampaSourcesDiscovered')[0];
    assert.equal(discovery.navigationOnly, true);
    assert.equal(discovery.sources[0].navigationOnly, true);
    assert.equal(discovery.sources[0].url, undefined);
});

test('discovery uses explicit Online Mod voice metadata without inferring from labels', () => {
    const r = runtime(); r.search();
    r.document.rows = [
        r.onlineModRow({ media: { voiceStudio: '  Studio Dub  ', voiceType: 'Other' } }),
        r.onlineModRow({ media: { voiceType: 'Original' } }),
        r.onlineModRow({ title: 'Not necessarily a voice' }),
        r.onlineModRow({ translate_voice: 'Explicit', media: { voiceStudio: 'Other' } }),
        r.onlineModRow({ media: { translation_name: 'Dub translation' } }),
        r.onlineModRow({ media: { voice_name: 'Voice name' } }),
        r.onlineModRow({ media: { translation_name: 12, voice_name: '   ' } })
    ];
    r.mutations[0]();
    const rows = r.received('lampaSourcesDiscovered')[0].sources;
    assert.deepEqual(rows.map(row => row.voice), ['Studio Dub', 'Original', '', 'Explicit', 'Dub translation', 'Voice name', '']);
    assert.ok(rows.every(row => row.navigationOnly && row.url === undefined));
});

test('unowned callbacks cannot consume an already pending native selection', () => {
    for (const wrapped of [false, true]) {
        const r = runtime(); r.search({ requestId: 'search-1' });
        const request = new r.context.Lampa.Reguest();
        const old = () => r.play({ url: 'https://stream.test/unowned-old' });
        if (wrapped) request.native('https://resolver.test/background', old);
        const row = element(); r.document.rows = [row]; r.mutations[0]();
        const token = r.received('lampaSourcesDiscovered').at(-1).sources[0].rowToken;
        r.context.$ = () => ({ trigger() {
            request.native('https://resolver.test/selected', () => r.play({ url: 'https://stream.test/selected' }));
        } });
        assert.equal(r.bridge.selectHeadlessSource(0, 'selected', 'search-1', token).success, true);
        if (wrapped) r.requests[0].success({}); else old();
        assert.equal(r.received('lampaNative').length, 0);
        r.requests.at(-1).success({});
        assert.equal(r.received('lampaNative').length, 1);
        assert.equal(r.received('lampaNative')[0].url, 'https://stream.test/selected');
    }
});

test('superseded and cancelled root search callbacks cannot publish rows for a newer movie', () => {
    for (const previous of ['superseded', 'cancelled']) {
        const r = runtime();
        let oldCalls = 0;
        const push = r.context.Lampa.Activity.push;
        r.context.Lampa.Activity.push = function (params) {
            push(params);
            const request = new r.context.Lampa.Reguest();
            request.native('https://provider.test/old-search', () => {
                oldCalls++; r.document.rows = [r.onlineModRow({ translate_voice: 'Old movie' })];
            });
        };
        r.search({ requestId: 'old-search' });
        if (previous === 'cancelled') r.bridge.clearActiveSearchContext();
        r.search({ id: 999, canonicalId: 'urn:media:tmdb:movie:999', requestId: 'new-search' });
        r.requests[0].success({}); r.mutations[0]();
        assert.equal(oldCalls, 0);
        assert.equal(r.received('lampaSourcesDiscovered').at(-1).sources.length, 0);
        assert.equal(r.received('lampaNative').length, 0);
    }
});

test('unrelated requests are not cancelled merely because a native search changed', () => {
    const r = runtime();
    let calls = 0;
    const unrelated = new r.context.Lampa.Reguest();
    unrelated.native('https://metadata.test/background', () => calls++);
    r.search({ requestId: 'search-1' });
    unrelated.native('https://metadata.test/background-2', () => calls++);
    r.search({ id: 999, canonicalId: 'urn:media:tmdb:movie:999', requestId: 'search-2' });
    r.requests[0].success({}); r.requests[1].success({});
    assert.equal(calls, 2);
    assert.equal(r.received('lampaNative').length, 0);
});

test('native selection binds async resolver to the discovered row and rejects stale rows', () => {
    const r = runtime();
    r.search({ requestId: 'search-1' });
    const row = element();
    r.document.rows = [row];
    r.mutations[0]();
    const token = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
    const request = new r.context.Lampa.Reguest();
    r.context.$ = target => ({ trigger(name) {
        assert.equal(target, row);
        assert.equal(name, 'hover:enter');
        request.native('https://resolver.test', () => r.play({ url: 'https://stream.test/video.m3u8' }));
    } });
    assert.equal(r.bridge.selectHeadlessSource(0, 'selection-1', 'search-1', token).success, true);
    r.requests[0].success({});
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(r.received('lampaNative')[0].requestId, 'selection-1');
    r.document.rows = [element()];
    assert.equal(r.bridge.selectHeadlessSource(0, 'selection-2', 'search-1', token).error, 'source-changed');
    assert.equal(r.bridge.selectHeadlessSource(0, 'selection-3', 'different-search', token).error, 'search-context-mismatch');
});

test('folder navigation invokes its callback without authorizing playback', () => {
    const r = runtime(); r.search({ requestId: 'search-1' });
    const folder = element('folder');
    r.document.rows = [folder];
    r.mutations[0]();
    const token = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
    let calls = 0;
    r.context.$ = target => ({ trigger(name) {
        assert.equal(target, folder);
        assert.equal(name, 'hover:enter');
        calls++;
        r.play({ url: 'https://stream.test/unauthorized' });
        r.document.rows = [element()];
    } });
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'wrong-search', token).error, 'search-context-mismatch');
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'search-1', token).success, true);
    assert.equal(calls, 1);
    assert.equal(r.received('lampaSelection').length, 0);
    assert.equal(r.received('lampaNative').length, 0);
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'search-1', token).error, 'source-changed');
});

test('real Online Mod folder template is navigation even without a folder CSS class', () => {
    const r = runtime(); r.search({ requestId: 'search-1' });
    const folder = element();
    r.context.Lampa.Template.get('online_mod_folder', { row: folder, title: 'Show more', quality: '...' });
    r.document.rows = [folder];
    r.mutations[0]();
    const discovered = r.received('lampaSourcesDiscovered')[0].sources[0];
    assert.equal(discovered.isFolder, true);
    assert.equal(r.bridge.selectHeadlessSource(0, 'selection-1', 'search-1', discovered.rowToken).error, 'folder-not-playable');
    let opened = false;
    r.context.$ = target => ({ trigger() { assert.equal(target, folder); opened = true; r.document.rows = [element()]; } });
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'search-1', discovered.rowToken).success, true);
    assert.equal(opened, true);
    assert.equal(r.received('lampaNative').length, 0);
});

test('folder navigation invalidates an older asynchronous playback selection', () => {
    const r = runtime(); r.search({ requestId: 'search-1' });
    const playable = element();
    const folder = element('folder');
    r.document.rows = [playable, folder];
    r.mutations[0]();
    const rows = r.received('lampaSourcesDiscovered')[0].sources;
    const request = new r.context.Lampa.Reguest();
    r.context.$ = target => ({ trigger() {
        if (target === playable) request.native('https://resolver.test', () => r.play({ url: 'https://stream.test/late' }));
        else r.document.rows = [element()];
    } });
    assert.equal(r.bridge.selectHeadlessSource(0, 'selection-1', 'search-1', rows[0].rowToken).success, true);
    assert.equal(r.bridge.navigateHeadlessFolder(1, 'search-1', rows[1].rowToken).success, true);
    r.requests[0].success({});
    assert.equal(r.received('lampaNative').length, 0);
});

test('synchronous folder stages expose only fresh tokens and support nesting', () => {
    const r = runtime(); r.search({ requestId: 'search-1' });
    const root = element('folder'), nested = element('folder'), final = element();
    r.document.rows = [root]; r.mutations[0]();
    const token = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
    r.context.$ = target => ({ trigger() { r.document.rows = [target === root ? nested : final]; } });
    const first = r.bridge.navigateHeadlessFolder(0, 'search-1', token);
    assert.equal(first.success, true);
    assert.equal(first.sources[0].isFolder, true);
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'search-1', token).error, 'source-changed');
    const second = r.bridge.navigateHeadlessFolder(0, 'search-1', first.sources[0].rowToken);
    assert.equal(second.success, true);
    assert.equal(second.sources[0].isFolder, false);
});

test('folder changing search title or returning asynchronous rows fails closed', () => {
    for (const changesTitle of [true, false]) {
        const r = runtime(); r.search({ requestId: 'search-1' });
        const folder = element('folder'); r.document.rows = [folder]; r.mutations[0]();
        const token = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
        r.context.$ = () => ({ trigger() {
            if (changesTitle) r.context.Lampa.Activity.active().search = 'Different title';
            r.document.rows = [];
        } });
        const result = r.bridge.navigateHeadlessFolder(0, 'search-1', token);
        assert.equal(result.error, changesTitle ? 'identity-changed' : 'unverified-async-navigation');
        r.document.rows = [element()]; r.mutations[0]();
        assert.equal(result.sources, undefined);
    }
});

test('owned pagination propagates operation through delayed request callbacks and nested stages', () => {
    const r = runtime(), owner = 'https://plugins.test/online_mod.js';
    r.context.__ilampaExecutingPluginURL = owner;
    r.context.Lampa.Component.add('online_mod', function() {});
    r.context.__ilampaExecutingPluginURL = null;
    r.search({ requestId: 'search-1' });
    function folder() { return r.context.Lampa.Template.get('online_mod_folder', {row: element(), quality: '...'}); }
    const root = folder(); r.document.rows = [root]; r.mutations[0]();
    const rootToken = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
    const request = new r.context.Lampa.Reguest();
    let finalRow;
    r.context.$ = target => ({ trigger() {
        if (target === finalRow) {
            request.native('https://provider.test/play', () => r.play({url: 'https://stream.test/final.m3u8'}));
            return;
        }
        r.document.rows = [];
        request.native('https://provider.test', () => {
            if (target === root) r.document.rows = [folder()];
            else { finalRow = r.onlineModRow({translate_voice: 'Dub'}); r.document.rows = [finalRow]; }
        });
    } });
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'search-1', rootToken, 'stage-1', owner).pending, true);
    assert.equal(r.bridge.folderOperationSnapshot('stage-1').pending, true);
    r.requests[0].success({});
    const first = r.bridge.folderOperationSnapshot('stage-1');
    assert.equal(first.sources[0].isFolder, true);
    assert.equal(first.parent, 'search-1');
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'search-1', first.sources[0].rowToken, 'stage-2', owner).pending, true);
    r.requests[1].success({});
    const second = r.bridge.folderOperationSnapshot('stage-2');
    assert.equal(second.parent, 'stage-1');
    assert.equal(second.sources[0].voice, 'Dub');
    assert.equal(second.sources[0].isFolder, false);
    r.requests[0].success({}); // stale parent callback cannot mutate the new stage
    assert.equal(r.bridge.folderOperationSnapshot('stage-2').sources[0].voice, 'Dub');
    assert.equal(r.bridge.selectHeadlessSource(0, 'play-1', 'search-1', second.sources[0].rowToken).success, true);
    r.requests[2].success({}); r.requests[2].success({});
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(r.received('lampaSelection')[0].audio, 'Dub');
    r.bridge.cancelFolderOperation('stage-2');
    r.requests[1].success({});
    assert.equal(r.bridge.folderOperationSnapshot('stage-2').error, 'operation-invalid');
});

test('unverified similar titles are not silently assigned the root identity', () => {
    const r = runtime(); r.search({ requestId: 'search-1' });
    const folder = r.context.Lampa.Template.get('online_mod_folder', {row: element(), title: 'Other film', id: 42, quality: '2024'});
    r.document.rows = [folder]; r.mutations[0]();
    const discovered = r.received('lampaSourcesDiscovered')[0].sources[0];
    assert.equal(discovered.isAlternative, true);
    const token = discovered.rowToken;
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'search-1', token).error, 'alternative-unverified');
});

test('delayed folder callback is suppressed after episode change or cancellation', () => {
    for (const cancel of [false, true]) {
        const r = runtime(), owner = 'https://plugins.test/online_mod.js';
        r.context.__ilampaExecutingPluginURL = owner;
        r.context.Lampa.Component.add('online_mod', function() {});
        r.context.__ilampaExecutingPluginURL = null;
        r.search({ requestId: 'tv-search', mediaType: 'tv', canonicalId: 'urn:media:tmdb:tv:550', season: 2, episode: 3 });
        const folder = r.context.Lampa.Template.get('online_mod_folder', {row: element(), quality: '...'});
        r.document.rows = [folder]; r.mutations[0]();
        const token = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
        const request = new r.context.Lampa.Reguest();
        let called = false;
        r.context.$ = () => ({ trigger() { r.document.rows = []; request.native('https://provider.test', () => { called = true; }); } });
        assert.equal(r.bridge.navigateHeadlessFolder(0, 'tv-search', token, 'stage-1', owner).pending, true);
        if (cancel) r.bridge.cancelFolderOperation('stage-1');
        else r.context.Lampa.Activity.active().episode = 4;
        r.requests[0].success({});
        assert.equal(called, false);
        assert.equal(r.bridge.folderOperationSnapshot('stage-1').error, 'operation-invalid');
    }
});

test('pagination refuses DOM rows not constructed by its request callback', () => {
    const r = runtime(), owner = 'https://plugins.test/online_mod.js';
    r.context.__ilampaExecutingPluginURL = owner;
    r.context.Lampa.Component.add('online_mod', function() {});
    r.context.__ilampaExecutingPluginURL = null;
    r.search({ requestId: 'search-1' });
    const folder = r.context.Lampa.Template.get('online_mod_folder', {row: element(), quality: '...'});
    r.document.rows = [folder]; r.mutations[0]();
    const token = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
    const request = new r.context.Lampa.Reguest();
    r.context.$ = () => ({trigger() { r.document.rows = []; request.native('https://provider.test', () => {}); }});
    assert.equal(r.bridge.navigateHeadlessFolder(0, 'search-1', token, 'stage-1', owner).pending, true);
    r.document.rows = [r.onlineModRow({})]; // unrelated mutation, outside the callback
    r.requests[0].success({});
    assert.equal(r.bridge.folderOperationSnapshot('stage-1').error, 'unattributed-rows');
});

test('cancelled headless selection cannot deliver a late resolver callback', () => {
    const r = runtime();
    r.search({ requestId: 'search-1' });
    r.document.rows = [element()];
    r.mutations[0]();
    const token = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
    const request = new r.context.Lampa.Reguest();
    r.context.$ = () => ({ trigger() { request.native('https://resolver.test', () => r.play({ url: 'https://stream.test/late' })); } });
    assert.equal(r.bridge.selectHeadlessSource(0, 'selection-1', 'search-1', token).success, true);
    r.bridge.cancelHeadlessSelection('selection-1');
    r.requests[0].success({});
    assert.equal(r.received('lampaNative').length, 0);
});

test('native TV selection rejects absent or mismatched episode identity', () => {
    const r = runtime();
    r.search({ requestId: 'tv-search', mediaType: 'tv', canonicalId: 'urn:media:tmdb:tv:550', season: 2, episode: 3 });
    const row = r.onlineModRow({ season: 2, episode: 4 });
    r.document.rows = [row];
    r.mutations[0]();
    const token = r.received('lampaSourcesDiscovered')[0].sources[0].rowToken;
    assert.equal(r.bridge.selectHeadlessSource(0, 'selection-1', 'tv-search', token).error, 'episode-mismatch');
    assert.equal(r.received('lampaSelection').length, 0);
    assert.equal(r.received('lampaNative').length, 0);
});

test('trusted explicit playback posts selection first, preserves exact URL/headers/subtitles, and is single-use', () => {
    const r = runtime(); r.show(); r.search();
    const url = 'https://stream.test/selected-480.m3u8?token=exact&quality=480';
    const headers = { Referer: 'https://provider.test/watch', Authorization: 'Bearer exact' };
    const subtitles = [{ label: 'English', url: 'https://stream.test/exact.vtt?lang=en' }];
    const data = { url, title: 'Selected', headers, subtitles,
        quality: { '2160p': 'https://stream.test/NOT-selected.m3u8' } };
    r.dispatch(element(), () => { assert.equal(r.play(data), true); r.play(data); });
    const selection = r.received('lampaSelection');
    const plays = r.received('lampaNative');
    assert.equal(selection.length, 1);
    assert.equal(plays.length, 1);
    assert.equal(plays[0].url, url);
    assert.deepEqual(plays[0].customHeaders, headers);
    assert.deepEqual(plays[0].availableSubtitles, subtitles);
    for (const key of ['requestId', 'canonicalId', 'mediaType', 'pluginId', 'selectionContext', 'generation', 'documentToken']) {
        assert.equal(plays[0][key], selection[0][key]);
    }
    assert.equal(plays[0].mediaType, 'movie');
    assert.equal(plays[0].pluginId, 'online_mod');
    assert.ok(r.messages.findIndex(x => x.name === 'lampaSelection') < r.messages.findIndex(x => x.name === 'lampaNative'));
});

test('quality-only, mismatched-card, folder, unsupported scheme and missing-abort events are rejected', () => {
    const r = runtime(); r.show(); r.search();
    for (const data of [
        { quality: { '2160p': 'https://stream.test/guess' } },
        { url: 'https://stream.test/wrong-title', movie: { id: 999 } },
        { url: 'file:///private/file.mp4' },
        { url: 'https://sylvan.apple.com/videos/aerial/test.mov' }
    ]) r.dispatch(element(), () => r.play(data));
    r.dispatch(element('folder'), () => r.play({ url: 'https://stream.test/folder' }));
    r.dispatch(element(), () => r.play({ url: 'https://stream.test/no-abort' }, false));
    assert.equal(r.received('lampaNative').length, 0);
});

test('generic async Player callbacks cannot borrow an expired or newer trusted dispatch', async () => {
    const r = runtime(); r.show(); r.search();
    let oldResolver;
    r.dispatch(element(), () => { oldResolver = () => r.play({ url: 'https://stream.test/old' }); });
    await flush();
    oldResolver();
    r.dispatch(element(), () => {});
    oldResolver();
    assert.equal(r.received('lampaNative').length, 0);
});

test('actual shipped Player create contract supplies data and a synchronous abort callback', () => {
    const start = appCode.indexOf('  function play$1(data) {');
    const end = appCode.indexOf("    console.log('Player', 'start play');", start);
    assert.ok(start >= 0 && end > start);
    const r = runtime(); r.show(); r.search();
    const context = {
        listener$7: { send(name, event) { assert.equal(name, 'create'); r.playerListener.send(name, event); } },
        console: { log() {} }
    };
    vm.createContext(context);
    vm.runInContext(appCode.slice(start, end) + "return 'unaborted';\n}\nthis.actualPlay = play$1;", context);
    r.dispatch(element(), () => assert.equal(context.actualPlay({ url: 'https://stream.test/actual' }), undefined));
    assert.equal(r.received('lampaNative')[0].url, 'https://stream.test/actual');
});

test('actual Reguest callback positions carry one immutable selection across nested async resolution', () => {
    const r = runtime(); r.show(); r.search();
    const request = new r.context.Lampa.Reguest();
    r.dispatch(element(), () => request.timeout(5000).native('https://resolver.test/first', () => {
        request.silent('https://resolver.test/second', () => r.play({
            url: 'https://stream.test/explicit', headers: { Referer: 'https://resolver.test' }
        }), false, { step: 2 }, { timeout: 3000 });
    }));
    assert.equal(r.received('lampaSelection').length, 1);
    const selected = r.received('lampaSelection')[0];
    r.requests[0].success({});
    assert.equal(r.requests[1].data.step, 2);
    assert.equal(r.requests[1].options.timeout, 3000);
    r.requests[1].success({});
    r.requests[1].success({});
    assert.equal(r.received('lampaSelection').length, 1);
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(r.received('lampaNative')[0].requestId, selected.requestId);
});

test('stale Reguest callback cannot borrow a newer dispatch or mutate selected identity', () => {
    const r = runtime(); r.show(); r.search();
    const request = new r.context.Lampa.Reguest();
    const card = { id: 550, media_type: 'movie' };
    r.dispatch(element(), () => request.native('https://resolver.test/old', () => r.play({
        url: 'https://stream.test/old', movie: card
    })));
    r.search({ id: 999, canonicalId: 'urn:media:tmdb:movie:999' });
    r.dispatch(element(), () => {
        r.requests[0].success({});
        r.play({ url: 'https://stream.test/new' });
    });
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(r.received('lampaNative')[0].canonicalId, 'urn:media:tmdb:movie:999');
    assert.equal(r.received('lampaNative')[0].url, 'https://stream.test/new');
});

test('unowned Reguest callback cannot consume a coincident trusted selection', () => {
    const r = runtime(); r.show(); r.search();
    const request = new r.context.Lampa.Reguest();
    request.native('https://resolver.test/background', () => r.play({ url: 'https://stream.test/background' }));
    r.dispatch(element(), () => r.requests[0].success({}));
    assert.equal(r.received('lampaNative').length, 0);
    assert.equal(r.received('lampaSelection').length, 0);
});

test('programmatic activity changes invalidate resolver ownership without a new trusted click', () => {
    const r = runtime(); r.show(); r.search();
    const request = new r.context.Lampa.Reguest();
    r.dispatch(element(), () => request.native('https://resolver.test', () => r.play({ url: 'https://stream.test/stale' })));
    r.context.Lampa.Activity.push({ component: 'online_mod', movie: { id: 999, media_type: 'movie' } });
    r.requests[0].success({});
    assert.equal(r.received('lampaNative').length, 0);
});

test('mutating the active movie object cannot relabel an already captured resolver identity', () => {
    const r = runtime(); r.show(); r.search();
    const request = new r.context.Lampa.Reguest();
    r.dispatch(element(), () => request.native('https://resolver.test', () => r.play({ url: 'https://stream.test/stale' })));
    r.context.Lampa.Activity.active().movie.id = 999;
    r.requests[0].success({});
    assert.equal(r.received('lampaNative').length, 0);
});

test('resolver intent expires without authorizing a late stream', () => {
    const r = runtime(); r.show(); r.search();
    const request = new r.context.Lampa.Reguest();
    r.dispatch(element(), () => request.native('https://resolver.test', () => r.play({ url: 'https://stream.test/late' })));
    r.clock.now += 30001;
    r.requests[0].success({});
    assert.equal(r.received('lampaNative').length, 0);
});

test('trusted Enter is supported but other keys do not authorize playback', () => {
    const r = runtime(); r.show(); r.search();
    r.dispatch(element(), () => r.play({ url: 'https://stream.test/no' }), { type: 'keydown', key: 'ArrowDown' });
    r.dispatch(element(), () => r.play({ url: 'https://stream.test/yes' }), { type: 'keydown', key: 'Enter' });
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(r.received('lampaNative')[0].url, 'https://stream.test/yes');
});

test('Soma captures immutable async intent and never invokes private HTML5 playback', async () => {
    const r = runtime(); r.show();
    const adapter = soma(r);
    const urls = deferred();
    const station = { id: 'groovesalad', title: 'Groove Salad', stream: { urls: urls.promise } };
    r.dispatch(element('soma'), () => adapter.player.play(station));
    const selection = r.received('lampaSelection')[0];
    assert.equal(selection.canonicalId, 'somafm_groovesalad');
    assert.equal(selection.mediaType, 'audio');
    assert.equal(r.received('lampaNative').length, 0);
    station.id = 'mutated'; station.title = 'Mutated title';
    urls.resolve(['https://ice.test/selected-aac']);
    await flush();
    const payload = r.received('lampaNative')[0];
    assert.equal(payload.requestId, selection.requestId);
    assert.equal(payload.canonicalId, 'somafm_groovesalad');
    assert.equal(payload.title, 'SomaFM: Groove Salad');
    assert.equal(payload.url, 'https://ice.test/selected-aac');
    assert.equal(adapter.originalCalls(), 0);
    assert.equal(adapter.destroyed(), 1);
});

test('slow old Soma result cannot steal a newer station selection', async () => {
    const r = runtime(); r.show(); const { player } = soma(r);
    const old = deferred(); const next = deferred();
    r.dispatch(element('soma'), () => player.play({ id: 'old', stream: { urls: old.promise } }));
    r.dispatch(element('soma'), () => player.play({ id: 'new', stream: { urls: next.promise } }));
    old.resolve(['https://ice.test/old']); await flush();
    assert.equal(r.received('lampaNative').length, 0);
    next.resolve(['https://ice.test/new']); await flush();
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(r.received('lampaNative')[0].canonicalId, 'somafm_new');
});

for (const reason of ['dismiss', 'hidden', 'pagehide', 'new-search', 'new-interaction']) {
    test(`Soma pending intent is invalidated by ${reason}`, async () => {
        const r = runtime(); r.show(); const { player } = soma(r); const urls = deferred();
        r.dispatch(element('soma'), () => player.play({ id: 'station', stream: { urls: urls.promise } }));
        if (reason === 'dismiss') { r.bridge.setPresentation(false); r.show(); }
        if (reason === 'hidden') { r.document.hidden = true; r.fireDocument('visibilitychange'); r.document.hidden = false; }
        if (reason === 'pagehide') r.fireWindow('pagehide');
        if (reason === 'new-search') r.search();
        if (reason === 'new-interaction') r.dispatch(element(), () => {});
        urls.resolve(['https://ice.test/stale']); await flush();
        assert.equal(r.received('lampaNative').length, 0);
    });
}

test('Soma uses the provider-ordered stream for the selected station when its playlist has mirrors', async () => {
    const r = runtime(); r.show(); const { player } = soma(r);
    r.dispatch(element('soma'), () => player.play({ id: 'station', stream: { urls: ['https://ice.test/a', 'https://ice.test/b'] } }));
    await flush();
    assert.equal(r.received('lampaNative').length, 1);
    assert.equal(r.received('lampaNative')[0].url, 'https://ice.test/a');
});

test('all bridge channels use captured dictionary envelopes, including plugins and timer callbacks', () => {
    const r = runtime();
    r.bridge.getPlugins();
    r.context.onerror('boom', 'test.js', 1, 2, new Error('boom'));
    r.fireWindow('unhandledrejection');
    r.context.__ilampaExecutingPluginURL = 'bundled://plugins/sample_source_plugin.js';
    r.context.Lampa.Component.add('test_component', {});
    r.context.__ilampaExecutingPluginURL = null;
    r.document.rows = []; r.mutations[0]();
    r.bridge.testTimer(10, 'timer-1');
    r.context.__ilampaGeneration = 99;
    r.context.__ilampaDocumentToken = 'MUST-NOT-RELABEL';
    for (const callback of [...r.timeouts.values()]) callback();
    for (const message of r.messages) {
        assert.equal(Array.isArray(message.body), false);
        assert.equal(message.body.generation, 7);
        assert.equal(message.body.documentToken, 'document-A');
    }
    assert.equal(r.received('lampaPluginsList')[0].plugins.length, 1);
    assert.equal(r.received('lampaComponentRegistered')[0].pluginUrl, 'bundled://plugins/sample_source_plugin.js');
    assert.equal(r.received('lampaLifecycle').find(x => x.status === 'timerCompleted').callbackId, 'timer-1');
});

test('interval component registration remains attributed after plugin evaluation returns', () => {
    const r = runtime();
    r.context.__ilampaExecutingPluginURL = 'https://plugins.test/a.js';
    r.context.__ilampaLastPluginURL = r.context.__ilampaExecutingPluginURL;
    const id = r.context.setInterval(() => r.context.Lampa.Component.add('interval_source', {}), 100);
    r.context.__ilampaExecutingPluginURL = null;
    r.intervals.get(id)();
    assert.equal(r.received('lampaComponentRegistered').at(-1).pluginUrl, 'https://plugins.test/a.js');
});

test('component registration reports only successful upstream calls and preserves the result', () => {
    const r = runtime({ rejectComponent: 'rejected', componentResult: 'upstream-result' });
    r.context.__ilampaExecutingPluginURL = 'https://plugins.test/a.js';
    assert.throws(() => r.context.Lampa.Component.add('rejected', {}), /registration rejected/);
    assert.equal(r.received('lampaComponentRegistered').length, 0);
    assert.equal(r.context.Lampa.Component.add('accepted', {}), 'upstream-result');
    assert.equal(r.received('lampaComponentRegistered').at(-1).pluginUrl, 'https://plugins.test/a.js');
});

test('interval component registration retains its scheduling plugin, not the last loaded plugin', () => {
    const r = runtime();
    r.context.__ilampaExecutingPluginURL = 'https://plugins.test/a.js';
    r.context.__ilampaLastPluginURL = r.context.__ilampaExecutingPluginURL;
    let observed;
    const id = r.context.setInterval(function () {
        observed = r.context.__ilampaExecutingPluginURL;
        r.context.Lampa.Component.add('interval_source', {});
    }, 100);
    r.context.__ilampaExecutingPluginURL = null;
    r.context.__ilampaLastPluginURL = 'https://plugins.test/b.js';
    r.intervals.get(id)();
    assert.equal(observed, 'https://plugins.test/a.js');
    assert.equal(r.received('lampaComponentRegistered').at(-1).pluginUrl, 'https://plugins.test/a.js');
    assert.equal(r.context.__ilampaExecutingPluginURL, null);
    r.context.clearInterval(id);
    assert.equal(r.intervals.has(id), false);
});

test('unowned interval registrations cannot borrow the last loaded plugin', () => {
    const r = runtime();
    r.context.__ilampaLastPluginURL = 'https://plugins.test/a.js';
    const id = r.context.setInterval(() => r.context.Lampa.Component.add('unowned_source', {}), 100);
    r.intervals.get(id)();
    assert.equal(r.received('lampaComponentRegistered').at(-1).pluginUrl, null);
});

test('missing document-start credentials fails closed', () => {
    const r = runtime({ generation: null, token: '' });
    r.show(); r.search();
    r.dispatch(element(), () => r.play({ url: 'https://stream.test/no-credentials' }));
    assert.equal(r.messages.length, 0);
});

test('bridge plugin mutations defer to native manager', () => {
    const r = runtime();
    for (const method of ['addPlugin', 'removePlugin', 'togglePlugin']) {
        assert.equal(r.bridge[method]('https://plugins.test/p.js', true).error, 'native-managed');
    }
});

function upstream(managed) {
    const start = appCode.indexOf('  var _created = [];');
    const end = appCode.indexOf('\n  /**', appCode.indexOf('  var Plugins = {', start));
    assert.ok(start >= 0 && end > start, 'Actual upstream Plugins module must be found');
    const storage = { plugins: [{ url: 'https://local.test/p.js', status: 1 }] };
    const calls = { reads: 0, writes: 0, account: 0, scripts: [] };
    const context = {
        __ilampaNativeManaged: managed,
        lampa_settings: { plugins_use: true },
        console: { log() {}, warn() {} }, Request: function () {},
        Storage: { get(name, empty) { calls.reads++; return storage[name] || JSON.parse(empty); },
            set(name, value) { calls.writes++; storage[name] = value; } },
        Account$1: { Api: { plugins(callback) { calls.account++; callback([{ url: 'https://account.test/p.js', status: 1 }]); } },
            Permit: { access: false } },
        object$2: { cub_domain: 'cub.test' },
        Utils$1: { fixMirrorLink: x => x, rewriteIfHTTPS: x => x, addUrlComponent: (x, part) => x + '?' + part,
            putScriptAsync(urls, callback) { calls.scripts.push(...urls); if (callback) callback(); } },
        Base64: { encode: value => value }, localStorage: { getItem() { return ''; } },
        location: { host: 'test' },
        Arrays: { remove(array, item) { const i = array.indexOf(item); if (i >= 0) array.splice(i, 1); } }
    };
    context.window = context;
    vm.createContext(context);
    vm.runInContext(appCode.slice(start, end), context, { filename: 'app.min.js:Plugins' });
    // Isolate blacklist network I/O, leaving actual task/load/add/push/save implementations intact.
    vm.runInContext('loadBlackList = function (callback) { callback([]); };', context);
    return { context, calls, storage, plugins: context.Plugins };
}

test('managed upstream task/load skip local/account/modification execution and persistence', () => {
    const r = upstream(true);
    let completed = 0;
    r.plugins.task(() => completed++);
    r.plugins.load(() => completed++);
    const record = { url: 'https://new.test/p.js', status: 1 };
    r.plugins.add(record); r.plugins.push(record); r.plugins.save(); r.plugins.remove(record);
    assert.equal(completed, 2);
    assert.equal(r.calls.reads, 0);
    assert.equal(r.calls.writes, 0);
    assert.equal(r.calls.account, 0);
    assert.equal(r.calls.scripts.length, 0);
    assert.equal(r.plugins.get().length, 0);
    assert.equal(r.plugins.awaits().length, 0);
});

for (const managed of [false, undefined]) test(`unmanaged browser (${String(managed)}) keeps local/account/modification and add/save/remove`, () => {
    const r = upstream(managed);
    let completed = 0;
    r.plugins.task(() => completed++);
    assert.equal(r.calls.account, 1);
    assert.deepEqual(plain(r.plugins.awaits()), [
        'https://account.test/p.js', 'https://local.test/p.js', 'http://bylampa.online/plugins/modification.js'
    ]);
    r.plugins.load(() => completed++);
    assert.equal(completed, 2);
    assert.equal(r.calls.scripts.length, 3);
    const record = { url: 'https://new.test/p.js', status: 1 };
    r.plugins.add(record);
    assert.equal(r.plugins.get().length, 2);
    assert.equal(r.calls.scripts.length, 4);
    r.plugins.save(); r.plugins.remove(record);
    assert.equal(r.plugins.get().length, 1);
    assert.ok(r.calls.writes >= 4);
});

(async () => {
    let failed = 0;
    for (const { name, run } of tests) {
        try { await run(); console.log('PASS ' + name); }
        catch (error) { failed++; console.error('FAIL ' + name + '\n' + error.stack); }
    }
    console.log(`\n${tests.length - failed}/${tests.length} bridge runtime tests passed`);
    process.exitCode = failed ? 1 : 0;
})();
