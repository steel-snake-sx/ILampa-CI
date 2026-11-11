import XCTest
@testable import iLampa

final class MediaDetailResolutionIntentTests: XCTestCase {
    func testRepeatedAppearanceForSameMediaSeasonEpisodeDoesNotStartAnotherAutomaticResolution() {
        let context = "urn:media:tmdb:tv:30984|1|1"
        XCTAssertTrue(SourceResolutionIntentPolicy.shouldStartAutomaticResolution(lastContext: nil, nextContext: context))
        XCTAssertFalse(SourceResolutionIntentPolicy.shouldStartAutomaticResolution(lastContext: context, nextContext: context))
    }

    func testSeasonEpisodeOrMediaChangeStartsDistinctAutomaticResolution() {
        let original = "urn:media:tmdb:tv:30984|1|1"
        XCTAssertTrue(SourceResolutionIntentPolicy.shouldStartAutomaticResolution(lastContext: original,
                                                                                  nextContext: "urn:media:tmdb:tv:30984|1|2"))
        XCTAssertTrue(SourceResolutionIntentPolicy.shouldStartAutomaticResolution(lastContext: original,
                                                                                  nextContext: "urn:media:tmdb:tv:30984|2|1"))
        XCTAssertTrue(SourceResolutionIntentPolicy.shouldStartAutomaticResolution(lastContext: original,
                                                                                  nextContext: "urn:media:tmdb:movie:550|none|none"))
    }

    func testOnlineResolutionRejectsStaleOrCancelledResult() {
        let request = UUID()
        let context = "urn:media:tmdb:tv:30984|1|1"
        func accepted(_ currentRequest: UUID, _ currentContext: String, cancelled: Bool = false) -> Bool {
            SourceResolutionIntentPolicy.isCurrentResult(requestId: request, currentRequestId: currentRequest,
                                                         context: context, currentContext: currentContext,
                                                         isCancelled: cancelled)
        }
        XCTAssertTrue(accepted(request, context))
        XCTAssertFalse(accepted(UUID(), context))
        XCTAssertFalse(accepted(request, "urn:media:tmdb:tv:30984|1|2"))
        XCTAssertFalse(accepted(request, context, cancelled: true))
    }
}
