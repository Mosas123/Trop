import Foundation

/// Finds the best addon stream for a song from its metadata. Shared by playback
/// upgrades and lossless downloads, so both use identical matching.
enum AddonSourceResolver {
    struct Match: Sendable {
        let track: AddonTrack
        let stream: AddonStream
    }

    private static func cacheKey(
        title: String,
        artist: String,
        album: String?,
        duration: Int?,
        requireCD: Bool,
        preferAtmos: Bool,
        preferHiRes: Bool
    ) -> String {
        // Duration bucket: copies differ by a second or two, versions don't.
        let bucket = (duration ?? 0) / 5
        // Full labels and album edition go in the key; a cached
        // instrumental copy must NEVER be served to a vocal track.
        let components = [
            TextMatch.normalize(title),
            TextMatch.normalize(artist),
            TextMatch.normalize(album ?? ""),
            String(bucket),
            requireCD ? "cd" : "any",
            preferAtmos ? "atmos" : "",
            preferHiRes ? "hires" : ""
        ]
        return components.joined(separator: "|")
    }

    private struct Criteria: Sendable {
        let title: String
        let artist: String
        let album: String?
        let duration: Int?
        let queries: [String]
    }

    /// Every addon entry point (search, album cache, lossless and AAC) must
    /// pass the same identity test before a URL or quality tier is considered.
    private static func verified(_ track: AddonTrack, for criteria: Criteria) -> Bool {
        TextMatch.verifiedAudioSource(
            wantedTitle: criteria.title,
            wantedArtist: criteria.artist,
            wantedAlbum: criteria.album,
            wantedDuration: criteria.duration,
            candidateTitle: track.title,
            candidateArtist: track.artist,
            candidateAlbum: track.album,
            candidateDuration: track.durationSeconds
        )
    }

    /// Tries the healthiest addons first, two at a time, and only falls back to
    /// the rest when the first batch has no lossless answer. This keeps a single
    /// lookup to a handful of requests instead of querying every addon.
    @MainActor
    static func bestMatch(
        for song: SongItem,
        requireCD: Bool = false,
        preferAtmos: Bool = false,
        preferHiRes: Bool = false
    ) async -> Match? {
        let installations = Array(MusicAddonsStore.shared.enabledStremioInstallations.prefix(4))
        guard !installations.isEmpty else { return nil }

        let title = TextMatch.queryTitle(song.title)
        let artist = TextMatch.queryArtist(song.artists.first?.name ?? "")
        // Two searches race per addon: the specific one (artist + album +
        // title) and the fallback (artist + title) for addons whose search
        // chokes on the extra album words.
        let album = TextMatch.queryTitle(song.album ?? "")
        var queries: [String] = []
        let withAlbum = [artist, album, title].filter { !$0.isEmpty }.joined(separator: " ")
        let withoutAlbum = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        if !withAlbum.isEmpty { queries.append(withAlbum) }
        if !withoutAlbum.isEmpty, !queries.contains(withoutAlbum) { queries.append(withoutAlbum) }
        let criteria = Criteria(
            title: song.title,
            artist: artist,
            album: song.album,
            duration: song.duration > 0 ? song.duration : nil,
            queries: queries
        )

        let cacheKey = Self.cacheKey(
            title: song.title,
            artist: artist,
            album: song.album,
            duration: criteria.duration,
            requireCD: requireCD,
            preferAtmos: preferAtmos,
            preferHiRes: preferHiRes
        )
        if let cached = await AddonMatchCache.shared.get(cacheKey),
           Self.verified(cached.track, for: criteria) {
            return cached
        }

        var available: [MusicAddonInstallation] = []
        for installation in installations {
            if await AddonHealth.shared.isCoolingDown(installation.key) { continue }
            available.append(installation)
        }
        // Everything parked: still try once rather than giving up on lossless.
        if available.isEmpty { available = installations }

        let order = await AddonHealth.shared.ordered(available.map(\.key))
        let sorted = order.compactMap { key in available.first { $0.key == key } }

        for start in stride(from: 0, to: sorted.count, by: 2) {
            let batch = Array(sorted[start..<min(start + 2, sorted.count)])
            if let match = await race(
                batch,
                criteria: criteria,
                requireCD: requireCD,
                preferAtmos: preferAtmos,
                preferHiRes: preferHiRes
            ) {
                await AddonMatchCache.shared.store(match, for: cacheKey)
                return match
            }
        }
        return nil
    }

    private static func race(
        _ installations: [MusicAddonInstallation],
        criteria: Criteria,
        requireCD: Bool,
        preferAtmos: Bool,
        preferHiRes: Bool
    ) async -> Match? {
        let maxRank = preferAtmos ? 5 : (preferHiRes ? 4 : 3)
        guard !installations.isEmpty else { return nil }
        return await withTaskGroup(of: (String, (Match, Int)?, Double).self) { group in
            for installation in installations {
                group.addTask {
                    let started = CFAbsoluteTimeGetCurrent()
                    let result = await bestMatch(
                        in: installation,
                        criteria: criteria,
                        requireCD: requireCD,
                        preferAtmos: preferAtmos,
                        preferHiRes: preferHiRes
                    )
                    return (installation.key, result, CFAbsoluteTimeGetCurrent() - started)
                }
            }
            var best: (Match, Int)?
            for await (key, candidate, latency) in group {
                if let candidate {
                    await AddonHealth.shared.recordSuccess(key, latency: latency)
                    if best == nil || candidate.1 > best!.1 {
                        best = candidate
                    }
                    if candidate.1 == maxRank {
                        group.cancelAll()
                        break
                    }
                } else {
                    await AddonHealth.shared.recordMiss(key, latency: latency)
                }
            }
            return best?.0
        }
    }

    /// AAC 320 fallback: same metadata matching, but asks the addon for its
    /// lossy 320 copy. Used when no FLAC worked and JioSaavn may not have it.
    @MainActor
    static func bestLossyMatch(for song: SongItem) async -> Match? {
        let installations = Array(MusicAddonsStore.shared.enabledStremioInstallations.prefix(4))
        guard !installations.isEmpty else { return nil }

        let title = TextMatch.queryTitle(song.title)
        let artist = TextMatch.queryArtist(song.artists.first?.name ?? "")
        let album = TextMatch.queryTitle(song.album ?? "")
        var queries: [String] = []
        let withAlbum = [artist, album, title].filter { !$0.isEmpty }.joined(separator: " ")
        let withoutAlbum = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        if !withAlbum.isEmpty { queries.append(withAlbum) }
        if !withoutAlbum.isEmpty, !queries.contains(withoutAlbum) { queries.append(withoutAlbum) }
        let criteria = Criteria(
            title: song.title,
            artist: artist,
            album: song.album,
            duration: song.duration > 0 ? song.duration : nil,
            queries: queries
        )

        let order = await AddonHealth.shared.ordered(installations.map(\.key))
        for key in order {
            guard let installation = installations.first(where: { $0.key == key }),
                  let client = try? MusicAddonClient(installation: installation) else { continue }
            var collected: [AddonTrack] = []
            await withTaskGroup(of: [AddonTrack].self) { group in
                for query in queries {
                    group.addTask {
                        await candidates(
                            in: client,
                            query: query,
                            criteria: criteria,
                            preferAtmos: false,
                            preferHiRes: false
                        )
                    }
                }
                for await list in group { collected.append(contentsOf: list) }
            }
            var seen = Set<String>()
            let unique = collected.filter { seen.insert($0.id).inserted }
            guard !unique.isEmpty else { continue }
            let ranked = unique
                .sorted {
                    score($0, criteria: criteria, preferAtmos: false, preferHiRes: false)
                        > score($1, criteria: criteria, preferAtmos: false, preferHiRes: false)
                }
                .prefix(2)
            for track in ranked {
                guard let stream = try? await client.resolveStream(
                          type: track.type,
                          id: track.id,
                          preferAtmos: false,
                          quality: .high
                      ),
                      !stream.isEncrypted,
                      stream.qualityTier == "High" else { continue }
                return Match(track: track, stream: stream)
            }
        }
        return nil
    }

    /// Collects candidates for one addon (both queries + the album route) in
    /// parallel, then dedupes and resolves only the best few.
    private static func bestMatch(
        in installation: MusicAddonInstallation,
        criteria: Criteria,
        requireCD: Bool,
        preferAtmos: Bool,
        preferHiRes: Bool
    ) async -> (Match, Int)? {
        guard let client = try? MusicAddonClient(installation: installation) else { return nil }
        let hasAlbum = !(criteria.album ?? "").isEmpty

        var collected: [AddonTrack] = []
        // Album index: the first track of an album pays one album lookup; the
        // rest of the queue matches against that list with no extra searches.
        var usedAlbumIndex = false
        if let album = criteria.album, hasAlbum,
           let cached = await AddonAlbumCache.shared.get(
               Self.albumKey(installationKey: installation.key, artist: criteria.artist, album: album)
           ), !cached.isEmpty {
            let filtered = Self.filterAlbumTracks(
                cached,
                criteria: criteria,
                preferAtmos: preferAtmos,
                preferHiRes: preferHiRes
            )
            if !filtered.isEmpty {
                collected = filtered
                usedAlbumIndex = true
            }
        }

        if !usedAlbumIndex {
            await withTaskGroup(of: [AddonTrack].self) { group in
                for query in criteria.queries {
                    group.addTask {
                        await candidates(
                            in: client,
                            query: query,
                            criteria: criteria,
                            preferAtmos: preferAtmos,
                            preferHiRes: preferHiRes
                        )
                    }
                }
                if hasAlbum {
                    group.addTask {
                        await albumCandidates(
                            in: client,
                            installationKey: installation.key,
                            criteria: criteria,
                            preferAtmos: preferAtmos,
                            preferHiRes: preferHiRes
                        )
                    }
                }
                for await list in group {
                    collected.append(contentsOf: list)
                }
            }
        }

        var seen = Set<String>()
        let unique = collected.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return nil }
        let ranked = unique
            .sorted {
                score($0, criteria: criteria, preferAtmos: preferAtmos, preferHiRes: preferHiRes)
                    > score($1, criteria: criteria, preferAtmos: preferAtmos, preferHiRes: preferHiRes)
            }
            .prefix(2)
        return await resolveBest(
            ranked,
            in: client,
            requireCD: requireCD,
            preferAtmos: preferAtmos,
            preferHiRes: preferHiRes
        )
    }

    /// Text search results that pass the hard metadata filters.
    private static func candidates(
        in client: MusicAddonClient,
        query: String,
        criteria: Criteria,
        preferAtmos: Bool,
        preferHiRes: Bool
    ) async -> [AddonTrack] {
        guard let found = try? await client.search(query, limit: 20) else { return [] }
        return found.filter { track in
            if track.isAtmosOnly, !preferAtmos { return false }
            if track.isHiRes, !preferHiRes { return false }
            return Self.verified(track, for: criteria)
        }
    }

    /// Exact route: find the album and list its tracks, preferring the exact
    /// duration. Cap of the addon itself is 20 tracks.
    private static func albumCandidates(
        in client: MusicAddonClient,
        installationKey: String,
        criteria: Criteria,
        preferAtmos: Bool,
        preferHiRes: Bool
    ) async -> [AddonTrack] {
        guard let albumName = criteria.album, !albumName.isEmpty else { return [] }
        let key = Self.albumKey(
            installationKey: installationKey,
            artist: criteria.artist,
            album: albumName
        )
        if let cached = await AddonAlbumCache.shared.get(key), !cached.isEmpty {
            return Self.filterAlbumTracks(
                cached,
                criteria: criteria,
                preferAtmos: preferAtmos,
                preferHiRes: preferHiRes
            )
        }
        let query = [criteria.artist, TextMatch.queryTitle(albumName)]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty,
              let albums = try? await client.searchAlbums(query, limit: 8),
              !albums.isEmpty else { return [] }

        let byArtist = albums.first { album in
            guard TextMatch.albumsMatch(album.title, albumName) else { return false }
            guard let albumArtist = album.artist, !albumArtist.isEmpty, !criteria.artist.isEmpty else {
                return true
            }
            return TextMatch.artistsMatch(albumArtist, criteria.artist)
        }
        guard let album = byArtist ?? albums.first(where: { TextMatch.albumsMatch($0.title, albumName) }),
              let tracks = try? await client.albumTracks(id: album.id),
              !tracks.isEmpty else { return [] }

        await AddonAlbumCache.shared.store(tracks, for: key)
        return Self.filterAlbumTracks(
            tracks,
            criteria: criteria,
            preferAtmos: preferAtmos,
            preferHiRes: preferHiRes
        )
    }

    private static func filterAlbumTracks(
        _ tracks: [AddonTrack],
        criteria: Criteria,
        preferAtmos: Bool,
        preferHiRes: Bool
    ) -> [AddonTrack] {
        return tracks.filter { track in
            guard !(track.isAtmosOnly && !preferAtmos),
                  !(track.isHiRes && !preferHiRes) else { return false }
            return Self.verified(track, for: criteria)
        }
    }

    private static func albumKey(installationKey: String, artist: String, album: String) -> String {
        // Album edition is part of identity, not just a search hint.
        let name = TextMatch.normalize(album)
        return "\(installationKey)|\(TextMatch.normalize(artist))|\(name)"
    }

    /// Resolves the given candidates in order and returns the best tier found.
    private static func resolveBest<C: Collection>(
        _ tracks: C,
        in client: MusicAddonClient,
        requireCD: Bool,
        preferAtmos: Bool,
        preferHiRes: Bool
    ) async -> (Match, Int)? where C.Element == AddonTrack {
        var best: (Match, Int)?
        for track in tracks {
            let streamQuality: AddonStreamQuality = preferAtmos
                ? .max
                : (requireCD ? .lossless : (preferHiRes ? .hires : .lossless))
            guard let stream = try? await client.resolveStream(
                      type: track.type,
                      id: track.id,
                      preferAtmos: preferAtmos,
                      quality: streamQuality
                  ),
                  !stream.isEncrypted else { continue }
            if stream.qualityTier == "Atmos", !preferAtmos { continue }
            if requireCD, stream.isHiRes { continue }
            let rank: Int
            switch stream.qualityTier {
            case "Lossless": rank = 3
            case "Atmos": rank = preferAtmos ? 4 : 2
            case "High": rank = 2
            default: rank = 1
            }
            if best == nil || rank > best!.1 {
                best = (Match(track: track, stream: stream), rank)
            }
            if rank == (preferAtmos ? 4 : 3) { break }
        }
        return best
    }

    /// Higher is a better metadata match: exact title, album, duration and
    /// artist. Used to decide which candidates are worth resolving.
    private static func score(
        _ track: AddonTrack,
        criteria: Criteria,
        preferAtmos: Bool,
        preferHiRes: Bool
    ) -> Int {
        var score = 0
        if preferAtmos, track.isAtmos { score += 10 }
        if preferHiRes, track.isHiRes { score += 8 }
        let wanted = TextMatch.normalizeTitle(criteria.title)
        let found = TextMatch.normalizeTitle(track.title)
        if !wanted.isEmpty, wanted == found { score += 60 }
        if let album = criteria.album, !album.isEmpty,
           let trackAlbum = track.album, !trackAlbum.isEmpty,
           TextMatch.albumsMatch(trackAlbum, album) {
            score += 25
        }
        if let duration = criteria.duration, let trackDuration = track.durationSeconds, trackDuration > 0 {
            let diff = abs(trackDuration - duration)
            if diff <= 2 { score += 25 } else if diff <= 6 { score += 15 } else if diff <= 20 { score += 5 }
        }
        if let artist = track.artist, !artist.isEmpty, !criteria.artist.isEmpty,
           TextMatch.artistsMatch(artist, criteria.artist) {
            score += 20
        }
        return score
    }
}


/// Short-lived resolved matches so a replay/download doesn't search again.
actor AddonMatchCache {
    static let shared = AddonMatchCache()

    private struct Entry {
        let match: AddonSourceResolver.Match
        let at: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 240
    private let maxEntries = 200

    func get(_ key: String) -> AddonSourceResolver.Match? {
        guard let entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < ttl else {
            entries[key] = nil
            return nil
        }
        return entry.match
    }

    func store(_ match: AddonSourceResolver.Match, for key: String) {
        if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(match: match, at: Date())
    }
}


/// Album track lists per addon, so a queue from one album is resolved once.
actor AddonAlbumCache {
    static let shared = AddonAlbumCache()

    private struct Entry {
        let tracks: [AddonTrack]
        let at: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval = 600
    private let maxEntries = 50

    func get(_ key: String) -> [AddonTrack]? {
        guard let entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.at) < ttl else {
            entries[key] = nil
            return nil
        }
        return entry.tracks
    }

    func store(_ tracks: [AddonTrack], for key: String) {
        if entries.count >= maxEntries { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(tracks: tracks, at: Date())
    }
}
