import AVKit
import SwiftUI
import XCTest
@testable import iLampa

/// Same CAF and verification routine as the independent control, but entering
/// NativePlayerView.makeUIViewController through real SwiftUI hosting.
extension PlayerStateIntegrationTests {
    func testProductionStartupWithControlAsset() async throws {
        let url = try makeIndependentFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = PlayPayload(url: url.absoluteString, title: "Local control comparison", isDiagnostic: true)
        let host = UIHostingController(rootView: NativePlayerView(payload: .constant(payload)))
        // A frame-only UIWindow is not attached to the app's scene on current
        // iOS, so SwiftUI never constructs its representable child controller.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.loadViewIfNeeded()
        host.view.layoutIfNeeded()
        XCTAssertTrue(host.view.window === window, "Control comparison must actually enter the live scene")
        defer { window.isHidden = true; window.rootViewController = nil }

        @MainActor func findPlayer(in controller: UIViewController) -> AVPlayerViewController? {
            if let player = controller as? AVPlayerViewController { return player }
            return controller.children.compactMap { findPlayer(in: $0) }.first
        }
        // Keep UIKit traversal on the main actor, not in a predicate evaluator.
        let deadline = Date().addingTimeInterval(10)
        while findPlayer(in: host)?.player == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let controller = try XCTUnwrap(findPlayer(in: host))
        let player = try XCTUnwrap(controller.player)
        XCTAssertTrue(PlayerPlaybackController.shared.activePlayer === player,
                      "Comparison must use the actual registered production player")
        defer {
            // Exercise the real owner teardown; do not substitute a fake lease.
            print("[LocalPlayerProbe] production owner teardown begin")
            PlayerPlaybackController.shared.pauseAndTeardown()
            print("[LocalPlayerProbe] production owner teardown returned")
            XCTAssertNil(player.currentItem)
            XCTAssertNil(controller.player)
            XCTAssertNil(PlayerPlaybackController.shared.activePlayer)
        }
        try await probe(url, exercisePlayback: true, providedPlayer: player)
    }
}
