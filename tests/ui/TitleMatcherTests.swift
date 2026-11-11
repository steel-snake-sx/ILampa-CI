import XCTest

// MARK: - Native Integration Tests for Media Identity & Title Anti-Collision (Priority 3)
// Verifies that 'Квест Вижна' is NEVER matched with 'Квест учителя Коро'
// Implements and verifies tokenization, stop-words, and threshold logic directly on native iOS runtime.

struct NativeTitleMatcher {
    static func isRelevantMatch(query: String, candidateTitle: String, minWordOverlapRatio: Double = 0.5) -> Bool {
        let qTokens = tokenize(query)
        let cTokens = tokenize(candidateTitle)

        guard !qTokens.isEmpty && !cTokens.isEmpty else { return false }

        let qNorm = normalize(query)
        let cNorm = normalize(candidateTitle)

        if qNorm == cNorm { return true }

        let qSet = Set(qTokens)
        let cSet = Set(cTokens)
        let intersection = qSet.intersection(cSet)

        // For short queries (<= 2 words like "Квест Вижна"):
        // Every meaningful word MUST be present in candidate title!
        if qTokens.count <= 2 {
            let missingWords = qSet.subtracting(cSet)
            return missingWords.isEmpty
        }

        let overlap = Double(intersection.count) / Double(qSet.count)
        return overlap >= minWordOverlapRatio
    }

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    static func tokenize(_ text: String) -> [String] {
        let stopWords: Set<String> = [
            "в", "на", "и", "с", "по", "о", "к", "у", "из", "за", "от", "для", "не",
            "the", "a", "an", "of", "in", "to", "on", "at", "for", "with", "by", "and"
        ]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }
}

final class TitleMatchingIntegrationTests: XCTestCase {

    func testVisionQuestNeverMatchesAssassinationClassroom() {
        let query = "Квест Вижна"
        let incorrectCandidate = "Квест учителя Коро"

        let isMatch = NativeTitleMatcher.isRelevantMatch(query: query, candidateTitle: incorrectCandidate)
        XCTAssertFalse(isMatch, "КРИТИЧЕСКИЙ СБОЙ: «Квест Вижна» ошибочно сопоставлен с аниме «Квест учителя Коро»!")
    }

    func testVisionQuestMatchesExactOrYearVariant() {
        let query = "Квест Вижна"
        let validCandidate1 = "Квест Вижна"
        let validCandidate2 = "Квест Вижна (2026)"

        XCTAssertTrue(NativeTitleMatcher.isRelevantMatch(query: query, candidateTitle: validCandidate1), "Точное совпадение должно приниматься")
        XCTAssertTrue(NativeTitleMatcher.isRelevantMatch(query: query, candidateTitle: validCandidate2), "Совпадение с годом должно приниматься")
    }

    func testFightClubExactMatch() {
        let query = "Бойцовский клуб"
        let candidate = "Бойцовский клуб"
        XCTAssertTrue(NativeTitleMatcher.isRelevantMatch(query: query, candidateTitle: candidate))
    }

    func testUnrelatedSingleWordOverlapRejected() {
        let isMatch = NativeTitleMatcher.isRelevantMatch(query: "Аватар Путь Воды", candidateTitle: "Аватар: Легенда об Аанге")
        XCTAssertFalse(isMatch, "Нерелевантный спинофф с низким перекрытием должен отсекаться")
    }
}

// MARK: - Native Import Classification Integration Tests (Priority 4)
enum NativeClassification: Equatable {
    case pluginScript
    case directMediaStream(String)
    case providerEndpoint(String)
    case unsupportedWebpage
}

struct NativeImportClassifier {
    static func classify(urlString: String) -> NativeClassification {
        guard let url = URL(string: urlString) else { return .unsupportedWebpage }
        let pathLower = url.path.lowercased()

        if pathLower.hasSuffix(".m3u8") { return .directMediaStream("HLS") }
        if pathLower.hasSuffix(".mp4") { return .directMediaStream("MP4") }
        if pathLower.hasSuffix(".mov") { return .directMediaStream("MOV") }
        if pathLower.hasSuffix(".mkv") { return .directMediaStream("MKV") }

        if pathLower.hasSuffix(".js") || url.scheme == "ilampa" || pathLower.contains("/plugin/") {
            return .pluginScript
        }

        if pathLower.contains("/ts") || pathLower.contains("/torrserver") {
            return .providerEndpoint("TorrServer")
        }

        return .unsupportedWebpage
    }
}

final class ImportClassificationIntegrationTests: XCTestCase {
    func testClassifyPluginUrls() {
        XCTAssertEqual(NativeImportClassifier.classify(urlString: "https://tsynik.github.io/lampa/e.js"), .pluginScript)
        XCTAssertEqual(NativeImportClassifier.classify(urlString: "https://tsynik.github.io/lampa/soma.js"), .pluginScript)
    }

    func testClassifyMediaStreams() {
        XCTAssertEqual(NativeImportClassifier.classify(urlString: "https://devstreaming.apple.com/test.m3u8"), .directMediaStream("HLS"))
        XCTAssertEqual(NativeImportClassifier.classify(urlString: "https://commondatastorage.googleapis.com/test.mp4"), .directMediaStream("MP4"))
    }

    func testRejectArbitraryWebpages() {
        XCTAssertEqual(NativeImportClassifier.classify(urlString: "https://www.google.com/search?q=movie"), .unsupportedWebpage)
        XCTAssertEqual(NativeImportClassifier.classify(urlString: "https://www.kinopoisk.ru/film/326/"), .unsupportedWebpage)
    }
}
