import SwiftUI

// Source picker presentation controls.

// MARK: - 4. Picker Filters Sheet View (`filters`)
struct PickerFiltersSheetView: View {
    @Binding var selectedQuality: String
    @Binding var selectedStudio: String
    @Binding var selectedProvider: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("КАЧЕСТВО") {
                    ForEach(["Все", "1080p", "720p", "480p"], id: \.self) { q in
                        Button {
                            selectedQuality = q
                        } label: {
                            HStack {
                                Text(q)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedQuality == q {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section("ОЗВУЧКА") {
                    ForEach(["Любая", "Дубляж", "Оригинал", "AniLibria", "LostFilm"], id: \.self) { s in
                        Button {
                            selectedStudio = s
                        } label: {
                            HStack {
                                Text(s)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedStudio == s {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section("ИСТОЧНИК") {
                    ForEach(["Все", "Online Mod", "AniLibria", "Kodik", "Filmix"], id: \.self) { p in
                        Button {
                            selectedProvider = p
                        } label: {
                            HStack {
                                Text(p)
                                    .foregroundColor(.primary)
                                Spacer()
                                if selectedProvider == p {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Фильтры")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 5. Picker Sorting Sheet View (`sorting`)
struct PickerSortingSheetView: View {
    @Binding var sortMode: String
    @Environment(\.dismiss) private var dismiss

    let sortOptions = [
        ("recommended", "Рекомендуемые", "Мой приоритет источников"),
        ("quality", "По качеству", "Заявленное и подтверждённое отдельно"),
        ("verified", "Проверенные сначала", "Если статус реально известен"),
        ("voiceover", "По озвучке", "По названию студии / дорожки"),
        ("provider", "По источникам", "Группировать по провайдеру")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("ПОРЯДОК СОРТИРОВКИ") {
                    ForEach(sortOptions, id: \.0) { id, title, sub in
                        Button {
                            sortMode = id
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(sub)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if sortMode == id {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("При открытом списке новые результаты не переставляют строки под пальцем; их можно добавить вручную.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Сортировка")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") {
                        dismiss()
                    }
                }
            }
        }
    }
}
