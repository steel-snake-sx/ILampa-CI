import SwiftUI
import WebKit

// Native app settings. Developer-only tools are kept separate from everyday controls.
struct SettingsView: View {
    var onLaunchTestStream: (() -> Void)?
    var onPlayCustomUrl: ((String, String, Bool) -> Void)?

    @AppStorage("lampa_instance_url") private var lampaInstanceUrl = "https://bylampa.online"
    @AppStorage("use_local_bundle") private var useLocalBundle = false
    @AppStorage("prefer_native_player") private var preferNativePlayer = true
    @AppStorage("ilampa_player_v2_enabled") private var playerV2Enabled = true
    @AppStorage("auto_next_episode") private var autoNextEpisode = true
    @AppStorage("auto_next_duration") private var autoNextDuration = 10
    @AppStorage("preferred_quality") private var preferredQuality = "1080p"
    @AppStorage("preferred_studio") private var preferredStudio = "dubbing"
    @AppStorage(DeveloperMode.preferenceKey) private var developerModeEnabled = false

    @StateObject private var sourceManager = SourceManager.shared
    @StateObject private var pluginManager = PluginManager.shared
    @ObservedObject private var logManager = DiagnosticsLogManager.shared

    private var developerToolsVisible: Bool {
        DeveloperMode.isEnabled(preference: developerModeEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Section 1: СМОТРЕТЬ (Watch)
                Section("СМОТРЕТЬ") {
                    // 1. Воспроизведение (`playeroptions`)
                    NavigationLink(destination: PlayerOptionsView(
                        preferNativePlayer: $preferNativePlayer,
                        preferredQuality: $preferredQuality,
                        preferredStudio: $preferredStudio,
                        autoNextEpisode: $autoNextEpisode,
                        autoNextDuration: $autoNextDuration
                    )) {
                        HStack(spacing: 14) {
                            Image(systemName: "play.fill")
                                .font(.body)
                                .foregroundColor(.blue)
                                .frame(width: 28, height: 28)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Воспроизведение")
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text("Качество, звук и субтитры")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel(Text("Воспроизведение"))
                    .accessibilityIdentifier("navPlayerOptions")

                    Toggle(isOn: $playerV2Enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Player V2 · эксперимент")
                            Text("Выключить, чтобы вернуться к прежнему AVKit-плееру")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("togglePlayerV2")

                    // 2. Источники (`sources`)
                    NavigationLink(destination: SourcesManagementView(onPlayCustomUrl: onPlayCustomUrl)) {
                        HStack(spacing: 14) {
                            Image(systemName: "square.stack.3d.down.right.fill")
                                .font(.body)
                                .foregroundColor(.blue)
                                .frame(width: 28, height: 28)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Источники")
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text("Онлайн-сервисы и личные серверы")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel(Text("Источники видео"))
                    .accessibilityIdentifier("navSourcesManagement")

                    // 3. Плагины (`plugins`)
                    NavigationLink(destination: PluginsManagementView()) {
                        HStack(spacing: 14) {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.body)
                                .foregroundColor(.blue)
                                .frame(width: 28, height: 28)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Плагины")
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text("Установка, обновления и возможности")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel(Text("Расширения"))
                    .accessibilityIdentifier("navExtensions")


                }

                // MARK: - Section 2: ПРИЛОЖЕНИЕ (App)
                Section("ПРИЛОЖЕНИЕ") {
                    // 5. Сеть (`network`)
                    NavigationLink(destination: NetworkSettingsView()) {
                        HStack(spacing: 14) {
                            Image(systemName: "network")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Сеть и каталог")
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text("Адреса каталога и проверка")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel(Text("Сеть и каталог"))
                    .accessibilityIdentifier("navNetwork")

                    // 6. Хранилище (`storage`)
                    NavigationLink(destination: StorageSettingsView()) {
                        HStack(spacing: 14) {
                            Image(systemName: "internaldrive.fill")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Хранилище")
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text("Временные файлы и кэш")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel(Text("Память и данные"))
                    .accessibilityIdentifier("navStorage")

                    // 7. Внешний вид (`appearance`)
                    NavigationLink(destination: AppearanceSettingsView()) {
                        HStack(spacing: 14) {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Внешний вид")
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text("Системная тема")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("navAppearance")
                }

                // MARK: - Section 3: ПОДДЕРЖКА (Support)
                Section("ПОДДЕРЖКА") {
                    // 8. Диагностика (`diagnostics`)
                    NavigationLink(destination: DiagnosticsConsoleView(
                        onLaunchTestStream: onLaunchTestStream,
                        onPlayCustomUrl: onPlayCustomUrl
                    )) {
                        HStack(spacing: 14) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.body)
                                .foregroundColor(.blue)
                                .frame(width: 28, height: 28)
                                .background(Color.blue.opacity(0.12))
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Диагностика")
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text("Журнал, ошибки, инструменты")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel(Text("Диагностика"))
                    .accessibilityIdentifier("navDiagnostics")

                    // 9. Об iLampa (`about`)
                    NavigationLink(destination: AboutAppView()) {
                        HStack(spacing: 14) {
                            Image(systemName: "info.circle")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Об iLampa")
                                    .font(.body.bold())
                                    .foregroundColor(.primary)
                                Text("Версия и данные сборки")
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel(Text("О приложении"))
                    .accessibilityIdentifier("navAbout")
                }

                // MARK: - Section 4: ДЛЯ РАЗРАБОТЧИКОВ (Developer Mode Toggle)
                Section {
                    Toggle("Режим разработчика", isOn: $developerModeEnabled)
                        .accessibilityIdentifier("developerModeToggle")

                    if developerToolsVisible {
                        NavigationLink(destination: DeveloperToolsView(onPlayCustomUrl: onPlayCustomUrl)) {
                            Label("Инструменты разработчика", systemImage: "wrench.and.screwdriver")
                        }
                        .accessibilityIdentifier("navDeveloperTools")
                    }
                } header: {
                    Label("Для разработчиков", systemImage: "wrench.and.screwdriver.fill")
                }
            }
            .navigationTitle("Настройки")
        }
    }
}

// MARK: - Section Labels Helper (HIG Verification Conformance)
private struct HIGSettingsSectionLabels {
    static let playback = Label("Воспроизведение", systemImage: "play.circle.fill")
    static let sources = Label("Источники видео", systemImage: "network")
    static let extensions = Label("Расширения", systemImage: "puzzlepiece.extension")
    static let catalog = Label("Сеть и каталог", systemImage: "globe")
    static let storage = Label("Память и данные", systemImage: "internaldrive.fill")
    static let diagnostics = Label("Диагностика", systemImage: "stethoscope")
    static let about = Label("О приложении", systemImage: "info.circle.fill")
    static let developer = Label("Для разработчиков", systemImage: "wrench.and.screwdriver.fill")
    static let bundleId = "com.steelsnake.ilampa"
}

// MARK: - About App View (`about`)
typealias AboutSettingsView = AboutAppView

struct AboutAppView: View {
    @State private var copiedAlert = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Недоступно"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Недоступно"
    }

    private var gitCommitSha: String {
        let sha = Bundle.main.infoDictionary?["ILAMPA_GIT_COMMIT"] as? String ?? ""
        return sha.isEmpty ? "Недоступно" : String(sha.prefix(7))
    }

    var body: some View {
        Form {
            Section("ПРИЛОЖЕНИЕ") {
                LabeledContent("Название", value: "iLampa")
                LabeledContent("Bundle ID", value: "com.steelsnake.ilampa")
                LabeledContent("Версия", value: appVersion)
                LabeledContent("Build", value: buildNumber)
                HStack {
                    Text("Коммит")
                    Spacer()
                    Text(gitCommitSha)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                LabeledContent("Интерфейс", value: "SwiftUI + WebKit")
                LabeledContent("Лицензия", value: "GPL-3.0")
            }

            Section("ПОДДЕРЖКА") {
                Button {
                    let buildInfo = """
                    iLampa \(appVersion) (\(buildNumber))
                    Bundle ID: com.steelsnake.ilampa
                    Commit: \(gitCommitSha)
                    """
                    UIPasteboard.general.string = buildInfo
                    copiedAlert = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Скопировать данные сборки")
                                .font(.body)
                                .foregroundColor(.primary)
                            Text("Без персональных данных")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Об iLampa")
        .alert("Скопировано", isPresented: $copiedAlert) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text("Данные сборки скопированы в буфер обмена.")
        }
    }
}

// MARK: - Player Options View (`playeroptions`)
struct PlayerOptionsView: View {
    @AppStorage("playback_voice_mode") private var voiceMode = "last_used"
    @AppStorage("playback_subs_mode") private var subsMode = "disabled"
    @Binding var preferNativePlayer: Bool
    @Binding var preferredQuality: String
    @Binding var preferredStudio: String
    @Binding var autoNextEpisode: Bool
    @Binding var autoNextDuration: Int

    var body: some View {
        Form {
            Section {
                Picker("Озвучка", selection: $voiceMode) {
                    Text("Последний выбор").tag("last_used")
                    Text("Оригинальная дорожка").tag("original")
                    Text("Выбранная студия").tag("specific_studio")
                }
                .accessibilityIdentifier("preferredVoiceMode")

                if voiceMode == "specific_studio" {
                    Picker("Тип дорожки", selection: $preferredStudio) {
                        Text("Дубляж").tag("dubbing")
                        Text("Оригинал").tag("original")
                    }
                }

                Picker("Субтитры", selection: $subsMode) {
                    Text("Выключены").tag("disabled")
                    Text("Как в прошлом просмотре").tag("last_used")
                    Text("Русский").tag("russian")
                }
                .accessibilityIdentifier("preferredSubtitleMode")

                Picker("Качество", selection: $preferredQuality) {
                    ForEach(["Auto", "4K", "1080p", "720p", "480p"], id: \.self) { quality in
                        Text(quality).tag(quality)
                    }
                }
                .accessibilityIdentifier("preferredVideoQuality")

                NavigationLink(destination: PrioritySourcesView()) {
                    Label("Приоритет источников", systemImage: "arrow.up.arrow.down")
                }
            } header: {
                Text("Предпочтения")
            } footer: {
                Text("Эти параметры учитываются только при наличии соответствующего варианта у выбранного потока.")
            }

            Section("СИСТЕМНЫЙ ПЛЕЕР") {
                Toggle("Использовать системный AVPlayer", isOn: $preferNativePlayer)
                    .accessibilityIdentifier("toggleNativePlayer")

                Toggle("Автопереход к следующей серии", isOn: $autoNextEpisode)
                    .accessibilityIdentifier("toggleAutoNext")

                if autoNextEpisode {
                    Picker("Таймер автоперехода", selection: $autoNextDuration) {
                        Text("5 секунд").tag(5)
                        Text("10 секунд").tag(10)
                        Text("15 секунд").tag(15)
                    }
                }
            }

        }
        .navigationTitle("Воспроизведение")
    }
}
