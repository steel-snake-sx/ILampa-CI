import Foundation

/// Native defense against late resolver responses and incidental/background player events.
struct PlaybackSelectionGate {
    struct Selection {
        let requestID: String
        let canonicalID: String
        let mediaType: String
        let pluginID: String
        let context: String
        let generation: Int
        let createdAt: Date
        var season: Int? = nil
        var episode: Int? = nil
        var audio: String? = nil

        var selectedVoiceName: String? {
            guard ["lampa_player_create", "headless_native_bridge"].contains(context),
                  let voice = audio?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !voice.isEmpty else { return nil }
            return String(voice.prefix(200))
        }
    }

    private(set) var pending: Selection?
    mutating func clear() { pending = nil }
    mutating func invalidatePending() { pending = nil }

    mutating func select(_ selection: Selection, isVisible: Bool) {
        let isPermitted = isVisible || selection.context == "headless_native_bridge"
        guard isPermitted, !selection.requestID.isEmpty, !selection.canonicalID.isEmpty,
              !selection.pluginID.isEmpty, !selection.context.isEmpty else { return }
        pending = selection
    }

    mutating func consume(_ payload: PlayPayload, generation: Int, isVisible: Bool, now: Date = Date()) -> Bool {
        consumeSelection(payload, generation: generation, isVisible: isVisible, now: now) != nil
    }

    /// Returns the accepted selection, so callers can use its selected-row metadata only
    /// after all attribution checks have succeeded and the selection has been consumed.
    mutating func consumeSelection(_ payload: PlayPayload, generation: Int, isVisible: Bool, now: Date = Date()) -> Selection? {
        let isPermitted = isVisible || payload.selectionContext == "headless_native_bridge"
        guard isPermitted, let selection = pending,
              selection.generation == generation,
              now.timeIntervalSince(selection.createdAt) >= 0,
              now.timeIntervalSince(selection.createdAt) < 60,
              payload.action == "play", payload.requestId == selection.requestID,
              payload.canonicalId == selection.canonicalID, payload.mediaType == selection.mediaType,
              payload.pluginId == selection.pluginID, payload.selectionContext == selection.context,
              payload.season == selection.season, payload.episode == selection.episode,
              selection.audio == nil || payload.currentStudio == nil || selection.audio == payload.currentStudio,
              let url = URL(string: payload.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        pending = nil
        return selection
    }
}
