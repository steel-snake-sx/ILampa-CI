import Foundation

struct RadioStation: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let genre: String
    let largeimage: String
    let listeners: Int
    let playlists: [RadioPlaylist]
    
    // Computed — not in JSON
    var resolvedStreamURLs: [URL] = []
    
    struct RadioPlaylist: Codable, Equatable, Sendable {
        let url: String
        let quality: String
        let format: String
    }
    
    var genreDisplay: String {
        genre.split(separator: "|").map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " • ")
    }
    
    var imageURL: URL? { URL(string: largeimage) }
    
    // Preferred playlist: 320k MP3 > 256k MP3 > 128k MP3
    var preferredPlaylist: RadioPlaylist? {
        playlists.first(where: { $0.url.hasSuffix("320.pls") && $0.format == "mp3" })
        ?? playlists.first(where: { $0.url.hasSuffix("256.pls") && $0.format == "mp3" })
        ?? playlists.first(where: { $0.quality == "highest" && $0.format == "mp3" })
        ?? playlists.first(where: { $0.quality == "highest" })
        ?? playlists.first
    }
    
    // CodingKeys to handle JSON keys that differ from Swift naming
    enum CodingKeys: String, CodingKey {
        case id, title, description, genre, largeimage, image, listeners, playlists
    }

    init(id: String, title: String, description: String, genre: String, largeimage: String, listeners: Int, playlists: [RadioPlaylist], resolvedStreamURLs: [URL] = []) {
        self.id = id
        self.title = title
        self.description = description
        self.genre = genre
        self.largeimage = largeimage
        self.listeners = listeners
        self.playlists = playlists
        self.resolvedStreamURLs = resolvedStreamURLs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        
        // largeimage or fallback to image
        if let img = try? container.decode(String.self, forKey: .largeimage), !img.isEmpty {
            self.largeimage = img
        } else if let img = try? container.decode(String.self, forKey: .image), !img.isEmpty {
            self.largeimage = img
        } else {
            self.largeimage = ""
        }

        // SomaFM API encodes listeners as String ("158"), Int, or missing
        if let intVal = try? container.decode(Int.self, forKey: .listeners) {
            self.listeners = intVal
        } else if let strVal = try? container.decode(String.self, forKey: .listeners), let intVal = Int(strVal) {
            self.listeners = intVal
        } else {
            self.listeners = 0
        }

        self.playlists = try container.decodeIfPresent([RadioPlaylist].self, forKey: .playlists) ?? []
        self.resolvedStreamURLs = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(genre, forKey: .genre)
        try container.encode(largeimage, forKey: .largeimage)
        try container.encode(listeners, forKey: .listeners)
        try container.encode(playlists, forKey: .playlists)
    }
}

struct SomaFMChannelsResponse: Codable {
    let channels: [RadioStation]
}
