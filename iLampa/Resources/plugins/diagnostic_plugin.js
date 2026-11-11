(function () {
    'use strict';

    var pluginInfo = {
        name: "Diagnostic Source Plugin",
        version: "1.0.0",
        author: "iLampa Test Suite",
        description: "Локальный тестовый плагин для проверки жизненного цикла расширений",
        type: "source"
    };

    if (typeof Lampa !== 'undefined') {
        if (Lampa.Plugins && Lampa.Plugins.add) {
            Lampa.Plugins.add(pluginInfo);
        }

        if (Lampa.Sources && Lampa.Sources.add) {
            Lampa.Sources.add({
                id: "diagnostic_test_source",
                name: "Диагностический источник",
                description: "Проверочный источник потока для автоматизированных тестов"
            });
        }

        if (Lampa.Listener && Lampa.Listener.follow) {
            Lampa.Listener.follow('app', function (e) {
                if (console && console.log) {
                    console.log('DiagnosticTestPlugin: App listener hook fired with type ' + (e ? e.type : 'none'));
                }
            });
        }
    }
})();
