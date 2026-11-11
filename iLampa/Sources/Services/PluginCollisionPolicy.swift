import Foundation

/// Describes why two plugin records are considered to be in collision.
enum PluginCollisionReason: Equatable {
    /// Two enabled plugins register the same Lampa component ID (e.g. "online_mod").
    case duplicateComponentId(componentId: String)
    /// A remote URL mirrors a bundled plugin already in the bundle.
    case remoteReplicatesBundled(bundledUrl: String)
}

/// Result of a collision check.
struct PluginCollisionReport: Equatable {
    let winner: LampaPluginRecord
    let loser: LampaPluginRecord
    let reason: PluginCollisionReason
    
    /// Human-readable explanation shown to users.
    var userMessage: String {
        switch reason {
        case .duplicateComponentId(let id):
            return "Two plugins register the same component \"\(id)\". \"\(winner.name)\" takes priority. \"\(loser.name)\" has been disabled to avoid conflicts."
        case .remoteReplicatesBundled:
            return "\"\(winner.name)\" is already built into iLampa. The external copy \"\(loser.name)\" has been disabled."
        }
    }
}

/// Encapsulates the collision-resolution policy for Lampa plugin records.
/// Never executes two implementations registering the same exclusive component ID.
/// Respects explicit user preference for Online Mod (bundled vs community/remote).
enum PluginCollisionPolicy {
    /// Inspect an array of enabled plugins and return any collision reports.
    /// Plugins identified as losers should be disabled by the caller.
    static func resolveCollisions(in plugins: [LampaPluginRecord]) -> [PluginCollisionReport] {
        var reports: [PluginCollisionReport] = []
        let enabled = plugins.filter(\.isEnabled)

        // 1. Online Mod exclusive conflict resolution respecting user preference
        let onlinePlugins = enabled.filter {
            let u = $0.urlString.lowercased()
            return u.contains("online_mod") || u.contains("online.js")
        }
        if onlinePlugins.count > 1 {
            let pref = OnlineModPreferenceManager.currentPreference
            let bundledPlugin = onlinePlugins.first { $0.urlString.hasPrefix("bundled://") }
            let remotePlugin = onlinePlugins.first { !$0.urlString.hasPrefix("bundled://") }

            if let bundledPlugin, let remotePlugin {
                let winner = (pref == .remote) ? remotePlugin : bundledPlugin
                let loser = (pref == .remote) ? bundledPlugin : remotePlugin
                reports.append(PluginCollisionReport(
                    winner: winner,
                    loser: loser,
                    reason: .duplicateComponentId(componentId: "online_mod")
                ))
            }
        }

        // 2. SomaFM conflict resolution
        let somaPlugins = enabled.filter {
            let u = $0.urlString.lowercased()
            return u.contains("soma")
        }
        if somaPlugins.count > 1 {
            let bundled = somaPlugins.first { $0.urlString.hasPrefix("bundled://") }
            let remote = somaPlugins.first { !$0.urlString.hasPrefix("bundled://") }
            if let bundled, let remote {
                reports.append(PluginCollisionReport(
                    winner: bundled,
                    loser: remote,
                    reason: .remoteReplicatesBundled(bundledUrl: "bundled://plugins/soma.js")
                ))
            }
        }

        // Deduplicate reports by loser
        var seen = Set<String>()
        return reports.filter { seen.insert($0.loser.id.uuidString).inserted }
    }
}

