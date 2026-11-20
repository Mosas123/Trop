//
//  PlaybackManager.swift
//  Trop
//
//  Created by 686udjie on 29/06/2026.
//

import Foundation

/// Resolves streams and hands off to PlayerController, trying the client fallback chain.
actor PlaybackManager {
    static let shared = PlaybackManager()

    private var inflightResolutions: [String: Task<PlaybackResult, Error>] = [:]
    private var albumAudioMatchCache: [String: (videoId: String?, at: Date)] = [:]



    private func resolutionKey(videoId: String, forDownload: Bool) -> String {
        forDownload ? "\(videoId):download" : "\(videoId):resolve"
    }

    /// Playback resolution must never share an in-flight entry with a bare
    /// `resolve(...)` (preload/Top-100 warmup), because that task never calls
    /// `play()` — awaiting it would return a result without starting audio.
    private func playKey(videoId: String, intentGeneration: Int) -> String {
        "\(videoId):play:\(intentGeneration)"
    }

    private func isCurrentIntent(_ intentGeneration: Int) async -> Bool {
        await MainActor.run {
            NowPlaying.shared.playbackGeneration == intentGeneration
        }
    }

    private init() {}

    /// Audius uses its own full-track streaming endpoint and never passes a
    /// provider-prefixed ID to the YouTube stream resolver.
    private func resolveAudius(videoId: String, song fallbackSong: SongItem? = nil) async throws -> PlaybackResult {
        guard let identifier = MusicCatalogID(storageKey: videoId),
              identifier.source == .audius else {
            throw MusicCatalogError.unavailableTrack
        }
        guard let song = await songForResolve(videoId, fallback: fallbackSong) else {
            throw MusicCatalogError.unavailableTrack
        }
        let sourceTrack = MusicCatalogTrack(
            id: identifier,
            title: song.title,
            artist: song.artistNamesDisplay,
            durationSeconds: song.duration,
            artworkURL: song.thumbnailUrl.flatMap(URL.init(string:)),
            permalinkURL: nil,
            isStreamable: true
        )
        let streamURL = try AudiusClient().streamURL(for: sourceTrack)
        return PlaybackResult(
            streamUrl: streamURL.absoluteString,
            itag: 0,
            mimeType: "audio/mpeg",
            bitrate: 0,
            audioQuality: "audius",
            videoId: videoId,
            title: song.title,
            author: sourceTrack.artist,
            duration: song.duration,
            expiresInSeconds: 0,
            clientName: "audius",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
    }

    /// Qobuz uses fresh, authorized, short-lived FLAC links. Its IDs must
    /// never enter the YouTube stream resolver.
    private func resolveQobuz(videoId: String, song fallbackSong: SongItem? = nil) async throws -> PlaybackResult {
        guard let identifier = MusicCatalogID(storageKey: videoId),
              identifier.source == .qobuz else {
            throw QobuzError.invalidTrack
        }
        guard let song = await songForResolve(videoId, fallback: fallbackSong) else {
            throw QobuzError.invalidTrack
        }
        guard let credentials = try await QobuzCredentialStore.shared.load() else {
            throw QobuzError.notConfigured
        }
        let streamURL = try await QobuzClient().streamURL(
            trackId: identifier.rawValue, credentials: credentials
        )
        return PlaybackResult(
            streamUrl: streamURL.absoluteString,
            itag: 0,
            mimeType: "audio/flac",
            bitrate: 0,
            audioQuality: "qobuz-cd",
            videoId: videoId,
            title: song.title,
            author: song.artistNamesDisplay,
            duration: song.duration,
            expiresInSeconds: 0,
            clientName: "qobuz",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
    }

    /// PencariMusic was removed from the app; ids saved by older versions are
    /// resolved by the installed add-ons using the track metadata.
    private func resolveLegacyPencari(videoId: String, song fallbackSong: SongItem? = nil) async throws -> PlaybackResult {
        guard let song = await songForResolve(videoId, fallback: fallbackSong) else {
            throw MusicCatalogError.unavailableTrack
        }
        guard let preference = addonPreference else { throw MusicCatalogError.unavailableTrack }
        guard let match = await AddonSourceResolver.bestMatch(
                  for: song,
                  requireCD: preference.requireCD,
                  preferAtmos: preference.preferAtmos,
                  preferHiRes: preference.preferHiRes
              ),
              case .url(let url) = match.stream.kind,
              let finalURL = await Self.verifiedStreamURL(url.absoluteString) else {
            throw MusicCatalogError.unavailableTrack
        }
        if let name = await addonName(for: match.track.installationKey) {
            resolvedSourceNames[videoId] = name
        }
        let quality: String
        switch match.stream.qualityTier {
        case "Atmos": quality = "addon-atmos"
        case "Lossless": quality = match.stream.isHiRes ? "addon-hi-res" : "addon-cd"
        default: quality = "addon-\(match.stream.qualityTier.lowercased())"
        }
        return PlaybackResult(
            streamUrl: finalURL.absoluteString,
            itag: 0,
            mimeType: match.stream.mimeType,
            bitrate: match.stream.bitrate,
            audioQuality: quality,
            videoId: videoId,
            title: song.title,
            author: song.artistNamesDisplay,
            duration: song.duration,
            expiresInSeconds: 0,
            clientName: "addon",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
    }

    /// JioSaavn resolves to a decrypted (usually 320 kbps AAC) URL.
    private func resolveJioSaavn(videoId: String, song fallbackSong: SongItem? = nil) async throws -> PlaybackResult {
        guard let identifier = MusicCatalogID(storageKey: videoId),
              identifier.source == .jiosaavn else {
            throw MusicCatalogError.unavailableTrack
        }
        guard let song = await songForResolve(videoId, fallback: fallbackSong) else {
            throw MusicCatalogError.unavailableTrack
        }
        let streamURL = try await JioSaavnClient().resolveStreamURL(for: identifier.rawValue)
        let ext = streamURL.pathExtension.lowercased()
        let mime: String
        let quality: String
        switch ext {
        case "mp3": mime = "audio/mpeg"; quality = "jiosaavn-320-mp3"
        case "aac": mime = "audio/aac"; quality = "jiosaavn-320-aac"
        default: mime = "audio/mp4"; quality = "jiosaavn-320"
        }
        return PlaybackResult(
            streamUrl: streamURL.absoluteString,
            itag: 0,
            mimeType: mime,
            bitrate: 320_000,
            audioQuality: quality,
            videoId: videoId,
            title: song.title,
            author: song.artistNamesDisplay,
            duration: song.duration,
            expiresInSeconds: 0,
            clientName: "jiosaavn",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
    }

    /// Queue metadata for a track that isn't necessarily playing (downloads
    /// from a list pass their own SongItem).
    private func songForResolve(_ videoId: String, fallback: SongItem?) async -> SongItem? {
        if let fallback { return fallback }
        return await queueSong(for: videoId)
    }

    /// Reads a Stremio music addon: resolves the stream URL and maps its
    /// declared quality into the player badge.
    private func resolveAddon(videoId: String, song fallbackSong: SongItem? = nil) async throws -> PlaybackResult {
        guard let ref = AddonPlaybackID.decode(videoId),
              let installation = await MainActor.run(body: {
                  MusicAddonsStore.shared.installation(key: ref.k)
              }) else {
            throw MusicCatalogError.unavailableTrack
        }
        guard let song = await songForResolve(videoId, fallback: fallbackSong) else {
            throw MusicCatalogError.unavailableTrack
        }
        let client = try MusicAddonClient(installation: installation)
        let mode = SettingsStore.shared.musicQualityMode
        let atmos = (mode == .auto || mode == .lossless) && SettingsStore.shared.preferAtmos
        let streamQuality: AddonStreamQuality = atmos
            ? .max
            : (mode == .cd ? .lossless : (SettingsStore.shared.preferHiRes ? .hires : .lossless))
        let stream = try await client.resolveStream(
            type: ref.t,
            id: ref.i,
            preferAtmos: atmos,
            quality: streamQuality
        )
        guard !stream.isEncrypted else { throw MusicCatalogError.unavailableTrack }
        let isAtmosStream = stream.qualityTier.lowercased().contains("atmos")
            || stream.mimeType.lowercased().contains("eac3")
            || stream.mimeType.lowercased().contains("ec+3")
        Log.player.info(
            "ADDON_STREAM quality=\(stream.qualityTier) mime=\(stream.mimeType) atmos=\(isAtmosStream) requested=\(atmos)"
        )
        resolvedSourceNames[videoId] = installation.manifest.name

        if case .youtube(let youTubeId) = stream.kind {
            var request = StreamResolveRequest.playback(videoId: youTubeId)
            request.options.audioQuality = SettingsStore.shared.audioQuality
            let resolved = try await StreamFallback.resolveFirstValid(
                request, using: InnerTubeClient.tropShared, providers: .tropLive
            )
            return PlaybackResult(
                streamUrl: resolved.streamUrl,
                itag: resolved.itag,
                mimeType: resolved.mimeType,
                bitrate: resolved.bitrate,
                audioQuality: resolved.audioQuality,
                videoId: videoId,
                title: song.title,
                author: song.artistNamesDisplay,
                duration: song.duration,
                expiresInSeconds: resolved.expiresInSeconds,
                clientName: "addon",
                musicVideoType: nil,
                hasVideoContent: false,
                muxedStreamUrl: nil,
                loudnessDb: nil
            )
        }

        guard case .url(let url) = stream.kind else {
            throw MusicCatalogError.unavailableTrack
        }
        let quality: String
        if stream.qualityTier == "Lossless" {
            quality = stream.isHiRes ? "hi-res" : "cd"
        } else {
            quality = stream.qualityTier.lowercased()
        }
        return PlaybackResult(
            streamUrl: url.absoluteString,
            itag: 0,
            mimeType: stream.mimeType,
            bitrate: stream.bitrate,
            audioQuality: "addon-\(quality)",
            videoId: videoId,
            title: song.title,
            author: song.artistNamesDisplay,
            duration: song.duration,
            expiresInSeconds: 0,
            clientName: "addon",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
    }

    // MARK: - Automatic lossless upgrade

    /// Prefetched FLAC resolutions keyed by the YouTube videoId they upgrade.
    private var upgradeResultCache: [String: (result: PlaybackResult, at: Date)] = [:]
    private var upgradePrefetchInFlight: Set<String> = []
    private var resolvedSourceNames: [String: String] = [:]
    private var queueObserver: NSObjectProtocol?
    private var queueChangeTask: Task<Void, Never>?
    private var prefetchRefreshTask: Task<Void, Never>?

    /// Lossy sources (YouTube/JioSaavn/AAC) are allowed unless the user asked
    /// for FLAC explicitly (CD or Best FLAC).
    private var lossySourcesAllowed: Bool {
        let mode = SettingsStore.shared.musicQualityMode
        return mode != .cd && mode != .lossless
    }

    /// Auto/High race YouTube, JioSaavn and add-on AAC 320. Standard/Low stay
    /// on YouTube and only use the others when YouTube has no stream.
    private var prefers320Lossy: Bool {
        guard lossySourcesAllowed else { return false }
        let quality = SettingsStore.shared.audioQuality
        return quality == .auto || quality == .high
    }

    private struct AddonQualityPreference: Sendable {
        let requireCD: Bool
        let preferHiRes: Bool
        let preferAtmos: Bool
    }

    /// What the add-ons should look for. Nil means no add-ons (or no upgrade).
    private var addonPreference: AddonQualityPreference? {
        guard SettingsStore.shared.hasMusicAddons else { return nil }
        switch SettingsStore.shared.musicQualityMode {
        case .off:
            return nil
        case .cd:
            return AddonQualityPreference(
                requireCD: true,
                preferHiRes: false,
                preferAtmos: false
            )
        case .lossless:
            return AddonQualityPreference(
                requireCD: false,
                preferHiRes: SettingsStore.shared.preferHiRes,
                preferAtmos: SettingsStore.shared.preferAtmos
            )
        case .auto, .high:
            return AddonQualityPreference(
                requireCD: false,
                preferHiRes: SettingsStore.shared.preferHiRes,
                preferAtmos: SettingsStore.shared.preferAtmos
            )
        }
    }

    /// Only ever returns an *already prefetched* FLAC, so the play path never
    /// touches the network for lossless. Misses go straight to YouTube.
    private func cachedUpgrade(videoId: String) -> (result: PlaybackResult, age: TimeInterval)? {
        guard !MusicPlaybackIdentity.isExternal(videoId) else { return nil }
        guard let cached = upgradeResultCache[videoId] else { return nil }
        let age = Date().timeIntervalSince(cached.at)
        guard age < upgradeTTL(for: cached.result) else { return nil }
        let acceptable: Bool
        if let preference = addonPreference {
            acceptable = Self.resultMatches(cached.result, preference: preference)
        } else {
            let quality = cached.result.audioQuality.lowercased()
            acceptable = prefers320Lossy
                && (quality.contains("jiosaavn") || quality.contains("addon-aac"))
        }
        guard acceptable else { return nil }
        return (cached.result, age)
    }

    private func prefetchedUpgrade(videoId: String) -> PlaybackResult? {
        cachedUpgrade(videoId: videoId)?.result
    }

    private static func resultMatches(
        _ result: PlaybackResult,
        preference: AddonQualityPreference
    ) -> Bool {
        let quality = result.audioQuality.lowercased()
        if quality.contains("addon-aac") || quality.contains("jiosaavn") {
            let mode = SettingsStore.shared.musicQualityMode
            let allowedMode = mode != .cd && mode != .lossless
            let qualitySetting = SettingsStore.shared.audioQuality
            return allowedMode && (qualitySetting == .auto || qualitySetting == .high)
        }
        if quality.contains("atmos") { return preference.preferAtmos }
        guard isLosslessResult(result) else { return false }
        if isHiResResult(result), !preference.preferHiRes { return false }
        if preference.requireCD, isHiResResult(result) { return false }
        return true
    }

    /// Add-on URLs are minted per request and expire quickly.
    private func upgradeTTL(for result: PlaybackResult) -> TimeInterval { 240 }

    /// Dispatches the prefetch by the user's quality mode. Lossless falls back
    /// to JioSaavn High so an unreachable FLAC origin doesn't leave the user on
    /// Standard.
    private func resolvePreferredUpgrade(
        videoId: String,
        interactive: Bool = false,
        budget: Double? = nil,
        ignoreCache: Bool = false
    ) async -> PlaybackResult? {
        guard let preference = addonPreference else { return nil }
        let cached = ignoreCache ? nil : upgradeResultCache[videoId].flatMap {
            Date().timeIntervalSince($0.at) < upgradeTTL(for: $0.result) ? $0.result : nil
        }
        if let cached, Self.resultMatches(cached, preference: preference) {
            return cached
        }
        if let lossless = await losslessWithinBudget(
            videoId: videoId,
            seconds: budget ?? (interactive ? 4 : 8),
            preference: preference
        ) {
            return lossless
        }
        if prefers320Lossy {
            // Add-on AAC 320 and JioSaavn 320 cover each other: whichever
            // answers first wins.
            let hasAddonAAC = await MainActor.run {
                MusicAddonsStore.shared.availableAudioCapabilities.aac320
            }
            let fallback = await withTaskGroup(of: PlaybackResult?.self) { group in
                if hasAddonAAC {
                    group.addTask { await self.resolveAddonAAC(videoId: videoId) }
                }
                group.addTask { await self.resolveJioSaavnFallback(videoId: videoId) }
                var first: PlaybackResult?
                for await candidate in group {
                    guard let candidate else { continue }
                    first = candidate
                    break
                }
                group.cancelAll()
                return first
            }
            if let fallback {
                if upgradeResultCache.count >= 100 {
                    upgradeResultCache.removeAll(keepingCapacity: true)
                }
                upgradeResultCache[videoId] = (fallback, Date())
                return fallback
            }
        }
        return nil
    }

    /// The enabled add-ons race for the FLAC; whichever answers first wins.
    private func losslessWithinBudget(
        videoId: String,
        seconds: Double,
        preference: AddonQualityPreference
    ) async -> PlaybackResult? {
        await withTaskGroup(of: PlaybackResult?.self) { group -> PlaybackResult? in
            group.addTask {
                await self.resolveAddonLossless(videoId: videoId, preference: preference)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// JioSaavn 320 fallback: best match by metadata. Callers decide when the
    /// lossy pool is allowed (everything except CD / Best FLAC).
    private func resolveJioSaavnFallback(videoId: String) async -> PlaybackResult? {
        guard !MusicPlaybackIdentity.isExternal(videoId),
              !MusicPlaybackIdentity.isLegacyPencari(videoId) else { return nil }
        guard let song = await queueSong(for: videoId) else { return nil }
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let artist = song.artists.first?.name ?? ""
        let query = artist.isEmpty ? title : "\(artist) \(title)"
        let client = JioSaavnClient()
        guard let tracks = try? await client.search(query: query, limit: 8),
              let best = Self.bestCatalogMatch(
                   tracks, title: title, artist: artist, duration: song.duration
               ),
              best.isStreamable,
              let url = try? await client.resolveStreamURL(for: best.id.rawValue),
              let finalURL = await Self.verifiedStreamURL(url.absoluteString) else {
            return nil
        }
        resolvedSourceNames[videoId] = "JioSaavn"
        return PlaybackResult(
            streamUrl: finalURL.absoluteString,
            itag: 0,
            mimeType: "audio/mp4",
            bitrate: 320_000,
            audioQuality: "jiosaavn-320",
            videoId: videoId,
            title: song.title,
            author: song.artistNamesDisplay,
            duration: song.duration,
            expiresInSeconds: 0,
            clientName: "jiosaavn",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
    }

    /// JioSaavn and the add-on AAC 320 copy race each other.
    private func resolveLossyBest(videoId: String) async -> PlaybackResult? {
        await withTaskGroup(of: PlaybackResult?.self) { group in
            group.addTask { await self.resolveAddonAAC(videoId: videoId) }
            group.addTask { await self.resolveJioSaavnFallback(videoId: videoId) }
            var best: PlaybackResult?
            for await candidate in group {
                guard let candidate else { continue }
                best = candidate
                break
            }
            group.cancelAll()
            return best
        }
    }

    /// AAC 320 fallback from the add-ons.
    private func resolveAddonAAC(videoId: String) async -> PlaybackResult? {
        guard SettingsStore.shared.hasMusicAddons, lossySourcesAllowed else { return nil }
        guard !MusicPlaybackIdentity.isExternal(videoId),
              !MusicPlaybackIdentity.isLegacyPencari(videoId) else { return nil }
        guard let song = await queueSong(for: videoId) else { return nil }
        guard let match = await AddonSourceResolver.bestLossyMatch(for: song),
              case .url(let url) = match.stream.kind,
              let finalURL = await Self.verifiedStreamURL(url.absoluteString) else {
            return nil
        }
        if let name = await addonName(for: match.track.installationKey) {
            resolvedSourceNames[videoId] = name
        }
        return PlaybackResult(
            streamUrl: finalURL.absoluteString,
            itag: 0,
            mimeType: "audio/mp4",
            bitrate: 320_000,
            audioQuality: "addon-aac-320",
            videoId: videoId,
            title: song.title,
            author: song.artistNamesDisplay,
            duration: song.duration,
            expiresInSeconds: 0,
            clientName: "addon",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
    }

    /// Same track as a lossless stream on one of the installed add-ons.
    private func resolveAddonLossless(
        videoId: String,
        preference: AddonQualityPreference
    ) async -> PlaybackResult? {
        guard addonPreference != nil else { return nil }
        guard !MusicPlaybackIdentity.isExternal(videoId) else { return nil }
        guard let song = await queueSong(for: videoId) else { return nil }
        guard let match = await AddonSourceResolver.bestMatch(
                  for: song,
                  requireCD: preference.requireCD,
                  preferAtmos: preference.preferAtmos,
                  preferHiRes: preference.preferHiRes
              ),
              match.stream.qualityTier == "Lossless"
                  || (preference.preferAtmos && match.stream.qualityTier == "Atmos"),
              case .url(let url) = match.stream.kind,
              let finalURL = await Self.verifiedStreamURL(url.absoluteString) else { return nil }
        if let name = await addonName(for: match.track.installationKey) {
            resolvedSourceNames[videoId] = name
        }
        let result = PlaybackResult(
            streamUrl: finalURL.absoluteString,
            itag: 0,
            mimeType: match.stream.mimeType,
            bitrate: match.stream.bitrate,
            audioQuality: match.stream.qualityTier == "Atmos"
                ? "addon-atmos"
                : (match.stream.isHiRes ? "addon-hi-res" : "addon-cd"),
            videoId: videoId,
            title: song.title,
            author: song.artistNamesDisplay,
            duration: song.duration,
            expiresInSeconds: 0,
            clientName: "addon",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
        if upgradeResultCache.count >= 100 {
            upgradeResultCache.removeAll(keepingCapacity: true)
        }
        if resolvedSourceNames.count >= 200 { resolvedSourceNames.removeAll(keepingCapacity: true) }
        upgradeResultCache[videoId] = (result, Date())
        return result
    }

    private static func isLosslessResult(_ result: PlaybackResult) -> Bool {
        losslessLabel(result) != nil
    }

    private static func isHiResResult(_ result: PlaybackResult) -> Bool {
        result.audioQuality.lowercased().contains("hi-res")
    }

    private static func tierRank(_ label: String?) -> Int {
        switch label {
        case "Lossless": return 2
        case "High": return 1
        default: return 0
        }
    }

    /// Optional mid-track upgrade (user setting). Fades out, reloads the better
    /// stream at the same position, fades back in, and updates the badge.
    private func applyUpgradeIfEnabled(_ result: PlaybackResult, videoId: String) async {
        guard SettingsStore.shared.upgradeDuringPlayback else { return }
        let currentVideoId = await MainActor.run { NowPlaying.shared.videoId }
        let isPlaying = await MainActor.run { NowPlaying.shared.isPlaying }
        guard currentVideoId == videoId, isPlaying else { return }
        let position = await MainActor.run { NowPlaying.shared.currentTime }
        let oldLabel = await MainActor.run { NowPlaying.shared.qualityBadgeLabel }
        let oldURL = await MainActor.run { NowPlaying.shared.currentStreamURL }
        let oldLossless = await MainActor.run { NowPlaying.shared.currentLosslessLabel }
        let intentGeneration = await MainActor.run {
            NowPlaying.shared.playbackGeneration
        }

        let newLabel = Self.qualityLabel(result)
        guard Self.tierRank(newLabel) > Self.tierRank(oldLabel) else { return }

        // Never cut the current audio for a stream that can't even serve bytes.
        guard await Self.verifyStream(result.streamUrl) else {
            upgradeResultCache[videoId] = nil
            return
        }

        let song = await queueSong(for: videoId)
        let targetVolume = await MainActor.run { SettingsStore.shared.playerVolume }
        guard await isCurrentIntent(intentGeneration) else { return }
        await PlayerController.shared.fadeVolume(to: 0, duration: 0.12)
        await PlayerController.shared.play(
            url: result.streamUrl,
            title: song?.title,
            artist: song?.artistNamesDisplay,
            videoId: videoId,
            duration: song.map { TimeInterval($0.duration) },
            artists: song?.artists ?? [],
            thumbnailUrl: song?.thumbnailUrl,
            losslessLabel: Self.losslessLabel(result),
            qualityLabel: newLabel,
            startAt: position,
            intentGeneration: intentGeneration
        )
        guard await isCurrentIntent(intentGeneration) else {
            await MainActor.run {
                PlayerController.shared.setVolumeOverride(targetVolume)
            }
            return
        }
        let upgradeSourceName = sourceName(for: result, videoId: videoId)
        if await isCurrentIntent(intentGeneration) {
            await MainActor.run {
                NowPlaying.shared.currentResult = result
                NowPlaying.shared.currentSourceName = upgradeSourceName
            }
        }
        // Stay muted while the new stream buffers; fade in only once audio is
        // actually advancing. Fading during buffering made it enter abruptly
        // at full volume.
        var started = false
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(50))
            let time = await MainActor.run { NowPlaying.shared.currentTime }
            let currentId = await MainActor.run { NowPlaying.shared.videoId }
            let generation = await MainActor.run {
                NowPlaying.shared.playbackGeneration
            }
            if currentId != videoId || generation != intentGeneration { break }
            if time > position + 0.05 { started = true; break }
        }

        guard await isCurrentIntent(intentGeneration) else {
            await MainActor.run {
                PlayerController.shared.setVolumeOverride(targetVolume)
            }
            return
        }

        if started {
            await PlayerController.shared.fadeVolume(to: targetVolume, duration: 0.35)
            await MainActor.run { PlayerController.shared.setVolumeOverride(nil) }
            return
        }

        // Didn't start: roll back to the previous stream, audible again.
        upgradeResultCache[videoId] = nil
        await MainActor.run { PlayerController.shared.setVolumeOverride(targetVolume) }
        if let oldURL {
            await PlayerController.shared.play(
                url: oldURL,
                title: song?.title,
                artist: song?.artistNamesDisplay,
                videoId: videoId,
                duration: song.map { TimeInterval($0.duration) },
                artists: song?.artists ?? [],
                thumbnailUrl: song?.thumbnailUrl,
                losslessLabel: oldLossless,
                qualityLabel: oldLabel ?? "Standard",
                startAt: position,
                intentGeneration: intentGeneration
            )
        }
        await MainActor.run { PlayerController.shared.setVolumeOverride(nil) }
    }

    /// Cheap reachability check: Range request, 200/206, audio-ish content type.
    /// Verifies the stream and returns the **final** URL (after redirects), so
    /// mpv doesn't pay the 307/302 hop again when playback starts.
    private static func verifiedStreamURL(_ urlString: String) async -> URL? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 || http.statusCode == 206 else { return nil }
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
           !(type.contains("audio")
             || type.contains("flac")
             || type.contains("octet-stream")
             || type.contains("video/mp4")) {
            return nil
        }
        return response.url ?? url
    }

    private static func verifyStream(_ urlString: String) async -> Bool {
        await verifiedStreamURL(urlString) != nil
    }

    /// Starts listening for queue mutations (radio fill, shuffle, reorder) so
    /// the new next songs get warmed without waiting for a track change.
    func startQueueObserver() {
        guard queueObserver == nil else { return }
        queueObserver = NotificationCenter.default.addObserver(
            forName: .tropQueueChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.handleQueueChanged() }
        }
    }

    private func handleQueueChanged() {
        queueChangeTask?.cancel()
        queueChangeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            await self?.prefetchForCurrentTrack()
        }
    }

    private func prefetchForCurrentTrack() async {
        let lossyOnly = addonPreference == nil && prefers320Lossy
        guard addonPreference != nil || lossyOnly else { return }
        guard let current = await MainActor.run(body: { NowPlaying.shared.videoId }) else { return }
        await prefetchUpcomingUpgrades(after: current, count: 2)
    }

    /// Boundary-only upgrade: warm this track (for replays) and the next one
    /// so it *starts* in the better source. Never swaps mid-track.
    private func scheduleUpgradePrefetch(videoId: String) {
        Task {
            let upgradesEnabled = SettingsStore.shared.upgradeDuringPlayback
            // With mid-track swaps on, warm the current track first so the swap
            // happens soon. With them off there is nothing to swap: warm the
            // next queue tracks first and keep the current one for later.
            if self.addonPreference != nil, upgradesEnabled {
                let needsFetch = self.upgradeResultCache[videoId] == nil
                if needsFetch {
                    await MainActor.run { NowPlaying.shared.isUpgradingQuality = true }
                }
                let upgraded = await self.resolvePreferredUpgrade(videoId: videoId, interactive: true)
                await MainActor.run { NowPlaying.shared.isUpgradingQuality = false }
                if let upgraded {
                    await self.applyUpgradeIfEnabled(upgraded, videoId: videoId)
                }
            }

            await self.prefetchUpcomingUpgrades(after: videoId, count: 2)
            await self.prefetchNextMetadata(after: videoId)

            if self.addonPreference != nil, !upgradesEnabled,
               self.upgradeResultCache[videoId] == nil {
                // Replay cache for the current track, after the queue is warm.
                _ = await self.resolvePreferredUpgrade(videoId: videoId, budget: 20)
            }
        }
        schedulePrefetchRefresh(videoId: videoId)
    }

    /// Add-on URLs expire; re-warm the next songs when this track is about to
    /// end. Polls so it also works when the duration was unknown at start.
    private func schedulePrefetchRefresh(videoId: String) {
        prefetchRefreshTask?.cancel()
        prefetchRefreshTask = Task { [weak self] in
            var refreshed = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                let state = await MainActor.run {
                    (NowPlaying.shared.videoId, NowPlaying.shared.duration, NowPlaying.shared.currentTime)
                }
                guard state.0 == videoId else { return }
                guard state.1 > 0 else { continue }
                if !refreshed, state.1 - state.2 <= 90 {
                    refreshed = true
                    await self.prefetchUpcomingUpgrades(
                        after: videoId,
                        count: 2,
                        refreshSoonExpiring: true
                    )
                }
                if state.2 >= state.1 { return }
            }
        }
    }

    /// Warms catalogue metadata + album cover for the next queue track.
    private func prefetchNextMetadata(after videoId: String) async {
        let queue = await MainActor.run { NowPlaying.shared.queueSongs }
        guard let index = queue.firstIndex(where: { $0.videoId == videoId }),
              queue.indices.contains(index + 1) else { return }
        let next = queue[index + 1]
        guard !MusicPlaybackIdentity.isExternal(next.videoId) else { return }
        let artist = next.artists.first?.name ?? ""
        _ = await MetadataResolver.enrich(
            title: next.title,
            artist: artist,
            album: next.album,
            duration: next.duration
        )
        if let album = next.album, !album.isEmpty {
            _ = await AlbumCoverStore.shared.coverURL(album: album, artist: artist)
        }
    }

    /// Warms the next two queue tracks while the current one plays, so both
    /// start straight in the better source instead of waiting for the search.
    /// Runs off the play path, sequentially, with a longer budget for the cold
    /// addon lookups.
    private func prefetchUpcomingUpgrades(
        after videoId: String,
        count: Int = 2,
        refreshSoonExpiring: Bool = false
    ) async {
        let lossyOnly = addonPreference == nil && prefers320Lossy
        guard addonPreference != nil || lossyOnly else { return }
        let queue = await MainActor.run { NowPlaying.shared.queueSongs }
        guard let index = queue.firstIndex(where: { $0.videoId == videoId }) else { return }
        let upcoming = queue.dropFirst(index + 1).prefix(count).map(\.videoId)

        var targets: [String] = []
        for id in upcoming {
            guard !MusicPlaybackIdentity.isExternal(id) else { continue }
            if let cached = upgradeResultCache[id] {
                let maxAge = refreshSoonExpiring ? 90 : upgradeTTL(for: cached.result)
                if Date().timeIntervalSince(cached.at) < maxAge { continue }
            }
            guard upgradePrefetchInFlight.insert(id).inserted else { continue }
            targets.append(id)
        }

        for id in targets {
            guard !Task.isCancelled else { break }
            // The queue may have moved on while the previous track was warmed.
            let stillUpcoming = await MainActor.run { () -> Bool in
                guard let current = NowPlaying.shared.videoId,
                      let position = NowPlaying.shared.queueSongs.firstIndex(where: { $0.videoId == current }) else {
                    return false
                }
                return NowPlaying.shared.queueSongs
                    .dropFirst(position + 1)
                    .prefix(3)
                    .contains { $0.videoId == id }
            }
            guard stillUpcoming else { continue }
            await MainActor.run { SponsorBlockIntegration.shared.warm(for: id) }
            if addonPreference != nil {
                _ = await resolvePreferredUpgrade(
                    videoId: id,
                    budget: 30,
                    ignoreCache: refreshSoonExpiring
                )
            } else if let lossy = await resolveLossyBest(videoId: id) {
                if upgradeResultCache.count >= 100 {
                    upgradeResultCache.removeAll(keepingCapacity: true)
                }
                upgradeResultCache[id] = (lossy, Date())
            }
        }
        upgradePrefetchInFlight.subtract(targets)
    }

    private static func losslessLabel(_ result: PlaybackResult) -> String? {
        let mime = result.mimeType.lowercased()
        let quality = result.audioQuality.lowercased()
        if quality == "addon-hi-res" { return "FLAC · Hi-Res" }
        if quality == "addon-cd" { return "FLAC · CD" }
        if mime == "audio/flac" { return "FLAC" }
        if quality == "qobuz-cd" { return "FLAC · CD" }
        if quality.contains("hi-res") || quality.contains("hires") || quality.contains("24") {
            return "FLAC · Hi-Res"
        }
        if quality.contains("lossless") { return "FLAC" }
        return nil
    }

    /// Lossless always beats lossy. Between lossy sources, the higher bitrate
    /// wins; if YouTube's bitrate is unknown, prefer a known upgrade.
    private static func shouldPreferUpgrade(
        _ upgrade: PlaybackResult,
        over current: PlaybackResult
    ) -> Bool {
        if losslessLabel(upgrade) != nil { return true }
        if losslessLabel(current) != nil { return false }
        let upgradeRate = upgrade.bitrate
        let currentRate = current.bitrate
        if currentRate <= 0 { return upgradeRate > 0 }
        return upgradeRate > currentRate
    }

    /// Badge text is a tier, not a codec: Standard / High / Lossless.
    private static func qualityLabel(_ result: PlaybackResult) -> String? {
        if result.audioQuality.lowercased().contains("atmos") { return "Dolby Atmos" }
        if losslessLabel(result) != nil { return "Lossless" }
        if result.bitrate >= 160_000 { return "High" }
        if result.audioQuality.lowercased().contains("jiosaavn") { return "High" }
        return "Standard"
    }

    /// A catalogue search is not evidence that its first title hit is the
    /// requested recording. Missing artist or duration must fail closed.
    private static func bestCatalogMatch(
        _ tracks: [MusicCatalogTrack],
        title: String,
        artist: String,
        duration: Int
    ) -> MusicCatalogTrack? {
        tracks.first { track in
            TextMatch.verifiedAudioSource(
                wantedTitle: title,
                wantedArtist: artist,
                wantedDuration: duration > 0 ? duration : nil,
                candidateTitle: track.title,
                candidateArtist: track.artist,
                candidateDuration: track.durationSeconds
            )
        }
    }

    /// Plays a downloaded copy if one exists, no matter which source it came
    /// from. Returns nil when the track isn't available offline.
    private func playLocalFile(
        videoId: String,
        intentGeneration: Int
    ) async -> PlaybackResult? {
        guard await isCurrentIntent(intentGeneration) else { return nil }
        guard let localPath = await DownloadManager.shared.localURL(for: videoId) else { return nil }
        let isFLAC = localPath.pathExtension.lowercased() == "flac"
        let song = await MainActor.run { NowPlaying.shared.queueSongs.first { $0.videoId == videoId } }
        await PlayerController.shared.play(
            url: localPath.absoluteString,
            title: song?.title,
            artist: song?.artists.map(\.name).joined(separator: ", "),
            videoId: videoId,
            duration: song.map { TimeInterval($0.duration) },
            artists: song?.artists ?? [],
            thumbnailUrl: song?.thumbnailUrl,
            losslessLabel: isFLAC ? "FLAC" : nil,
            qualityLabel: isFLAC ? "Lossless" : "Standard",
            intentGeneration: intentGeneration,
            sourceMIMEType: isFLAC ? "audio/flac" : "audio/mp4"
        )
        if await isCurrentIntent(intentGeneration) {
            await MainActor.run {
                NowPlaying.shared.currentSourceName = "Downloaded"
                NowPlaying.shared.updateVideoAvailability()
            }
        }
        let localResult = PlaybackResult(
            streamUrl: localPath.absoluteString,
            itag: 0,
            mimeType: isFLAC ? "audio/flac" : "audio/mp4",
            bitrate: 0,
            audioQuality: "local",
            videoId: videoId,
            title: song?.title,
            author: song?.artists.map(\.name).joined(separator: ", "),
            duration: song?.duration,
            expiresInSeconds: Int.max,
            clientName: "local",
            musicVideoType: nil,
            hasVideoContent: false,
            muxedStreamUrl: nil,
            loudnessDb: nil
        )
        if await isCurrentIntent(intentGeneration) {
            await MainActor.run {
                NowPlaying.shared.currentResult = localResult
            }
        }
        return localResult
    }

    /// Resolve a video and start playback. Returns the result used, or throws.
    @discardableResult
    func resolveAndPlay(
        videoId: String,
        intent: Int? = nil
    ) async throws -> PlaybackResult {
        let intentGeneration = await MainActor.run {
            intent ?? NowPlaying.shared.playbackGeneration
        }
        Log.player.info(
            "PLAY_INTENT begin gen=\(intentGeneration) videoId=\(videoId)"
        )
        guard await isCurrentIntent(intentGeneration) else {
            Log.player.info(
                "PLAY_INTENT drop gen=\(intentGeneration) videoId=\(videoId)"
            )
            throw CancellationError()
        }
        // Metadata already switched; stop the previous track so its audio
        // doesn't keep playing while the new stream resolves.
        let previous = await MainActor.run { PlayerController.shared.currentVideoId }
        let isPlaying = await MainActor.run { NowPlaying.shared.isPlaying }
        if isPlaying, let previous, previous != videoId {
            await PlayerController.shared.fadeVolume(to: 0, duration: 0.12)
            await MainActor.run { PlayerController.shared.setPaused(true) }
            await MainActor.run { PlayerController.shared.setVolumeOverride(nil) }
        }
        // Downloaded files win over every network source, including add-ons:
        // an add-on track saved for offline use must play without the addon.
        if let local = await playLocalFile(
            videoId: videoId,
            intentGeneration: intentGeneration
        ) {
            scheduleUpgradePrefetch(videoId: videoId)
            return local
        }
        guard await isCurrentIntent(intentGeneration) else {
            Log.player.info(
                "PLAY_INTENT drop after local gen=\(intentGeneration) videoId=\(videoId)"
            )
            throw CancellationError()
        }
        // Podcasts are finite audio, not music recordings. They must not
        // enter add-on FLAC/Atmos matching, JioSaavn music fallback or album
        // video/audio rematching, even when the music beta is enabled.
        if let episode = await queueSong(for: videoId),
           episode.contentKind == .episode || episode.contentKind == .podcast {
            var request = StreamResolveRequest.playback(videoId: videoId)
            request.options.audioQuality = SettingsStore.shared.audioQuality
            let result = try await StreamFallback.resolveFirstValid(
                request,
                using: InnerTubeClient.tropShared,
                providers: .tropLive
            )
            guard await isCurrentIntent(intentGeneration) else {
                throw CancellationError()
            }
            return await playNetworkResult(
                result, videoId: videoId, intentGeneration: intentGeneration
            )
        }
        if MusicPlaybackIdentity.isLegacyPencari(videoId) {
            let result = try await resolveLegacyPencari(videoId: videoId)
            await playNetworkResult(result, videoId: videoId, intentGeneration: intentGeneration)
            scheduleUpgradePrefetch(videoId: videoId)
            return result
        }
        if MusicPlaybackIdentity.isExternal(videoId) {
            let result: PlaybackResult
            if MusicPlaybackIdentity.isQobuz(videoId) {
                result = try await resolveQobuz(videoId: videoId)
            } else if MusicPlaybackIdentity.isJioSaavn(videoId) {
                result = try await resolveJioSaavn(videoId: videoId)
            } else if MusicPlaybackIdentity.isAddon(videoId) {
                result = try await resolveAddon(videoId: videoId)
            } else {
                result = try await resolveAudius(videoId: videoId)
            }
            let song = await queueSong(for: videoId)
            guard await isCurrentIntent(intentGeneration) else { return result }
            await PlayerController.shared.play(
                url: result.streamUrl,
                title: song?.title,
                artist: song?.artistNamesDisplay,
                videoId: videoId,
                duration: song.map { TimeInterval($0.duration) },
                artists: song?.artists ?? [],
                thumbnailUrl: song?.thumbnailUrl,
                losslessLabel: Self.losslessLabel(result),
                qualityLabel: Self.qualityLabel(result),
                intentGeneration: intentGeneration,
                sourceMIMEType: result.mimeType,
                isAtmos: result.audioQuality.lowercased().contains("atmos")
            )
            let externalSourceName = sourceName(for: result, videoId: videoId)
            if await isCurrentIntent(intentGeneration) {
                await MainActor.run {
                    NowPlaying.shared.currentSourceName = externalSourceName
                    NowPlaying.shared.currentResult = result
                }
            }
            scheduleUpgradePrefetch(videoId: videoId)
            return result
        }
        await MainActor.run { SponsorBlockIntegration.shared.warm(for: videoId) }

        // A prefetched lossless/high stream means the track can start right in
        // the better source instead of resolving YouTube first.
        if let cached = cachedUpgrade(videoId: videoId) {
            let upgrade = cached.result
            // Prefetch already verified a fresh URL; skipping the extra Range
            // request removes the startup delay on cached lossless.
            var usable = cached.age < 90
            if !usable { usable = await Self.verifyStream(upgrade.streamUrl) }
            if usable {
                await playNetworkResult(upgrade, videoId: videoId, intentGeneration: intentGeneration)
                scheduleUpgradePrefetch(videoId: videoId)
                return upgrade
            }
            upgradeResultCache[videoId] = nil
        }

        // Off (or no add-on FLAC): Auto/High start straight in the lossy pool
        // (JioSaavn / AAC 320) instead of YouTube.
        if addonPreference == nil, prefers320Lossy,
           let lossy = await resolveLossyBest(videoId: videoId) {
            if upgradeResultCache.count >= 100 {
                upgradeResultCache.removeAll(keepingCapacity: true)
            }
            upgradeResultCache[videoId] = (lossy, Date())
            await playNetworkResult(lossy, videoId: videoId, intentGeneration: intentGeneration)
            scheduleUpgradePrefetch(videoId: videoId)
            return lossy
        }

        if let cached = await StreamCache.shared.get(videoId: videoId) {
            // A prefetched upgrade can still be better than the cached stream.
            if let upgrade = prefetchedUpgrade(videoId: videoId),
               Self.shouldPreferUpgrade(upgrade, over: cached) {
                if await Self.verifyStream(upgrade.streamUrl) {
                    await playNetworkResult(upgrade, videoId: videoId, intentGeneration: intentGeneration)
                    scheduleUpgradePrefetch(videoId: videoId)
                    return upgrade
                }
                upgradeResultCache[videoId] = nil
            }
            // Cache can hold the video's transport response; still apply
            // album-audio verification when the selected row is a song.
            let played = await playNetworkResult(
                cached, videoId: videoId, intentGeneration: intentGeneration
            )
            scheduleUpgradePrefetch(videoId: videoId)
            return played
        }

        let key = playKey(
            videoId: videoId,
            intentGeneration: intentGeneration
        )
        if let existing = inflightResolutions[key] {
            return try await existing.value
        }

        let task = Task { [self] in
            do {
                return try await resolveAndPlayFromNetwork(
                    videoId: videoId,
                    intentGeneration: intentGeneration
                )
            } catch {
                // YouTube has no stream: JioSaavn/AAC can still cover it, even
                // in Standard/Low (only when YouTube failed).
                if self.lossySourcesAllowed,
                   let lossy = await self.resolveLossyBest(videoId: videoId) {
                    if self.upgradeResultCache.count >= 100 {
                        self.upgradeResultCache.removeAll(keepingCapacity: true)
                    }
                    self.upgradeResultCache[videoId] = (lossy, Date())
                    await self.playNetworkResult(lossy, videoId: videoId, intentGeneration: intentGeneration)
                    self.scheduleUpgradePrefetch(videoId: videoId)
                    return lossy
                }
                throw error
            }
        }
        inflightResolutions[key] = task
        defer { clearInflight(key: key) }
        return try await task.value
    }

    /// Runs the client fallback chain for playback. Only called once per
    /// videoId by `resolveAndPlay`, which owns the in-flight dedup entry.
    private func resolveAndPlayFromNetwork(
        videoId: String,
        intentGeneration: Int
    ) async throws -> PlaybackResult {
        var request = StreamResolveRequest.playback(videoId: videoId)
        request.options.audioQuality = SettingsStore.shared.audioQuality
        let result = try await StreamFallback.resolveFirstValid(
            request,
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        )
        // If a better source was prefetched, use whichever is higher quality.
        // Lossless always wins; otherwise compare bitrate. The prefetched
        // result is local, so this comparison adds no wait.
        if let upgrade = prefetchedUpgrade(videoId: videoId),
           Self.shouldPreferUpgrade(upgrade, over: result) {
            if await Self.verifyStream(upgrade.streamUrl) {
                await playNetworkResult(upgrade, videoId: videoId, intentGeneration: intentGeneration)
                scheduleUpgradePrefetch(videoId: videoId)
                return upgrade
            }
            // Dead cached URL (origin rotated/expired): drop it, use YouTube.
            upgradeResultCache[videoId] = nil
        }
        let played = await playNetworkResult(
            result, videoId: videoId, intentGeneration: intentGeneration
        )
        // Warm this track (for replays) and the next two while it plays. Off
        // the play path: never delays audio.
        scheduleUpgradePrefetch(videoId: videoId)
        return played
    }

    private func addonName(for key: String) async -> String? {
        await MainActor.run { MusicAddonsStore.shared.installation(key: key)?.manifest.name }
    }

    private func sourceName(for result: PlaybackResult, videoId: String) -> String {
        // Only credit the add-on when the stream that is actually playing came
        // from it; a cached prefetch name must not mislabel a YouTube stream.
        if result.clientName.lowercased() == "addon",
           let addon = resolvedSourceNames[videoId] {
            return addon
        }
        switch result.clientName.lowercased() {
        case "local": return "Downloaded"
        case "jiosaavn": return "JioSaavn"
        case "qobuz": return "Qobuz"
        case "audius": return "Audius"
        case "addon": return "Add-on"
        default: return "YouTube"
        }
    }

    /// When an old/ambiguous song entry resolves to a YouTube music VIDEO,
    /// look for an independently typed ATV album audio track. A video's
    /// audio-bearing stream is still the video's mix; codec selection alone
    /// cannot turn it into the album master.
    private func albumAudioVersion(
        of result: PlaybackResult,
        for videoId: String,
        song: SongItem?,
        intentGeneration: Int
    ) async -> PlaybackResult {
        guard MusicPlaybackIdentity.isYouTube(videoId),
              result.videoId == videoId,
              let song,
              song.contentKind != .episode,
              song.contentKind != .podcast,
              !["addon", "jiosaavn", "qobuz", "audius", "local"].contains(
                  result.clientName.lowercased()
              ),
              MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
                  selectedVideo: song.recordingPreference == .musicVideo,
                  rowType: song.musicVideoType,
                  sourceType: result.musicVideoType,
                  rowIsVideo: song.isVideo == true,
                  albumKnown: !(song.album ?? "").isEmpty || song.albumId != nil,
                  expectedDuration: song.duration,
                  resolvedDuration: result.duration ?? 0
              ),
              let artist = song.artists.first?.name,
              !artist.isEmpty
        else { return result }

        let candidateID: String?
        if let cached = albumAudioMatchCache[videoId],
           Date().timeIntervalSince(cached.at) < (cached.videoId == nil ? 600 : 3_600) {
            candidateID = cached.videoId
        } else {
            let query = "\(artist) \(song.title)"
            let found: String?
            do {
                let data = try await InnerTubeClient.tropShared.search(
                    query: query, client: .webRemix
                )
                guard await isCurrentIntent(intentGeneration) else { return result }
                let parsed = SearchParser.parseSearchResults(from: data.value)
                let candidates = parsed.flatMap(\.items).compactMap { item -> SongItem? in
                    if case .song(let song) = item { return song }
                    return nil
                }
                let valid = candidates.filter { candidate in
                    candidate.videoId != videoId
                        && MusicRecordingSelectionPolicy.verifiedAlbumAudio(
                            wanted: .init(
                                title: song.title,
                                artist: artist,
                                album: song.album,
                                duration: song.duration,
                                originalWasVideo: song.isMusicVideo
                                    || MusicRecordingSelectionPolicy.isVideoRecording(
                                        result.musicVideoType
                                    )
                            ),
                            candidate: .init(
                                title: candidate.title,
                                artists: candidate.artists.map(\.name),
                                album: candidate.album,
                                duration: candidate.duration,
                                type: candidate.musicVideoType
                            )
                        )
                }
                // De-duplicate top-card and shelf copies of the same ATV.
                // If no album metadata survives and distinct ATV releases
                // match, refuse an arbitrary selection: one might be a
                // clean/radio edit or an alternate official recording.
                let unique = Array(
                    Dictionary(valid.map { ($0.videoId, $0) },
                               uniquingKeysWith: { first, _ in first }).values
                )
                let releaseKeys = Set(unique.map {
                    TextMatch.normalize($0.album ?? "")
                })
                let ambiguous = (song.album ?? "").isEmpty
                    && unique.count > 1
                    && releaseKeys.count > 1
                // Prefer the same release first, then the closest duration.
                let sorted = unique.sorted { lhs, rhs in
                    let lhsAlbum = song.album != nil
                        && lhs.album != nil
                        && TextMatch.albumsMatch(lhs.album ?? "", song.album ?? "")
                    let rhsAlbum = song.album != nil
                        && rhs.album != nil
                        && TextMatch.albumsMatch(rhs.album ?? "", song.album ?? "")
                    if lhsAlbum != rhsAlbum { return lhsAlbum }
                    return abs(lhs.duration - song.duration)
                        < abs(rhs.duration - song.duration)
                }
                if ambiguous {
                    Log.player.info(
                        "MUSIC_MATCH ambiguous ATV candidates videoId=\(videoId) count=\(unique.count)"
                    )
                }
                found = ambiguous ? nil : sorted.first?.videoId
            } catch {
                // Search is optional. Network errors must not block music.
                return result
            }
            if albumAudioMatchCache.count >= 100 {
                albumAudioMatchCache.removeAll(keepingCapacity: true)
            }
            albumAudioMatchCache[videoId] = (found, Date())
            candidateID = found
        }

        guard let candidateID, await isCurrentIntent(intentGeneration) else {
            let preference = String(describing: song.recordingPreference)
            let rowType = song.musicVideoType ?? "unknown"
            let streamType = result.musicVideoType ?? "unknown"
            let duration = result.duration ?? 0
            Log.player.info(
                "MUSIC_MATCH no verified ATV source for selected=\(videoId) preference=\(preference) rowType=\(rowType) streamType=\(streamType) duration=\(duration)"
            )
            return result
        }
        var request = StreamResolveRequest.playback(videoId: candidateID)
        request.options.audioQuality = SettingsStore.shared.audioQuality
        guard let albumAudio = try? await StreamFallback.resolveFirstValid(
            request,
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        ), albumAudio.videoId == candidateID,
           !MusicRecordingSelectionPolicy.isVideoRecording(albumAudio.musicVideoType),
           await isCurrentIntent(intentGeneration)
        else { return result }

        Log.player.notice(
            "MUSIC_MATCH album audio selected original=\(videoId) audio=\(candidateID)"
        )
        return albumAudio
    }

    @discardableResult
    private func playNetworkResult(
        _ result: PlaybackResult,
        videoId: String,
        intentGeneration: Int
    ) async -> PlaybackResult {
        guard await isCurrentIntent(intentGeneration) else {
            Log.player.info(
                "PLAY_INTENT drop result gen=\(intentGeneration) videoId=\(videoId)"
            )
            return result
        }
        let queueSong = await queueSong(for: videoId)
        let audioResult = await albumAudioVersion(
            of: result,
            for: videoId,
            song: queueSong,
            intentGeneration: intentGeneration
        )
        guard await isCurrentIntent(intentGeneration) else { return result }
        let queueArtistName = queueSong.map { artistDisplayString(from: $0.artists) } ?? ""
        let fallbackAuthor = result.author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artistName = !queueArtistName.isEmpty ? queueArtistName : fallbackAuthor
        let rawTitle = queueSong?.title ?? result.title ?? ""
        await PlayerController.shared.play(
            url: audioResult.streamUrl,
            title: cleanedTitle(rawTitle, artist: artistName),
            artist: artistName,
            videoId: videoId,
            duration: audioResult.duration.flatMap {
                $0 > 0 ? TimeInterval($0) : nil
            } ?? queueSong.flatMap { $0.duration > 0
                ? TimeInterval($0.duration) : nil
            },
            artists: queueSong?.artists ?? [],
            loudnessDb: audioResult.loudnessDb,
            thumbnailUrl: queueSong?.thumbnailUrl,
            losslessLabel: Self.losslessLabel(audioResult),
            qualityLabel: Self.qualityLabel(audioResult),
            intentGeneration: intentGeneration,
            sourceMIMEType: audioResult.mimeType,
            isAtmos: audioResult.audioQuality.lowercased().contains("atmos"),
            bypassSponsorBlock: audioResult.videoId != videoId
                || queueSong?.contentKind == .episode
                || queueSong?.contentKind == .podcast
        )
        let sourceName = sourceName(for: audioResult, videoId: videoId)
        if await isCurrentIntent(intentGeneration) {
            await MainActor.run {
                NowPlaying.shared.currentSourceName = sourceName
                NowPlaying.shared.currentResult = audioResult
            }
        }
        await publishVideoAvailability(
            // Video mode still belongs to the user's original YouTube ID.
            // Only the audio stream is substituted with its album recording.
            result: result,
            videoId: videoId,
            rowType: queueSong?.musicVideoType,
            intentGeneration: intentGeneration
        )
        return audioResult
    }

    private func clearInflight(key: String) {
        inflightResolutions.removeValue(forKey: key)
    }

    /// Queue song for resolve-time metadata (artists, artwork, video type).
    /// One MainActor hop instead of one per field, so the snapshot is
    /// consistent even if the queue changes mid-resolve.
    /// Strips a leading/trailing "Artist - " that YouTube titles often carry so
    /// the player shows just the song name.
    private func cleanedTitle(_ title: String, artist: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return text }
        let lower = text.lowercased()
        let suffix = " - \(name)".lowercased()
        let prefix = "\(name) - ".lowercased()
        if lower.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        } else if lower.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func queueSong(for videoId: String) async -> SongItem? {
        await MainActor.run {
            NowPlaying.shared.queueSongs.first { $0.videoId == videoId }
        }
    }

    /// Publishes video availability for a resolve result. The row type wins
    /// (resolve responses often omit it); unknown rows fall back to an
    /// authoritative lookup inside the shared availability check.
    private func publishVideoAvailability(
        result: PlaybackResult,
        videoId: String,
        rowType: String?,
        intentGeneration: Int
    ) async {
        guard await isCurrentIntent(intentGeneration) else { return }
        let type = result.musicVideoType ?? rowType
        let hasVideo = await VideoAvailability.shared.hasVideo(
            videoId: videoId, rowType: rowType, result: result, using: InnerTubeClient.tropShared
        )
        await MainActor.run {
            guard NowPlaying.shared.playbackGeneration == intentGeneration else { return }
            NowPlaying.shared.updateVideoAvailability(musicVideoType: type, hasVideo: hasVideo)
        }
    }

    /// Resolves a playable video stream URL for video mode. Prefers a muxed
    /// (audio+video) stream; when the video offers none, falls back to an EDL
    /// that combines a DASH video-only stream with a separate audio stream.
    func resolveVideoStream(videoId: String) async throws -> String {
        var request = StreamResolveRequest(videoId: videoId)
        request.options.audioQuality = SettingsStore.shared.audioQuality
        switch try await StreamFallback.resolveVideo(
            request,
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        ) {
        case .muxed(let url):
            return url
        case .split(let videoURL, let audioURL, let duration):
            return StreamFallback.combineVideoAndAudio(
                videoURL: videoURL,
                audioURL: audioURL,
                duration: duration
            )
        case .hls(let url):
            return url
        }
    }

    /// Returns the muxed/video stream URL for video mode, preferring the cached one.
    func resolveMuxedURL(videoId: String) async throws -> String {
        if let cached = await StreamCache.shared.get(videoId: videoId),
           let muxed = cached.muxedStreamUrl {
            return muxed
        }
        return try await resolveVideoStream(videoId: videoId)
    }

    func resolveVideoOnlyURL(videoId: String) async throws -> String {
        let request = StreamResolveRequest(videoId: videoId)
        switch try await StreamFallback.resolveVideo(
            request,
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        ) {
        case .muxed(let url):
            return url
        case .split(let videoURL, _, _):
            return videoURL
        case .hls(let url):
            return url
        }
    }

    /// Stable per-launch session id for PoToken minting.
    static let sessionId: String = UUID().uuidString
    /// Resolve a video without playing. Useful for previews / testing.
    func resolve(
        videoId: String,
        preferredFormat: Format? = nil,
        forDownload: Bool = false,
        downloadQuality: DownloadQuality? = nil,
        song: SongItem? = nil
    ) async throws -> PlaybackResult {
        if MusicPlaybackIdentity.isLegacyPencari(videoId) {
            return try await resolveLegacyPencari(videoId: videoId, song: song)
        }
        if MusicPlaybackIdentity.isExternal(videoId) {
            // Every external resolver returns a direct stream URL, so all of
            // them can also be saved for offline playback.
            if MusicPlaybackIdentity.isQobuz(videoId) {
                return try await resolveQobuz(videoId: videoId, song: song)
            }
            if MusicPlaybackIdentity.isJioSaavn(videoId) {
                return try await resolveJioSaavn(videoId: videoId, song: song)
            }
            if MusicPlaybackIdentity.isAddon(videoId) {
                return try await resolveAddon(videoId: videoId, song: song)
            }
            return try await resolveAudius(videoId: videoId, song: song)
        }
        if !forDownload, let cached = await StreamCache.shared.get(videoId: videoId) {
            return cached
        }

        var quality = downloadQuality ?? SettingsStore.shared.downloadQuality
        // `.lossless` is for provider downloads (handled before this point);
        // YouTube itself must still resolve a lossy format.
        if quality == .lossless { quality = .high }
        let key = resolutionKey(videoId: videoId, forDownload: forDownload)
            + (forDownload ? ":\(quality.rawValue)" : "")
        if let existing = inflightResolutions[key] {
            return try await existing.value
        }

        let task = Task { [self] in
            try await resolveFromNetwork(videoId: videoId, preferredFormat: preferredFormat, forDownload: forDownload, downloadQuality: quality)
        }
        inflightResolutions[key] = task
        defer { clearInflight(key: key) }
        return try await task.value
    }

    private func resolveFromNetwork(videoId: String, preferredFormat: Format?, forDownload: Bool, downloadQuality: DownloadQuality) async throws -> PlaybackResult {
        var request = forDownload ? StreamResolveRequest.download(videoId: videoId) : .playback(videoId: videoId)
        request.options.preferredFormat = preferredFormat
        request.options.audioQuality = SettingsStore.shared.audioQuality
        request.options.downloadQuality = downloadQuality
        return try await StreamFallback.resolveFirstValid(
            request,
            using: InnerTubeClient.tropShared,
            providers: .tropLive
        )
    }
}
