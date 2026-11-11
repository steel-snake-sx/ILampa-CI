import Foundation

// Normalizes provider-specific audio track and voiceover labels into standardized names.
struct VoiceoverNormalizer {
    static let standardStudios: [String: String] = [
        "dubbing": "Дубляж (Официальный)",
        "lostfilm": "LostFilm",
        "hdrezka": "HDRezka Studio",
        "anilibria": "AniLibria",
        "redheadsound": "Red Head Sound",
        "kubik": "Кубик в Кубе",
        "tvshows": "TVShows",
        "newstudio": "NewStudio",
        "original": "Оригинал"
    ]

    // Returns a clean, user-friendly display name for a voiceover or studio.
    static func normalize(rawName: String) -> (id: String, displayName: String) {
        let lower = rawName.lowercased()

        if lower.contains("дубляж") || lower.contains("dubbing") || lower.contains("дублированный") {
            return ("dubbing", standardStudios["dubbing"]!)
        } else if lower.contains("lostfilm") || lower.contains("лостфильм") {
            return ("lostfilm", standardStudios["lostfilm"]!)
        } else if lower.contains("hdrezka") || lower.contains("rezka") || lower.contains("резка") {
            return ("hdrezka", standardStudios["hdrezka"]!)
        } else if lower.contains("anilibria") || lower.contains("анилибрия") {
            return ("anilibria", standardStudios["anilibria"]!)
        } else if lower.contains("red head sound") || lower.contains("rhs") {
            return ("redheadsound", standardStudios["redheadsound"]!)
        } else if lower.contains("кубик") || lower.contains("kubik") {
            return ("kubik", standardStudios["kubik"]!)
        } else if lower.contains("оригинал") || lower.contains("original") {
            return ("original", standardStudios["original"]!)
        }

        // Clean up raw name if unknown
        let clean = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean.lowercased(), clean.isEmpty ? "Стандартная озвучка" : clean)
    }

    // Sorts sources so that user's preferred studio and quality appear at the top.
    static func prioritize<T>(items: [T], preferredStudio: String, preferredQuality: String,
                             studioExtractor: (T) -> String,
                             qualityExtractor: (T) -> String) -> [T] {
        items.sorted { a, b in
            let aStudio = studioExtractor(a)
            let bStudio = studioExtractor(b)
            let aQual = qualityExtractor(a)
            let bQual = qualityExtractor(b)

            let aStudioMatch = aStudio.lowercased() == preferredStudio.lowercased()
            let bStudioMatch = bStudio.lowercased() == preferredStudio.lowercased()
            if aStudioMatch != bStudioMatch {
                return aStudioMatch
            }

            let aQualMatch = aQual.lowercased() == preferredQuality.lowercased()
            let bQualMatch = bQual.lowercased() == preferredQuality.lowercased()
            if aQualMatch != bQualMatch {
                return aQualMatch
            }

            return false
        }
    }
}
