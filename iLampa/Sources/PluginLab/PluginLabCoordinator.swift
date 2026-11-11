import Foundation
import SwiftUI
import Combine

/// Central coordinator for autonomous plugin compatibility testing.
/// Manages the diagnostic campaign lifecycle, one-switch toggle, sequential runner,
/// live UI metrics, and report export.
@MainActor
final class PluginLabCoordinator: ObservableObject {
    static let shared = PluginLabCoordinator()

    // MARK: - Published State for UI

    @Published var isDiagnosticsActive: Bool = false {
        didSet {
            if isDiagnosticsActive && !isSessionRunning {
                startDiagnostics()
            } else if !isDiagnosticsActive && isSessionRunning {
                stopDiagnostics()
            }
        }
    }

    @Published private(set) var inventory: [PluginLabItem] = []
    @Published private(set) var currentPlugin: PluginLabItem? = nil
    @Published private(set) var currentStageText: String = "Готов к запуску"
    @Published private(set) var progress: Double = 0.0

    @Published private(set) var discoveredCount: Int = 0
    @Published private(set) var testedCount: Int = 0
    @Published private(set) var passCount: Int = 0
    @Published private(set) var partialCount: Int = 0
    @Published private(set) var failCount: Int = 0
    @Published private(set) var inconclusiveCount: Int = 0

    @Published private(set) var lastReportDate: Date? = nil
    @Published private(set) var lastReportDuration: TimeInterval = 0.0
    @Published private(set) var lastReportURL: URL? = nil
    @Published private(set) var isExporting: Bool = false
    @Published var exportError: String? = nil

    // MARK: - Internal Session Controls

    private var sessionID = UUID()
    private var sessionStartTime: Date? = nil
    private var sessionFinishTime: Date? = nil
    private var isSessionRunning = false
    private var activeTestTask: Task<Void, Never>? = nil
    private let runner: PluginTestRunner
    private let runtimeProbe: PluginRuntimeProbe

    private init() {
        self.runner = PluginTestRunner()
        self.runtimeProbe = PluginRuntimeProbe()
        loadInitialInventory()
    }

    // MARK: - Initial Inventory & Resume

    private func loadInitialInventory() {
        // Try restoring from persistent checkpoint first
        if let checkpoint = PluginDiagnosticsRecorder.shared.loadCheckpoint() {
            self.sessionID = checkpoint.sessionID
            self.inventory = checkpoint.items
            recalculateCounters()
            self.lastReportDate = checkpoint.lastUpdated
            return
        }

        // Discover inventory from application sources
        let discovered = PluginLabDiscovery.shared.discoverPlugins()
        self.inventory = discovered
        recalculateCounters()
    }

    private func recalculateCounters() {
        discoveredCount = inventory.count
        testedCount = inventory.filter { $0.stage == .completed || $0.stage == .failed }.count
        passCount = inventory.filter { $0.status == .pass }.count
        partialCount = inventory.filter { $0.status == .partial }.count
        failCount = inventory.filter { $0.status == .fail }.count
        inconclusiveCount = inventory.filter { $0.status == .blocked || $0.status == .untested }.count

        if discoveredCount > 0 {
            progress = Double(testedCount) / Double(discoveredCount)
        } else {
            progress = 0.0
        }
    }

    // MARK: - Campaign Execution

    func startDiagnostics() {
        guard !isSessionRunning else { return }
        isSessionRunning = true
        isDiagnosticsActive = true
        sessionStartTime = Date()
        sessionFinishTime = nil
        // Preserve the restored campaign identity and its persisted evidence when resuming.
        if inventory.allSatisfy({ $0.stage == .pending }) {
            sessionID = UUID()
        }

        activeTestTask = Task {
            currentStageText = "Подготовка кампании тестирования..."

            // If inventory is empty, refresh discovery
            if inventory.isEmpty {
                inventory = PluginLabDiscovery.shared.discoverPlugins()
                recalculateCounters()
            }

            var completedIDs: [String] = inventory.filter { $0.stage == .completed }.map(\.id)

            // Sequentially test each uncompleted plugin
            for index in 0..<inventory.count {
                if Task.isCancelled || !self.isDiagnosticsActive { break }

                var item = inventory[index]
                if item.stage == .completed { continue }

                currentPlugin = item
                currentStageText = "Тестирование: \(item.name)..."

                // Run the complete lifecycle test
                let resultItem = await runner.runDiagnostic(
                    item: item,
                    runtimeProbe: runtimeProbe,
                    onStageChanged: { [weak self] stage, stageMessage in
                        guard let self else { return }
                        self.currentStageText = "\(item.name): \(stageMessage)"
                    }
                )

                self.inventory[index] = resultItem
                completedIDs.append(resultItem.id)
                recalculateCounters()

                // Save persistent checkpoint after each completed test
                PluginDiagnosticsRecorder.shared.saveCheckpoint(
                    sessionID: self.sessionID,
                    items: self.inventory,
                    completedIDs: completedIDs
                )
            }

            // Teardown probe runtime
            runtimeProbe.teardown()
            currentPlugin = nil

            let finished = Date()
            sessionFinishTime = finished
            let duration = sessionStartTime.map { finished.timeIntervalSince($0) } ?? 0.0
            lastReportDuration = duration
            lastReportDate = finished
            currentStageText = "Диагностика завершена за \(String(format: "%.1f", duration)) с"

            isSessionRunning = false
            isDiagnosticsActive = false

            // Prepare ZIP, but surface failures rather than silently swallowing them.
            do {
                _ = try exportReportArchive()
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    func stopDiagnostics() {
        isSessionRunning = false
        isDiagnosticsActive = false
        activeTestTask?.cancel()
        activeTestTask = nil
        runtimeProbe.teardown()
        currentStageText = "Диагностика приостановлена пользователем"
        currentPlugin = nil
    }

    func runAgain() {
        stopDiagnostics()
        PluginDiagnosticsRecorder.shared.clear()

        // Reset inventory statuses
        let fresh = PluginLabDiscovery.shared.discoverPlugins()
        inventory = fresh
        recalculateCounters()

        startDiagnostics()
    }

    // MARK: - Export

    func exportReportArchive() throws -> URL {
        isExporting = true
        defer { isExporting = false }

        let bundle = Bundle.main
        let exportFinished = sessionFinishTime ?? Date()
        let exportStarted = sessionStartTime ?? exportFinished
        let duration = max(0, exportFinished.timeIntervalSince(exportStarted))
        let env = PluginLabEnvironment(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            gitCommit: bundle.object(forInfoDictionaryKey: "ILAMPA_GIT_COMMIT") as? String ?? "not embedded",
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            runtimeType: "WebKit + PluginLabProbe",
            webkitConfiguration: "Unobtrusive Inactive Policy None",
            testRunnerVersion: "PluginLab-Runner/2.1",
            startedAt: exportStarted,
            finishedAt: exportFinished
        )

        let archiveURL = try PluginReportExporter.exportArchive(
            sessionID: sessionID,
            environment: env,
            inventory: inventory,
            allEvidence: PluginDiagnosticsRecorder.shared.allEvidence(),
            duration: duration
        )

        self.lastReportURL = archiveURL
        return archiveURL
    }
}
