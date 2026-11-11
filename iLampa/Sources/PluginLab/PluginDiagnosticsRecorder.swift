import Foundation

/// Per-plugin diagnostic evidence bundle stored before packaging.
struct PluginDiagnosticEvidence: Codable {
    let item: PluginLabItem
    var timeline: [PluginLabTimelineEvent]
    var jsErrors: [PluginProbeRawReport.JSError]
    var nativeErrors: [String]
    var uiComponents: [PluginLabUIComponentInfo]
    var apiCoverage: [PluginLabAPICoverage]
    var bridgeEvents: [[String: String]]
    var networkErrors: [String]
    var screenshotData: Data?
}

/// Thread-safe recorder managing per-plugin diagnostic evidence, persistent checkpoints,
/// bounded memory usage, and allowlist privacy redaction.
final class PluginDiagnosticsRecorder {
    static let shared = PluginDiagnosticsRecorder()

    private let queue = DispatchQueue(label: "com.steelsnake.ilampa.pluginlab.recorder", attributes: .concurrent)
    private var evidenceStore: [String: PluginDiagnosticEvidence] = [:] // pluginId -> Evidence
    // Old campaigns used an unscoped probe and cannot be reused as attributed evidence.
    private let checkpointFileName = "plugin_lab_checkpoint_2_1.json"

    private var storageDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("iLampa/PluginLab", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {}

    private var evidenceDirectory: URL {
        let dir = storageDirectory.appendingPathComponent("evidence_2_1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func evidenceURL(_ pluginId: String) -> URL {
        let safe = pluginId.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        return evidenceDirectory.appendingPathComponent(String(safe.prefix(100)) + ".json")
    }

    // MARK: - Evidence Recording

    func recordEvidence(_ evidence: PluginDiagnosticEvidence) {
        // Commit evidence to disk BEFORE the checkpoint marks its plugin completed.
        queue.sync(flags: .barrier) {
            self.evidenceStore[evidence.item.id] = evidence
            if let encoded = try? JSONEncoder().encode(evidence) {
                try? encoded.write(to: self.evidenceURL(evidence.item.id), options: .atomic)
            }
        }
    }

    func getEvidence(for pluginId: String) -> PluginDiagnosticEvidence? {
        queue.sync {
            if let cached = evidenceStore[pluginId] { return cached }
            guard let data = try? Data(contentsOf: evidenceURL(pluginId)) else { return nil }
            return try? JSONDecoder().decode(PluginDiagnosticEvidence.self, from: data)
        }
    }

    func allEvidence() -> [PluginDiagnosticEvidence] {
        queue.sync {
            var result = evidenceStore
            if let files = try? FileManager.default.contentsOfDirectory(
                at: evidenceDirectory, includingPropertiesForKeys: nil
            ) {
                for file in files where file.pathExtension == "json" {
                    if let data = try? Data(contentsOf: file),
                       let evidence = try? JSONDecoder().decode(PluginDiagnosticEvidence.self, from: data) {
                        result[evidence.item.id] = evidence
                    }
                }
            }
            return Array(result.values)
        }
    }

    func clear() {
        queue.sync(flags: .barrier) {
            self.evidenceStore.removeAll()
            let cpFile = self.storageDirectory.appendingPathComponent(self.checkpointFileName)
            try? FileManager.default.removeItem(at: cpFile)
            try? FileManager.default.removeItem(at: self.evidenceDirectory)
        }
    }

    // MARK: - Persistent Checkpoints

    func saveCheckpoint(sessionID: UUID, items: [PluginLabItem], completedIDs: [String]) {
        queue.sync(flags: .barrier) {
            let checkpoint = PluginLabSessionCheckpoint(
                sessionID: sessionID,
                lastUpdated: Date(),
                completedPluginIDs: completedIDs,
                items: items
            )
            let fileURL = self.storageDirectory.appendingPathComponent(self.checkpointFileName)
            if let data = try? JSONEncoder().encode(checkpoint) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    func loadCheckpoint() -> PluginLabSessionCheckpoint? {
        queue.sync {
            let fileURL = storageDirectory.appendingPathComponent(checkpointFileName)
            guard let data = try? Data(contentsOf: fileURL),
                  let checkpoint = try? JSONDecoder().decode(PluginLabSessionCheckpoint.self, from: data) else {
                return nil
            }
            return checkpoint
        }
    }

    // MARK: - Privacy Redaction

    /// Redact entire archive files, preserving valid JSON/JSONL/CSV rather than truncating at 8 KiB.
    static func redactArchiveText(_ input: String) -> String {
        return redactSensitiveData(input, maxBytes: nil)
    }

    /// Allowlist-based privacy redaction stripping tokens, passwords, cookies, and keys.
    static func redactSensitiveData(_ input: String, maxBytes: Int? = 8192) -> String {
        guard !input.isEmpty else { return "" }

        // Bounded line length (8 KiB max)
        var text = input
        if let maxBytes, text.utf8.count > maxBytes {
            text = String(text.prefix(maxBytes / 2)) + " ... [TRUNCATED >8KiB]"
        }

        return text
            // Previously the probe logged Storage.set values. Old persisted reports
            // must also be safe to export after a new build is installed.
            .replacingOccurrences(
                of: #"(Storage set:\s*[^=\r\n]+\s*=\s*)[^\r\n"}]*"#,
                with: "$1[REDACTED]",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"([?&](token|access_token|api_key|key|auth|secret|pass|password|sessid|sid)=)[^&#\s]+"#,
                with: "$1[REDACTED]",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"(Bearer\s+)[A-Za-z0-9_\-\.]+"#,
                with: "$1[REDACTED]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(Basic\s+)[A-Za-z0-9+/=]+"#,
                with: "$1[REDACTED]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(cookie:\s*)[^\r\n]+"#,
                with: "$1[REDACTED]",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"((?:\\?"(?:password|api_key|access_token|authorization|secret|token|cookie|session)\\?"|(?:password|api_key|access_token|authorization|secret|token|cookie|session))\s*[:=]\s*\\?")[^"\\\r\n]*"#,
                with: "$1[REDACTED]",
                options: [.regularExpression, .caseInsensitive]
            )
    }
}
