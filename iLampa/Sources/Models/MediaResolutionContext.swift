import Foundation

/// Immutable resolution context stamped on every media lookup, source resolution,
/// and playback authorization to strictly prevent cross-media state leakage.
struct MediaResolutionContext: Equatable, Sendable {
    let requestId: UUID
    let actionId: UUID
    let canonicalId: String
    let title: String
    let mediaType: String // "movie" or "tv"
    let season: Int?
    let episode: Int?
    let balancer: String?
    let generation: Int
    let revision: Int
    var originalTitle: String? = nil

    var contextKey: String {
        "\(mediaType):\(canonicalId):s\(season ?? 0):e\(episode ?? 0):gen\(generation):rev\(revision)"
    }

    /// Verifies if a candidate payload or source discovery matches this exact context.
    func matches(canonicalId: String?, season: Int? = nil, episode: Int? = nil) -> Bool {
        guard let canonicalId, canonicalId == self.canonicalId else { return false }
        if mediaType == "tv" {
            if let season, self.season != nil, season != self.season { return false }
            if let episode, self.episode != nil, episode != self.episode { return false }
        }
        return true
    }

    /// Rejection reason if context does not match.
    func rejectionReason(canonicalId: String?, season: Int? = nil, episode: Int? = nil) -> String? {
        guard let canonicalId else { return "Canonical ID is missing" }
        if canonicalId != self.canonicalId {
            return "Canonical ID mismatch: candidate=\(canonicalId) vs active=\(self.canonicalId)"
        }
        if mediaType == "tv" {
            if let season, self.season != nil, season != self.season {
                return "Season mismatch: candidate=S\(season) vs active=S\(self.season!)"
            }
            if let episode, self.episode != nil, episode != self.episode {
                return "Episode mismatch: candidate=E\(episode) vs active=E\(self.episode!)"
            }
        }
        return nil
    }
}
