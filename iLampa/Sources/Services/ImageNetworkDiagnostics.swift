import Foundation

/// One bounded, privacy-safe probe per artwork host when AsyncImage reports a failure.
/// Network paths used by images and AVPlayer may differ under a VPN.
@MainActor
enum ImageNetworkDiagnostics {
    private static var probedHosts = Set<String>()

    static func inspectFailure(of url: URL) async {
        guard let host = url.host, probedHosts.insert(host).inserted else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DiagnosticsLogManager.shared.log(category: "[Artwork]",
                message: "Artwork load failed, probeHost=\(host), probeHTTP=\(status) (HEAD request)",
                level: .warning)
        } catch {
            let ns = error as NSError
            DiagnosticsLogManager.shared.log(category: "[Artwork]",
                message: "Artwork load failed, probeHost=\(host), errorDomain=\(ns.domain), errorCode=\(ns.code)",
                level: .warning)
        }
    }
}
