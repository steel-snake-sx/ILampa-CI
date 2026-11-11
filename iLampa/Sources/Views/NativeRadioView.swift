import SwiftUI

@MainActor
struct NativeRadioView: View {
    var embeddedInNavigation = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var radioPlayer = RadioPlayerModel.shared
    @State private var stations: [RadioStation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadingStationId: String?
    
    var body: some View {
        Group {
            if embeddedInNavigation {
                radioContent
            } else {
                NavigationStack { radioContent }
            }
        }
        .task { await loadStations() }
    }

    private var radioContent: some View {
            Group {
                if isLoading && stations.isEmpty {
                    ProgressView("Загрузка станций…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage, stations.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi.slash")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Не удалось загрузить станции")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Повторить") { Task { await loadStations() } }
                            .buttonStyle(.bordered)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stationList
                }
            }
            .navigationTitle("Радио SomaFM")
            .toolbar {
                if !embeddedInNavigation {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Закрыть") {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { Task { await loadStations(forceRefresh: true) } }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
    }
    
    private var stationList: some View {
        List {
            if let current = radioPlayer.currentStation {
                Section("Сейчас играет") {
                    NowPlayingBanner(station: current, player: radioPlayer)
                }
            }
            
            Section("Все станции (\(stations.count))") {
                ForEach(stations) { station in
                    RadioStationRow(
                        station: station,
                        isActive: radioPlayer.currentStation?.id == station.id,
                        isLoading: loadingStationId == station.id,
                        onSelect: { Task { await selectStation(station) } }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private func loadStations(forceRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        do {
            stations = try await SomaFMService.shared.channels(forceRefresh: forceRefresh)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
    
    private func selectStation(_ station: RadioStation) async {
        // If already playing this station, toggle
        if radioPlayer.currentStation?.id == station.id {
            radioPlayer.togglePlayback()
            return
        }
        
        loadingStationId = station.id
        do {
            let urls = try await SomaFMService.shared.resolveStreamURLs(for: station)
            radioPlayer.play(station: station, streamURLs: urls)
        } catch {
            DiagnosticsLogManager.shared.log(
                category: "[Radio]",
                message: "Failed to resolve stream for \(station.title): \(error.localizedDescription)",
                level: .error
            )
        }
        loadingStationId = nil
    }
}

struct RadioStationRow: View {
    let station: RadioStation
    let isActive: Bool
    let isLoading: Bool
    var onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Artwork
                AsyncImage(url: station.imageURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.gray.opacity(0.3)
                    }
                }
                .frame(width: 56, height: 56)
                .cornerRadius(8)
                .overlay(
                    Group {
                        if isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(8)
                        } else if isActive {
                            Image(systemName: "waveform")
                                .foregroundColor(.white)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(8)
                        }
                    }
                )
                
                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(station.title)
                        .font(.body.bold())
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    Text(station.genreDisplay)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    
                    Text(station.description)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                
                Spacer()
                
                // Listener count
                VStack(alignment: .trailing, spacing: 2) {
                    if isActive {
                        Image(systemName: "pause.circle.fill")
                            .font(.title2)
                            .foregroundColor(.blue)
                    } else {
                        Image(systemName: "play.circle")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                    Text("\(station.listeners)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("radioStation_\(station.id)")
    }
}

struct NowPlayingBanner: View {
    let station: RadioStation
    @ObservedObject var player: RadioPlayerModel
    
    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: station.imageURL) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Color.gray.opacity(0.3)
                }
            }
            .frame(width: 48, height: 48)
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(station.title)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(player.isLoading ? "Буферизация…" : player.isPlaying ? "В эфире" : "Пауза")
                    .font(.caption)
                    .foregroundColor(player.isPlaying ? .green : .secondary)
            }
            
            Spacer()
            
            Button(action: { player.togglePlayback() }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
            }
            
            Button(action: { player.stop() }) {
                Image(systemName: "stop.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
