import SwiftUI

// MARK: - 1. Priority Sources View (`priority`)
struct PrioritySourcesView: View {
    @ObservedObject private var engine = SourceProviderEngine.shared
    @AppStorage(SourcePriority.storageKey) private var savedPriority = ""

    private var orderedProviders: [SourceProviderProtocol] {
        let providers = engine.providers.filter { $0.canResolveDirectly }
        let keys = SourcePriority.order(saved: SourcePriority.decode(savedPriority), available: providers.map(\.providerId))
        return keys.compactMap { key in providers.first { $0.providerId == key } }
    }

    var body: some View {
        Form {
            Section {
                ForEach(orderedProviders, id: \.providerId) { provider in
                    VStack(alignment: .leading) {
                        Text(provider.displayName)
                        if !provider.isConfigured {
                            Text("Не настроен").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .onMove { indices, destination in
                    var keys = orderedProviders.map(\.providerId)
                    keys.move(fromOffsets: indices, toOffset: destination)
                    // Retain preferences for temporarily absent providers.
                    let missing = SourcePriority.decode(savedPriority).filter { !keys.contains($0) }
                    savedPriority = SourcePriority.encode(keys + missing)
                    engine.invalidateCache()
                }

            } header: {
                Text("Прямые источники")
            } footer: {
                Text("Перетащите источники в нужном порядке. Приоритет влияет на прямой поиск, но не на интерактивные плагины.")
            }
        }
        .navigationTitle("Приоритет источников")
        .toolbar { EditButton() }
    }
}

// MARK: - 2. Online Mod View (`onlinemod`)
struct OnlineModView: View {
    @AppStorage("use_external_onlinemod") private var useExternalScript = false

    var body: some View {
        Form {
            Section("РЕАЛИЗАЦИЯ") {
                Button {
                    useExternalScript = false
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Встроенная")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Использовать модуль из приложения")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if !useExternalScript {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }

                NavigationLink(destination: OnlineModExternalView()) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Внешний скрипт")
                            .font(.body)
                            .foregroundColor(.primary)
                        Text("Для разработчиков, требуется проверка")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("СОСТОЯНИЕ") {
                LabeledContent("Обнаружение", value: useExternalScript ? "Внешний скрипт" : "Встроенный модуль")
                LabeledContent("Потоки", value: "Проверяются при выборе")

                NavigationLink(destination: LogViewerSubView(initialFilter: "OnlineMod")) {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Просмотреть ошибки")
                                .font(.body)
                            Text("Фильтр журнала для Online Mod")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                Text("Смена реализации — явное действие. Существующие параметры остаются без изменений до подтверждения.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Online Mod")
    }
}

// MARK: - 3. Online Mod External View (`onlinemodexternal`)
struct OnlineModExternalView: View {
    @AppStorage("external_onlinemod_url") private var externalScriptUrl = "https://bwa.ad/online.js"
    @State private var checkStatus: String?

    var body: some View {
        Form {
            Section("АДРЕС") {
                TextField("https://example.org/online_mod.js", text: $externalScriptUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Text("Код стороннего автора может выполнять действия от имени плагина. Проверьте источник перед включением.")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Section("ПРОВЕРКА") {
                Button("Проверить скрипт") {
                    checkScript()
                }
                if let status = checkStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Внешний скрипт")
    }

    private func checkScript() {
        checkStatus = "Проверка…"
        Task {
            guard let url = URL(string: externalScriptUrl) else {
                await MainActor.run { checkStatus = "Некорректный адрес URL" }
                return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 5.0
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    await MainActor.run { checkStatus = "Скрипт доступен (\(data.count) байт)" }
                } else {
                    await MainActor.run { checkStatus = "Ошибка HTTP ответа" }
                }
            } catch {
                await MainActor.run { checkStatus = "Сбой соединения: \(error.localizedDescription)" }
            }
        }
    }
}

// MARK: - 4. AniLibria Detail View (`sourcedetail`)
struct AniLibriaDetailView: View {
    @State private var checkStatus: String?
    @State private var isChecking = false

    var body: some View {
        Form {
            Section("ВОЗМОЖНОСТЬ") {
                LabeledContent("Тип", value: "Нативный источник")
                LabeledContent("Настройка", value: "В приложении")
                LabeledContent("Просмотр", value: "Проверяется при выборе")
            }

            Section("ПРОБЛЕМЫ") {
                Button {
                    runCheck()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isChecking ? "Проверка…" : "Проверить доступность")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Никакой автоматической переустановки")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isChecking)

                if let status = checkStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                NavigationLink(destination: LogViewerSubView(initialFilter: "AniLibria")) {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Журнал AniLibria")
                                .font(.body)
                            Text("Связанные ошибки и события")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("AniLibria")
    }

    private func runCheck() {
        isChecking = true
        checkStatus = nil
        Task {
            guard let url = URL(string: "https://api.anilibria.tv/v3/title/search?search=test") else { return }
            var req = URLRequest(url: url)
            req.timeoutInterval = 5.0
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    await MainActor.run {
                        checkStatus = "API AniLibria доступно (HTTP \(http.statusCode))"
                        isChecking = false
                    }
                } else {
                    await MainActor.run {
                        checkStatus = "API вернуло ошибку"
                        isChecking = false
                    }
                }
            } catch {
                await MainActor.run {
                    checkStatus = "Ошибка подключения: \(error.localizedDescription)"
                    isChecking = false
                }
            }
        }
    }
}

// MARK: - 5. Kodik Setup View (`sourceissue` / `kodiksetup`)
struct KodikSetupView: View {
    @AppStorage("kodik_api_token") private var kodikToken = ""
    @AppStorage("kodik_api_endpoint") private var kodikEndpoint = "https://kodikapi.com"

    var body: some View {
        Form {
            Section("ПОДКЛЮЧЕНИЕ") {
                LabeledContent("Состояние", value: kodikToken.isEmpty ? "Не настроено" : "Настроено")
                TextField("API токен (Kodik)", text: $kodikToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Адрес API", text: $kodikEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                Text("Требования к ключу или авторизации определяются реальным адаптером. Макет не предполагает универсальный пароль.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Kodik")
    }
}

// MARK: - 6. Media Servers View (`servers`)
struct MediaServersView: View {
    var onPlayCustomUrl: ((String, String, Bool) -> Void)? = nil
    @ObservedObject private var sourceManager = SourceManager.shared
    @State private var selectedServer: LampaSourceRecord?

    enum ServerKind: String, CaseIterable, Identifiable {
        case torrserver = "TorrServer"
        case jellyfin = "Jellyfin"
        case plex = "Plex"
        case emby = "Emby"
        var id: String { rawValue }
        var description: String {
            switch self {
            case .torrserver: return "Торрент-клиент и кэш"
            case .jellyfin: return "Персональная медиатека"
            case .plex: return "Персональная медиатека"
            case .emby: return "Персональная медиатека"
            }
        }
    }

    var body: some View {
        Form {
            Section("ДОСТУПНЫЕ ТИПЫ") {
                ForEach(sourceManager.registeredSources.filter {
                    ["jellyfin", "plex", "emby", "torrserver_default"].contains($0.canonicalKey)
                }) { server in
                    Button {
                        selectedServer = server
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.displayName)
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text(server.canonicalKey == "torrserver_default" ? "Сервер воспроизведения" : "Личная медиатека")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.bold()).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Медиасерверы")
        .navigationDestination(isPresented: Binding(
            get: { selectedServer != nil },
            set: { if !$0 { selectedServer = nil } }
        )) {
            if let server = selectedServer {
                SourceConfigurationDetailView(record: server, onPlayCustomUrl: onPlayCustomUrl)
            }
        }
    }
}

// MARK: - 7. Server Detail View (`serverdetail`)
struct ServerDetailView: View {
    let serverType: String
    let serverSubtitle: String

    @State private var host = ""
    @State private var token = ""
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("ПОДКЛЮЧЕНИЕ") {
                TextField("Адрес сервера (http://…)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Токен / пароль (при наличии)", text: $token)
            }

            Section("ДЕЙСТВИЯ") {
                Button {
                    runTest()
                } label: {
                    HStack {
                        Text(isTesting ? "Проверка…" : "Проверить соединение")
                        if isTesting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isTesting || host.isEmpty)

                if let res = testResult {
                    Text(res)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Сохранить конфигурацию") {
                    UserDefaults.standard.set(host, forKey: "server_\(serverType)_host")
                    UserDefaults.standard.set(token, forKey: "server_\(serverType)_token")
                    testResult = "Конфигурация сохранена"
                }
                .disabled(host.isEmpty)
            }
        }
        .navigationTitle(serverType)
        .onAppear {
            host = UserDefaults.standard.string(forKey: "server_\(serverType)_host") ?? ""
            token = UserDefaults.standard.string(forKey: "server_\(serverType)_token") ?? ""
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            guard let url = URL(string: host) else {
                await MainActor.run {
                    testResult = "Некорректный URL"
                    isTesting = false
                }
                return
            }
            var req = URLRequest(url: url)
            req.timeoutInterval = 4.0
            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse {
                    await MainActor.run {
                        testResult = "Сервер ответил кодом HTTP \(http.statusCode)"
                        isTesting = false
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = "Ошибка соединения: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}

// MARK: - 8. Direct Stream View (`direct`)
struct DirectStreamView: View {
    @State private var streamUrl = ""
    var onPlayDirect: ((String) -> Void)?

    private var cleanURL: String { streamUrl.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasValidURL: Bool {
        guard let url = URL(string: cleanURL), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil else { return false }
        return true
    }

    var body: some View {
        Form {
            Section("ПРЯМАЯ ССЫЛКА") {
                TextField("URL видеопотока (HLS .m3u8 или MP4)", text: $streamUrl)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                NavigationLink(destination: DirectReviewView(url: cleanURL, onPlay: {
                    onPlayDirect?(cleanURL)
                })) {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle")
                            .foregroundColor(.blue)
                        Text("Проверить ссылку")
                    }
                }
                .disabled(!hasValidURL)
            }

            Section {
                Text("Прямые потоки воспроизводятся встроенным AVPlayer без использования плагинов.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Прямая ссылка")
    }
}

// MARK: - 9. Direct Review View (`directreview`)
struct DirectReviewView: View {
    let url: String
    var onPlay: (() -> Void)?

    var format: String {
        let l = url.lowercased()
        if l.contains(".m3u8") { return "HLS" }
        if l.contains(".mp4") { return "MP4" }
        if l.contains(".mkv") { return "MKV" }
        return "Неизвестный формат"
    }

    var body: some View {
        Form {
            Section("СВЕДЕНИЯ О ПОТОКЕ") {
                LabeledContent("Адрес", value: url)
                LabeledContent("Формат", value: format)
                LabeledContent("Поток", value: "Не проверен")
                LabeledContent("Качество", value: "Неизвестно")
            }

            Section {
                Button {
                    onPlay?()
                } label: {
                    HStack {
                        Spacer()
                        Label("Открыть в плеере", systemImage: "play.fill")
                            .bold()
                        Spacer()
                    }
                }
                .foregroundColor(.blue)
            }
        }
        .navigationTitle("Проверка ссылки")
    }
}
