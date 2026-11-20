import Foundation

/// Canonical metadata resolved from an external catalogue.
struct ResolvedMetadata: Sendable, Codable {
    let title: String
    let artist: String
    let album: String?
    let year: Int?
    let artworkURL: URL?
    let source: String
}

/// Multi-source metadata enrichment with fallback: iTunes Search (fast, free,
/// no auth) first, then MusicBrainz + Cover Art Archive. Never uploads anything;
/// only reads public catalogues.
enum MetadataResolver {
    /// Resolve canonical metadata for a track. Tries iTunes, then MusicBrainz.
    static func enrich(title: String, artist: String, album: String? = nil, duration: Int? = nil) async -> ResolvedMetadata? {
        let query = TextMatch.recordingQuery(title: title, artist: artist)
        let title = query.title
        let artist = query.artist
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        let key = "track-v3|\(TextMatch.normalize(TextMatch.recordingTitle(title)))|\(TextMatch.normalize(TextMatch.queryArtist(artist)))"
            + "|\(TextMatch.normalize(album ?? ""))|\(duration ?? 0)"
        if let cached = await MetadataCache.shared.lookup(key) {
            return cached.value
        }

        // Apple/iTunes is the primary catalogue (matches the app's design);
        // MusicBrainz and Deezer are fallbacks only.
        var resolved = await iTunes(title: title, artist: artist, album: album, duration: duration)
        if resolved == nil {
            resolved = await deezer(title: title, artist: artist, album: album, duration: duration)
        }
        if resolved == nil {
            resolved = await musicBrainz(title: title, artist: artist, duration: duration)
        }
        await MetadataCache.shared.store(key, resolved)
        return resolved
    }

    /// iTunes' musicArtist endpoint has no portraits. This lookup is only for
    /// actual album artwork and requires the album and performer to match.
    static func albumArtwork(title: String, artist: String) async -> URL? {
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        let key = "album-v2|" + cacheKey(title: title, artist: artist)
        if let cached = await MetadataCache.shared.lookup(key) { return cached.value?.artworkURL }
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(title)"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "10")
        ]
        guard let url = components?.url,
              let response: ITunesResponse = try? await decode(url, headers: [:]) else { return nil }
        let match = response.results.first {
            MusicArtworkSelectionPolicy.matchesRequestedRelease(
                requested: title, candidate: $0.collectionName
            )
                && TextMatch.normalizeArtist($0.artistName ?? "")
                    == TextMatch.normalizeArtist(artist)
        }
        let artwork = ArtworkURLs.highRes(match?.artworkUrl100).flatMap(URL.init(string:))
        let value = artwork.map {
            ResolvedMetadata(title: title, artist: artist, album: title, year: nil, artworkURL: $0, source: "iTunes")
        }
        await MetadataCache.shared.store(key, value)
        return artwork
    }

    private static func cacheKey(title: String, artist: String) -> String {
        "\(TextMatch.normalizeTitle(title))|\(TextMatch.normalizeArtist(artist))"
    }

    // MARK: - iTunes Search

    private struct ITunesResponse: Decodable {
        struct Result: Decodable {
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let releaseDate: String?
            let artworkUrl100: String?
            let trackTimeMillis: Int?
        }
        let results: [Result]
    }

    private static func iTunes(title: String, artist: String, album: String?, duration: Int?) async -> ResolvedMetadata? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(TextMatch.catalogueArtist(artist)) \(TextMatch.recordingTitle(title))"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15")
        ]
        guard let url = components?.url,
              let response: ITunesResponse = try? await decode(url, headers: [:]) else {
            return nil
        }

        let candidates = response.results.filter { result in
            guard let track = result.trackName, let name = result.artistName else { return false }
            guard TextMatch.recordingsMatch(track, title), TextMatch.artistsMatch(name, artist) else { return false }
            let querySuspicious = TextMatch.isSuspiciousVersion(title)
            if !querySuspicious, TextMatch.isSuspiciousVersion(track) { return false }
            if let duration, duration > 0, let millis = result.trackTimeMillis {
                let seconds = millis / 1000
                if abs(seconds - duration) > 15 { return false }
            }
            return true
        }
        // Prefer the release that matches the album we already know.
        let best = candidates.first { result in
            guard let requested = album, !requested.isEmpty,
                  let found = result.collectionName else { return false }
            return TextMatch.albumsMatch(found, requested)
        } ?? candidates.first
        guard let best else { return nil }

        let artwork = ArtworkURLs.highRes(best.artworkUrl100)
        let year = best.releaseDate.flatMap { Int($0.prefix(4)) }
        return ResolvedMetadata(
            title: best.trackName ?? title,
            artist: best.artistName ?? artist,
            album: best.collectionName ?? album,
            year: year,
            artworkURL: artwork.flatMap(URL.init(string:)),
            source: "iTunes"
        )
    }

    // MARK: - MusicBrainz + Cover Art Archive

    private struct MusicBrainzResponse: Decodable {
        struct Recording: Decodable {
            struct Credit: Decodable {
                struct Artist: Decodable { let name: String }
                let artist: Artist
            }
            struct Release: Decodable {
                let id: String
                let title: String?
                let date: String?
            }
            let title: String?
            let firstReleaseDate: String?
            let releases: [Release]?
            let artistCredit: [Credit]?
            let length: Int?

            enum CodingKeys: String, CodingKey {
                case title, releases, length
                case firstReleaseDate = "first-release-date"
                case artistCredit = "artist-credit"
            }
        }
        let recordings: [Recording]
    }

    private static func musicBrainz(title: String, artist: String, duration: Int?) async -> ResolvedMetadata? {
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: "recording:\"\(TextMatch.recordingTitle(title))\" AND artist:\"\(TextMatch.catalogueArtist(artist))\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1")
        ]
        // MusicBrainz requires an identifying User-Agent.
        let headers = ["User-Agent": "Thrum/1.0 (https://github.com/Mosas123/Trop)"]
        guard let url = components?.url,
              let response: MusicBrainzResponse = try? await decode(url, headers: headers),
              let recording = response.recordings.first else {
            return nil
        }

        guard TextMatch.recordingsMatch(recording.title ?? "", title),
              recording.artistCredit?.contains(where: { TextMatch.artistsMatch($0.artist.name, artist) }) == true else {
            return nil
        }

        if let duration, duration > 0, let milliseconds = recording.length,
           abs(milliseconds / 1000 - duration) > 15 { return nil }

        let release = recording.releases?.first
        let year = (release?.date ?? recording.firstReleaseDate).flatMap { Int($0.prefix(4)) }
        var artworkURL: URL?
        if let releaseID = release?.id {
            artworkURL = URL(string: "https://coverartarchive.org/release/\(releaseID)/front")
        }
        return ResolvedMetadata(
            title: recording.title ?? title,
            artist: artist,
            album: release?.title,
            year: year,
            artworkURL: artworkURL,
            source: "MusicBrainz"
        )
    }

    // MARK: - Deezer (fallback)

    private struct DeezerResponse: Decodable {
        struct Track: Decodable {
            struct Artist: Decodable { let name: String? }
            struct Album: Decodable {
                let title: String?
                let cover_xl: String?
            }
            let title: String?
            let artist: Artist?
            let album: Album?
            let duration: Int?
        }
        let data: [Track]
    }

    private static func deezer(title: String, artist: String, album: String?, duration: Int?) async -> ResolvedMetadata? {
        var components = URLComponents(string: "https://api.deezer.com/search")
        let query = artist.isEmpty ? TextMatch.recordingTitle(title) : "\(TextMatch.catalogueArtist(artist)) \(TextMatch.recordingTitle(title))"
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "15")
        ]
        guard let url = components?.url,
              let response: DeezerResponse = try? await decode(url, headers: [:]) else {
            return nil
        }
        let candidates = response.data.filter { track in
            guard let trackTitle = track.title else { return false }
            guard TextMatch.recordingsMatch(trackTitle, title),
                  TextMatch.artistsMatch(track.artist?.name ?? "", artist) else { return false }
            let querySuspicious = TextMatch.isSuspiciousVersion(title)
            if !querySuspicious, TextMatch.isSuspiciousVersion(trackTitle) { return false }
            if let duration, duration > 0, let seconds = track.duration,
               abs(seconds - duration) > 15 {
                return false
            }
            return true
        }
        let best = candidates.first { track in
            guard let requested = album, !requested.isEmpty,
                  let found = track.album?.title else { return false }
            return TextMatch.albumsMatch(found, requested)
        } ?? candidates.first
        guard let best else { return nil }
        return ResolvedMetadata(
            title: best.title ?? title,
            artist: best.artist?.name ?? artist,
            album: best.album?.title,
            year: nil,
            artworkURL: best.album?.cover_xl.flatMap(URL.init(string:)),
            source: "Deezer"
        )
    }

    // MARK: - Helpers

    private static func decode<T: Decodable>(_ url: URL, headers: [String: String]) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

}

/// Small in-memory cache (positive and negative) so repeated tracks don't refetch.
actor MetadataCache {
    static let shared = MetadataCache()

    struct Entry: Codable, Sendable {
        let value: ResolvedMetadata?
        let storedAt: Date
        let expiresAt: Date
    }

    private var store: [String: Entry] = [:]
    private let diskURL: URL
    private let positiveTTL: TimeInterval = 30 * 24 * 3600
    private let negativeTTL: TimeInterval = 30 * 60
    private var persistTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskURL = base.appendingPathComponent("metadata-cache.json")
        if let data = try? Data(contentsOf: diskURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            let now = Date()
            store = decoded.filter { $0.value.expiresAt > now }
        }
    }

    func lookup(_ key: String) -> Entry? {
        guard let entry = store[key] else { return nil }
        guard entry.expiresAt > Date() else {
            store[key] = nil
            return nil
        }
        return entry
    }

    func store(_ key: String, _ value: ResolvedMetadata?) {
        if store[key] == nil, store.count >= 2000 {
            for victim in Array(store.keys.prefix(500)) {
                store.removeValue(forKey: victim)
            }
        }
        let now = Date()
        let ttl = value == nil ? negativeTTL : positiveTTL
        store[key] = Entry(value: value, storedAt: now, expiresAt: now.addingTimeInterval(ttl))
        schedulePersist()
    }

    /// Debounced disk write so a burst of resolutions isn't 100 file writes.
    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: diskURL, options: .atomic)
    }

    func clear() {
        store.removeAll()
        persistTask?.cancel()
        try? FileManager.default.removeItem(at: diskURL)
    }
}
