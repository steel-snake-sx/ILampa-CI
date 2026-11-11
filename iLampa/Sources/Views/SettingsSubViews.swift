import SwiftUI
import WebKit

// MARK: - Network and catalog

struct NetworkSettingsView: View {
    @AppStorage("lampa_instance_url") private var catalogURL = "https://bylampa.online"
    @AppStorage("lampa_backup_instance_url") private var backupURL = ""
    @State private var primaryDraft = ""
    @State private var backupDraft = ""
    @State private var checking = false
    @State private var catalogStatus = "Не проверено"
    @State private var backupStatus = "Не проверено"
    @State private var invalidAddress = false

    var body: some View {
        Form {
            Section {
                TextField("Основной URL", text: $primaryDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .accessibilityIdentifier("catalogPrimaryURL")
                TextField("Резервный URL (необязательно)", text: $backupDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .accessibilityIdentifier("catalogBackupURL")
                Button("Сохранить адреса") {
                    saveAddresses()
                }
            } header: {
                Text("Адреса каталога")
            } footer: {
                Text("Резервный адрес можно проверять отдельно. Автоматическое переключение между адресами пока не включено.")
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Основной").font(.subheadline.weight(.medium))
                    Text(catalogStatus).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Резервный").font(.subheadline.weight(.medium))
                    Text(backupStatus).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    Task { await checkConnections() }
                } label: {
                    HStack {
                        Label("Проверить соединение", systemImage: "network")
                        Spacer()
                        if checking { ProgressView() }
                    }
                }
                .disabled(checking)
                .accessibilityIdentifier("runRealNetworkCheck")
            } header: {
                Text("Проверка доступности")
            } footer: {
                Text("Проверяются реальные HTTP-ответы адресов каталога, а не доступность всего интернета.")
            }
        }
        .navigationTitle("Сеть и каталог")
        .onAppear {
            primaryDraft = catalogURL
            backupDraft = backupURL
        }
        .task { await checkConnections() }
        .alert("Некорректный адрес", isPresented: $invalidAddress) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text("Основной и резервный адреса должны быть корректными HTTP- или HTTPS-URL.")
        }
    }

    private func validAddress(_ address: String) -> Bool {
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme), url.host != nil else { return false }
        return true
    }

    private func saveAddresses() {
        let primary = primaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let backup = backupDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validAddress(primary), backup.isEmpty || validAddress(backup) else {
            invalidAddress = true
            return
        }
        catalogURL = primary
        backupURL = backup
        Task { await checkConnections() }
    }

    @MainActor
    private func checkConnections() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        catalogStatus = "Проверка…"
        backupStatus = "Не настроен"
        catalogStatus = await checkHTTP(catalogURL)
        let backup = backupURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !backup.isEmpty {
            backupStatus = "Проверка…"
            backupStatus = await checkHTTP(backup)
        }
    }

    private func checkHTTP(_ address: String) async -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validAddress(trimmed), let url = URL(string: trimmed) else { return "Некорректный адрес" }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "Нет HTTP-ответа" }
            return (200...399).contains(http.statusCode)
                ? "Доступен · HTTP \(http.statusCode)"
                : "HTTP \(http.statusCode)"
        } catch {
            return "Недоступен · проверьте адрес и соединение"
        }
    }
}

// MARK: - 5. Storage Settings View (`storage`)
struct StorageSettingsView: View {
    @State private var httpCacheSize = "Проверка…"
    @State private var diagnosticLogSize = "Проверка…"
    @State private var showConfirmSheet = false
    @State private var showSuccessAlert = false

    var body: some View {
        Form {
            Section("Использование памяти") {
                LabeledContent("HTTP-кэш приложения", value: httpCacheSize)
                LabeledContent("Журнал диагностики", value: diagnosticLogSize)
                LabeledContent("Размер кэша WebKit", value: "Недоступен")
            }

            Section("Очистка") {
                Button("Очистить HTTP-кэш") {
                    URLCache.shared.removeAllCachedResponses()
                    refreshUsage()
                    showSuccessAlert = true
                }
                Button("Очистить временный кэш WebKit", role: .destructive) {
                    showConfirmSheet = true
                }
            }

            Section {
                Text("Удаляется только временный кэш. Cookies, данные сайтов, плагины, настройки и история просмотров сохраняются.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Хранилище")
        .onAppear(perform: refreshUsage)
        .alert("Кэш очищен", isPresented: $showSuccessAlert) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text("Операция очистки кэша завершена.")
        }
        .confirmationDialog("Очистить кэш WebKit?", isPresented: $showConfirmSheet, titleVisibility: .visible) {
            Button("Очистить кэш", role: .destructive) {
                let store = WKWebsiteDataStore.default()
                let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]
                store.fetchDataRecords(ofTypes: types) { records in
                    store.removeData(ofTypes: types, for: records) {
                        DispatchQueue.main.async {
                            refreshUsage()
                            showSuccessAlert = true
                        }
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Cookies, авторизация и сохранённые данные сайтов не удаляются.")
        }
    }

    private func refreshUsage() {
        let cache = URLCache.shared
        let totalBytes = Int64(cache.currentDiskUsage) + Int64(cache.currentMemoryUsage)
        httpCacheSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        let journal = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("iLampa/DiagnosticsJournal", isDirectory: true)
        guard let journal, FileManager.default.fileExists(atPath: journal.path) else {
            diagnosticLogSize = "0 Б"
            return
        }
        let files = FileManager.default.enumerator(at: journal, includingPropertiesForKeys: [.fileSizeKey])
        var size: Int64 = 0
        while let url = files?.nextObject() as? URL {
            if let length = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(length)
            }
        }
        diagnosticLogSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - 7. Appearance Settings View (`appearance`)
struct AppearanceSettingsView: View {
    @AppStorage("app_appearance_mode") private var appearanceMode = "system"
    private var selectedMode: AppearanceMode { AppearanceMode(storedValue: appearanceMode) }

    var body: some View {
        Form {
            Section("ТЕМА") {
                Button {
                    appearanceMode = AppearanceMode.system.rawValue
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                            .opacity(selectedMode == .system ? 1 : 0)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Как в системе")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Рекомендуется")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
                .accessibilityIdentifier("appearance_system")
                .accessibilityValue(selectedMode == .system ? "Выбрано" : "Не выбрано")

                Button {
                    appearanceMode = AppearanceMode.light.rawValue
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                            .opacity(selectedMode == .light ? 1 : 0)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Светлая")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Для приложения")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
                .accessibilityIdentifier("appearance_light")
                .accessibilityValue(selectedMode == .light ? "Выбрано" : "Не выбрано")

                Button {
                    appearanceMode = AppearanceMode.dark.rawValue
                } label: {
                    HStack {
                        Image(systemName: "checkmark")
                            .foregroundColor(.blue)
                            .opacity(selectedMode == .dark ? 1 : 0)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Тёмная")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Для приложения")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
                .accessibilityIdentifier("appearance_dark")
                .accessibilityValue(selectedMode == .dark ? "Выбрано" : "Не выбрано")
            }
        }
        .navigationTitle("Внешний вид")
        .overlay(alignment: .topLeading) {
            AppearanceTestProbe(identifier: "appearance_settings_scheme")
        }
    }
}
