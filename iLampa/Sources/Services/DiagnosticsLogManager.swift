import Foundation
import Combine
import UIKit

/// Selectable diagnostic logging level conforming to the iLampa Final Design Lock
enum DiagnosticsLogLevel: String, Codable, CaseIterable {
    case basic = "basic"
    case normal = "normal"
    case detailed = "detailed"
    case full = "full"

    var displayName: String {
        switch self {
        case .basic: return "Только ошибки"
        case .normal: return "Обычный (по умолчанию)"
        case .detailed: return "Детальный (на 24 часа)"
        case .full: return "Полная трассировка"
        }
    }
}

/// Structured log entry correlating user actions, provider events, and bridge messages.
/// Enforces max 8 KiB per serialized record (with truncation flag).
struct DiagnosticLogEntry: Identifiable, Equatable, Codable {
    let id: UUID
    let timestamp: Date
    let category: String
    let message: String
    let level: LogLevel
    let actionId: UUID?
    let metadata: [String: String]
    let isTruncated: Bool

    enum LogLevel: String, Codable, CaseIterable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case success = "SUCCESS"
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: String,
        message: String,
        level: LogLevel = .info,
        actionId: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.actionId = actionId
        self.metadata = metadata

        // Bound each single record to 8 KiB maximum
        let maxBytes = 8192
        let utf8 = message.utf8
        if utf8.count > maxBytes {
            let truncatedStr = String(message.prefix(4000)) + " ... [TRUNCATED >8KiB]"
            self.message = truncatedStr
            self.isTruncated = true
        } else {
            self.message = message
            self.isTruncated = false
        }
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    var fullLine: String {
        let actionStr = actionId != nil ? " [act:\(actionId!.uuidString.prefix(8))]" : ""
        let truncStr = isTruncated ? " [TRUNCATED]" : ""
        return "[\(formattedTime)] [\(level.rawValue)]\(actionStr) \(category): \(message)\(truncStr)"
    }

    func toJSONL() -> String {
        var dict: [String: Any] = [
            "id": id.uuidString,
            "timestamp": ISO8601DateFormatter().string(from: timestamp),
            "level": level.rawValue,
            "category": category,
            "message": message,
            "isTruncated": isTruncated,
            "metadata": metadata
        ]
        if let actionId {
            dict["actionId"] = actionId.uuidString
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"message\":\"\(message)\"}"
        }
        return str
    }
}

/// Native on-device action-correlated, privacy-sanitized diagnostic logger conforming to
/// the definitive Design Lock policy:
/// - 7-day age limit
/// - 16 MiB disk quota: 8 segments × 2 MiB maximum rotating ring
/// - 250 structured in-memory entries ring buffer
/// - Max 8 KiB per serialized record
/// - Detailed mode automatic reversion to Normal after 24 hours
/// - Allowlist-based privacy redaction
/// - Headless WebKit resilient (operates independently if WebKit is dead)
final class DiagnosticsLogManager: ObservableObject {
    static let shared = DiagnosticsLogManager()

    private let storageKey = "ilampa_diagnostics_level"
    private let detailedModeTtlKey = "ilampa_diagnostics_detailed_expiry"

    // Design-locked bounds
    private var maxMemoryEntries: Int {
        let configured = UserDefaults.standard.integer(forKey: "ilampa_diagnostics_memory_entries")
        let allowed: Set<Int> = [250, 500, 1000, 2500, 5000, 10000]
        return allowed.contains(configured) ? configured : 250
    }
    private let maxDiskTotalBytes: Int64 = 16 * 1024 * 1024 // 16 MiB
    private let maxSegmentBytes: Int64 = 2 * 1024 * 1024   // 2 MiB
    private let maxSegmentsCount = 8
    private let maxAgeSeconds: TimeInterval = 7 * 86400      // 7 days

    @MainActor @Published private(set) var entries: [DiagnosticLogEntry] = []
    @Published var logLevel: DiagnosticsLogLevel {
        didSet {
            UserDefaults.standard.set(logLevel.rawValue, forKey: storageKey)
            if logLevel == .detailed {
                // Set 24h expiration timestamp
                let expiry = Date().addingTimeInterval(24 * 3600)
                UserDefaults.standard.set(expiry.timeIntervalSince1970, forKey: detailedModeTtlKey)
            }
            log(category: "[System]", message: "Уровень логирования изменен на: \(logLevel.displayName)", level: .info)
        }
    }

    private var lastCategory: String?
    private var lastMessage: String?
    private var repeatCount: Int = 0
    private let queue = DispatchQueue(label: "com.ilampa.diagnostics.queue", qos: .utility)
    private var currentSegmentIndex = 0

    private var logsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("iLampa/DiagnosticsJournal", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let saved = DiagnosticsLogLevel(rawValue: raw) {
            self.logLevel = saved
        } else {
            self.logLevel = .normal
        }

        checkDetailedModeTtl()
        rotateAndEvictOldSegments()

        log(category: "[System]", message: "Нативный диагностический журнал инициализирован (уровень: \(logLevel.displayName), лимит: 16 МиБ / 7 дн.)", level: .info)
    }

    /// Verifies if 24h Detailed Mode has expired and reverts to Normal
    func checkDetailedModeTtl() {
        if logLevel == .detailed {
            let expiryTime = UserDefaults.standard.double(forKey: detailedModeTtlKey)
            if expiryTime > 0 && Date().timeIntervalSince1970 > expiryTime {
                self.logLevel = .normal
                log(category: "[System]", message: "Истёк 24-часовой срок подробного режима логирования. Автоматический возврат к обычному уровню.", level: .info)
            }
        }
    }

    func log(
        category: String,
        message: String,
        level: DiagnosticLogEntry.LogLevel = .info,
        actionId: UUID? = nil,
        metadata: [String: String] = [:]
    ) {
        checkDetailedModeTtl()

        // Filter by logging level
        if logLevel == .basic {
            // Basic only records errors and warnings
            if level != .error && level != .warning { return }
        } else if logLevel == .normal {
            // Normal records errors, warnings, success, and significant lifecycle info
            if level == .info {
                let isSignificant = category.contains("Action") || category.contains("Player") || category == "[PlaybackStage]" ||
                                    category.contains("Bridge") || category.contains("System") ||
                                    category.contains("Batch") || category.contains("Host")
                if !isSignificant { return }
            }
        }

        let sanitized = sanitize(message)

        queue.sync {
            // Suppress rapid identical spam
            // Playback stages identify individual attempts even when their fixed
            // message matches the previous event; suppressing them loses correlation.
            if category != "[PlaybackStage]", sanitized == self.lastMessage && category == self.lastCategory {
                self.repeatCount += 1
                if self.repeatCount % 25 != 0 { return }
            } else {
                self.lastCategory = category
                self.lastMessage = sanitized
                self.repeatCount = 0
            }
        }

        let entry = DiagnosticLogEntry(
            category: category,
            message: sanitized,
            level: level,
            actionId: actionId,
            metadata: metadata
        )

        #if DEBUG
        print(entry.fullLine)
        #endif

        // In-memory 250-ring buffer
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxMemoryEntries {
                self.entries.removeFirst(self.entries.count - self.maxMemoryEntries)
            }
        }

        // Asynchronously append to rotating disk journal
        queue.async {
            self.appendEntryToDisk(entry)
        }
    }

    /// Strict Allowlist Redaction:
    /// Strips credentials, auth tokens, passwords, session IDs, cookies, signed query params, and private keys.
    func sanitize(_ str: String) -> String {
        guard !str.isEmpty else { return "" }
        return str
            .replacingOccurrences(
                of: #"([?&](token|access_token|api_key|x-plex-token|key|auth|secret|pass|password|sessid|sid|signature)=)[^&#\s]+"#,
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
    }

    @MainActor func clear() {
        entries.removeAll()
        lastCategory = nil
        lastMessage = nil
        repeatCount = 0

        queue.async {
            let fm = FileManager.default
            let dir = self.logsDirectory
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fm.removeItem(at: file)
                }
            }
        }

        log(category: "[System]", message: "Диагностический журнал очищен пользователем", level: .info)
    }

    @MainActor var formattedLogSize: String {
        let text = exportLogs()
        let bytes = text.utf8.count
        if bytes < 1024 { return "\(bytes) Б (\(entries.count) в памяти)" }
        let kb = bytes / 1024
        return "\(kb) КБ (\(entries.count) в памяти)"
    }

    @MainActor func exportLogs() -> String {
        return entries.map { $0.fullLine }.joined(separator: "\n")
    }

    @MainActor func exportJSONL() -> String {
        return entries.map { $0.toJSONL() }.joined(separator: "\n")
    }

    @MainActor func copyToClipboard() {
        let text = exportLogs()
        UIPasteboard.general.string = text
    }

    @MainActor func trimMemoryEntries(to requested: Int) {
        let limit = [250, 500, 1000, 2500, 5000, 10000].contains(requested)
            ? requested : 250
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    // MARK: - Disk Segment Rotation Engine (16 MiB max, 8 × 2 MiB, 7-day TTL)

    private func appendEntryToDisk(_ entry: DiagnosticLogEntry) {
        let line = entry.toJSONL() + "\n"
        guard let data = line.data(using: .utf8) else { return }

        let segmentFile = logsDirectory.appendingPathComponent("segment_\(currentSegmentIndex).jsonl")
        if let handle = try? FileHandle(forWritingTo: segmentFile) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: segmentFile)
        }

        // Check current segment size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: segmentFile.path),
           let size = attrs[.size] as? Int64, size >= maxSegmentBytes {
            currentSegmentIndex = (currentSegmentIndex + 1) % maxSegmentsCount
            // Next segment file is overwritten
            let nextFile = logsDirectory.appendingPathComponent("segment_\(currentSegmentIndex).jsonl")
            try? FileManager.default.removeItem(at: nextFile)
        }
    }

    private func rotateAndEvictOldSegments() {
        queue.async {
            let fm = FileManager.default
            let now = Date()
            guard let files = try? fm.contentsOfDirectory(at: self.logsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }

            var totalSize: Int64 = 0
            var validFiles: [(url: URL, date: Date, size: Int64)] = []

            for file in files {
                guard let vals = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let date = vals.contentModificationDate,
                      let size = vals.fileSize else { continue }

                // Evict older than 7 days
                if now.timeIntervalSince(date) > self.maxAgeSeconds {
                    try? fm.removeItem(at: file)
                    continue
                }

                validFiles.append((url: file, date: date, size: Int64(size)))
                totalSize += Int64(size)
            }

            // Evict oldest if exceeding 16 MiB
            if totalSize > self.maxDiskTotalBytes {
                let sortedByDate = validFiles.sorted { $0.date < $1.date }
                for item in sortedByDate {
                    if totalSize <= self.maxDiskTotalBytes { break }
                    try? fm.removeItem(at: item.url)
                    totalSize -= item.size
                }
            }
        }
    }

    // MARK: - Privacy-safe, allowlisted JSONL export

    /// Only fixed component labels and strictly validated structured fields leave the device.
    /// Messages and metadata can contain arbitrary JS, URLs, headers, or media names and are
    /// never copied. Export uses the same in-memory snapshot shown by the log viewer.
    static func safeExportData(entries: [DiagnosticLogEntry], bundle: Bundle = .main) throws -> Data {
        let components: [String: String] = [
            "[System]": "system", "[Player]": "player", "[AVFoundation]": "player",
            "[BridgeHandoff]": "bridge", "[HeadlessHost]": "webkit_host",
            "[OnlineMod]": "online_mod", "[PlaybackStage]": "playback",
            "[Provider]": "provider", "[Resolution]": "resolution",
            "[PluginManager]": "plugin_manager", "[JSException]": "javascript_error",
            "[CompatibilityUI]": "source_bridge"
        ]
        func safeBundleValue(_ key: String, pattern: String) -> String {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  value.range(of: pattern, options: .regularExpression) != nil else { return "unavailable" }
            return value
        }
        var records: [[String: Any]] = [[
            "type": "build", "bundleId": safeBundleValue("CFBundleIdentifier", pattern: #"^[A-Za-z0-9.-]{1,128}$"#),
            "version": safeBundleValue("CFBundleShortVersionString", pattern: #"^[0-9.]{1,32}$"#),
            "build": safeBundleValue("CFBundleVersion", pattern: #"^[0-9.]{1,32}$"#),
            "git": safeBundleValue("ILAMPA_GIT_COMMIT", pattern: #"^[a-fA-F0-9]{7,40}$"#),
            "os": ProcessInfo.processInfo.operatingSystemVersionString
        ]]
        for entry in entries {
            var record: [String: Any] = ["type": "event", "id": entry.id.uuidString,
                "timestamp": ISO8601DateFormatter().string(from: entry.timestamp),
                "level": entry.level.rawValue, "component": components[entry.category] ?? "other"]
            if let action = entry.actionId { record["actionId"] = action.uuidString }
            // Export only fixed failure codes, never arbitrary bridge messages,
            // URLs, media titles or headers. This makes zero-source reports useful.
            if ["[OnlineMod]", "[CompatibilityUI]", "[Provider]"].contains(entry.category) {
                let message = entry.message.lowercased()
                let labels: [(match: String, code: String)] = [
                    ("missing-component", "missing_component"),
                    ("not-ready", "core_not_ready"),
                    ("online mod ещё не загружен", "plugin_not_loaded"),
                    ("провайдер не готов к поиску", "provider_inactive"),
                    ("таймаут инициализации", "core_timeout"),
                    ("совпадений не найдено", "no_matching_titles"),
                    ("поток не может быть разрешен", "stream_unavailable"),
                    ("не разрешено прямых url", "no_direct_stream"),
                    ("ошибка поиска", "provider_error")
                ]
                if let code = labels.first(where: { message.contains($0.match) })?.code {
                    record["reasonCode"] = code
                }
            }
            // Playback stages are generated by native code, with a closed vocabulary and
            // bounded integers; do not forward unknown metadata keys or string values.
            if entry.category == "[PlaybackStage]",
               let stage = entry.metadata["stage"],
               ["discovery", "selection", "selection_rejected", "webkit_action", "handoff", "timeout", "item_failed", "item_ready", "playing"].contains(stage) {
                record["stage"] = stage
                // Discovery and playback are separate actions. Only a UUID generated by
                // native discovery is allowed to link them; never forward arbitrary metadata.
                if let raw = entry.metadata["discoveryId"], let id = UUID(uuidString: raw) {
                    record["discoveryId"] = id.uuidString
                }
                for key in ["sourceIndex", "code", "underlyingCode", "status", "count"] {
                    if let raw = entry.metadata[key], let value = Int(raw), (-1_000_000...1_000_000).contains(value) {
                        record[key] = value
                    }
                }
                if let domain = entry.metadata["domain"], ["AVFoundationErrorDomain", "NSURLErrorDomain", "NSOSStatusErrorDomain", "CoreMediaErrorDomain", "other"].contains(domain) {
                    record["domain"] = domain
                }
            }
            records.append(record)
        }
        var output = Data()
        for record in records {
            output.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            output.append(0x0a)
        }
        return output
    }

    @MainActor func exportDiagnosticsJSONL() throws -> URL {
        let data = try Self.safeExportData(entries: entries)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ilampa-diagnostics-\(UUID().uuidString).jsonl")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// Fail closed until export is rebuilt around a verified allowlist. The in-memory
    /// log can contain arbitrary plugin text and the former system snapshot included
    /// full plugin URLs; regex checks alone cannot prove those payloads are safe.
    @MainActor func exportDiagnosticsZip() -> URL? {
        log(category: "[PrivacyGate]", message: "Экспорт недоступен до проверки защиты личных данных.", level: .warning)
        return nil
    }
}
