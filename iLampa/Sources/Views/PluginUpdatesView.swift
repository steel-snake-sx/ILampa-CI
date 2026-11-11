import SwiftUI
import CryptoKit

/// Checks remote JavaScript bytes against the installed copy.
/// A changed remote script is never trusted or executed automatically.
@MainActor
struct PluginUpdatesView: View {
    @ObservedObject private var manager = PluginManager.shared
    @State private var results: [UUID: String] = [:]
    @State private var changedPlugins: Set<UUID> = []
    @State private var isChecking = false
    @State private var isPreparing: UUID?
    @State private var checkedCount = 0
    @State private var approvalID: UUID?
    @State private var approvalHash: String?
    @State private var errorMessage: String?
    @State private var checkTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Button {
                    checkTask?.cancel()
                    checkTask = Task { await checkAll() }
                } label: {
                    HStack {
                        Label(isChecking ? "Проверка…" : "Проверить обновления", systemImage: "arrow.clockwise")
                        Spacer()
                        if isChecking { ProgressView() }
                    }
                }
                .disabled(isChecking)
                .accessibilityIdentifier("checkPluginUpdatesButton")

                if isChecking {
                    Text("Проверено \(checkedCount) из \(manager.installedPlugins.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Проверка")
            } footer: {
                Text("Сравнивается SHA-256 загруженного кода с локальной копией. Изменение кода не всегда означает новую версию. Ничего не запускается автоматически.")
            }

            Section("Установленные плагины") {
                ForEach(manager.installedPlugins) { plugin in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(plugin.name)
                                .font(.body.weight(.medium))
                                .lineLimit(2)
                            Spacer()
                            Text(results[plugin.id] ?? "Не проверено")
                                .font(.footnote)
                                .foregroundStyle(changedPlugins.contains(plugin.id) ? Color.orange : Color.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        if changedPlugins.contains(plugin.id) {
                            HStack {
                                Text("Код на сервере отличается от установленного.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(isPreparing == plugin.id ? "Загрузка…" : "Подготовить") {
                                    Task { await stageUpdate(pluginID: plugin.id) }
                                }
                                .disabled(isPreparing != nil || isChecking)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Обновления плагинов")
        .onDisappear {
            checkTask?.cancel()
            if let id = approvalID { manager.discardStagedUpdate(pluginID: id) }
        }
        .confirmationDialog("Подтвердить обновление плагина?", isPresented: Binding(
            get: { approvalID != nil },
            set: { if !$0 {
                if let id = approvalID { manager.discardStagedUpdate(pluginID: id) }
                approvalID = nil
                approvalHash = nil
            } }
        ), titleVisibility: .visible) {
            Button("Подтвердить код и включить") {
                if let id = approvalID, let hash = approvalHash {
                    if manager.approveStagedUpdate(pluginID: id, expectedSHA256: hash) {
                        changedPlugins.remove(id)
                        results[id] = "Обновление подтверждено"
                    } else {
                        errorMessage = "Код изменился с момента проверки. Повторите проверку."
                    }
                }
                approvalID = nil
                approvalHash = nil
            }
            Button("Отмена", role: .cancel) {
                if let id = approvalID { manager.discardStagedUpdate(pluginID: id) }
                approvalID = nil
                approvalHash = nil
            }
        } message: {
            Text("Загруженный код изменился. После подтверждения плагин сможет выполнять JavaScript. Без подтверждения новая версия не запускается.")
        }
        .alert("Не удалось обновить плагин", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("ОК", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func checkAll() async {
        guard !isChecking else { return }
        isChecking = true
        checkedCount = 0
        defer { isChecking = false }
        changedPlugins.removeAll()
        for plugin in manager.installedPlugins {
            if Task.isCancelled { return }
            let scheme = plugin.url.scheme?.lowercased()
            guard scheme == "https" || scheme == "http" else {
                results[plugin.id] = "Встроенный · вместе с приложением"
                checkedCount += 1
                continue
            }
            guard let localHash = manager.cachedScriptSHA256(for: plugin.urlString) else {
                results[plugin.id] = "Нет локального кода"
                checkedCount += 1
                continue
            }
            do {
                var request = URLRequest(url: plugin.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                request.httpMethod = "GET"
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      data.count <= 2_000_000, !data.isEmpty,
                      let source = String(data: data, encoding: .utf8),
                      Data(source.utf8) == data,
                      !source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
                    results[plugin.id] = "Некорректный ответ сервера"
                    checkedCount += 1
                    continue
                }
                let remoteHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if remoteHash == localHash {
                    results[plugin.id] = "Без изменений"
                } else {
                    results[plugin.id] = "Изменение кода"
                    changedPlugins.insert(plugin.id)
                }
            } catch is CancellationError {
                return
            } catch {
                results[plugin.id] = "Недоступен для проверки"
            }
            checkedCount += 1
        }
    }

    private func stageUpdate(pluginID: UUID) async {
        guard isPreparing == nil else { return }
        isPreparing = pluginID
        defer { isPreparing = nil }
        do {
            let hash = try await manager.stageUpdatedScriptForApproval(pluginID: pluginID)
            approvalID = pluginID
            approvalHash = hash
        } catch {
            errorMessage = "Не удалось безопасно загрузить изменённый JavaScript. Проверьте доступность источника."
        }
    }
}
