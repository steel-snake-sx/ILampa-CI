import SwiftUI

// MARK: - Source Detail & Configuration View
@MainActor
struct SourceConfigurationDetailView: View {
    let record: LampaSourceRecord
    var onPlayCustomUrl: ((String, String, Bool) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine = SourceProviderEngine.shared
    @StateObject private var sourceManager = SourceManager.shared
    @ObservedObject private var onlineModPref = OnlineModPreferenceManager.shared

    // Storage for credentials
    @AppStorage("torrserver_host") private var torrServerHost = "192.168.1.100"
    @AppStorage("torrserver_port") private var torrServerPort = "8090"
    @AppStorage("torrserver_auth_enabled") private var torrServerAuth = false
    @AppStorage("torrserver_username") private var torrServerUser = ""
    @AppStorage("torrserver_password") private var torrServerPass = ""

    @AppStorage("jellyfin_host") private var jellyfinHost = ""
    @AppStorage("jellyfin_port") private var jellyfinPort = "8096"
    @AppStorage("jellyfin_api_key") private var jellyfinApiKey = ""

    @AppStorage("plex_host") private var plexHost = ""
    @AppStorage("plex_port") private var plexPort = "32400"
    @AppStorage("plex_token") private var plexToken = ""

    @AppStorage("emby_host") private var embyHost = ""
    @AppStorage("emby_port") private var embyPort = "8096"
    @AppStorage("emby_api_key") private var embyApiKey = ""

    @AppStorage("kodik_api_token") private var kodikApiToken = ""

    // Testing States
    @State private var isTestingConnectivity = false
    @State private var connectivityResult: String? = nil
    @State private var isTestingResolution = false
    @State private var resolutionResult: String? = nil
    @State private var resolvedSampleUrl: String? = nil
    @State private var showConfirmDelete = false
    @State private var pendingOnlineModPreference: OnlineModOriginPreference?

    private var currentRecord: LampaSourceRecord {
        sourceManager.registeredSources.first(where: { $0.id == record.id }) ?? record
    }

    var body: some View {
            Form {
                // Header overview
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: iconName)
                            .font(.system(size: 32))
                            .foregroundColor(iconColor)
                            .frame(width: 52, height: 52)
                            .background(iconColor.opacity(0.12))
                            .cornerRadius(12)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentRecord.displayName)
                                .font(.title3.bold())
                            Text(providerTypeDescription)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        StatusBadge(status: currentStatus)
                    }
                    .padding(.vertical, 4)

                    Toggle("Источник включен", isOn: Binding(
                        get: { currentRecord.isEnabled },
                        set: { _ in sourceManager.toggleSource(id: currentRecord.id) }
                    ))
                }

                // MARK: - Testing Actions (Connectivity vs Resolution)
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        // Test 1: Connectivity (Network Reachability / Ping)
                        HStack {
                            Button(action: runConnectivityTest) {
                                HStack {
                                    if isTestingConnectivity {
                                        ProgressView().scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "network")
                                    }
                                    Text("Проверить соединение (Ping / HTTP)")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(isTestingConnectivity)
                            .accessibilityIdentifier("testConnectivityButton")

                            Spacer()
                        }

                        if let conn = connectivityResult {
                            Text(conn)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(6)
                        }

                        Divider()

                        // Test 2: Resolution (Full Media Stream Resolver)
                        HStack {
                            Button(action: runResolutionTest) {
                                HStack {
                                    if isTestingResolution {
                                        ProgressView().scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "play.circle.fill")
                                    }
                                    Text("Проверить разрешение потока (Resolve)")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(isTestingResolution)
                            .accessibilityIdentifier(resolutionButtonIdentifier)

                            Spacer()
                        }

                        if let res = resolutionResult {
                            Text(res)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(UIColor.secondarySystemBackground))
                                .cornerRadius(6)
                        }

                        if let sample = resolvedSampleUrl {
                            Button("Воспроизвести образец в AVPlayer") {
                                onPlayCustomUrl?(sample, "\(currentRecord.displayName) (Образец)", false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("playSampleStreamButton")
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Label("Тестирование доступности", systemImage: "stethoscope")
                } footer: {
                    Text("Сетевой ответ или результат поиска не подтверждает успешное воспроизведение.")
                        .font(.caption)
                }

                // MARK: - Credentials & Parameters Configuration
                switch currentRecord.canonicalKey {
                case "torrserver_default":
                    Section {
                        HStack {
                            Text("IP-адрес")
                            Spacer()
                            TextField("192.168.1.100", text: $torrServerHost)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }

                        HStack {
                            Text("Порт")
                            Spacer()
                            TextField("8090", text: $torrServerPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }

                        Toggle("Авторизация (пароль)", isOn: $torrServerAuth)

                        if torrServerAuth {
                            TextField("Имя пользователя", text: $torrServerUser)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            SecureField("Пароль", text: $torrServerPass)
                        }
                    } header: {
                        Label("Параметры TorrServer", systemImage: "server.rack")
                    } footer: {
                        Text("Укажите локальный адрес запущенного сервера TorrServer Matrix/MatriX.")
                            .font(.caption)
                    }

                case "kodik_anime":
                    Section {
                        SecureField("API-токен Kodik", text: $kodikApiToken)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } header: {
                        Label("Авторизация Kodik", systemImage: "key.fill")
                    } footer: {
                        Text("Укажите персональный токен Kodik API для поиска и воспроизведения.")
                            .font(.caption)
                    }

                case "jellyfin":
                    Section {
                        HStack {
                            Text("Хост")
                            Spacer()
                            TextField("192.168.1.50", text: $jellyfinHost)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }
                        HStack {
                            Text("Порт")
                            Spacer()
                            TextField("8096", text: $jellyfinPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        SecureField("API-ключ (необязательно)", text: $jellyfinApiKey)
                    } header: {
                        Label("Параметры Jellyfin", systemImage: "externaldrive.badge.wifi")
                    }

                case "plex":
                    Section {
                        HStack {
                            Text("Хост")
                            Spacer()
                            TextField("192.168.1.60", text: $plexHost)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }
                        HStack {
                            Text("Порт")
                            Spacer()
                            TextField("32400", text: $plexPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        SecureField("X-Plex-Token", text: $plexToken)
                    } header: {
                        Label("Параметры Plex", systemImage: "tv.fill")
                    }

                case "emby":
                    Section {
                        HStack {
                            Text("Хост")
                            Spacer()
                            TextField("192.168.1.70", text: $embyHost)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }
                        HStack {
                            Text("Порт")
                            Spacer()
                            TextField("8096", text: $embyPort)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        SecureField("API-ключ Emby", text: $embyApiKey)
                    } header: {
                        Label("Параметры Emby", systemImage: "play.display")
                    }

                case "online_mod":
                    Section {
                        ForEach(OnlineModOriginPreference.allCases, id: \.self) { pref in
                            Button {
                                if pref != onlineModPref.preference {
                                    pendingOnlineModPreference = pref
                                }
                            } label: {
                                HStack {
                                    Text(pref.displayName).foregroundColor(.primary)
                                    Spacer()
                                    if pref == onlineModPref.preference {
                                        Image(systemName: "checkmark").foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    } header: {
                        Label("Реализация Online Mod", systemImage: "arrow.triangle.swap")
                    } footer: {
                        Text("Выбор реализации применяется после подтверждения. Доступность источников проверяется отдельно.")
                            .font(.caption)
                    }

                default:
                    if let streamUrl = currentRecord.customEndpointUrl, currentRecord.providerType == .directFeed {
                        Section("URL потока") {
                            Text(streamUrl)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)

                            Button("Воспроизвести в плеере") {
                                onPlayCustomUrl?(streamUrl, currentRecord.displayName, false)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("playDirectUrlButton")
                        }
                    }
                    if let endpoint = currentRecord.customEndpointUrl, currentRecord.canonicalKey.hasPrefix("server_") {
                        Section("Адрес сервера") {
                            Text(endpoint).font(.caption.monospaced()).foregroundColor(.secondary)
                            Text("Пользовательский адрес сохранён, но не подключён к адаптеру медиасервера.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }

                // MARK: - Technical Information
                Section("Сведения о провайдере") {
                    LabeledContent("Ключ", value: currentRecord.canonicalKey)
                    LabeledContent("Тип", value: currentRecord.providerType.rawValue)
                    if let last = currentRecord.lastResolvedAt {
                        LabeledContent("Последнее разрешение", value: last.formatted(date: .numeric, time: .shortened))
                    }
                    if currentRecord.consecutiveFailureCount > 0 {
                        LabeledContent("Ошибок подряд", value: "\(currentRecord.consecutiveFailureCount)")
                            .foregroundColor(.red)
                    }
                }

                // Delete custom source
                if currentRecord.providerType == .directFeed || currentRecord.canonicalKey.hasPrefix("server_") {
                    Section {
                        Button(role: .destructive) {
                            showConfirmDelete = true
                        } label: {
                            Label("Удалить источник", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(currentRecord.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .alert("Удалить источник «\(currentRecord.displayName)»?", isPresented: $showConfirmDelete) {
                Button("Удалить", role: .destructive) {
                    sourceManager.removeSource(id: currentRecord.id)
                    dismiss()
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Источник будет удален из конфигурации приложения.")
            }
            .confirmationDialog("Изменить реализацию Online Mod?", isPresented: Binding(
                get: { pendingOnlineModPreference != nil },
                set: { if !$0 { pendingOnlineModPreference = nil } }
            ), titleVisibility: .visible) {
                Button("Подтвердить") {
                    if let preference = pendingOnlineModPreference {
                        onlineModPref.setPreference(preference)
                    }
                    pendingOnlineModPreference = nil
                }
                Button("Отмена", role: .cancel) { pendingOnlineModPreference = nil }
            } message: {
                Text("Выбор перезапустит синхронизацию плагинов. Доступность выбранной реализации не гарантируется.")
            }
    }

    private var currentStatus: ProviderOperationalStatus {
        switch currentRecord.canonicalKey {
        case "online_mod": return engine.onlineModProvider.operationalStatus
        case "anilibria_native": return engine.anilibriaProvider.operationalStatus
        case "kodik_anime": return engine.kodikAnimeProvider.operationalStatus
        case "torrserver_default": return engine.torrServerProvider.operationalStatus
        case "jellyfin": return engine.jellyfinProvider.operationalStatus
        case "plex": return engine.plexProvider.operationalStatus
        case "emby": return engine.embyProvider.operationalStatus
        default: return currentRecord.operationalStatus
        }
    }

    private var iconName: String {
        switch currentRecord.canonicalKey {
        case "online_mod": return "film.stack.fill"
        case "anilibria_native": return "sparkles.tv.fill"
        case "kodik_anime": return "tv.badge.wifi.fill"
        case "torrserver_default": return "server.rack"
        case "jellyfin": return "externaldrive.badge.wifi"
        case "plex": return "tv.fill"
        case "emby": return "play.display"
        default: return "play.rectangle.on.rectangle.fill"
        }
    }

    private var iconColor: Color {
        switch currentRecord.canonicalKey {
        case "online_mod": return .purple
        case "anilibria_native": return .blue
        case "kodik_anime": return .teal
        case "torrserver_default": return .green
        case "jellyfin": return .purple
        case "plex": return .orange
        case "emby": return .green
        default: return .pink
        }
    }

    private var providerTypeDescription: String {
        switch currentRecord.providerType {
        case .pluginComponent: return "Онлайн-балансер JavaScript"
        case .nativeAPI: return "Нативный API"
        case .torrServer: return "Торрент-сервер"
        case .directFeed: return "Прямой медиапоток"
        }
    }

    private var resolutionButtonIdentifier: String {
        switch currentRecord.canonicalKey {
        case "online_mod": return "testOnlineModButton"
        case "anilibria_native": return "testAniLibriaButton"
        case "kodik_anime": return "testKodikButton"
        case "torrserver_default": return "testTorrServerButton"
        case "jellyfin": return "testJellyfinButton"
        case "plex": return "testPlexButton"
        case "emby": return "testEmbyButton"
        default: return "testDirectResolutionButton"
        }
    }

    private func runConnectivityTest() {
        isTestingConnectivity = true
        connectivityResult = "Проверка сетевого соединения..."
        Task {
            let res: (success: Bool, message: String)
            switch currentRecord.canonicalKey {
            case "anilibria_native":
                res = await checkHttpPing(url: "https://anilibria.top")
            case "online_mod":
                let isReady = LampaHeadlessHost.shared.isAppReady
                res = (isReady, isReady ? "Среда WebKit активна и готова к вызовам моста" : "Среда WebKit инициализируется")
            case "torrserver_default":
                res = await checkHttpPing(url: "http://\(torrServerHost):\(torrServerPort)/echo")
            case "kodik_anime":
                res = await checkHttpPing(url: "https://kodikapi.com")
            case "jellyfin":
                res = await checkHttpPing(url: "http://\(jellyfinHost):\(jellyfinPort)/System/Info/Public")
            case "plex":
                res = await checkHttpPing(url: "http://\(plexHost):\(plexPort)/identity")
            case "emby":
                res = await checkHttpPing(url: "http://\(embyHost):\(embyPort)/System/Info/Public")
            default:
                if let urlStr = currentRecord.customEndpointUrl {
                    res = await checkHttpPing(url: urlStr)
                } else {
                    res = (false, "URL для проверки не указан")
                }
            }

            await MainActor.run {
                self.isTestingConnectivity = false
                self.connectivityResult = res.message
            }
        }
    }

    private func runResolutionTest() {
        isTestingResolution = true
        resolutionResult = "Проверка разрешения потока..."
        Task {
            let res: (success: Bool, message: String, sampleUrl: String?)
            switch currentRecord.canonicalKey {
            case "anilibria_native":
                res = await engine.anilibriaProvider.runVerificationTest()
            case "online_mod":
                res = await engine.onlineModProvider.runVerificationTest()
            case "torrserver_default":
                res = await engine.torrServerProvider.runVerificationTest()
            case "kodik_anime":
                res = await engine.kodikAnimeProvider.runVerificationTest()
            case "jellyfin":
                res = await engine.jellyfinProvider.runVerificationTest()
            case "plex":
                res = await engine.plexProvider.runVerificationTest()
            case "emby":
                res = await engine.embyProvider.runVerificationTest()
            default:
                if currentRecord.providerType == .directFeed, let stream = currentRecord.customEndpointUrl {
                    let head = await checkHttpPing(url: stream)
                    res = (head.success, head.success ? "Сервер ответил; воспроизведение потока не проверено" : head.message, head.success ? stream : nil)
                } else {
                    res = (false, "Проверка разрешения потока для этого источника недоступна", nil)
                }
            }

            await MainActor.run {
                self.isTestingResolution = false
                self.resolutionResult = res.message
                self.resolvedSampleUrl = res.sampleUrl
                self.engine.objectWillChange.send()
            }
        }
    }

    private func checkHttpPing(url urlString: String) async -> (success: Bool, message: String) {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return (false, "Некорректный адрес URL")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse {
                return (true, "Сервер ответил кодом HTTP \(http.statusCode) (онлайн)")
            }
            return (true, "Соединение установлено успешно")
        } catch {
            return (false, "Ошибка соединения: \(error.localizedDescription)")
        }
    }
}

