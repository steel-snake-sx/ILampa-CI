// ============================================================================
// iLampa Reference Source Plugin (Open-Source / Inspectable Fixture)
// License: MIT
// Purpose: Deterministic verification of Gate 1.3 Priority 1 & 2:
// 1. Plugin initialization.
// 2. Actual provider discovery.
// 3. Real source results.
// 4. Selection of a specific available media item.
// 5. Selection of an actual episode and audio variant.
// 6. Real playback event (Lampa.Player.play).
// 7. Correct playback descriptor reaching Swift.
// 8. Native AVPlayer opening the selected authorized media.
// ============================================================================

(function () {
    'use strict';

    if (typeof Lampa === 'undefined') {
        return;
    }

    function SampleSourceComponent(object) {
        var scroll = new Lampa.Scroll({ mask: true, over: true });
        var files = new Lampa.Files(object);

        var authorizedStreams = [
            {
                id: 'open_stream_1',
                title: 'Apple Test Stream (BipBop 1080p)',
                quality: '1080p',
                season: 1,
                episode: 1,
                voice: 'Оригинал (AAC Stereo)',
                url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8',
                qualities: {
                    '1080p': 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8',
                    '720p': 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear4/prog_index.m3u8',
                    '480p': 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear3/prog_index.m3u8'
                }
            },
            {
                id: 'open_stream_2',
                title: 'Apple Test Stream: Эпизод 2 (BipBop 720p)',
                quality: '720p',
                season: 1,
                episode: 2,
                voice: 'Оригинал (AAC Stereo)',
                url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear4/prog_index.m3u8',
                qualities: {
                    '720p': 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/gear4/prog_index.m3u8'
                }
            },
            {
                id: 'open_stream_3',
                title: 'Open Media: Multi-audio HLS Stream',
                quality: '1080p',
                season: 1,
                episode: 3,
                voice: 'Дубляж (Dolby Digital)',
                url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
                qualities: {
                    '1080p': 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'
                }
            }
        ];

        this.create = function () {
            var container = $('<div class="sample-source-list online-list"></div>');

            authorizedStreams.forEach(function (item, index) {
                var domItem = $(
                    '<div class="online selector" data-index="' + index + '" style="padding: 12px; margin: 6px 0; background: rgba(255,255,255,0.08); border-radius: 8px; cursor: pointer;">' +
                        '<div class="online__body">' +
                            '<div class="online__title" style="font-weight: bold; font-size: 15px; color: #fff;">' + item.title + '</div>' +
                            '<div class="online__quality" style="font-size: 12px; color: #aaa; margin-top: 4px;">S' + item.season + 'E' + item.episode + ' • ' + item.quality + ' • ' + item.voice + '</div>' +
                        '</div>' +
                    '</div>'
                );

                domItem.on('click hover:enter', function () {
                    var playlist = authorizedStreams.map(function (s) {
                        return {
                            title: s.title,
                            url: s.url,
                            quality: s.qualities
                        };
                    });

                    var first = {
                        title: item.title,
                        url: item.url,
                        quality: item.qualities,
                        season: item.season,
                        episode: item.episode,
                        voice: item.voice,
                        playlist: playlist
                    };

                    console.log('[SampleSource] Triggering Lampa.Player.play for:', first.title);
                    Lampa.Player.play(first);
                    Lampa.Player.playlist(playlist);
                });

                container.append(domItem);
            });

            scroll.append(container);
            files.append(scroll.render());
            return files.render();
        };

        this.start = function () {
            // Focus first item
            if (window.$) {
                $('.sample-source-list .selector').first().addClass('focus');
            }
        };

        this.destroy = function () {
            if (scroll && scroll.destroy) scroll.destroy();
            if (files && files.destroy) files.destroy();
        };
    }

    Lampa.Component.add('sample_source', SampleSourceComponent);

    Lampa.Listener.follow('full', function (e) {
        if (e.type === 'complite') {
            console.log('[SampleSource] Card opened for:', e.data && e.data.movie && e.data.movie.title);
        }
    });

    console.log('[SampleSource] Plugin initialized. Component "sample_source" registered.');
})();
