import UIKit

/// Deliberately empty: no iLampa module, WebKit, AVKit, audio setup, networking,
/// singleton, SwiftUI lifecycle, or application resource is linked here.
@main
final class ControlApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
