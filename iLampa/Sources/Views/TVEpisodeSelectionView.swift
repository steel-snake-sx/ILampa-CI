import SwiftUI

/// Browsing a season does not change the playback identity until an episode is chosen.
struct TVEpisodeSelectionView: View {
    let seasons: [SeasonSummary]
    let isLoading: Bool
    let selectedSeason: Int
    let selectedEpisode: Int
    let onSelect: (Int, Int) -> Void

    @State private var browsingSeason: Int

    init(seasons: [SeasonSummary], isLoading: Bool, selectedSeason: Int, selectedEpisode: Int,
         onSelect: @escaping (Int, Int) -> Void) {
        self.seasons = seasons
        self.isLoading = isLoading
        self.selectedSeason = selectedSeason
        self.selectedEpisode = selectedEpisode
        self.onSelect = onSelect
        _browsingSeason = State(initialValue: selectedSeason)
    }

    private var orderedSeasons: [SeasonSummary] {
        // Existing providers require a positive season number; do not offer
        // specials until their identity can be resolved end to end.
        seasons.filter { $0.seasonNumber > 0 }.sorted { $0.seasonNumber < $1.seasonNumber }
    }

    private var displayedSeason: Int {
        orderedSeasons.contains { $0.seasonNumber == browsingSeason }
            ? browsingSeason : (orderedSeasons.first?.seasonNumber ?? browsingSeason)
    }

    private var episodeCount: Int {
        max(0, seasons.first { $0.seasonNumber == displayedSeason }?.episodeCount ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("СЕЗОН")
                    if orderedSeasons.isEmpty {
                        message(isLoading ? "Загрузка сезонов…" : "Сведения о сезонах недоступны в каталоге.")
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(orderedSeasons) { season in
                                    let number = season.seasonNumber
                                    Button { browsingSeason = number } label: {
                                        Text("\(number)")
                                            .font(.subheadline.bold())
                                            .padding(.horizontal, 14)
                                            .frame(minWidth: 44, minHeight: 44)
                                            .background(displayedSeason == number ? Color.blue : Color(UIColor.tertiarySystemGroupedBackground))
                                            .foregroundColor(displayedSeason == number ? .white : .primary)
                                            .cornerRadius(10)
                                    }
                                    .accessibilityLabel("Сезон \(number)")
                                    .accessibilityIdentifier("seasonButton_\(number)")
                                    .accessibilityAddTraits(displayedSeason == number ? .isSelected : [])
                                }
                            }
                            .padding(12)
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("СЕРИИ")
                    if episodeCount == 0 {
                        message(isLoading ? "Загрузка серий…" : "Сведения о сериях недоступны в каталоге.")
                    } else {
                        VStack(spacing: 0) {
                            ForEach(1...episodeCount, id: \.self) { episode in
                                if episode > 1 { Divider().padding(.leading, 16) }
                                let isSelected = displayedSeason == selectedSeason && episode == selectedEpisode
                                Button { onSelect(displayedSeason, episode) } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(displayedSeason)×\(String(format: "%02d", episode)) · Серия \(episode)")
                                                .font(.headline)
                                                .foregroundColor(.primary)
                                            if isSelected {
                                                Text("Выбранная серия")
                                                    .font(.subheadline)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        if isSelected { Text("Выбрано").font(.subheadline).foregroundColor(.blue) }
                                        Image(systemName: "chevron.right").foregroundColor(.secondary)
                                    }
                                    .padding(16)
                                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityIdentifier("episodeButton_\(episode)")
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                            }
                        }
                        .background(Color(UIColor.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                    }
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle("Сезоны и серии")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.bold()).foregroundColor(.secondary).padding(.horizontal, 6)
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
    }
}
