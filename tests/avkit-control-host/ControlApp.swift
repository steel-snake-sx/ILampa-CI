import UIKit
import AVKit

/// Separate diagnostic executable: no iLampa, SwiftUI, WebKit or audio lease.
@main
final class AVKitControlApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = HLSControlController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

final class HLSControlController: UIViewController {
    private var playerController: AVPlayerViewController?
    private let reopen = UIButton(type: .system)
    private let close = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        reopen.setTitle("Open independent HLS", for: .normal)
        reopen.accessibilityIdentifier = "controlReopen"
        reopen.addTarget(self, action: #selector(openPlayer), for: .touchUpInside)
        close.setTitle("Close independent HLS", for: .normal)
        close.accessibilityIdentifier = "controlClose"
        close.addTarget(self, action: #selector(closePlayer), for: .touchUpInside)
        for button in [reopen, close] {
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                button.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
        openPlayer()
    }

    @objc private func openPlayer() {
        guard playerController == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { print("[IndependentAVKit] audio activation failed: \(error)") }
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.showsPlaybackControls = true
        controller.requiresLinearPlayback = false
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(controller.view, at: 0)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 44),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        playerController = controller
        close.isHidden = false
        reopen.isHidden = true
        print("[IndependentAVKit] play same Apple bipbop HLS; no production services")
        controller.player?.play()
    }

    @objc private func closePlayer() {
        guard let controller = playerController else { return }
        controller.player?.pause()
        controller.player?.replaceCurrentItem(with: nil)
        controller.player = nil
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        playerController = nil
        close.isHidden = true
        reopen.isHidden = false
        do { try AVAudioSession.sharedInstance().setActive(false) }
        catch { print("[IndependentAVKit] audio deactivation failed: \(error)") }
    }
}
