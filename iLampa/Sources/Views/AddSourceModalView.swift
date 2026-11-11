import SwiftUI

// MARK: - Add Source Modal View
@MainActor
struct AddSourceModalView: View {
    var onSaved: (LampaSourceRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var sourceManager = SourceManager.shared

    @State private var sourceTitle = ""
    @State private var sourceUrl = ""
    @State private var selectedType: SourceProviderType = .directFeed

    // Validation State
    @State private var isValidating = false
    @State private var validationResult: String? = nil
    @State private var isValidated = false
    @State private var detectedContentType: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название источника", text: $sourceTitle)

                    Picker("Тип источника", selection: $selectedType) {
                        Text("Прямой видеопоток (HLS .m3u8, MP4)").tag(SourceProviderType.directFeed)
                        Text("Торрент-сервер (TorrServer)").tag(SourceProviderType.torrServer)
                        Text("Медиасервер (Jellyfin / Plex / Emby)").tag(SourceProviderType.nativeAPI)
                    }
                    .onChange(of: selectedType) { _, _ in
                        isValidated = false
                        validationResult = nil
                    }

                    TextField(urlPlaceholder, text: $sourceUrl)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: sourceUrl) { _, _ in
                            isValidated = false
                            validationResult = nil
                        }
                } header: {
                    Label("Параметры источника", systemImage: "link")
                } footer: {
                    Text("Поддерживаются только проверенные медиапотоки и серверы. Произвольные веб-сайты отклоняются.")
                        .font(.caption)
                }

                // Verification and Preview
                Section {
                    Button(action: validateUrl) {
                        HStack {
                            if isValidating {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "checkmark.shield")
                            }
                            Text("Проверить доступность URL")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)

                    if let result = validationResult {
                        HStack(spacing: 8) {
                            Image(systemName: isValidated ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(isValidated ? .green : .red)
                            Text(result)
                                .font(.caption)
                                .foregroundColor(isValidated ? .green : .red)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Label("Проверка безопасности и доступности", systemImage: "shield.checkerboard")
                }
            }
            .navigationTitle("Новый источник")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        saveSource()
                    }
                    .disabled(!isValidated || sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var urlPlaceholder: String {
        switch selectedType {
        case .directFeed: return "https://domain.com/stream.m3u8"
        case .torrServer: return "http://192.168.1.100:8090"
        default: return "http://192.168.1.50:8096"
        }
    }

    private func validateUrl() {
        let clean = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let validationType = selectedType
        guard let url = URL(string: clean), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            isValidated = false
            validationResult = "Некорректный протокол. Допустимы только http:// и https://"
            return
        }

        // Strict rejection of arbitrary web pages
        let host = url.host?.lowercased() ?? ""
        let forbidden = ["google.com", "youtube.com", "kinopoisk.ru", "wikipedia.org", "yandex.ru"]
        if forbidden.contains(where: { host.contains($0) }) {
            isValidated = false
            validationResult = "Произвольные веб-сайты не являются источниками видео. Укажите прямой медиапоток (.m3u8, .mp4) или сервер."
            return
        }

        isValidating = true
        validationResult = "Проверка сетевого ответа..."

        Task {
            var req = URLRequest(url: url)
            req.timeoutInterval = 4.0
            req.httpMethod = "HEAD"

            do {
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse {
                    let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    let isMedia = mime.contains("mpegurl") || mime.contains("video") || mime.contains("audio") || clean.hasSuffix(".m3u8") || clean.hasSuffix(".mp4")
                    await MainActor.run {
                        self.isValidating = false
                        guard self.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines) == clean,
                              self.selectedType == validationType else { return }
                        if (200...399).contains(http.statusCode) {
                            if validationType == .directFeed && !isMedia {
                                self.isValidated = false
                                self.validationResult = "Сервер ответил (HTTP \(http.statusCode)), но тип содержимого (\(mime.isEmpty ? "неизвестно" : mime)) не является видеопотоком."
                            } else {
                                self.isValidated = true
                                self.detectedContentType = mime
                                self.validationResult = "URL подтвержден (HTTP \(http.statusCode)). Готов к сохранению."
                                if self.sourceTitle.isEmpty {
                                    self.sourceTitle = url.lastPathComponent.isEmpty ? host : url.lastPathComponent
                                }
                            }
                        } else {
                            self.isValidated = false
                            self.validationResult = "Сервер вернул код ошибки HTTP \(http.statusCode)"
                        }
                    }
                } else {
                    await MainActor.run {
                        self.isValidating = false
                        guard self.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines) == clean,
                              self.selectedType == validationType else { return }
                        self.isValidated = false
                        self.validationResult = "Сервер не вернул HTTP-ответ"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isValidating = false
                    guard self.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines) == clean,
                          self.selectedType == validationType else { return }
                    self.isValidated = false
                    self.validationResult = "Сбой соединения: \(error.localizedDescription)"
                }
            }
        }
    }

    private func saveSource() {
        let cleanTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUrl = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let record: LampaSourceRecord
        if selectedType == .directFeed {
            record = sourceManager.addDirectStream(title: cleanTitle, streamUrl: cleanUrl)
        } else {
            record = sourceManager.addCustomServer(title: cleanTitle, endpointUrl: cleanUrl, serverType: selectedType)
        }
        onSaved(record)
        dismiss()
    }
}

