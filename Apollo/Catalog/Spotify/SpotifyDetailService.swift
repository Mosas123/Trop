import Foundation

/// Fetches Spotify detail pages and projects them into the app's existing
/// `AlbumDetailInfo` / `PlaylistDetailInfo` / `ArtistDetailInfo` models, so
/// the current screens render without changes.
@MainActor
final class SpotifyDetailService {
    static let shared = SpotifyDetailService()

    private let client: SpotifyPathfinderClient

    init(client: SpotifyPathfinderClient = SpotifyPathfinderClient()) {
        self.client = client
    }

    // MARK: - Album

    func albumDetail(id: String) async throws -> AlbumDetailInfo {
        let data = try await client.album(id: id)
        var detail = try Self.parseAlbum(data, requestedID: id)

        // Album rows can omit per-track credits. Never let the player show an
        // empty artist: use the album artist for every track that lacks one.
        if detail.artists.isEmpty,
           let fallback = detail.songs.first(where: { !$0.artists.isEmpty })?.artists {
            detail.artists = fallback
        }
        if !detail.artists.isEmpty {
            for index in detail.songs.indices where detail.songs[index].artists.isEmpty {
                detail.songs[index].artists = detail.artists
            }
        }
        if ExplicitContentPolicy.hidesExplicit {
            detail.songs.removeAll { $0.isExplicit }
        }

        // Apple/iTunes fills missing fields and upgrades a low-resolution
        // Spotify cover without changing artists or identifiers.
        if detail.thumbnailUrl == nil
            || detail.year == nil
            || ArtworkQuality.pixelWidth(of: detail.thumbnailUrl.flatMap(URL.init(string:))) < 1000 {
            let artists = detail.artists.map {
                CatalogArtist(
                    id: $0.id ?? $0.name,
                    name: $0.name,
                    artworkURL: nil
                )
            }
            let album = CatalogAlbum(
                id: id,
                source: .spotify,
                title: detail.title,
                artists: artists,
                releaseDate: detail.year.map { String($0) },
                artworkURL: detail.thumbnailUrl.flatMap(URL.init(string:)),
                externalURL: URL(string: "https://open.spotify.com/album/\(id)")
            )
            let enrichment = await CatalogEnricher().enrich(album)
            if let artwork = enrichment.artworkURL {
                let current = detail.thumbnailUrl.flatMap(URL.init(string:))
                if let best = ArtworkQuality.better(current, than: artwork) {
                    detail.thumbnailUrl = best.absoluteString
                }
            }
            if detail.year == nil, let date = enrichment.releaseDate, let year = Int(date.prefix(4)) {
                detail.year = year
            }
            if let genre = enrichment.genre, !genre.isEmpty {
                detail.genre = genre
            }
        }

        return detail
    }

    private static func parseAlbum(_ data: Data, requestedID: String) throws -> AlbumDetailInfo {
        guard let root = try Self.object(from: data),
              let payload = root["data"] as? [String: Any],
              let album = payload["albumUnion"] as? [String: Any] else {
            throw CatalogError.notFound
        }

        let title = (album["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Album"
        let albumID = Self.identifier(album) ?? requestedID
        let albumArtists = Self.artists(from: album["artists"])
        let cover = Self.coverURLString(album["coverArt"])
        let year = Self.year(from: album["date"])

        let tracksNode = album["tracksV2"] ?? album["tracks"]
        let rawTracks = Self.items(of: tracksNode)
        let songs = rawTracks.compactMap { wrapper -> SongItem? in
            let track = (wrapper["track"] as? [String: Any]) ?? wrapper
            return Self.song(
                from: track,
                fallbackAlbumTitle: title,
                fallbackAlbumID: albumID,
                fallbackCover: cover,
                fallbackArtists: albumArtists,
                fallbackYear: year
            )
        }
        let totalCount = max(Self.intValue((tracksNode as? [String: Any])?["totalCount"]), songs.count)

        return AlbumDetailInfo(
            title: title,
            artists: albumArtists,
            year: year,
            songCount: totalCount,
            duration: songs.reduce(0) { $0 + $1.duration },
            thumbnailUrl: cover,
            playlistId: nil,
            browseId: SpotifyCatalogID.album(albumID),
            songs: songs,
            descriptionText: Self.copyrightText(album["copyright"]),
            relatedAlbums: [],
            videos: [],
            featuredPlaylists: []
        )
    }

    // MARK: - Playlist

    func playlistDetail(id: String) async throws -> PlaylistDetailInfo {
        var offset = 0
        let pageSize = 100
        var allItems: [[String: Any]] = []
        var playlist: [String: Any]?
        var totalCount = 0

        while offset < 2000 {
            let data = try await client.playlist(id: id, offset: offset, limit: pageSize)
            guard let root = try Self.object(from: data),
                  let payload = root["data"] as? [String: Any],
                  let node = payload["playlistV2"] as? [String: Any] else {
                throw CatalogError.notFound
            }
            if playlist == nil {
                playlist = node
                totalCount = Self.intValue((node["content"] as? [String: Any])?["totalCount"])
            }
            let pageItems = Self.items(of: node["content"])
            allItems.append(contentsOf: pageItems)
            if pageItems.isEmpty || allItems.count >= totalCount || pageItems.count < pageSize {
                break
            }
            offset += pageSize
        }

        guard let playlist else { throw CatalogError.notFound }

        let title = (playlist["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Playlist"
        let cover = Self.coverURLString(playlist["images"]) ?? Self.coverURLString(playlist["visualIdentity"])
        let owner = ((playlist["ownerV2"] as? [String: Any])?["data"] as? [String: Any])
        let ownerName = (owner?["name"] as? String)
            ?? (owner?["displayName"] as? String)
            ?? (owner?["username"] as? String)
        let ownerAvatar = Self.coverURLString(owner?["avatar"])

        let songs = allItems.compactMap { wrapper -> SongItem? in
            let track = ((wrapper["itemV2"] as? [String: Any])?["data"] as? [String: Any])
                ?? ((wrapper["itemV3"] as? [String: Any])?["data"] as? [String: Any])
            guard let track else { return nil }
            return Self.song(
                from: track,
                fallbackAlbumTitle: nil,
                fallbackAlbumID: nil,
                fallbackCover: cover,
                fallbackArtists: [],
                fallbackYear: nil
            )
        }

        let visibleSongs = ExplicitContentPolicy.hidesExplicit
            ? songs.filter { !$0.isExplicit }
            : songs
        return PlaylistDetailInfo(
            title: title,
            authorName: ownerName,
            authorBrowseId: nil,
            authorAvatarUrl: ownerAvatar,
            descriptionText: (playlist["description"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            songCount: max(totalCount, visibleSongs.count),
            duration: visibleSongs.reduce(0) { $0 + $1.duration },
            thumbnailUrl: cover,
            playlistId: SpotifyCatalogID.playlist(id),
            songs: visibleSongs
        )
    }

    // MARK: - Artist

    func artistDetail(id: String) async throws -> ArtistDetailInfo {
        let data = try await client.artistOverview(id: id)
        guard let root = try Self.object(from: data),
              let payload = root["data"] as? [String: Any],
              let artist = payload["artistUnion"] as? [String: Any] else {
            throw CatalogError.notFound
        }

        let profile = artist["profile"] as? [String: Any]
        let name = (profile?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Artist"
        let stats = artist["stats"] as? [String: Any]
        let monthly = Self.intValue(stats?["monthlyListeners"])
        let followers = Self.intValue(stats?["followers"])
        let avatar = Self.coverURLString((artist["visuals"] as? [String: Any])?["avatarImage"])
            ?? Self.coverURLString(artist["visualIdentity"])
        let header = Self.coverURLString(artist["headerImage"])

        let topTracks = Self.items(of: (artist["discography"] as? [String: Any])?["topTracks"])
        let songs = topTracks.compactMap { wrapper -> SongItem? in
            let track = (wrapper["track"] as? [String: Any]) ?? wrapper
            return Self.song(
                from: track,
                fallbackAlbumTitle: nil,
                fallbackAlbumID: nil,
                fallbackCover: nil,
                fallbackArtists: [YTArtist(name: name, id: SpotifyCatalogID.artist(id))],
                fallbackYear: nil
            )
        }

        var albums: [AlbumItem] = []
        var singles: [AlbumItem] = []
        if let discographyData = try? await client.artistDiscography(id: id),
           let discographyRoot = try? Self.object(from: discographyData),
           let discographyPayload = discographyRoot["data"] as? [String: Any],
           let discographyArtist = discographyPayload["artistUnion"] as? [String: Any] {
            let releases = Self.items(of: ((discographyArtist["discography"] as? [String: Any])?["all"]))
            for wrapper in releases {
                let releaseItems = Self.items(of: wrapper["releases"])
                guard let release = releaseItems.first,
                      let album = Self.albumItem(from: release, artistName: name, artistID: id) else { continue }
                let type = (release["type"] as? String)?.uppercased() ?? ""
                if type == "ALBUM" || type == "COMPILATION" {
                    albums.append(album)
                } else {
                    singles.append(album)
                }
            }
        }

        let related = Self.items(of: ((artist["relatedContent"] as? [String: Any])?["relatedArtists"]))
            .compactMap { node -> ArtistItem? in
                guard let relatedID = Self.identifier(node),
                      let relatedProfile = node["profile"] as? [String: Any],
                      let relatedName = relatedProfile["name"] as? String else { return nil }
                let image = Self.coverURLString((node["visuals"] as? [String: Any])?["avatarImage"])
                    ?? Self.coverURLString(node["visualIdentity"])
                return ArtistItem(
                    browseId: SpotifyCatalogID.artist(relatedID),
                    name: relatedName,
                    thumbnailUrl: image,
                    isSubscribed: false
                )
            }

        let bio = ((profile?["biography"] as? [String: Any])?["text"] as? String)
            .map(Self.stripHTML)
            .flatMap { $0.isEmpty ? nil : $0 }
        let subtitle = monthly > 0
            ? "\(Self.compactCount(monthly)) monthly listeners"
            : (followers > 0 ? "\(Self.compactCount(followers)) followers" : nil)

        let visibleSongs = ExplicitContentPolicy.hidesExplicit
            ? songs.filter { !$0.isExplicit }
            : songs
        return ArtistDetailInfo(
            name: name,
            thumbnailUrl: avatar,
            subscriberCountText: subtitle,
            descriptionText: bio,
            isSubscribed: false,
            browseId: SpotifyCatalogID.artist(id),
            songs: visibleSongs,
            albums: albums,
            singles: singles,
            videos: [],
            playlists: [],
            relatedArtists: related,
            heroImageURL: header,
            heroImageResolved: true,
            subscriptionChannelId: nil
        )
    }

    // MARK: - Podcast

    func podcastDetail(id: String) async throws -> PodcastDetailInfo {
        let showData = try await client.show(id: id)
        guard let showRoot = try Self.object(from: showData),
              let showPayload = showRoot["data"] as? [String: Any],
              let show = showPayload["podcastUnionV2"] as? [String: Any] else {
            throw CatalogError.notFound
        }

        let title = (show["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Podcast"
        let author = ((show["publisher"] as? [String: Any])?["name"] as? String)
        let description = (show["htmlDescriptionPlain"] as? String)
            ?? (show["description"] as? String).map(Self.stripHTML)
        let cover = Self.coverURLString(show["coverArt"])
            ?? Self.coverURLString((show["visualIdentity"] as? [String: Any])?["squareCoverImage"])

        var episodes: [EpisodeItem] = []
        var offset = 0
        let pageSize = 100
        while offset < 2000 {
            let data = try await client.podcastEpisodes(id: id, offset: offset, limit: pageSize)
            guard let root = try Self.object(from: data),
                  let payload = root["data"] as? [String: Any],
                  let podcast = payload["podcastUnionV2"] as? [String: Any] else { break }
            let page = Self.items(of: podcast["episodesV2"])
            if page.isEmpty { break }
            for wrapper in page {
                guard let entity = wrapper["entity"] as? [String: Any],
                      let episode = entity["data"] as? [String: Any],
                      let episodeID = Self.identifier(episode) else { continue }
                let episodeTitle = (episode["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Episode"
                let duration = Self.intValue((episode["duration"] as? [String: Any])?["totalMilliseconds"]) / 1000
                episodes.append(
                    EpisodeItem(
                        videoId: SpotifyCatalogID.episode(episodeID),
                        title: episodeTitle,
                        artists: [YTArtist(name: title)],
                        duration: duration,
                        thumbnailUrl: cover,
                        publishDate: (episode["releaseDate"] as? [String: Any])?["isoString"] as? String,
                        descriptionText: episode["description"] as? String,
                        viewsText: nil
                    )
                )
            }
            if page.count < pageSize { break }
            offset += pageSize
        }

        return PodcastDetailInfo(
            title: title,
            author: author,
            descriptionText: description,
            thumbnailUrl: cover,
            browseId: SpotifyCatalogID.podcast(id),
            isSubscribed: false,
            episodes: episodes
        )
    }

    // MARK: - Audiobooks

    func audiobookDetail(id: String) async throws -> AlbumDetailInfo {
        let showData = try await client.show(id: id)
        guard let showRoot = try Self.object(from: showData),
              let showPayload = showRoot["data"] as? [String: Any],
              let show = showPayload["podcastUnionV2"] as? [String: Any] else {
            throw CatalogError.notFound
        }

        let title = (show["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown Audiobook"
        let authors = Self.authors(from: show["authorsV2"])
        let artistList = authors.isEmpty
            ? [YTArtist(name: ((show["publisher"] as? [String: Any])?["name"] as? String) ?? "Unknown Author")]
            : authors.map { YTArtist(name: $0.name, id: SpotifyCatalogID.artist($0.id)) }
        let cover = Self.coverURLString(show["coverArt"])
            ?? Self.coverURLString((show["visualIdentity"] as? [String: Any])?["squareCoverImage"])
        let year = Self.year(from: show["publishDate"])

        var songs: [SongItem] = []
        var offset = 0
        let pageSize = 100
        while offset < 2000 {
            let data = try await client.bookChapters(id: id, offset: offset, limit: pageSize)
            guard let root = try Self.object(from: data),
                  let payload = root["data"] as? [String: Any],
                  let book = payload["podcastUnionV2"] as? [String: Any] else { break }
            let page = Self.items(of: book["chaptersV2"])
            if page.isEmpty { break }
            for wrapper in page {
                guard let entity = wrapper["entity"] as? [String: Any],
                      let chapter = entity["data"] as? [String: Any],
                      let chapterID = Self.identifier(chapter) else { continue }
                let chapterTitle = (chapter["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter"
                let duration = Self.intValue((chapter["duration"] as? [String: Any])?["totalMilliseconds"]) / 1000
                songs.append(
                    SongItem(
                        videoId: SpotifyCatalogID.chapter(chapterID),
                        title: chapterTitle,
                        artists: artistList,
                        album: title,
                        albumId: SpotifyCatalogID.audiobook(id),
                        duration: duration,
                        thumbnailUrl: Self.coverURLString(chapter["coverArt"]) ?? cover,
                        isExplicit: false,
                        playlistId: nil,
                        viewCount: nil,
                        year: year,
                        isVideo: false,
                        musicVideoType: nil,
                        recordingPreference: .albumAudio,
                        contentKind: .music
                    )
                )
            }
            if page.count < pageSize { break }
            offset += pageSize
        }

        return AlbumDetailInfo(
            title: title,
            artists: artistList,
            year: year,
            songCount: songs.count,
            duration: songs.reduce(0) { $0 + $1.duration },
            thumbnailUrl: cover,
            playlistId: nil,
            browseId: SpotifyCatalogID.audiobook(id),
            songs: songs,
            descriptionText: (show["htmlDescriptionPlain"] as? String)
                ?? (show["description"] as? String).map(Self.stripHTML),
            relatedAlbums: [],
            videos: [],
            featuredPlaylists: []
        )
    }

    private static func authors(from node: Any?) -> [CatalogArtist] {
        guard let dict = node as? [String: Any],
              let entries = dict["items"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let name = (entry["name"] as? String)
                ?? ((entry["profile"] as? [String: Any])?["name"] as? String)
            guard let name, !name.isEmpty else { return nil }
            return CatalogArtist(id: Self.identifier(entry) ?? name, name: name, artworkURL: nil)
        }
    }

    // MARK: - Song / release mapping

    private static func song(
        from track: [String: Any],
        fallbackAlbumTitle: String?,
        fallbackAlbumID: String?,
        fallbackCover: String?,
        fallbackArtists: [YTArtist],
        fallbackYear: Int?
    ) -> SongItem? {
        guard let trackID = Self.identifier(track) else { return nil }
        let title = (track["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown"
        let albumNode = track["albumOfTrack"] as? [String: Any]
        let trackArtists = Self.artists(from: track["artists"])
        let durationNode = track["duration"] ?? track["trackDuration"]
        let durationMS = Self.intValue((durationNode as? [String: Any])?["totalMilliseconds"])
        let cover = Self.coverURLString(albumNode?["coverArt"]) ?? fallbackCover
        let albumTitle = (albumNode?["name"] as? String) ?? fallbackAlbumTitle
        let albumID = albumNode.flatMap(identifier) ?? fallbackAlbumID
        let explicit = (track["contentRating"] as? [String: Any])?["label"] as? String == "EXPLICIT"

        return SongItem(
            videoId: SpotifyCatalogID.track(trackID),
            title: title,
            artists: trackArtists.isEmpty ? fallbackArtists : trackArtists,
            album: albumTitle,
            albumId: albumID.map(SpotifyCatalogID.album),
            duration: max(0, durationMS / 1000),
            thumbnailUrl: cover,
            isExplicit: explicit,
            playlistId: nil,
            viewCount: nil,
            year: Self.year(from: albumNode?["date"]) ?? fallbackYear,
            isVideo: false,
            musicVideoType: nil,
            recordingPreference: .albumAudio,
            contentKind: .music,
            catalogID: SpotifyCatalogID.track(trackID)
        )
    }

    private static func albumItem(from release: [String: Any], artistName: String, artistID: String) -> AlbumItem? {
        guard let releaseID = Self.identifier(release),
              let title = release["name"] as? String,
              !title.isEmpty else { return nil }
        return AlbumItem(
            browseId: SpotifyCatalogID.album(releaseID),
            title: title,
            artists: [YTArtist(name: artistName, id: SpotifyCatalogID.artist(artistID))],
            year: Self.year(from: release["date"]),
            thumbnailUrl: Self.coverURLString(release["coverArt"]),
            playlistId: nil,
            isExplicit: false
        )
    }

    // MARK: - JSON helpers

    private static func object(from data: Data) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func items(of node: Any?) -> [[String: Any]] {
        guard let dict = node as? [String: Any] else { return [] }
        return (dict["items"] as? [[String: Any]]) ?? []
    }

    private static func identifier(_ node: [String: Any]) -> String? {
        if let id = node["id"] as? String, !id.isEmpty { return id }
        if let uri = node["uri"] as? String, let last = uri.split(separator: ":").last {
            return String(last)
        }
        return nil
    }

    private static func artists(from node: Any?) -> [YTArtist] {
        let entries: [[String: Any]]
        if let dict = node as? [String: Any] {
            entries = dict["items"] as? [[String: Any]] ?? []
        } else {
            entries = node as? [[String: Any]] ?? []
        }
        guard !entries.isEmpty else { return [] }
        return entries.compactMap { entry in
            let profile = entry["profile"] as? [String: Any]
            guard let name = (profile?["name"] as? String) ?? (entry["name"] as? String),
                  !name.isEmpty else { return nil }
            return YTArtist(name: name, id: Self.identifier(entry).map(SpotifyCatalogID.artist))
        }
    }

    private static func coverURLString(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        var sources = dict["sources"] as? [[String: Any]] ?? []
        if sources.isEmpty,
           let data = dict["data"] as? [String: Any],
           let nested = data["sources"] as? [[String: Any]] {
            sources = nested
        }
        if sources.isEmpty,
           let image = dict["image"] as? [String: Any],
           let data = image["data"] as? [String: Any],
           let nested = data["sources"] as? [[String: Any]] {
            sources = nested
        }
        let candidates = sources.compactMap { source -> (Int, String)? in
            guard let raw = source["url"] as? String, !raw.isEmpty else { return nil }
            return (max(Self.intValue(source["width"]), Self.intValue(source["maxWidth"])), raw)
        }
        return candidates.max { $0.0 < $1.0 }?.1
    }

    private static func year(from date: Any?) -> Int? {
        guard let dict = date as? [String: Any] else { return nil }
        if let year = dict["year"] as? Int { return year }
        if let iso = dict["isoString"] as? String, let year = Int(iso.prefix(4)) { return year }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func copyrightText(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any],
              let items = dict["items"] as? [[String: Any]] else { return nil }
        let text = items.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private static func stripHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactCount(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }
}
