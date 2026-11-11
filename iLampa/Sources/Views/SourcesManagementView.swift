import SwiftUI

// Unified Apple-Way Video Sources Manager Screen (Settings → Sources).
// Categorizes all video providers into 4 distinct groups:
// 1. Online Balancers & Plugins (Online Mod, Filmix, HDRezka, etc.)
// 2. Native APIs (AniLibria, Kodik)
// 3. Personal Media Servers (TorrServer, Jellyfin, Plex, Emby)
// 4. Direct Media Streams (HLS .m3u8, MP4)
//
// Supports adding sources by validated URL, separate connectivity vs resolution testing,
// priority selection, enable/disable switches, and detailed provider configuration.
@MainActor
struct SourcesManagementView: View {
    var onPlayCustomUrl: ((String, String, Bool) -> Void)?

    @StateObject private var engine = SourceProviderEngine.shared
    @StateObject private var sourceManager = SourceManager.shared
    @StateObject private var pluginManager = PluginManager.shared
    @StateObject private var registry = PluginCapabilityRegistry.shared

    @AppStorage("ilampa_preferred_source_provider") private var preferredProviderKey = "auto"
    @AppStorage(DeveloperMode.preferenceKey) private var developerModeEnabled = false

    // Modals
    @State private var showAddSourceSheet = false
    @State private var showLampaSheet = false
    @State private var selectedSourceForDetail: LampaSourceRecord? = nil
    @State private var pendingAddedSource: LampaSourceRecord? = nil

    private var developerToolsVisible: Bool {
        DeveloperMode.isEnabled(preference: developerModeEnabled)
    }

    private var activeSourcesCount: Int {
        sourceManager.registeredSources.filter { $0.isEnabled }.count
    }

    var body: some View {
        Group {
            if sourceManager.registeredSources.isEmpty {
                // MARK: - Canonical Empty State (`sourceempty`)
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 56))
                        .foregroundColor(.blue.opacity(0.8))
                        .padding(.bottom, 8)
                    Text("Нет подключенных источников")
                        .font(.title3.bold())
                    Text("Подключите онлайн-балансеры, личные серверы (TorrServer, Jellyfin, Plex, Emby) или прямые потоки для начала воспроизведения.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button {
                        showAddSourceSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Добавить источник")
                                .bold()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("centerAddSourceButton")
                    Spacer()
                }
            } else {
                List {
                    Section {
                        Text("Источники автоматически появляются здесь, когда приложение или плагины предоставляют соответствующую возможность.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Section("ПОРЯДОК И ВЫБОР") {
                        NavigationLink(destination: PrioritySourcesView()) {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Приоритет и резерв")
                                    Text("Сначала предпочитаемые, затем остальные")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            } icon: {
                                Image(systemName: "arrow.up.arrow.down").foregroundColor(.blue)
                            }
                        }
                    }

                    Section("ОНЛАЙН") {
                        ForEach(sourceManager.registeredSources.filter {
                            ["online_mod", "anilibria_native", "kodik_anime"].contains($0.canonicalKey)
                        }) { source in
                            sourceRow(record: source, icon: "play.tv.fill", iconColor: .blue,
                                      subtitle: "Встроенный источник", status: status(for: source))
                        }
                    }

                    let pluginSources = sourceManager.registeredSources.filter {
                        $0.providerType == .pluginComponent && $0.canonicalKey != "online_mod"
                    }
                    if !pluginSources.isEmpty {
                        Section("ИЗ ПЛАГИНОВ") {
                            ForEach(pluginSources) { source in
                                sourceRow(record: source, icon: "puzzlepiece.extension.fill", iconColor: .indigo,
                                          subtitle: pluginDescription(for: source),
                                          status: source.operationalStatus)
                            }
                        }
                    }

                    let serverSources = sourceManager.registeredSources.filter {
                        ["torrserver_default", "jellyfin", "plex", "emby"].contains($0.canonicalKey)
                            || $0.canonicalKey.hasPrefix("server_")
                    }
                    if !serverSources.isEmpty {
                        Section("МОИ МЕДИАСЕРВЕРЫ") {
                            NavigationLink(destination: MediaServersView(onPlayCustomUrl: onPlayCustomUrl)) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Медиасерверы")
                                        Text("Подключение на отдельных страницах")
                                            .font(.caption).foregroundColor(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "server.rack").foregroundColor(.secondary)
                                }
                            }
                            ForEach(serverSources.filter { $0.canonicalKey.hasPrefix("server_") }) { source in
                                sourceRow(record: source, icon: "server.rack", iconColor: .green,
                                          subtitle: "Медиасервер", status: status(for: source))
                            }
                        }
                    }

                    let otherSources = sourceManager.registeredSources.filter {
                        ($0.providerType == .nativeAPI || $0.providerType == .torrServer)
                            && !["anilibria_native", "kodik_anime", "torrserver_default", "jellyfin", "plex", "emby"].contains($0.canonicalKey)
                            && !$0.canonicalKey.hasPrefix("server_")
                    }
                    if !otherSources.isEmpty {
                        Section("ДРУГИЕ ИСТОЧНИКИ") {
                            ForEach(otherSources) { source in
                                sourceRow(record: source, icon: "play.tv.fill", iconColor: .blue,
                                          subtitle: "Источник видео", status: status(for: source))
                            }
                        }
                    }

                    Section("ПРЯМЫЕ ССЫЛКИ") {
                        NavigationLink(destination: DirectStreamView(onPlayDirect: { streamUrl in
                            onPlayCustomUrl?(streamUrl, "Прямой видеопоток", false)
                        })) {
                            Label("Открыть прямую ссылку", systemImage: "play.fill")
                        }
                        let directSources = sourceManager.registeredSources.filter { $0.providerType == .directFeed }
                        ForEach(directSources) { source in
                            sourceRow(record: source, icon: "antenna.radiowaves.left.and.right", iconColor: .pink,
                                      subtitle: source.customEndpointUrl ?? "Прямой HLS / MP4 поток",
                                      status: source.operationalStatus)
                        }
                        .onDelete(perform: deleteDirectStream)
                    }

            // MARK: - Developer Diagnostics (Opt-in)
            if developerToolsVisible {
                Section {
                    NavigationLink(destination: DiagnosticsConsoleView()) {
                        HStack {
                            Image(systemName: "terminal")
                                .foregroundColor(.blue)
                            Text("Открыть журнал диагностики устройства")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .accessibilityIdentifier("openDiagnosticsConsoleButton")

                    Button("[Dev] Открыть веб-интерфейс Lampa") {
                        showLampaSheet = true
                    }
                    .accessibilityIdentifier("openLampaFromSourcesButton")
                } header: {
                    Label("Диагностика", systemImage: "wrench.and.screwdriver")
                }
            }
            }
        }
    }
    .navigationTitle("Источники")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !sourceManager.registeredSources.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSourceSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.bold())
                    }
                    .accessibilityIdentifier("addSourceToolbarButton")
                }
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { selectedSourceForDetail != nil },
            set: { if !$0 { selectedSourceForDetail = nil } }
        )) {
            if let record = selectedSourceForDetail {
                SourceConfigurationDetailView(record: record, onPlayCustomUrl: onPlayCustomUrl)
            }
        }
        .sheet(isPresented: $showAddSourceSheet, onDismiss: {
            if let record = pendingAddedSource {
                pendingAddedSource = nil
                selectedSourceForDetail = record
            }
        }) {
            AddSourceModalView { newRecord in
                pendingAddedSource = newRecord
            }
        }
        .sheet(isPresented: $showLampaSheet) {
            LampaWebSheetView()
        }
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func sourceRow(
        record: LampaSourceRecord,
        icon: String,
        iconColor: Color,
        subtitle: String,
        status: ProviderOperationalStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconColor)
                    .frame(width: 36, height: 36)
                    .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

                Button {
                    selectedSourceForDetail = record
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(subtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if status != .unconfigured && status != .authRequired {
                    Toggle("Включить \(record.displayName)", isOn: Binding(
                        get: { record.isEnabled },
                        set: { _ in sourceManager.toggleSource(id: record.id) }
                    ))
                    .labelsHidden()
                    .fixedSize()
                }
            }

            HStack(spacing: 8) {
                StatusBadge(status: status)
                if record.canonicalKey == preferredProviderKey {
                    Text("Основной")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                Spacer(minLength: 6)
                Button(status == .unconfigured || status == .authRequired ? "Настроить" : "Подробнее") {
                    selectedSourceForDetail = record
                }
                .font(.footnote.weight(.medium))
                .accessibilityIdentifier("configure_\(record.canonicalKey)")
            }
        }
        .padding(.vertical, 6)
    }

    private func status(for source: LampaSourceRecord) -> ProviderOperationalStatus {
        switch source.canonicalKey {
        case "online_mod": return engine.onlineModProvider.operationalStatus
        case "anilibria_native": return engine.anilibriaProvider.operationalStatus
        case "kodik_anime": return engine.kodikAnimeProvider.operationalStatus
        case "torrserver_default": return engine.torrServerProvider.operationalStatus
        case "jellyfin": return engine.jellyfinProvider.operationalStatus
        case "plex": return engine.plexProvider.operationalStatus
        case "emby": return engine.embyProvider.operationalStatus
        default: return source.operationalStatus
        }
    }

    private func pluginDescription(for source: LampaSourceRecord) -> String {
        guard let owner = source.parentPluginId else { return "Владелец не установлен" }
        guard let plugin = pluginManager.installedPlugins.first(where: { $0.id == owner }) else {
            return "Плагин недоступен"
        }
        return "Плагин: \(plugin.name)"
    }

    private func deleteDirectStream(at offsets: IndexSet) {
        let directSources = sourceManager.registeredSources.filter { $0.providerType == .directFeed }
        for index in offsets {
            let item = directSources[index]
            sourceManager.removeSource(id: item.id)
        }
    }
}

// MARK: - Status Badge View
// Visual indicator representing truthful operational status across sources and plugins
struct StatusBadge: View {
    let status: ProviderOperationalStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.bold())
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(6)
    }

    private var color: Color {
        switch status {
        case .playbackVerified:
            return .green
        case .streamResolved, .resultsFound, .radioReady:
            return .teal
        case .searchAvailable, .initialized, .noMatchingTitles, .interfaceOnly:
            return .blue
        case .registered, .executed, .loaded, .authRequired, .adapterRequired:
            return .orange
        case .unconfigured, .connectionFailed:
            return .red
        }
    }
}
