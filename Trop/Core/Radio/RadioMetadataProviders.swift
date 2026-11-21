import Foundation

/// Identity captured before a network request. Late metadata/artwork from
/// an old station must never overwrite the user's latest playback selection.
struct RadioMetadataIdentity: Equatable, Sendable {
    let generation: Int
    let stationID: String?
    let streamURL: String?

    func matches(generation: Int, stationID: String?, streamURL: String?) -> Bool {
        self.generation == generation
            && self.stationID == stationID
            && self.streamURL == streamURL
    }
}

struct RadioNowPlaying: Equatable, Sendable {
    let artist: String
    let title: String
    let album: String?
    let coverURL: URL?
}

/// Keep radio metadata current while iOS permits background audio execution.
/// This never starts playback or asks iOS for extra background runtime.
enum RadioAppExecutionState: Sendable {
    case active
    case background
    case inactive
}

struct RadioLockScreenFields: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
}

enum RadioBackgroundMetadataPolicy {
    static func shouldRefresh(
        isRadio: Bool,
        isPlaying: Bool,
        appState: RadioAppExecutionState
    ) -> Bool {
        guard isRadio, isPlaying else { return false }
        switch appState {
        case .active, .background:
            return true
        case .inactive:
            return false
        }
    }

    /// The previous mpv/Apolo stream can still expose an ICY title while a
    /// replacement station is loading. Never label that title as the new station.
    static func mayReadICY(
        isRadio: Bool,
        selectedStationID: String?,
        activeStationID: String?,
        pendingStationID: String?
    ) -> Bool {
        isRadio && selectedStationID != nil
            && selectedStationID == activeStationID && pendingStationID == nil
    }

    /// Prefer the title embedded in the current live audio over an API response
    /// for a different track (which may be ahead of or behind the live stream).
    /// Stations without a usable ICY title continue to use their broadcaster API.
    static func acceptsProvider(
        _ provider: RadioNowPlaying,
        currentICYRaw: String?,
        stationName: String
    ) -> Bool {
        guard let currentICYRaw,
              let icy = ICYTitleParser.parse(currentICYRaw, stationName: stationName) else {
            return true
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard icy.title.compare(provider.title, options: options) == .orderedSame else {
            return false
        }
        return icy.artist.isEmpty || provider.artist.isEmpty
            || icy.artist.compare(provider.artist, options: options) == .orderedSame
    }

    /// Failed catalogue image lookups must not restart on every 1-second ICY
    /// poll. A new song or a newly supplied broadcaster URL bypasses cooldown.
    static func mayAttemptArtwork(
        key: String,
        failedKey: String?,
        retryAfter: Date?,
        now: Date
    ) -> Bool {
        guard key == failedKey, let retryAfter else { return true }
        return now >= retryAfter
    }

    /// The station icon can finish downloading after a current-song cover.
    /// Once song artwork is published, a late station icon must not replace it.
    static func mayPublishStationArtwork(
        isRadio: Bool,
        liveSongHasArtwork: Bool
    ) -> Bool {
        !isRadio || !liveSongHasArtwork
    }

    /// Surface the detected song without losing the station identity.
    /// A station-only fallback is used when the broadcast has no valid song.
    static func lockScreenFields(
        stationTitle: String,
        stationArtist: String,
        songTitle: String?,
        songArtist: String?
    ) -> RadioLockScreenFields {
        let station = stationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let stationCredit = stationArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        let song = songTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard song.count >= 2,
              song.caseInsensitiveCompare(station) != .orderedSame else {
            return RadioLockScreenFields(title: station, artist: stationCredit, album: "")
        }
        let credit = songArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return RadioLockScreenFields(
            title: song,
            artist: credit.isEmpty ? station : credit,
            album: station
        )
    }
}

protocol RadioMetadataProvider: Sendable {
    func metadata(for streamURL: URL, stationName: String) async -> RadioNowPlaying?
}

/// Per-broadcaster now-playing APIs for stations that do not expose ICY.
/// Radio Paradise is the first one; add others here as they are validated.
enum RadioMetadataProviders {
    static func provider(for streamURL: URL, stationName: String) -> (any RadioMetadataProvider)? {
        if RadioParadiseProvider.matches(streamURL: streamURL, stationName: stationName) {
            return RadioParadiseProvider()
        }
        if TritonProvider.matches(streamURL: streamURL) {
            return TritonProvider()
        }
        if BBCRadioProvider.matches(streamURL: streamURL, stationName: stationName) {
            return BBCRadioProvider()
        }
        if RadioFranceProvider.matches(streamURL: streamURL, stationName: stationName) {
            return RadioFranceProvider()
        }
        return nil
    }
}

/// Radio Paradise publishes JSON per channel. Their AAC/MP3 streams carry no
/// ICY; the FLAC+meta ones do, and this API also supplies the cover/album.
struct RadioParadiseProvider: RadioMetadataProvider {
    static func matches(streamURL: URL, stationName: String) -> Bool {
        let host = (streamURL.host ?? "").lowercased()
        let name = stationName.lowercased()
        return host.contains("radioparadise.com") || name.contains("radio paradise")
    }

    func metadata(for streamURL: URL, stationName: String) async -> RadioNowPlaying? {
        var components = URLComponents(string: "https://api.radioparadise.com/api/now_playing")
        components?.queryItems = [
            URLQueryItem(name: "chan", value: "\(Self.channel(streamURL: streamURL, stationName: stationName))"),
            URLQueryItem(name: "info", value: "true")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let artist = payload.artist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard title.count >= 2, title.lowercased() != "null" else { return nil }
        let album = payload.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RadioNowPlaying(
            artist: artist,
            title: title,
            album: (album?.isEmpty == false) ? album : nil,
            coverURL: payload.cover.flatMap(URL.init(string:))
        )
    }

    /// Channel mapping from the stream filename or the Radio Browser name.
    private static func channel(streamURL: URL, stationName: String) -> Int {
        let haystack = (streamURL.absoluteString + " " + stationName).lowercased()
        if haystack.contains("2050") { return 5 }
        if haystack.contains("mellow") { return 1 }
        if haystack.contains("rock") { return 2 }
        if haystack.contains("global") { return 3 }
        if haystack.contains("beyond") { return 4 }
        return 0
    }

    private struct Payload: Decodable {
        let artist: String?
        let title: String?
        let album: String?
        let cover: String?
    }
}


/// StreamTheWorld (Triton) mounts publish JSON/XML now-playing. The public
/// stream usually redirects to a `*_SC` mount whose ICY blocks are empty, but
/// Triton answers for the base mount (e.g. CARACOL_RADIOAAC).
struct TritonProvider: RadioMetadataProvider {
    static func matches(streamURL: URL) -> Bool {
        let host = (streamURL.host ?? "").lowercased()
        return host.contains("streamtheworld.com")
    }

    func metadata(for streamURL: URL, stationName: String) async -> RadioNowPlaying? {
        for mount in Self.mounts(for: streamURL) {
            var components = URLComponents(string: "https://np.tritondigital.com/public/nowplaying")
            components?.queryItems = [
                URLQueryItem(name: "mountName", value: mount),
                URLQueryItem(name: "numberToFetch", value: "1"),
                URLQueryItem(name: "eventType", value: "track")
            ]
            guard let url = components?.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let xml = String(data: data, encoding: .utf8) else { continue }
            let fields = Self.properties(from: xml)
            let title = fields["cue_title"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard title.count >= 2, title.caseInsensitiveCompare(stationName) != .orderedSame else { continue }
            let artist = (fields["track_artist_name"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let album = (fields["track_album_name"] ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RadioNowPlaying(
                artist: artist,
                title: title,
                album: album.isEmpty ? nil : album,
                coverURL: fields["track_cover_url"].flatMap(URL.init(string:))
            )
        }
        return nil
    }

    /// Public stream URLs point at `.../MOUNT_SC` or `.../MOUNT.aac`; Triton
    /// needs the base mount.
    static func mounts(for streamURL: URL) -> [String] {
        var name = (streamURL.lastPathComponent.removingPercentEncoding ?? streamURL.lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".aac", ".mp3", ".m3u8", ".m3u", ".pls"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        var candidates: [String] = [name]
        if name.hasSuffix("_SC") { candidates.append(String(name.dropLast(3))) }
        for candidate in candidates {
            if candidate.hasSuffix("AAC") { candidates.append(String(candidate.dropLast(3))) }
            if candidate.hasSuffix("MP3") { candidates.append(String(candidate.dropLast(3))) }
        }
        var seen = Set<String>()
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func properties(from xml: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<property name="([^"]+)"><!\[CDATA\[(.*?)\]\]></property>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [:] }
        let string = xml as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: string.length)) {
            guard match.numberOfRanges == 3 else { continue }
            result[string.substring(with: match.range(at: 1))] =
                string.substring(with: match.range(at: 2))
        }
        return result
    }
}


/// BBC Radio publishes the current music segment through the public RMS API.
/// Stream URLs use Akamai hosts, so the service id comes from the path/name.
struct BBCRadioProvider: RadioMetadataProvider {
    static func matches(streamURL: URL, stationName: String) -> Bool {
        let haystack = (streamURL.absoluteString + " " + stationName).lowercased()
        return haystack.contains("bbc") && (haystack.contains("bbc_") || haystack.contains("bbc radio"))
    }

    func metadata(for streamURL: URL, stationName: String) async -> RadioNowPlaying? {
        guard let service = Self.serviceID(streamURL: streamURL, stationName: stationName) else { return nil }
        var components = URLComponents(string: "https://rms.api.bbc.co.uk/v2/services/\(service)/segments/latest")
        components?.queryItems = []
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let segment = payload.data.first { $0.segmentType == "music" && ($0.offset?.nowPlaying ?? false) }
            ?? payload.data.first { $0.segmentType == "music" }
        guard let segment,
              let artist = segment.titles?.primary?.trimmingCharacters(in: .whitespacesAndNewlines),
              let title = segment.titles?.secondary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artist.isEmpty, title.count >= 2 else { return nil }
        let cover: URL?
        if let rawCover = segment.imageURL?.replacingOccurrences(of: "{recipe}", with: "400x400") {
            cover = URL(string: rawCover)
        } else {
            cover = nil
        }
        return RadioNowPlaying(artist: artist, title: title, album: nil, coverURL: cover)
    }

    static func serviceID(streamURL: URL, stationName: String) -> String? {
        if let range = streamURL.absoluteString.range(of: #"bbc_[a-z0-9_]+"#, options: [.regularExpression, .caseInsensitive]) {
            return String(streamURL.absoluteString[range]).lowercased()
        }
        let name = stationName.lowercased()
        let map: [(String, String)] = [
            ("1xtra", "bbc_1xtra"),
            ("radio 1", "bbc_radio_one"),
            ("radio 2", "bbc_radio_two"),
            ("radio 3", "bbc_radio_three"),
            ("radio 4 extra", "bbc_radio_four_extra"),
            ("radio 4", "bbc_radio_fourfm"),
            ("radio 5 sports extra", "bbc_radio_five_live_sports_extra"),
            ("radio 5", "bbc_radio_five_live"),
            ("6 music", "bbc_6music"),
            ("asian network", "bbc_asian_network"),
            ("world service", "bbc_world_service"),
            ("radio scotland", "bbc_radio_scotland_fm"),
            ("radio wales", "bbc_radio_wales_fm"),
            ("radio ulster", "bbc_radio_ulster"),
            ("radio cymru", "bbc_radio_cymru")
        ]
        return map.first { name.contains($0.0) }?.1
    }

    private struct Payload: Decodable {
        let data: [Segment]
    }

    private struct Segment: Decodable {
        let segmentType: String?
        let titles: Titles?
        let imageURL: String?
        let offset: Offset?

        enum CodingKeys: String, CodingKey {
            case segmentType = "segment_type"
            case titles
            case imageURL = "image_url"
            case offset
        }
    }

    private struct Titles: Decodable {
        let primary: String?
        let secondary: String?
    }

    private struct Offset: Decodable {
        let nowPlaying: Bool?
        enum CodingKeys: String, CodingKey { case nowPlaying = "now_playing" }
    }
}

/// Radio France exposes live metadata per station id (Inter 1, Info 2,
/// Musique 4, Culture 5, Mouv 6, FIP 7).
struct RadioFranceProvider: RadioMetadataProvider {
    static func matches(streamURL: URL, stationName: String) -> Bool {
        guard stationID(streamURL: streamURL, stationName: stationName) != nil else {
            return false
        }
        let host = (streamURL.host ?? "").lowercased()
        let name = stationName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // FIP's legacy stream URLs often use direct.fipradio.fr, not
        // radiofrance.fr. Exact station names are useful for CDN hosts too.
        return host == "radiofrance.fr" || host.hasSuffix(".radiofrance.fr")
            || host == "fipradio.fr" || host.hasSuffix(".fipradio.fr")
            || name == "fip" || name.hasPrefix("fip (")
            || name.hasPrefix("france inter")
            || name.hasPrefix("france info")
            || name.hasPrefix("france musique")
            || name.hasPrefix("france culture")
            || name.hasPrefix("mouv")
    }

    func metadata(for streamURL: URL, stationName: String) async -> RadioNowPlaying? {
        guard let stationID = Self.stationID(streamURL: streamURL, stationName: stationName),
              let endpoint = URL(string: "https://api.radiofrance.fr/livemeta/pull/\(stationID)")
        else { return nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Self.nowPlaying(from: root)
    }

    /// Radio France's payload marks the currently selected step through
    /// levels[0].items[levels[0].position]. Picking arbitrary steps by date
    /// alone can select an unrelated item or show nothing.
    static func nowPlaying(
        from root: [String: Any],
        at date: Date = Date()
    ) -> RadioNowPlaying? {
        guard let steps = root["steps"] as? [String: Any] else { return nil }
        let current: [String: Any]?
        if let levels = root["levels"] as? [[String: Any]], let level = levels.first {
            guard let items = level["items"] as? [Any],
                  let position = (level["position"] as? NSNumber)?.intValue,
                  items.indices.contains(position)
            else { return nil }
            let uid: String
            if let string = items[position] as? String {
                uid = string
            } else if let number = items[position] as? NSNumber {
                uid = number.stringValue
            } else {
                return nil
            }
            current = steps[uid] as? [String: Any]
        } else {
            // Older metadata responses without a levels cursor: use only
            // genuinely time-bounded steps, never arbitrary undated items.
            let timestamp = date.timeIntervalSince1970
            let dated = steps.values.compactMap { value -> [String: Any]? in
                guard let step = value as? [String: Any],
                      let rawStart = (step["start"] as? NSNumber)?.doubleValue,
                      let rawEnd = (step["end"] as? NSNumber)?.doubleValue
                else { return nil }
                let start = rawStart > 100_000_000_000 ? rawStart / 1_000 : rawStart
                let end = rawEnd > 100_000_000_000 ? rawEnd / 1_000 : rawEnd
                return start <= timestamp && timestamp <= end ? step : nil
            }
            current = dated.max {
                (($0["start"] as? NSNumber)?.doubleValue ?? 0)
                    < (($1["start"] as? NSNumber)?.doubleValue ?? 0)
            }
        }
        guard let step = current else { return nil }
        let title = (step["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authors = step["authors"]
        let artist: String
        if let names = authors as? [String] {
            artist = names.joined(separator: ", ")
        } else {
            artist = authors as? String ?? ""
        }
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, !trimmedArtist.isEmpty else { return nil }
        let album = (step["titreAlbum"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cover = (step["visual"] as? String).flatMap(URL.init(string:))
        return RadioNowPlaying(
            artist: trimmedArtist,
            title: title,
            album: (album?.isEmpty == false) ? album : nil,
            coverURL: cover
        )
    }

    static func stationID(streamURL: URL, stationName: String) -> Int? {
        let path = streamURL.path.lowercased()
        let name = stationName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filename = streamURL.lastPathComponent.lowercased()
        // Do not show the main FIP channel's title on a FIP Jazz/Rock/
        // Groove/etc. stream. The specialty stations have different IDs.
        if name == "fip" || name.hasPrefix("fip (")
            || filename == "fip" || filename.hasPrefix("fip-")
            || filename.hasPrefix("fip_") || filename.hasPrefix("fip.") {
            return 7
        }
        let haystack = path + " " + name
        if haystack.contains("franceinter") || haystack.contains("france inter") { return 1 }
        if haystack.contains("franceinfo") || haystack.contains("france info") { return 2 }
        if haystack.contains("francemusique") || haystack.contains("france musique") { return 4 }
        if haystack.contains("franceculture") || haystack.contains("france culture") { return 5 }
        if haystack.contains("mouv") { return 6 }
        return nil
    }
}
