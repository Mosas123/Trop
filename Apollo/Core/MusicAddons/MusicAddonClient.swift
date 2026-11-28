import Foundation

struct AddonPlaybackRef: Codable, Sendable, Equatable {
    let k: String
    let t: String
    let i: String
}

enum AddonPlaybackID {
    static let prefix = "addon:"

    static func encode(key: String, type: String, id: String) -> String {
        let ref = AddonPlaybackRef(k: key, t: type, i: id)
        let data = (try? JSONEncoder().encode(ref)) ?? Data()
        return prefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ raw: String) -> AddonPlaybackRef? {
        guard raw.hasPrefix(prefix) else { return nil }
        var base = String(raw.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base) else { return nil }
        return try? JSONDecoder().decode(AddonPlaybackRef.self, from: data)
    }
}

enum MusicAddonClientError: Error, Equatable {
    case unsupportedProtocol
    case invalidURL
    case noResults
    case noStream
}

struct AddonTrack: Sendable, Equatable {
    let installationKey: String
    let type: String
    let id: String
    let title: String
    let poster: URL?
    let detail: String?
    var artist: String? = nil
    var album: String? = nil
    var durationSeconds: Int? = nil
    var isAtmos: Bool = false
    var isHiRes: Bool = false
    var isAtmosOnly: Bool = false
}

struct AddonAlbum: Sendable, Equatable {
    let installationKey: String
    let id: String
    let title: String
    let artist: String?
    let trackCount: Int?
    let year: Int?
}

enum AddonStreamQuality: String, Sendable {
    case max
    case hires
    case lossless
    case high
}

/// Search-tier hint for Eclipse addons. Without it NullBeat serves its MAX
/// (hi-res) master in Auto, bypassing the independent Hi-Res opt-in.
private enum AddonSearchQualityHint {
    static func item() -> URLQueryItem? {
        let settings = SettingsStore.shared
        let value: String?
        switch settings.activeStreamingMode {
        case .off:
            value = nil
        case .high:
            value = "high"
        case .cd:
            value = "lossless"
        case .auto, .lossless:
            if settings.preferAtmos && settings.activeStreamingPreferHiRes {
                // "max" only with both opt-ins: alone it may return hi-res
                // even when Hi-Res is off. Atmos alone uses the resolve flag.
                value = "max"
            } else if settings.activeStreamingPreferHiRes {
                value = "hires"
            } else {
                value = "lossless"
            }
        }
        guard let value else { return nil }
        return URLQueryItem(name: "quality", value: value)
    }
}

struct AddonStream: Sendable {
    enum Kind: Sendable {
        case url(URL)
        case youtube(String)
    }
    let kind: Kind
    let mimeType: String
    let bitrate: Int
    /// "Lossless" / "High" / "Standard" derived from the stream metadata.
    let qualityTier: String
    /// The addon warns the file needs its own decryption; refuse it.
    var isEncrypted: Bool = false
    var sampleRateHz: Int? = nil
    var bitDepth: Int? = nil
    /// 24-bit / >48 kHz copy (the addon reports "hires"), as opposed to CD.
    var isHiRes: Bool = false
    /// Declared file size, when the addon reports it.
    var sizeBytes: Int? = nil
}

/// Short-lived cache for addon search/album responses. Stream URLs are never
/// cached: they are short-lived and must be minted per playback/download.
actor AddonResponseCache {
    static let shared = AddonResponseCache()

    private struct Entry {
        let data: Data
        let at: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 300
    private let maxEntries = 64

    func data(for key: String) -> Data? {
        guard let entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < ttl else {
            entries[key] = nil
            return nil
        }
        return entry.data
    }

    func store(_ data: Data, for key: String) {
        if entries.count >= maxEntries {
            let cutoff = Date().addingTimeInterval(-ttl)
            entries = entries.filter { $0.value.at >= cutoff }
            if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }
        }
        entries[key] = Entry(data: data, at: Date())
    }
}

/// Read-only client for Stremio music addons. It only calls `catalog/.../search`
/// and `stream/...` and never executes provider code.
actor MusicAddonClient {
    let installation: MusicAddonInstallation
    private let baseURL: URL
    private let catalogTypes: [String]
    private let searchCatalogs: [StremioDescriptor.Catalog]
    /// Eclipse-style addons expose a `search` resource and `/search?q=` +
    /// `/stream/<id>` (Nebula, NullBeat) instead of Stremio catalogs.
    private let eclipseMode: Bool

    init(installation: MusicAddonInstallation) throws {
        guard installation.manifest.protocolKind == .stremio,
              let descriptor = installation.manifest.stremio else {
            throw MusicAddonClientError.unsupportedProtocol
        }
        self.installation = installation
        self.baseURL = installation.manifestURL.deletingLastPathComponent()
        let preferred = ["track", "song", "music", "audio"]
        let available = Set(descriptor.types.map { $0.lowercased() })
        let types = preferred.filter { available.contains($0) }
        let finalTypes = types.isEmpty ? descriptor.types.map { $0.lowercased() } : types
        self.catalogTypes = finalTypes
        let searchable = descriptor.catalogs.filter { catalog in
            catalog.extra?.contains { $0.name.lowercased() == "search" } == true
        }
        let preferredCatalogs = searchable.filter { finalTypes.contains($0.type.lowercased()) }
        self.searchCatalogs = preferredCatalogs.isEmpty ? searchable : preferredCatalogs
        // NullBeat (and other Eclipse addons) also publish browse catalogs with
        // no search extra; the `search` resource is what tells them apart from
        // Stremio addons, which always search through a catalog.
        self.eclipseMode = descriptor.usesEclipseRouting
    }

    var installationKey: String { installation.key }
    var name: String { installation.manifest.name }

    /// Some addons advertise `contentType: music` but their search catalog is
    /// a movie/series index (PencariMovie does exactly that). Only music items
    /// are safe to show, play or download.
    static let musicTypes: Set<String> = ["track", "music", "audio", "song"]

    /// Music addons that wrap tracks as `movie`/`series` items (the Stremio
    /// convention PencariMusic uses). Only trust that when the manifest says
    /// its content type is music, so film addons stay out.
    private var allowsWrappedTrackTypes: Bool {
        (installation.manifest.stremio?.contentType ?? "").lowercased() == "music"
    }

    private func isMusicItemType(_ type: String) -> Bool {
        let lower = type.lowercased()
        if Self.musicTypes.contains(lower) { return true }
        return allowsWrappedTrackTypes && (lower == "movie" || lower == "series")
    }

    func search(_ query: String, limit: Int = 20) async throws -> [AddonTrack] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        if eclipseMode {
            // A resolver-only Eclipse addon may have no /search route.
            guard installation.manifest.stremio?.offers("search") == true else {
                return []
            }
            return try await eclipseSearch(term, limit: limit)
        }
        guard !searchCatalogs.isEmpty else { return [] }
        var tracks: [AddonTrack] = []
        var seen = Set<String>()

        for catalog in searchCatalogs.prefix(3) {
            guard let encoded = term.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
            ) else { continue }
            let url = baseURL
                .appendingPathComponent("catalog")
                .appendingPathComponent(catalog.type)
                .appendingPathComponent(catalog.id)
                .appendingPathComponent("search=\(encoded).json")
            guard let data = await cachedFetch(url, key: "catalog|\(url.absoluteString)"),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any],
                  let metas = root["metas"] as? [[String: Any]] else { continue }
            for meta in metas {
                guard let id = meta["id"] as? String,
                      let name = meta["name"] as? String,
                      !name.isEmpty else { continue }
                let type = ((meta["type"] as? String) ?? catalog.type).lowercased()
                guard isMusicItemType(type) else { continue }
                let key = "\(type)|\(id)"
                guard seen.insert(key).inserted else { continue }
                let posterString = (meta["poster"] as? String) ?? (meta["logo"] as? String)
                let detail = (meta["description"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Wrapper addons title tracks as "Artist - Title" and put the
                // duration in the description ("FLAC · LOSSLESS · 25 MB · 4:04").
                var title = name
                var artist: String? = nil
                if allowsWrappedTrackTypes, let split = Self.splitArtistTitle(name) {
                    artist = split.artist
                    title = split.title
                }
                let duration = Self.parseDurationSeconds(meta["duration"])
                    ?? (allowsWrappedTrackTypes ? Self.durationFromDescription(detail) : nil)
                tracks.append(AddonTrack(
                    installationKey: installation.key,
                    type: type,
                    id: id,
                    title: title,
                    poster: posterString.flatMap(URL.init(string:)),
                    detail: (detail?.isEmpty == false) ? detail : nil,
                    artist: artist,
                    durationSeconds: duration
                ))
                if tracks.count >= limit { return tracks }
            }
        }
        return tracks
    }

    private func eclipseSearch(_ term: String, limit: Int) async throws -> [AddonTrack] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        var items = [URLQueryItem(name: "q", value: term)]
        // Ask for the CD/lossless tier instead of letting NullBeat default to
        // its MAX/hi-res master; Atmos and High are explicit opt-ins.
        if let hint = AddonSearchQualityHint.item() { items.append(hint) }
        components?.queryItems = items
        guard let url = components?.url,
              let data = await cachedFetch(url, key: "search|\(url.absoluteString)"),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let tracks = root["tracks"] as? [[String: Any]] else { return [] }
        return tracks.prefix(limit).compactMap { track in
            guard let id = track["id"] as? String,
                  let title = track["title"] as? String else { return nil }
            let artist = track["artist"] as? String
            let album = track["album"] as? String
            let duration = Self.parseDurationSeconds(track["duration"])
            let artwork = (track["artworkURL"] as? String) ?? (track["coverURL"] as? String)
            return AddonTrack(
                installationKey: installation.key,
                type: "track",
                id: id,
                title: title,
                poster: artwork.flatMap(URL.init(string:)),
                detail: album,
                artist: artist,
                album: album,
                durationSeconds: duration,
                isAtmos: (track["isAtmos"] as? Bool) ?? false,
                isHiRes: (track["isHiRes"] as? Bool) ?? false,
                isAtmosOnly: (track["isAtmosOnly"] as? Bool) ?? false
            )
        }
    }

    /// Addons disagree on durations: numbers, "370", "6:10" or "1:02:03".
    private static func parseDurationSeconds(_ value: Any?) -> Int? {
        switch value {
        case let seconds as Int: return seconds
        case let seconds as Double: return Int(seconds)
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Int(trimmed) { return seconds }
            let parts = trimmed.split(separator: ":").compactMap { Int($0) }
            guard (1...3).contains(parts.count) else { return nil }
            return parts.reduce(0) { $0 * 60 + $1 }
        default: return nil
        }
    }

    /// Resolve a recording through the explicit Eclipse identity API before
    /// launching multiple fuzzy text searches. An addon that declares only
    /// "resolve" can still provide audio to Apollo's normal playback queue.
    /// Caller must independently verify title, artist and duration before
    /// trusting the returned track ID; no URL is stored or executed here.
    func resolveIdentity(
        title: String,
        artist: String,
        durationSeconds: Int?
    ) async -> AddonTrack? {
        guard eclipseMode,
              installation.manifest.stremio?.offers("resolve") == true,
              !title.isEmpty, !artist.isEmpty else { return nil }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("resolve"),
            resolvingAgainstBaseURL: false
        )
        var query = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist)
        ]
        if let durationSeconds, durationSeconds > 0,
           durationSeconds <= Int.max / 1_000 {
            query.append(URLQueryItem(
                name: "durationMs", value: String(durationSeconds * 1_000)
            ))
        }
        components?.queryItems = query
        guard let url = components?.url,
              let data = await fetch(url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let item = root["item"] as? [String: Any],
              let id = item["id"] as? String, !id.isEmpty,
              let resolvedTitle = item["title"] as? String,
              let resolvedArtist = item["artist"] as? String,
              !resolvedTitle.isEmpty, !resolvedArtist.isEmpty else {
            return nil
        }
        let type = ((item["type"] as? String) ?? "track").lowercased()
        guard isMusicItemType(type) else { return nil }
        let duration: Int? = Self.parseDurationSeconds(item["duration"])
            ?? (item["durationMs"] as? Int).map { $0 / 1_000 }
        let poster = item["artworkURL"] as? String
        return AddonTrack(
            installationKey: installation.key,
            type: type,
            id: id,
            title: resolvedTitle,
            poster: poster.flatMap(URL.init(string:)),
            detail: item["album"] as? String,
            artist: resolvedArtist,
            album: item["album"] as? String,
            durationSeconds: duration
        )
    }

    /// Albums returned by the same search call (Eclipse addons only).
    func searchAlbums(_ query: String, limit: Int = 8) async -> [AddonAlbum] {
        guard eclipseMode,
              installation.manifest.stremio?.offers("search") == true else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "q", value: term)]
        guard let url = components?.url,
              let data = await cachedFetch(url, key: "search|\(url.absoluteString)"),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let raw = root["albums"] as? [[String: Any]] else { return [] }
        var albums: [AddonAlbum] = []
        for album in raw.prefix(limit) {
            guard let id = album["id"] as? String,
                  let title = album["title"] as? String,
                  !title.isEmpty else { continue }
            albums.append(AddonAlbum(
                installationKey: installation.key,
                id: id,
                title: title,
                artist: album["artist"] as? String,
                trackCount: album["trackCount"] as? Int,
                year: album["year"] as? Int
            ))
        }
        return albums
    }

    /// Full track list for an album (Eclipse addons cap it at 20 tracks).
    func albumTracks(id: String) async throws -> [AddonTrack] {
        guard eclipseMode,
              let url = EclipseAddonURL.resource(
                baseURL: baseURL, resource: "album", id: id
              ) else {
            return []
        }
        guard let data = await cachedFetch(url, key: "album|\(url.absoluteString)"),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let raw = root["tracks"] as? [[String: Any]] else {
            throw MusicAddonClientError.noResults
        }
        return raw.compactMap { track in
            guard let trackId = track["id"] as? String,
                  let title = track["title"] as? String,
                  !title.isEmpty else { return nil }
            return AddonTrack(
                installationKey: installation.key,
                type: "track",
                id: trackId,
                title: title,
                poster: (track["artworkURL"] as? String).flatMap(URL.init(string:)),
                detail: track["album"] as? String,
                artist: track["artist"] as? String,
                album: track["album"] as? String,
                durationSeconds: Self.parseDurationSeconds(track["duration"]),
                isAtmos: (track["isAtmos"] as? Bool) ?? false,
                isHiRes: (track["isHiRes"] as? Bool) ?? false,
                isAtmosOnly: (track["isAtmosOnly"] as? Bool) ?? false
            )
        }
    }

    func resolveStream(
        type: String,
        id: String,
        preferAtmos: Bool = false,
        quality: AddonStreamQuality = .max,
        allowHiRes: Bool = false,
        requireLossless: Bool = false
    ) async throws -> AddonStream {
        if eclipseMode {
            return try await eclipseStream(id: id, preferAtmos: preferAtmos, quality: quality)
        }
        return try await stremioStream(
            type: type, id: id, preferAtmos: preferAtmos,
            quality: quality, allowHiRes: allowHiRes,
            requireLossless: requireLossless
        )
    }

    private func eclipseStream(
        id: String,
        preferAtmos: Bool,
        quality: AddonStreamQuality
    ) async throws -> AddonStream {
        // Addons that carry Dolby Atmos copies (NullBeat) switch between the
        // Atmos and the plain FLAC master with this flag.
        // Encode the track ID exactly once; using an already percent-escaped
        // ID with URL.appendingPathComponent double-encodes ':' into '%253A'.
        guard let url = EclipseAddonURL.resource(
            baseURL: baseURL,
            resource: "stream",
            id: id,
            queryItems: [
                URLQueryItem(name: "atmos", value: preferAtmos ? "true" : "false"),
                URLQueryItem(name: "quality", value: quality.rawValue)
            ]
        ) else {
            throw MusicAddonClientError.invalidURL
        }
        guard let data = await fetch(url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let raw = root["url"] as? String,
              let streamURL = URL(string: raw),
              let scheme = streamURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              streamURL.user == nil, streamURL.password == nil else {
            throw MusicAddonClientError.noStream
        }
        let format = ((root["format"] as? String) ?? (root["codec"] as? String) ?? "")
            .lowercased()
        let quality = ((root["quality"] as? String) ?? "").lowercased()
        let encrypted = (root["encrypted"] as? Bool) ?? false
        let bitDepth = root["bitDepth"] as? Int
        let sampleRate = root["sampleRate"] as? Int
        let hiRes = quality.contains("hires") || quality.contains("hi-res")
            || (bitDepth ?? 0) >= 24 || (sampleRate ?? 0) > 48_000
        let size = root["size"] as? Int
        let haystack = format + " " + quality
        if haystack.contains("atmos") || haystack.contains("eac3")
            || haystack.contains("e-ac-3") || haystack.contains("ec-3")
            || haystack.contains("dolby") {
            return AddonStream(
                kind: .url(streamURL),
                mimeType: "audio/mp4",
                bitrate: 768_000,
                qualityTier: "Atmos",
                isEncrypted: encrypted,
                sampleRateHz: sampleRate,
                bitDepth: bitDepth,
                sizeBytes: size
            )
        }
        if haystack.contains("flac") || haystack.contains("lossless") || haystack.contains("hires") || haystack.contains("hi-res") {
            return AddonStream(
                kind: .url(streamURL),
                mimeType: "audio/flac",
                bitrate: 0,
                qualityTier: "Lossless",
                isEncrypted: encrypted,
                sampleRateHz: sampleRate,
                bitDepth: bitDepth,
                isHiRes: hiRes,
                sizeBytes: size
            )
        }
        if haystack.contains("320") {
            return AddonStream(
                kind: .url(streamURL),
                mimeType: "audio/mp4",
                bitrate: 320_000,
                qualityTier: "High",
                isEncrypted: encrypted,
                sampleRateHz: sampleRate,
                bitDepth: bitDepth,
                sizeBytes: size
            )
        }
        return AddonStream(
            kind: .url(streamURL),
            mimeType: "audio/mpeg",
            bitrate: 0,
            qualityTier: "Standard",
            isEncrypted: encrypted,
            sampleRateHz: sampleRate,
            bitDepth: bitDepth,
            sizeBytes: size
        )
    }

    private func stremioStream(
        type: String,
        id: String,
        preferAtmos: Bool,
        quality: AddonStreamQuality,
        allowHiRes: Bool,
        requireLossless: Bool
    ) async throws -> AddonStream {
        guard isMusicItemType(type) else {
            throw MusicAddonClientError.noStream
        }
        let url = baseURL
            .appendingPathComponent("stream")
            .appendingPathComponent(type)
            .appendingPathComponent("\(id).json")
        guard let data = await fetch(url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else {
            throw MusicAddonClientError.noStream
        }
        let policy = AddonStreamQualityPolicy.stremio(
            requested: quality, preferAtmos: preferAtmos,
            allowHiRes: allowHiRes, requireLossless: requireLossless
        )
        var best: (AddonStream, Int)?
        for stream in streams {
            if let ytId = stream["ytId"] as? String, !ytId.isEmpty {
                let candidate = AddonStream(
                    kind: .youtube(ytId), mimeType: "audio/mp4",
                    bitrate: 0, qualityTier: "Standard",
                    isEncrypted: (stream["encrypted"] as? Bool) ?? false
                )
                if policy.accepts(candidate), best == nil { best = (candidate, 0) }
                continue
            }
            let raw = (stream["url"] as? String) ?? (stream["externalUrl"] as? String)
            guard let raw, let streamURL = URL(string: raw),
                  let scheme = streamURL.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }
            let hints = Self.describe(stream)
            let quality = Self.quality(from: hints, url: streamURL)
            let hintsObject = stream["behaviorHints"] as? [String: Any]
            let bitDepth = (stream["bitDepth"] as? Int) ?? (hintsObject?["bitDepth"] as? Int)
            let sampleRate = (stream["sampleRate"] as? Int)
                ?? (hintsObject?["sampleRate"] as? Int)
            let hiRes = hints.contains("hi-res") || hints.contains("hires")
                || hints.contains("24bit") || hints.contains("24-bit")
                || (bitDepth ?? 0) >= 24 || (sampleRate ?? 0) > 48_000
            let candidate = AddonStream(
                kind: .url(streamURL),
                mimeType: quality.mime,
                bitrate: quality.bitrate,
                qualityTier: quality.tier,
                isEncrypted: (stream["encrypted"] as? Bool) ?? false,
                sampleRateHz: sampleRate,
                bitDepth: bitDepth,
                isHiRes: hiRes,
                sizeBytes: hintsObject?["videoSize"] as? Int
            )
            let rank = policy.rank(candidate)
            guard rank >= 0, !candidate.isEncrypted else { continue }
            if best == nil || rank > best!.1 { best = (candidate, rank) }
        }
        guard let best else { throw MusicAddonClientError.noStream }
        return best.0
    }

    // MARK: - Helpers

    /// "Artist - Title" → (artist, title). Wrapper addons use this format.
    private static func splitArtistTitle(_ name: String) -> (artist: String, title: String)? {
        guard let separator = name.range(of: " - ") else { return nil }
        let artist = name[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let title = name[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !artist.isEmpty, !title.isEmpty else { return nil }
        return (artist, title)
    }

    /// Last mm:ss / h:mm:ss in a description, e.g. "FLAC · LOSSLESS · 25 MB · 4:04".
    private static func durationFromDescription(_ text: String?) -> Int? {
        guard let text, !text.isEmpty,
              let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{2})\b"#) else {
            return nil
        }
        let string = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: string.length))
        guard let last = matches.last, last.numberOfRanges == 3 else { return nil }
        let minutes = Int(string.substring(with: last.range(at: 1))) ?? 0
        let seconds = Int(string.substring(with: last.range(at: 2))) ?? 0
        return minutes * 60 + seconds
    }

    private func cachedFetch(_ url: URL, key: String) async -> Data? {
        if let cached = await AddonResponseCache.shared.data(for: key) { return cached }
        guard let data = await fetch(url) else { return nil }
        await AddonResponseCache.shared.store(data, for: key)
        return data
    }

    private func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private static func describe(_ stream: [String: Any]) -> String {
        let parts = [
            stream["name"] as? String,
            stream["description"] as? String,
            stream["title"] as? String
        ].compactMap { $0 }
        return parts.joined(separator: " ").lowercased()
    }

    private static func quality(from text: String, url: URL) -> (tier: String, mime: String, bitrate: Int) {
        let ext = url.pathExtension.lowercased()
        let haystack = (text + " " + url.absoluteString.lowercased())
        if haystack.contains("atmos") || haystack.contains("eac3")
            || haystack.contains("e-ac-3") || haystack.contains("ec-3")
            || haystack.contains("dolby") {
            return ("Atmos", "audio/mp4", 768_000)
        }
        if ext == "flac" || haystack.contains("flac") || haystack.contains("lossless") {
            return ("Lossless", "audio/flac", 0)
        }
        if haystack.contains("hi-res") || haystack.contains("hires") || haystack.contains("24bit") || haystack.contains("24-bit") {
            return ("Lossless", ext == "flac" ? "audio/flac" : "audio/mp4", 0)
        }
        let bitrate: Int
        if let match = haystack.range(of: #"(320|256|192)\s*kbps"#, options: .regularExpression) {
            let digits = haystack[match].prefix { $0.isNumber }
            bitrate = (Int(digits) ?? 0) * 1000
        } else {
            bitrate = haystack.contains("high") ? 256_000 : 0
        }
        let tier = (bitrate >= 160_000 || haystack.contains("high")) ? "High" : "Standard"
        switch ext {
        case "mp3": return (tier, "audio/mpeg", bitrate)
        case "aac": return (tier, "audio/aac", bitrate)
        case "m4a", "mp4": return (tier, "audio/mp4", bitrate)
        case "ogg", "opus": return (tier, "audio/ogg", bitrate)
        default: return (tier, "audio/mpeg", bitrate)
        }
    }
}
