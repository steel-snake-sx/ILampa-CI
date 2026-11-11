import Foundation

/// Discovers and builds a deduplicated inventory of plugins from all application sources:
/// installed extensions, curated items, supported catalogs, bundled files, and custom URLs.
@MainActor
final class PluginLabDiscovery {
    static let shared = PluginLabDiscovery()

    private init() {}

    /// Normalizes a URL string for stable deduplication.
    static func normalizeURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("bundled://") {
            return trimmed.lowercased()
        }
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased()
        }
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.url?.absoluteString ?? trimmed
    }

    /// Discovers all available plugins and returns a deduplicated inventory.
    func discoverPlugins(
        pluginManager: PluginManager = .shared,
        catalogStore: PluginCatalogStore? = nil,
        bundle: Bundle = .main
    ) -> [PluginLabItem] {
        let store = catalogStore ?? PluginCatalogStore(defaults: .standard)
        var inventory: [String: PluginLabItem] = [:] // normalizedURL -> PluginLabItem

        // 1. Installed plugins from user configuration
        for record in pluginManager.installedPlugins {
            let normURL = Self.normalizeURL(record.urlString)
            let stableId = PluginLabItem.makeStableId(url: normURL, name: record.name)
            inventory[normURL] = PluginLabItem(
                id: stableId,
                name: record.name,
                url: normURL,
                author: record.author,
                version: record.version,
                category: nil,
                origin: .installed,
                initialEnabledState: record.isEnabled,
                isInstalled: true,
                sha256: record.approvedScriptSHA256,
                declaredCapabilities: Array(record.registeredComponents)
            )
        }

        // 2. Curated plugins
        for curated in pluginManager.curatedPlugins {
            let normURL = Self.normalizeURL(curated.url)
            if var existing = inventory[normURL] {
                if existing.name.isEmpty { existing.name = curated.name }
                existing.origin = .curated
                inventory[normURL] = existing
            } else {
                let stableId = PluginLabItem.makeStableId(url: normURL, name: curated.name)
                inventory[normURL] = PluginLabItem(
                    id: stableId,
                    name: curated.name,
                    url: normURL,
                    author: nil,
                    version: "1.0.0",
                    category: "Curated",
                    origin: .curated,
                    initialEnabledState: false,
                    isInstalled: false
                )
            }
        }

        // 3. Catalog entries from store
        if let snapshot = store.snapshot {
            for entry in snapshot.entries {
                let normURL = Self.normalizeURL(entry.sourceURL.absoluteString)
                if var existing = inventory[normURL] {
                    if existing.author == nil { existing.author = entry.author }
                    if existing.category == nil { existing.category = entry.category }
                    inventory[normURL] = existing
                } else {
                    let stableId = PluginLabItem.makeStableId(url: normURL, name: entry.title)
                    inventory[normURL] = PluginLabItem(
                        id: stableId,
                        name: entry.title,
                        url: normURL,
                        author: entry.author,
                        version: "1.0.0",
                        category: entry.category,
                        origin: .catalog,
                        initialEnabledState: false,
                        isInstalled: false
                    )
                }
            }
        }

        // 4. Bundled plugin files in app resources
        let bundledFiles = [
            ("e.js", "e.js (Меню выхода и навигации)"),
            ("soma.js", "SomaFM (Радио & Музыка)"),
            ("online_mod.js", "Онлайн-мод (встроенный)"),
            ("diagnostic_plugin.js", "Диагностический плагин"),
            ("sample_source_plugin.js", "Тестовый источник")
        ]

        for (filename, displayName) in bundledFiles {
            let bundledURL = "bundled://plugins/\(filename)"
            let normURL = Self.normalizeURL(bundledURL)
            if inventory[normURL] == nil {
                let stableId = PluginLabItem.makeStableId(url: normURL, name: displayName)
                inventory[normURL] = PluginLabItem(
                    id: stableId,
                    name: displayName,
                    url: normURL,
                    author: "iLampa Team",
                    version: "1.0.0",
                    category: "Встроенные",
                    origin: .bundled,
                    initialEnabledState: false,
                    isInstalled: false
                )
            }
        }

        // 5. Fallback Pilot Catalog Seed (for guaranteed variety if network is offline)
        let pilotSeeds: [(name: String, cat: String, url: String)] = [
            ("Head filter", "settings / UI", "https://and7ey.github.io/lampa/head_filter.js"),
            // The old flat main/shikimori.js endpoint is HTTP 404; the publisher
            // moved the real script to its Shikimori/ directory.
            ("Shikimori catalog", "catalog / metadata", "https://lampame.github.io/main/Shikimori/Shikimori.js"),
            ("Additional categories", "catalog / navigation", "https://lampame.github.io/main/nc/nc.js"),
            ("Online Mod", "source", "https://nb557.github.io/plugins/online_mod.js"),
            ("CUB rating", "metadata", "https://plugin.rootu.top/cub-rating.js"),
            ("Navigation Bar", "navigation / settings", "https://lampaplugins.github.io/store/navigation_bar.js")
        ]

        for seed in pilotSeeds {
            let normURL = Self.normalizeURL(seed.url)
            if inventory[normURL] == nil {
                let stableId = PluginLabItem.makeStableId(url: normURL, name: seed.name)
                inventory[normURL] = PluginLabItem(
                    id: stableId,
                    name: seed.name,
                    url: normURL,
                    author: "Community",
                    version: "1.0.0",
                    category: seed.cat,
                    origin: .catalog,
                    initialEnabledState: false,
                    isInstalled: false
                )
            }
        }

        // Return sorted list: installed first, then curated, bundled, catalog
        return inventory.values.sorted { lhs, rhs in
            if lhs.isInstalled != rhs.isInstalled { return lhs.isInstalled && !rhs.isInstalled }
            if lhs.origin != rhs.origin {
                let order: [PluginLabOrigin: Int] = [.installed: 0, .curated: 1, .bundled: 2, .catalog: 3, .custom: 4]
                return (order[lhs.origin] ?? 5) < (order[rhs.origin] ?? 5)
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
