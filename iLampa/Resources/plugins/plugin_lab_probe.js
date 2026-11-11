/**
 * iLampa — Plugin Lab Diagnostic Probe
 * Deep instrumentation and non-destructive inspection harness for Lampa plugins.
 * Executes in isolated WebKit / JavaScriptCore runtime without modifying user state.
 */
(function (global) {
    'use strict';

    if (global.__pluginLabInitialized) return;
    global.__pluginLabInitialized = true;

    var events = [];
    var jsErrors = [];
    var registeredComponents = [];
    var componentFactories = Object.create(null);
    var probedPluginURL = null;
    var registeredSources = [];
    var registeredSettings = [];
    var domAdditions = [];
    var platformQueries = [];
    var networkRequests = [];
    var uiFailures = [];
    var apiTouches = Object.create(null);
    var activePluginURL = null;
    var storageSandboxActive = false;
    // Count synchronous work only while evaluating the selected plugin.
    // Lampa Core background activity is not evidence of plugin behavior.
    function isPluginCall() {
        // Late ready/timer/promise handlers retain their authentic plugin owner
        // through lampa_bridge's async attribution hook. They must be observed
        // even after the synchronous eval() scope has exited, but unrelated
        // Lampa Core events remain excluded.
        var expectedOwner = activePluginURL || probedPluginURL;
        return !!expectedOwner && global.__ilampaExecutingPluginURL === expectedOwner;
    }
    var isolatedStorage = Object.create(null);

    function recordEvent(level, category, message, metadata) {
        if (!isPluginCall()) return;
        var evt = {
            timestamp: new Date().toISOString(),
            level: level || 'INFO',
            category: category || '[Probe]',
            message: String(message || ''),
            metadata: metadata || {}
        };
        events.push(evt);
        if (global.webkit && global.webkit.messageHandlers && global.webkit.messageHandlers.pluginLabMessage) {
            try {
                global.webkit.messageHandlers.pluginLabMessage.postMessage(evt);
            } catch (e) { /* ignore postMessage failure */ }
        }
    }

    function recordTouch(apiName) {
        if (!isPluginCall()) return;
        apiTouches[apiName] = (apiTouches[apiName] || 0) + 1;
    }

    // Global JS Exception Handlers
    if (typeof global.addEventListener === 'function') {
        global.addEventListener('error', function (e) {
            var err = {
                message: e.message || String(e),
                filename: e.filename || '',
                lineno: e.lineno || 0,
                colno: e.colno || 0,
                stack: (e.error && e.error.stack) ? String(e.error.stack) : ''
            };
            if (isPluginCall()) jsErrors.push(err);
            recordEvent('ERROR', '[JavaScriptException]', err.message, err);
        });

        global.addEventListener('unhandledrejection', function (e) {
            var reason = e.reason;
            var err = {
                message: (reason && reason.message) ? reason.message : String(reason),
                stack: (reason && reason.stack) ? String(reason.stack) : ''
            };
            if (isPluginCall()) jsErrors.push(err);
            recordEvent('ERROR', '[UnhandledRejection]', err.message, err);
        });
    }

    // Intercept console logging
    if (global.console) {
        var origConsole = {
            log: global.console.log,
            warn: global.console.warn,
            error: global.console.error
        };
        global.console.error = function () {
            var msg = Array.prototype.slice.call(arguments).map(String).join(' ');
            if (isPluginCall()) jsErrors.push({ message: msg, stack: (new Error()).stack || '' });
            recordEvent('ERROR', '[ConsoleError]', msg);
            if (origConsole.error) origConsole.error.apply(global.console, arguments);
        };
        global.console.warn = function () {
            var msg = Array.prototype.slice.call(arguments).map(String).join(' ');
            recordEvent('WARN', '[ConsoleWarn]', msg);
            if (origConsole.warn) origConsole.warn.apply(global.console, arguments);
        };
        global.console.log = function () {
            var msg = Array.prototype.slice.call(arguments).map(String).join(' ');
            recordEvent('INFO', '[ConsoleLog]', msg);
            if (origConsole.log) origConsole.log.apply(global.console, arguments);
        };
    }

    // Ensure Lampa namespace exists
    if (!global.Lampa) global.Lampa = {};
    var L = global.Lampa;

    // 1. Lampa.Plugins
    if (!L.Plugins) L.Plugins = {};
    var origPluginsAdd = L.Plugins.add;
    L.Plugins.add = function (info) {
        recordTouch('Lampa.Plugins.add');
        var name = (info && info.name) ? String(info.name) : 'Unnamed Plugin';
        var type = (info && info.type) ? String(info.type) : 'general';
        var hasSource = !!(info && (info.source || info.resolve || info.search));
        recordEvent('SUCCESS', '[Plugins.add]', 'Plugin registered: ' + name + ' (type=' + type + ')', {
            name: name,
            type: type,
            hasSource: String(hasSource)
        });
        if (origPluginsAdd) return origPluginsAdd.apply(this, arguments);
    };

    // 2. Lampa.Component
    if (!L.Component) L.Component = {};
    var origComponentAdd = L.Component.add;
    L.Component.add = function (name, componentClass) {
        recordTouch('Lampa.Component.add');
        var compName = String(name || '');
        var probe = {
            name: compName,
            isPlatform: compName.indexOf('cub_') === 0 || compName.indexOf('shots_') === 0 ||
                        compName === 'main' || compName === 'settings' || compName === 'head' || compName === 'menu',
            hasNativeRenderer: false,
            lifecycleMethods: [],
            instantiationSuccess: false,
            instantiationError: null
        };

        // Known native component types in iLampa:
        if (compName === 'somafm' || compName === 'online_mod') {
            probe.hasNativeRenderer = true;
        }

        // Do not instantiate arbitrary third-party components during discovery:
        // constructors can issue requests, mutate storage or start media.
        if (typeof componentClass === 'function') {
            var prototype = componentClass.prototype || {};
            ['create', 'build', 'start', 'pause', 'stop', 'render', 'destroy'].forEach(function (m) {
                if (typeof prototype[m] === 'function') probe.lifecycleMethods.push(m);
            });
            recordEvent('INFO', '[Component.add]', 'Constructor deliberately not invoked: ' + compName);
        }

        if (isPluginCall()) {
            registeredComponents.push(probe);
            if (typeof componentClass === 'function' && !probe.isPlatform) {
                componentFactories[compName] = componentClass;
            }
        }
        recordEvent('INFO', '[Component.add]', 'Component registered: ' + compName, {
            name: compName,
            isPlatform: String(probe.isPlatform),
            hasNativeRenderer: String(probe.hasNativeRenderer),
            methods: probe.lifecycleMethods.join(',')
        });

        // Registration is not an actual rendering test.
        if (!probe.isPlatform && !probe.hasNativeRenderer) {
            recordEvent('INFO', '[UICompatibility]', 'Custom component requires a real UI check: ' + compName);
        }

        if (origComponentAdd) return origComponentAdd.apply(this, arguments);
    };

    // 3. Lampa.Sources
    if (!L.Sources) L.Sources = {};
    var origSourcesAdd = L.Sources.add;
    L.Sources.add = function (sourceObj) {
        recordTouch('Lampa.Sources.add');
        var srcId = (sourceObj && sourceObj.id) ? String(sourceObj.id) : ('source_' + registeredSources.length);
        var srcName = (sourceObj && sourceObj.name) ? String(sourceObj.name) : 'Custom Source';
        var hasResolve = !!(sourceObj && typeof sourceObj.resolve === 'function');
        var hasSearch = !!(sourceObj && typeof sourceObj.search === 'function');
        var hasNativeStream = !!(sourceObj && sourceObj.nativeStream);

        var probe = {
            id: srcId,
            name: srcName,
            hasResolve: hasResolve,
            hasSearch: hasSearch,
            hasNativeStream: hasNativeStream,
            // Method presence is only registration evidence, not an operational test.
            isOperational: false
        };
        if (isPluginCall()) registeredSources.push(probe);
        recordEvent('SUCCESS', '[Sources.add]', 'Source provider registered: ' + srcName + ' [' + srcId + ']', {
            id: srcId,
            name: srcName,
            isOperational: String(probe.isOperational)
        });
        if (origSourcesAdd) return origSourcesAdd.apply(this, arguments);
    };

    // 4. Lampa.SettingsApi
    if (!L.SettingsApi) L.SettingsApi = {};
    var origSettingsAddComponent = L.SettingsApi.addComponent;
    L.SettingsApi.addComponent = function (data) {
        recordTouch('Lampa.SettingsApi.addComponent');
        recordEvent('INFO', '[SettingsApi.addComponent]', 'Settings component added: ' + (data ? data.component : 'unknown'));
        if (origSettingsAddComponent) return origSettingsAddComponent.apply(this, arguments);
    };

    var origSettingsAddParam = L.SettingsApi.addParam;
    L.SettingsApi.addParam = function (data) {
        recordTouch('Lampa.SettingsApi.addParam');
        if (data && data.param) {
            var param = data.param;
            var field = data.field || {};
            var settingInfo = {
                component: String(data.component || ''),
                name: String(param.name || field.name || ''),
                type: String(param.type || 'trigger'),
                // Never persist the plugin's default setting value in a report.
                defaultValue: param.default != null ? '[WITHHELD]' : '',
                hasOnRender: typeof data.onRender === 'function',
                options: param.values ? Object.keys(param.values) : []
            };
            if (isPluginCall()) registeredSettings.push(settingInfo);
            recordEvent('INFO', '[SettingsApi.addParam]', 'Setting param added: ' + settingInfo.name + ' (' + settingInfo.type + ')');
        }
        if (origSettingsAddParam) return origSettingsAddParam.apply(this, arguments);
    };

    // 5. Lampa.Platform
    if (!L.Platform) L.Platform = {};
    var origPlatformIs = L.Platform.is;
    L.Platform.is = function (platform) {
        recordTouch('Lampa.Platform.is');
        var p = String(platform || '').toLowerCase();
        if (isPluginCall()) platformQueries.push(p);
        recordEvent('INFO', '[Platform.is]', 'Platform query: ' + p);

        // Honest iOS compatibility responses:
        if (p === 'apple_tv' || p === 'tizen' || p === 'webos' || p === 'android' || p === 'orsay' || p === 'nw') {
            return false;
        }
        if (p === 'ios' || p === 'apple' || p === 'browser') {
            return true;
        }
        if (origPlatformIs) return origPlatformIs.apply(this, arguments);
        return false;
    };

    // 6. Lampa.Listener
    if (!L.Listener) L.Listener = {};
    var origListenerFollow = L.Listener.follow;
    L.Listener.follow = function (event, callback) {
        recordTouch('Lampa.Listener.follow');
        recordEvent('INFO', '[Listener.follow]', 'Subscribed to event: ' + event);
        if (origListenerFollow) return origListenerFollow.apply(this, arguments);
    };

    // 7. Lampa.Storage (Isolated test storage)
    if (!L.Storage) L.Storage = {};
    var origStorageSet = L.Storage.set;
    var origStorageGet = L.Storage.get;
    var origStorageField = L.Storage.field;

    L.Storage.set = function (key, value) {
        if (!storageSandboxActive) {
            if (origStorageSet) return origStorageSet.apply(this, arguments);
            return undefined;
        }
        recordTouch('Lampa.Storage.set');
        isolatedStorage[String(key)] = value;
        recordEvent('INFO', '[Storage.set]', 'Storage key written: ' + String(key));
        return value;
    };

    L.Storage.get = function (key, fallback) {
        if (!storageSandboxActive) {
            if (origStorageGet) return origStorageGet.apply(this, arguments);
            return fallback;
        }
        recordTouch('Lampa.Storage.get');
        var scopedKey = String(key);
        return Object.prototype.hasOwnProperty.call(isolatedStorage, scopedKey)
            ? isolatedStorage[scopedKey] : fallback;
    };

    L.Storage.field = function (key) {
        if (!storageSandboxActive) {
            if (origStorageField) return origStorageField.apply(this, arguments);
            return '';
        }
        recordTouch('Lampa.Storage.field');
        var scopedKey = String(key);
        return Object.prototype.hasOwnProperty.call(isolatedStorage, scopedKey)
            ? isolatedStorage[scopedKey] : '';
    };

    // 8. Lampa.Activity
    if (!L.Activity) L.Activity = {};
    ['push', 'out', 'replace', 'back', 'active'].forEach(function (method) {
        var orig = L.Activity[method];
        L.Activity[method] = function () {
            recordTouch('Lampa.Activity.' + method);
            recordEvent('INFO', '[Activity.' + method + ']', 'Activity method called: ' + method);
            if (orig) return orig.apply(this, arguments);
        };
    });

    // 9. Lampa.Template & Lang
    if (!L.Template) L.Template = { add: function () { recordTouch('Lampa.Template.add'); }, get: function () { return ''; } };
    if (!L.Lang) L.Lang = { add: function () { recordTouch('Lampa.Lang.add'); }, translate: function (s) { return s; } };

    // 10. Lampa.Select, Modal, Noty
    if (!L.Select) L.Select = { show: function () { recordTouch('Lampa.Select.show'); } };
    if (!L.Modal) L.Modal = { open: function () { recordTouch('Lampa.Modal.open'); }, close: function () {} };
    if (!L.Noty) L.Noty = { show: function () { recordTouch('Lampa.Noty.show'); } };

    // 11. Lampa.Reguest & Request
    function recordRequest(url, method) {
        recordTouch('Lampa.Reguest');
        // Diagnostic URL metadata never includes query strings, fragments or credentials.
        var safeURL = String(url || '').split(/[?#]/)[0];
        try {
            var parsed = new URL(String(url || ''), global.location && global.location.href);
            safeURL = parsed.protocol + '//' + parsed.hostname + parsed.pathname;
        } catch (e) {}
        safeURL = safeURL.replace(/[A-Za-z0-9_-]{32,}/g, '[REDACTED]');
        if (isPluginCall()) networkRequests.push({ url: safeURL, method: String(method || 'GET') });
        recordEvent('INFO', '[NetworkRequest]', (method || 'GET') + ' ' + safeURL);
    }
    if (L.Reguest) {
        var origReguest = L.Reguest;
        L.Reguest = function (url) {
            recordRequest(url, 'GET');
            return origReguest.apply(this, arguments);
        };
    }
    if (L.Request) {
        var origRequest = L.Request;
        L.Request = function (url) {
            recordRequest(url, 'GET');
            return origRequest.apply(this, arguments);
        };
    }

    // 12. DOM Mutation Observer to detect created DOM elements & menu actions
    if (typeof global.MutationObserver === 'function' && typeof document !== 'undefined' && document.body) {
        try {
            var observer = new MutationObserver(function (mutations) {
                mutations.forEach(function (m) {
                    if (m.addedNodes) {
                        for (var i = 0; i < m.addedNodes.length; i++) {
                            var node = m.addedNodes[i];
                            if (node.nodeType === 1) { // ELEMENT_NODE
                                var action = node.getAttribute ? node.getAttribute('data-action') : null;
                                var className = node.className || '';
                                var text = (node.textContent || '').trim().substring(0, 100);
                                var info = {
                                    tag: node.tagName ? node.tagName.toLowerCase() : '',
                                    action: action,
                                    className: String(className),
                                    text: text
                                };
                                if (isPluginCall()) domAdditions.push(info);
                                recordEvent('INFO', '[DOMAddition]', 'DOM element inserted: <' + info.tag + '> ' + (action ? ('[data-action="' + action + '"]') : '') + ' class="' + className + '"');

                                // Custom actions can have JS handlers. Do not invent a missing handler.
                                if (action) recordEvent('INFO', '[UICompatibility]', 'Action observed, callback unverified: ' + action);
                            }
                        }
                    }
                });
            });
            observer.observe(document.body, { childList: true, subtree: true });
        } catch (e) { /* ignore observer failure */ }
    }

    // 13. Expose Probe Inspection & Non-destructive testing APIs
    global.__pluginLab = {
        beginPlugin: function (url) {
            this.clear();
            activePluginURL = String(url || '');
            probedPluginURL = activePluginURL;
            storageSandboxActive = true;
        },
        endPlugin: function () {
            activePluginURL = null;
        },

        // Optional observational smoke test after script registration, inside
        // PluginLab's isolated, non-persistent WKWebView. Constructors and
        // create() are genuinely invoked: no synthetic registration PASS.
        // Never start(), click(), or play media automatically. A failed
        // synthetic movie context is reported as unverified, not a real
        // production compatibility failure.
        probeRegisteredComponentUI: function () {
            var previousOwner = activePluginURL;
            var previousExecuting = global.__ilampaExecutingPluginURL;
            var inspected = 0;
            activePluginURL = probedPluginURL;
            global.__ilampaExecutingPluginURL = probedPluginURL;
            try {
                registeredComponents.forEach(function (probe) {
                    if (inspected >= 6 || probe.isPlatform || !componentFactories[probe.name]) return;
                    inspected++;
                    var component = null;
                    try {
                        var card = {
                            id: 550, title: 'PluginLab reference movie',
                            original_title: 'PluginLab reference movie',
                            source: 'tmdb', media_type: 'movie'
                        };
                        component = new componentFactories[probe.name]({
                            title: card.title, source: 'tmdb',
                            movie: card, card: card, mediaType: 'movie',
                            page: 1, url: ''
                        });
                        if (!component || typeof component.create !== 'function') {
                            recordEvent('INFO', '[ComponentUIProbe]',
                                'No create() available for ' + probe.name);
                            return;
                        }
                        var ui = component.create();
                        var root = ui && ui.nodeType === 1 ? ui
                            : (ui && ui[0] && ui[0].nodeType === 1 ? ui[0]
                            : (ui && typeof ui.get === 'function' ? ui.get(0) : null));
                        if (!root || root.nodeType !== 1) {
                            recordEvent('INFO', '[ComponentUIProbe]',
                                'Component ' + probe.name + ' returned no inspectable DOM');
                            return;
                        }
                        var selectors = root.querySelectorAll
                            ? root.querySelectorAll('.selector,[data-action]') : [];
                        var nodes = [];
                        if (root.matches && root.matches('.selector,[data-action]')) nodes.push(root);
                        for (var i = 0; i < selectors.length && nodes.length < 12; i++) nodes.push(selectors[i]);
                        if (!nodes.length) nodes.push(root);
                        nodes.forEach(function (node) {
                            domAdditions.push({
                                tag: String(node.tagName || '').toLowerCase(),
                                action: node.getAttribute ? node.getAttribute('data-action') : null,
                                className: String(node.className || ''),
                                text: String(node.textContent || '').trim().substring(0, 100)
                            });
                        });
                        probe.instantiationSuccess = true;
                        recordEvent('SUCCESS', '[ComponentUIProbe]',
                            'Constructed real WebKit UI for ' + probe.name + '; DOM nodes=' + nodes.length,
                            { component: probe.name, nodes: String(nodes.length), clicked: 'false' });
                    } catch (error) {
                        // A generic test card cannot satisfy every real plugin's
                        // source/context dependency. Keep it unverified rather
                        // than calling that an extension failure.
                        recordEvent('WARN', '[ComponentUIProbe]',
                            'Synthetic UI context not sufficient for ' + probe.name,
                            { component: probe.name,
                              reason: String(error && error.message || error).substring(0, 240) });
                    } finally {
                        try {
                            if (component && typeof component.destroy === 'function') component.destroy();
                        } catch (_) {}
                    }
                });
            } finally {
                global.__ilampaExecutingPluginURL = previousExecuting;
                activePluginURL = previousOwner;
            }
            return inspected;
        },
        getReport: function () {
            return {
                // The native bridge stores event attributes as [String: String].
                // metadata can contain nested objects and numeric fields, so return
                // lossless JSON text for that field instead of a nested dictionary.
                events: events.map(function (evt) {
                    return {
                        timestamp: String(evt.timestamp || ''),
                        level: String(evt.level || ''),
                        category: String(evt.category || ''),
                        message: String(evt.message || ''),
                        metadata: JSON.stringify(evt.metadata || {})
                    };
                }),
                jsErrors: jsErrors,
                registeredComponents: registeredComponents,
                registeredSources: registeredSources,
                registeredSettings: registeredSettings,
                domAdditions: domAdditions,
                platformQueries: platformQueries,
                networkRequests: networkRequests,
                uiFailures: uiFailures,
                apiTouches: apiTouches
            };
        },
        probeSetting: function (paramName, testValue) {
            var key = String(paramName);
            var hadValue = Object.prototype.hasOwnProperty.call(isolatedStorage, key);
            var previous = hadValue ? isolatedStorage[key] : undefined;
            isolatedStorage[key] = testValue;
            var success = String(isolatedStorage[key]) === String(testValue);
            if (hadValue) isolatedStorage[key] = previous;
            else delete isolatedStorage[key];
            return { success: success, param: key, testValue: testValue, restoredValue: previous };
        },
        restoreStorage: function () {
            isolatedStorage = Object.create(null);
        },
        clear: function () {
            activePluginURL = null;
            storageSandboxActive = false;
            events = [];
            jsErrors = [];
            registeredComponents = [];
            componentFactories = Object.create(null);
            probedPluginURL = null;
            registeredSources = [];
            registeredSettings = [];
            domAdditions = [];
            platformQueries = [];
            networkRequests = [];
            uiFailures = [];
            apiTouches = Object.create(null);
            this.restoreStorage();
        }
    };

    recordEvent('INFO', '[ProbeInit]', 'Plugin Lab diagnostic probe loaded and attached successfully.');
})(typeof window !== 'undefined' ? window : (typeof global !== 'undefined' ? global : this));
