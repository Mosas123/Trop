//
//  NowPlaying.swift
//  Trop
//
//  Created by 686udjie on 2/07/2026.
//

import AVFoundation
import Foundation
import Observation
import Nuke
import SwiftUI
import UIKit

/// The song currently playing on a radio stream (from ICY metadata), enriched
/// with canonical metadata and artwork when available.
struct LiveSongInfo: Equatable {
    var title: String
    var artist: String
    var album: String?
    var artwork: Data?
}

/// Last known position while a failed network stream is being re-resolved.
private struct InterruptedPlaybackPosition {
    let videoId: String
    let position: TimeInterval
    let expiresAt: Date
}

/// What is currently playing, used to route metadata and label the UI.
enum PlaybackKind: Sendable {
    case music
    case podcast
    case radio
}

/// Real-time station state, independent of finite song progress or mpv/Apolo.
enum RadioPlaybackStatus: Equatable, Sendable {
    case connecting
    case live
    case reconnecting
    case paused
    case unavailable

    var label: String {
        switch self {
        case .connecting: "Connecting…"
        case .live: "LIVE"
        case .reconnecting: "Reconnecting…"
        case .paused: "Paused"
        case .unavailable: "Unavailable"
        }
    }
}

/// Display metadata for one playback identity. Original SongItem artist/album
/// IDs remain untouched and continue to be used for navigation.
struct PlaybackMetadataSnapshot: Sendable {
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    let artworkURL: String?
    let source: String?
}

@MainActor
@Observable
final class NowPlaying {
    static let shared = NowPlaying()
    /// Synchronous radio streams use a synthetic `radio:<uuid>` video id.
    static let radioPrefix = "radio:"

    var title = ""
    var artist = ""
    /// For internet radio: the song currently playing on the station (ICY title).
    var liveTitle: String?
    /// Shows an honest connection state instead of a fake 0:00 song progress.
    var radioPlaybackStatus: RadioPlaybackStatus = .connecting
    /// Enriched live radio song (parsed + album/artwork from a catalogue).
    var liveSongInfo: LiveSongInfo?
    var albumTitle = ""
    var videoId: String?
    var artists: [YTArtist] = []
    private var confirmedMetadata: (videoId: String, value: ResolvedMetadata)?
    private var publishedArtwork: (videoId: String, url: String)?
    private var displayedArtworkVideoId: String?
    var isPlaying = false
    /// Displays the actual engine, including automatic beta fallback.
    var activePlaybackEngine = "MPVKit"
    /// True while the current stream is lossless (FLAC / Qobuz CD). Drives the
    /// player's "Lossless" badge.
    var isLosslessStream = false
    /// Codec/quality label for the badge, e.g. "FLAC" or "FLAC · CD".
    var losslessFormatLabel: String?
    /// Detected quality of whatever is currently playing (tier label).
    var qualityBadgeLabel: String?
    /// True while a better source is being resolved for the current track.
    var isUpgradingQuality = false
    /// Current stream URL + lossless label, kept to roll back a failed upgrade.
    var currentStreamURL: String?
    var currentLosslessLabel: String?
    /// Human name of the source currently feeding the player (add-on name,
    /// "Qobuz", "Downloaded"…), used by the details sheet.
    var currentSourceName: String?
    /// The stream actually playing, so details never show a stale cached one.
    var currentResult: PlaybackResult?
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var progress: Float {
        duration > 0 ? Float(currentTime / duration) : 0
    }
    var thumbnailImage: Image?
    var thumbnailUIImage: UIImage?
    var thumbnailVersion = 0
    var dominantColors: [Color] = [Color(red: 0.15, green: 0.15, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.08)]

    var accentColor: Color? {
        guard videoId != nil, let primary = dominantColors.first else { return nil }
        return primary
    }

    var queueSongs: [SongItem] = []
    var queueIndex = 0

    var isShuffleOn = false
    var isRepeatOn = false

    var hasVideo: Bool = false
    var isVideoMode: Bool = false
    var isVideoReady: Bool = false
    var musicVideoType: String?

    /// True while the queue is an AI "Surprise me" session; the AI refills the
    /// queue when it runs out so it keeps suggesting on its own.
    var isSurpriseSession = false

    private var originalQueue: [SongItem]?

    var hasNext: Bool {
        queueIndex + 1 < queueSongs.count
    }

    var hasPrevious: Bool {
        queueIndex > 0
    }

    var isBarPresented: Bool {
        videoId != nil
    }

    /// Whether the current playback is music, a podcast, or internet radio.
    var playbackKind: PlaybackKind {
        if videoId?.hasPrefix(Self.radioPrefix) == true { return .radio }
        if queueSongs.indices.contains(queueIndex) {
            let kind = queueSongs[queueIndex].contentKind
            if kind == .episode || kind == .podcast { return .podcast }
        }
        return .music
    }

    private var timer: Timer?
    private var icyTick = 0
    private var progressTick = 0
    /// Bumped whenever the user starts/changes playback, so deferred autoplay
    /// work can abort instead of hijacking the new track.
    private(set) var playbackGeneration = 0
    var sleepTimerEndsAt: Date?
    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?
    @ObservationIgnored private var artworkLoadTask: Task<Void, Never>?
    @ObservationIgnored private var enrichTask: Task<Void, Never>?
    @ObservationIgnored private var liveResolveTask: Task<Void, Never>?
    @ObservationIgnored private var radioMetadataTask: Task<Void, Never>?
    @ObservationIgnored private var radioArtworkTask: Task<Void, Never>?
    @ObservationIgnored private var lastRadioMetadataFetch = Date.distantPast
    @ObservationIgnored private var radioMetadataFailures = 0
    @ObservationIgnored private var radioMetadataCooldownUntil: Date?
    @ObservationIgnored private var lastRadioArtworkKey: String?
    var lastManualSkipTime: Date?
    private var isResolvingNext = false
    private var consecutiveFailures = 0
    private static let maxConsecutiveFailures = 3
    /// Timestamps of the last mid-play failure per videoId, to bound retries.
    private var lastFailureAt: [String: Date] = [:]

    private static let queueKey = "nowPlaying.queue"
    private static let positionKey = "nowPlaying.lastPosition"
    private var pendingResumePosition: TimeInterval?
    private var pendingResumeAt: Date?
    /// Short-lived position from a failed Apolo stream, used only if a fresh
    /// resolution for the same track is needed after the mpv fallback.
    @ObservationIgnored private var interruptedPlayback: InterruptedPlaybackPosition?
    /// An episode resume request is tied to the queue intent, not a fixed
    /// timer or the player ID (which is assigned before audio is ready).
    private var requestedPodcastResume: (videoId: String, generation: Int, position: TimeInterval)?
    private static let queueIndexKey = "nowPlaying.queueIndex"
    private static let shuffleKey = "nowPlaying.shuffle"
    private static let repeatKey = "nowPlaying.repeat"
    /// Last queue snapshot encoded to disk; lets `persistQueueState` skip the
    /// JSON encode when only index/shuffle/repeat changed.
    private var lastPersistedQueue: [SongItem]?

    private init() {
        restoreQueueIfNeeded()
    }

    deinit {
        Task { @MainActor [weak self] in self?.stopTimer() }
    }

    // MARK: - Persistent queue

    /// Keep the last audible position across an Apolo -> mpv -> re-resolve
    /// recovery, without allowing it to resume a different song or a later
    /// user-initiated play.
    func rememberInterruptedPlayback(_ position: TimeInterval, for videoId: String?) {
        guard let videoId, self.videoId == videoId,
              position.isFinite, position > 1 else { return }
        interruptedPlayback = InterruptedPlaybackPosition(
            videoId: videoId,
            position: position,
            expiresAt: Date().addingTimeInterval(45)
        )
    }

    /// Save a podcast's persisted position while the correct episode is
    /// selected. It will be consumed only at the next actual source load,
    /// before either Apolo or MPVKit starts playback.
    func requestPodcastResumePosition(_ position: TimeInterval, for videoId: String) {
        guard self.videoId == videoId, playbackKind == .podcast,
              position.isFinite, position > 10,
              (duration <= 0 || position < duration - 5) else { return }
        requestedPodcastResume = (
            videoId: videoId, generation: playbackGeneration, position: position
        )
    }

    /// Consumes a transient recovery position or the saved launch position.
    func takeResumePosition(for videoId: String?) -> TimeInterval? {
        guard let videoId, videoId == self.videoId else { return nil }
        if let request = requestedPodcastResume,
           request.videoId == videoId,
           request.generation == playbackGeneration {
            requestedPodcastResume = nil
            return request.position
        }
        if let recovery = interruptedPlayback, recovery.videoId == videoId {
            interruptedPlayback = nil
            if recovery.expiresAt > Date() { return recovery.position }
        }
        guard let position = pendingResumePosition,
              let savedAt = pendingResumeAt,
              Date().timeIntervalSince(savedAt) < 86_400 else { return nil }
        pendingResumePosition = nil
        pendingResumeAt = nil
        return position
    }

    private func restoreQueueIfNeeded() {
        guard SettingsStore.shared.persistQueue,
              let data = UserDefaults.standard.data(forKey: Self.queueKey),
              let songs = try? JSONDecoder().decode([SongItem].self, from: data),
              !songs.isEmpty else { return }
        queueSongs = songs
        // integer(forKey:) returns 0 even when key missing – distinguish via object(forKey:)
        let storedIndex: Int
        if UserDefaults.standard.object(forKey: Self.queueIndexKey) != nil {
            storedIndex = UserDefaults.standard.integer(forKey: Self.queueIndexKey)
        } else {
            storedIndex = 0
        }
        queueIndex = min(max(storedIndex, 0), songs.count - 1)
        isShuffleOn = UserDefaults.standard.bool(forKey: Self.shuffleKey)
        isRepeatOn = UserDefaults.standard.bool(forKey: Self.repeatKey)
        queueIndex = max(0, queueIndex)
        lastPersistedQueue = songs
        if let saved = UserDefaults.standard.dictionary(forKey: Self.positionKey),
           let savedId = saved["videoId"] as? String,
           let position = saved["position"] as? Double,
           let at = saved["at"] as? Double,
           queueSongs.indices.contains(queueIndex),
           queueSongs[queueIndex].videoId == savedId,
           Date().timeIntervalSince1970 - at < 86_400 {
            pendingResumePosition = position
            pendingResumeAt = Date(timeIntervalSince1970: at)
            currentTime = position
        }
    }

    func persistQueueState() {
        guard SettingsStore.shared.persistQueue else { return }
        if queueSongs.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.queueKey)
            UserDefaults.standard.removeObject(forKey: Self.queueIndexKey)
            UserDefaults.standard.removeObject(forKey: Self.shuffleKey)
            UserDefaults.standard.removeObject(forKey: Self.repeatKey)
            lastPersistedQueue = []
            return
        }
        // Only re-encode the (potentially large) array when it actually changed.
        if queueSongs != lastPersistedQueue {
            if let data = try? JSONEncoder().encode(queueSongs) {
                UserDefaults.standard.set(data, forKey: Self.queueKey)
                lastPersistedQueue = queueSongs
            }
        }
        UserDefaults.standard.set(queueIndex, forKey: Self.queueIndexKey)
        UserDefaults.standard.set(isShuffleOn, forKey: Self.shuffleKey)
        UserDefaults.standard.set(isRepeatOn, forKey: Self.repeatKey)
    }

    func setQueue(_ songs: [SongItem], startIndex: Int) {
        playbackGeneration += 1
        // A brand-new queue supersedes any in-flight next-track resolution.
        // Its old task must not leave the new queue permanently locked.
        isResolvingNext = false
        queueSongs = songs
        queueIndex = min(max(startIndex, 0), max(songs.count - 1, 0))
        originalQueue = nil
        isShuffleOn = false
        persistQueueState()
        queueDidChange()
    }

    /// Posted after any queue mutation so playback can warm the new next songs.
    func queueDidChange() {
        NotificationCenter.default.post(name: .tropQueueChanged, object: nil)
    }

    /// Ensures `queueIndex` points at a valid entry
    func repairQueueIndex() {
        if queueSongs.isEmpty {
            queueIndex = 0
            return
        }
        if let videoId, let idx = queueSongs.firstIndex(where: { $0.videoId == videoId }) {
            queueIndex = idx
        } else {
            queueIndex = min(max(queueIndex, 0), queueSongs.count - 1)
        }
    }

    func upcomingSongs(prefixLimit: Int? = nil) -> [SongItem] {
        let next = queueIndex + 1
        guard queueSongs.indices.contains(next) else { return [] }
        let rest = Array(queueSongs[next...])
        guard let prefixLimit else { return rest }
        return Array(rest.prefix(prefixLimit))
    }

    /// Shuffles upcoming songs, keeping the current one; tapping again re-shuffles.
    func shuffleQueue() {
        guard queueSongs.count > 1 else {
            isShuffleOn = true
            return
        }
        if originalQueue == nil {
            originalQueue = queueSongs
        }
        guard queueSongs.indices.contains(queueIndex) else { return }
        let prefix = queueIndex > 0 ? Array(queueSongs[0..<queueIndex]) : []
        let current = queueSongs[queueIndex]
        var rest = queueIndex + 1 < queueSongs.count ? Array(queueSongs[(queueIndex + 1)...]) : []
        rest.shuffle()
        queueSongs = prefix + [current] + rest
        queueIndex = prefix.count
        isShuffleOn = true
        persistQueueState()
        queueDidChange()
    }

    /// Restore the original (unshuffled) queue order.
    func disableShuffle() {
        guard queueSongs.indices.contains(queueIndex) else { return }
        if let orig = originalQueue {
            let currentVideoId = queueSongs[queueIndex].videoId
            queueSongs = orig
            // The shuffled index is meaningless against the original array
            // (radio appends, deletes and reorders change lengths).
            let restored = orig.firstIndex(where: { $0.videoId == currentVideoId }) ?? queueIndex
            queueIndex = min(restored, max(orig.count - 1, 0))
        }
        originalQueue = nil
        isShuffleOn = false
        persistQueueState()
        queueDidChange()
    }

    func moveQueueSongs(from source: IndexSet, to destination: Int) {
        guard !source.isEmpty, queueSongs.indices.contains(source.first ?? -1) else { return }
        queueSongs.move(fromOffsets: source, toOffset: destination)
        repairQueueIndex()
        persistQueueState()
        queueDidChange()
    }

    func repeatCurrent() {
        guard queueSongs.indices.contains(queueIndex) else { return }
        playCurrentSong(logContext: "repeatCurrent") {
            self.isRepeatOn = false
        }
    }

    func playNext(automatic: Bool = false) {
        guard hasNext else { return }
        guard !isResolvingNext else { return }
        if !automatic {
            lastManualSkipTime = Date()
            let progress = duration > 0 ? currentTime / duration : 0
            if progress < 0.5 {
                TasteProfileStore.shared.recordSkip(artist: artist)
            }
        }
        queueIndex += 1
        playCurrentSong(logContext: "playNext")
    }

    func playPrevious() {
        guard hasPrevious else { return }
        guard !isResolvingNext else { return }
        lastManualSkipTime = Date()
        queueIndex -= 1
        playCurrentSong(logContext: "playPrevious")
    }

    /// Starts the song at `queueIndex`: pushes metadata, persists the queue,
    /// and resolves the stream, clearing `isResolvingNext` afterwards.
    /// Shared by repeatCurrent/playNext/playPrevious and QueueView playback.
    func playCurrentSong(
        logContext: String,
        manageResolvingFlag: Bool = true,
        afterResolve: (() -> Void)? = nil
    ) {
        guard queueSongs.indices.contains(queueIndex) else { return }
        playbackGeneration += 1
        let intent = playbackGeneration
        if manageResolvingFlag {
            isResolvingNext = true
        }
        let song = queueSongs[queueIndex]
        update(with: song)
        persistQueueState()
        Task {
            var failed: Error?
            var wasCancelled = false
            do {
                try await PlaybackManager.shared.resolveAndPlay(
                    videoId: song.videoId,
                    intent: intent
                )
            } catch is CancellationError {
                wasCancelled = true
            } catch {
                failed = error
            }
            // A superseded resolver can finish after a different song starts.
            // Its result must NEVER clear that song's resolving flag, reset
            // failure counters or auto-advance the now-current queue.
            guard PlaybackIntentGuard.owns(
                expectedGeneration: intent,
                expectedVideoId: song.videoId,
                generation: self.playbackGeneration,
                videoId: self.videoId
            ) else {
                Log.nowPlaying.debug(
                    "PLAY_INTENT stale completion dropped context=\(logContext) videoId=\(song.videoId) gen=\(intent)"
                )
                return
            }
            if manageResolvingFlag {
                isResolvingNext = false
            }
            afterResolve?()
            if let failed {
                Log.nowPlaying.error("\(logContext) failed for \(song.videoId): \(failed)")
                isPlaying = false
                handlePlaybackFailure(failedVideoId: song.videoId)
            } else if !wasCancelled {
                consecutiveFailures = 0
            }
        }
    }

    func update(
        title: String,
        artist: String?,
        videoId: String,
        album: String? = nil,
        artists: [YTArtist] = [],
        thumbnailUrl: String? = nil,
        preserveMissingArtist: Bool = false
    ) {
        if self.videoId != videoId {
            confirmedMetadata = nil
            publishedArtwork = nil
        }
        self.isPlaying = true
        enrichTask?.cancel()
        liveResolveTask?.cancel()
        self.title = title
        // A deferred metadata update can arrive without artist credits (the
        // resolved stream only carries a title). Preserve a name only when it
        // was set for THIS track; a new track must never inherit the old one.
        let canPreserve = preserveMissingArtist && artistVideoId == videoId
        if !canPreserve || !artists.isEmpty {
            self.artists = artists
        }
        let cleaned = cleanArtistDisplay(artist ?? "")
        if !canPreserve || !cleaned.isEmpty {
            self.artist = cleaned
        }
        artistVideoId = videoId
        self.albumTitle = album ?? ""
        self.currentTime = 0
        self.duration = 0
        self.videoId = videoId
        self.liveTitle = nil
        self.liveSongInfo = nil
        radioMetadataTask?.cancel()
        radioMetadataTask = nil
        radioArtworkTask?.cancel()
        radioArtworkTask = nil
        lastRadioMetadataFetch = .distantPast
        radioMetadataFailures = 0
        radioMetadataCooldownUntil = nil
        lastRadioArtworkKey = nil
        self.radioPlaybackStatus = .connecting
        self.hasVideo = false
        self.isVideoMode = false
        self.isVideoReady = false
        startTimer()
        loadThumbnail(videoId: videoId, thumbnailUrl: thumbnailUrl)
        preloadNextTrack()
        if MusicPlaybackIdentity.isYouTube(videoId) {
            CanvasPrefetch.request(videoId: videoId, title: title, artist: self.artist, album: album)
        }
    }

    /// Clears the previous song's published payload before a new selection is
    /// initialized. No-op when the queue already initialized this videoId.
    /// Call it before setting `videoId` so the old title/artwork never leaks
    /// into the new track.
    func beginTransition(to videoId: String) {
        guard self.videoId != videoId else { return }
        let previous = self.videoId
        artworkLoadTask?.cancel()
        enrichTask?.cancel()
        liveResolveTask?.cancel()
        artworkLoadTask = nil
        enrichTask = nil
        liveResolveTask = nil
        lastLoadedVideoId = nil
        resolvedArtworkVideoId = nil
        confirmedMetadata = nil
        publishedArtwork = nil
        thumbnailImage = nil
        thumbnailUIImage = nil
        thumbnailVersion += 1
        dominantColors = [
            Color(red: 0.15, green: 0.15, blue: 0.2),
            Color(red: 0.05, green: 0.05, blue: 0.08),
        ]
        title = ""
        artist = ""
        artists = []
        albumTitle = ""
        artistVideoId = nil
        liveTitle = nil
        liveSongInfo = nil
        radioMetadataTask?.cancel()
        radioMetadataTask = nil
        radioArtworkTask?.cancel()
        radioArtworkTask = nil
        lastRadioMetadataFetch = .distantPast
        radioMetadataFailures = 0
        radioMetadataCooldownUntil = nil
        lastRadioArtworkKey = nil
        radioPlaybackStatus = .connecting
        currentSourceName = nil
        currentResult = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        stopTimer()
        Log.nowPlaying.info(
            "TRANSITION begin videoId=\(videoId) previous=\(previous ?? "nil")"
        )
    }

    func bumpPlaybackIntent() {
        playbackGeneration += 1
        // Invalidating the old request also releases its UI-level skip guard.
        isResolvingNext = false
    }

    /// Convenience pushing a `SongItem`'s metadata into the player state.
    func update(with song: SongItem) {
        loadedAt = Date()
        update(
            title: song.title,
            artist: song.artists.map(\.name).joined(separator: ", "),
            videoId: song.videoId,
            album: song.album,
            artists: song.artists,
            thumbnailUrl: song.thumbnailUrl
        )
        TasteProfileStore.shared.recordPlay(artist: song.artists.first?.name ?? song.artistNamesDisplay)
    }

    /// Records video availability: the watchable-video verdict comes from
    /// the shared availability check (row type preferred, authoritative
    /// lookup as fallback); this only stores it alongside the type and
    /// pre-warms when there is one to show.
    func updateVideoAvailability(musicVideoType: String? = nil, hasVideo: Bool = false) {
        if let musicVideoType {
            self.musicVideoType = musicVideoType
        }
        self.hasVideo = hasVideo
        if hasVideo {
            PlayerController.shared.preloadVideoURL()
        }
    }

    /// Pre-warms artwork for the previous and upcoming songs so swiping the
    /// mini player bar shows their art instantly.
    func preloadNeighborArtwork() {
        var urls = upcomingSongs(prefixLimit: 3)
            .compactMap(\.thumbnailUrl)
            .compactMap { URL(string: ArtworkURLs.highRes($0) ?? $0) }
        let neighborIds = queueSongs.indices.compactMap { index -> String? in
            guard index == queueIndex - 1 || (index > queueIndex && index <= queueIndex + 3) else { return nil }
            return queueSongs[index].videoId
        }
        urls.append(contentsOf: neighborIds.compactMap { URL(string: Self.artworkURL(for: $0)) })
        guard !urls.isEmpty else { return }
        Task { await ImagePreloader.shared.append(urls) }
    }

    /// All playback surfaces, including the lock screen, read this snapshot.
    /// Resolved credits take precedence over the original navigable credits.
    var currentMetadata: PlaybackMetadataSnapshot? {
        guard let videoId else { return nil }
        let confirmed = confirmedMetadata.flatMap { $0.videoId == videoId ? $0.value : nil }
        let resolvedArtist = confirmed?.artist ?? ""
        let resolvedTitle = confirmed?.title ?? ""
        let resolvedAlbum = confirmed?.album ?? ""
        let name = resolvedArtist.isEmpty ? artist : resolvedArtist
        let trackTitle = resolvedTitle.isEmpty ? title : resolvedTitle
        let album = resolvedAlbum.isEmpty ? (albumTitle.isEmpty ? nil : albumTitle) : resolvedAlbum
        return PlaybackMetadataSnapshot(
            videoId: videoId, title: trackTitle,
            artist: name.isEmpty ? artistDisplayString(from: artists) : name,
            album: album, artworkURL: publishedArtwork.flatMap { $0.videoId == videoId ? $0.url : nil },
            source: confirmed?.source
        )
    }

    func metadataSnapshot(for videoId: String) -> PlaybackMetadataSnapshot? {
        guard self.videoId == videoId else { return nil }
        return currentMetadata
    }

    func artwork(for videoId: String) -> UIImage? {
        guard self.videoId == videoId, displayedArtworkVideoId == videoId else { return nil }
        return thumbnailUIImage
    }

    var displayTitle: String { currentMetadata?.title ?? title }
    var displayAlbumTitle: String { currentMetadata?.album ?? albumTitle }

    var displayArtist: String {
        currentMetadata?.artist ?? artist
    }

    /// The caller supplies a verified catalogue result for this exact video.
    /// A late response must never replace the newly selected song's metadata.
    func acceptResolvedMetadata(_ metadata: ResolvedMetadata, videoId: String, replaceExisting: Bool = false) {
        guard self.videoId == videoId else { return }
        // Visible rows may supply an initial result; playback's own verified
        // lookup is authoritative. A later row must not change the release.
        guard replaceExisting || confirmedMetadata?.videoId != videoId else { return }
        confirmedMetadata = (videoId, metadata)
        if !metadata.title.isEmpty { title = metadata.title }
        if !metadata.artist.isEmpty { artist = metadata.artist }
        if let album = metadata.album, !album.isEmpty { albumTitle = album }
        PlayerController.shared.setNowPlayingMetadata()
    }

    func stopped(videoId: String?, isEof: Bool = true) {
        guard self.videoId == videoId else { return }
        if playbackKind == .radio {
            // Radio is an indefinite station, never a completed queue song.
            // Avoid YouTube re-resolve/queue advance after a station error.
            radioPlaybackStatus = .unavailable
            isPlaying = false
            stopTimer()
            PlayerController.shared.updateNowPlayingProgress()
            return
        }
        if let skipTime = lastManualSkipTime, Date().timeIntervalSince(skipTime) < 2, isResolvingNext {
            return
        }
        guard isEof else {
            recoverFromPlaybackFailure(videoId: videoId)
            return
        }
        let sinceLoad = Date().timeIntervalSince(loadedAt)
        if sinceLoad < 2 {
            Log.nowPlaying.debug("Ignoring spurious EOF \(String(format: "%.2f", sinceLoad))s after load")
            return
        }
        currentTime = duration
        TasteProfileStore.shared.recordCompletion(artist: artist)
        if let finishedId = videoId,
           duration >= 600 || musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" {
            Task { await EpisodePlaybackStore.shared.markPlayed(videoId: finishedId) }
        }
        if isRepeatOn {
            repeatCurrent()
            return
        }
        if hasNext {
            playNext(automatic: true)
        } else if isSurpriseSession {
            continueSurprise()
        } else if SettingsStore.shared.autoplaySimilar,
                  MusicPlaybackIdentity.isYouTube(videoId),
                  let endedVideoId = videoId {
            autoplaySimilar(from: endedVideoId)
        } else {
            // End of queue, pause but keep the last song shown in the player.
            isPlaying = false
            stopTimer()
            PlayerController.shared.updateNowPlayingProgress()
            Task { await PlaybackStateService.shared.stopTracking() }
        }
    }

    /// Refills an AI "Surprise me" session when its queue runs out, asking the
    /// AI for a fresh batch so it keeps choosing based on the listener's taste.
    private func continueSurprise() {
        let seed = videoId
        let generation = playbackGeneration
        Task {
            let items = await SurpriseMeService.musicQueue(seedVideoId: seed, refreshAI: true)
            guard generation == playbackGeneration else { return }
            guard !items.isEmpty else {
                isPlaying = false
                stopTimer()
                return
            }
            queueSongs = items
            queueIndex = 0
            isShuffleOn = false
            queueDidChange()
            let first = items[0]
            bumpPlaybackIntent()
            let intent = playbackGeneration
            update(with: first)
            try? await PlaybackManager.shared.resolveAndPlay(
                videoId: first.videoId,
                intent: intent
            )
            persistQueueState()
        }
    }

    /// Continues playback with a radio queue built from the last song when the
    /// queue runs out and "Autoplay Similar" is enabled.
    private func autoplaySimilar(from videoId: String) {
        let generation = playbackGeneration
        Task {
            do {
                let radio = try await PersonalizationService.shared.fetchRadio(videoId: videoId)
                guard generation == playbackGeneration else { return }
                let songs = radio.songs
                guard !songs.isEmpty else {
                    isPlaying = false
                    return
                }
                self.queueSongs = songs
                self.queueIndex = 0
                self.isShuffleOn = false
                self.queueDidChange()
                let first = songs[0]
                bumpPlaybackIntent()
                let intent = playbackGeneration
                update(with: first)
                try await PlaybackManager.shared.resolveAndPlay(
                    videoId: first.videoId,
                    intent: intent
                )
                self.persistQueueState()
            } catch {
                guard generation == playbackGeneration else { return }
                Log.nowPlaying.error("Autoplay similar failed: \(error)")
                isPlaying = false
            }
        }
    }

    /// A stream that died mid-play (not EOF, not a manual skip): drop the
    /// possibly-expired cached URL and re-resolve once. Repeated failures for
    /// the same video are only retried after a cooldown to avoid a loop.
    /// One bad song (resolve failed, expired stream, region block) must not kill
    /// the session: skip past it, but stop after a few consecutive failures so a
    /// systemic outage doesn't hammer YouTube or loop forever.
    /// Called by the player when a stream resolved but mpv couldn't start it.
    func reportPlaybackFailure(videoId: String) {
        guard self.videoId == videoId else { return }
        handlePlaybackFailure(failedVideoId: videoId)
    }

    private func handlePlaybackFailure(failedVideoId: String) {
        guard videoId == failedVideoId else {
            Log.nowPlaying.debug(
                "PLAY_INTENT ignoring obsolete failure for \(failedVideoId)"
            )
            return
        }
        consecutiveFailures += 1
        let canSkip = hasNext && consecutiveFailures < Self.maxConsecutiveFailures
        Log.nowPlaying.notice(
            "Playback failure \(consecutiveFailures)/\(Self.maxConsecutiveFailures) for \(failedVideoId); "
                + (canSkip ? "skipping to next" : "stopping")
        )
        if canSkip {
            playNext(automatic: true)
        } else {
            consecutiveFailures = 0
            isPlaying = false
        }
    }

    private func recoverFromPlaybackFailure(videoId: String?) {
        guard let videoId else {
            isPlaying = false
            return
        }
        PlayerController.shared.handleVideoStreamFailure()
        if let last = lastFailureAt[videoId], Date().timeIntervalSince(last) < 30 {
            isPlaying = false
            return
        }
        // Only failures from the last cooldown are useful; this also bounds the
        // dictionary over a long session.
        let cutoff = Date().addingTimeInterval(-30)
        lastFailureAt = lastFailureAt.filter { $0.value > cutoff }
        lastFailureAt[videoId] = Date()
        isPlaying = false
        Log.nowPlaying.notice("Stream failed mid-play, re-resolving \(videoId)")
        let intent = playbackGeneration
        Task {
            if MusicPlaybackIdentity.isYouTube(videoId) {
                await PlayerConfigStore.shared.notifyStreamRejection()
            }
            await StreamCache.shared.remove(videoId: videoId)
            do {
                try await PlaybackManager.shared.resolveAndPlay(
                    videoId: videoId,
                    intent: intent
                )
                // A resolved URL is not proof of audible playback. Keep the
                // 30-second cooldown so an Apolo -> mpv -> resolve failure
                // cannot immediately retry the same broken stream forever.
            } catch is CancellationError {
                return
            } catch {
                Log.nowPlaying.error("Mid-play recovery failed: \(error)")
                if self.videoId == videoId {
                    isPlaying = false
                }
            }
        }
    }

    static func artworkURL(for videoId: String) -> String {
        ArtworkURLs.fallback(for: videoId)
    }

    private var lastLoadedVideoId: String?
    private var resolvedArtworkVideoId: String?
    /// Video id the current artist/artists belong to, so a metadata update for a
    /// *different* track never keeps the previous artist.
    private var artistVideoId: String?
    /// When the current track started loading. Used to drop a spurious EOF that
    /// mpv can report for the previous file right after a new load (this made a
    /// freshly started song skip to the next one after ~1 second).
    private var loadedAt = Date()

    private func loadThumbnail(videoId: String, thumbnailUrl: String? = nil) {
        guard videoId != lastLoadedVideoId else { return }
        lastLoadedVideoId = videoId
        resolvedArtworkVideoId = nil
        enrichTask?.cancel()
        // Safety net: callers that resolve without song metadata pass nil.
        // The queue usually still knows this track's artwork — use it rather
        // than falling back to the low-res ytimg default.
        let selectedSong = queueSongs.first { $0.videoId == videoId }
        var thumb = thumbnailUrl
        if thumb == nil {
            thumb = selectedSong?.thumbnailUrl
        }

        let kind = selectedSong?.contentKind
        let isPodcast = kind == .episode || kind == .podcast
        let isMusic = !isPodcast
            && playbackKind != .radio
            && !MusicPlaybackIdentity.isExternal(videoId)
        artworkLoadTask?.cancel()
        artworkLoadTask = Task {
            // For downloaded songs, try embedded artwork first.
            if !MusicPlaybackIdentity.isExternal(videoId),
               let localURL = await DownloadManager.shared.localURL(for: videoId) {
                loadArtworkFromLocalFile(localURL, videoId: videoId)
                return
            }
            guard !Task.isCancelled, lastLoadedVideoId == videoId else { return }
            if isMusic {
                // Album art and video frame thumbnails are NOT interchangeable.
                // A YouTube still (or a video-classified row) is not proof
                // of an album cover, even if the AUDIO stream is FLAC.
                if let thumb, !thumb.isEmpty {
                    let needsVerifiedCover = MusicArtworkSelectionPolicy.shouldResolveVerifiedCover(
                        thumbnailURL: thumb,
                        isVideo: selectedSong?.isVideo,
                        musicVideoType: selectedSong?.musicVideoType
                    )
                    if needsVerifiedCover {
                        let resolved = await resolveCanonicalArtwork(videoId: videoId)
                        guard !Task.isCancelled, lastLoadedVideoId == videoId else { return }
                        if resolved { return }
                    }
                    // Keep verified release art when available. For video
                    // previews, attempt maxres/sd variants before hqdefault;
                    // never enlarge a tiny original hq frame as the first pick.
                    loadThumbnailFromCDN(
                        videoId: videoId,
                        thumbnailUrl: thumb,
                        preferSourceArtwork: !MusicArtworkSelectionPolicy.isVideoThumbnail(thumb)
                    )
                    return
                }
                // Only an entry with no selected artwork may use a
                // verified canonical album image or YouTube fallback.
                let resolved = await resolveCanonicalArtwork(videoId: videoId)
                guard !Task.isCancelled, lastLoadedVideoId == videoId else { return }
                if !resolved {
                    loadThumbnailFromCDN(videoId: videoId, thumbnailUrl: nil)
                }
            } else {
                enrichArtwork(videoId: videoId, replaceArtwork: true)
                loadThumbnailFromCDN(videoId: videoId, thumbnailUrl: thumb)
            }
        }
    }

    /// Resolves the canonical cover (Apple → Deezer → CAA) with a hard timeout
    /// and publishes it if it clearly matches. Returns whether it published.
    private func resolveCanonicalArtwork(videoId: String, minimumArtworkSide: CGFloat = 0) async -> Bool {
        guard !MusicPlaybackIdentity.isExternal(videoId) else { return false }
        let song = queueSongs.first { $0.videoId == videoId }
        let fallbackQuery = TextMatch.recordingQuery(title: title, artist: artist)
        let identity = song.map(TrackIdentity.make(from:)) ?? TrackIdentity(
            videoId: videoId,
            title: fallbackQuery.title,
            artist: fallbackQuery.artist,
            album: nil,
            durationSeconds: nil
        )
        let title = identity.title
        let artist = identity.artist
        let album = identity.album
        let duration = identity.durationSeconds
        guard !title.isEmpty else { return false }
        let resolved = await Self.resolveMetadataWithTimeout(
            title: title, artist: artist, album: album, duration: duration, seconds: 2.5
        )
        guard !Task.isCancelled, lastLoadedVideoId == videoId else { return false }
        var coverURL: URL?
        if let resolved,
           TextMatch.recordingsMatch(resolved.title, title),
           TextMatch.normalizeArtist(resolved.artist) == TextMatch.normalizeArtist(artist),
           MusicArtworkSelectionPolicy.matchesRequestedRelease(
               requested: album, candidate: resolved.album
           ) {
            coverURL = resolved.artworkURL
            acceptResolvedMetadata(resolved, videoId: videoId, replaceExisting: true)
        }
        // Do not accept a same-named single/compilation for an album track.
        // A known release can still supply art without rewriting song text.
        if coverURL == nil, let album, !album.isEmpty {
            coverURL = await MetadataResolver.albumArtwork(title: album, artist: artist)
        }
        guard !Task.isCancelled, lastLoadedVideoId == videoId,
              let artworkString = ArtworkURLs.highRes(coverURL?.absoluteString),
              let artworkURL = URL(string: artworkString),
              let image = try? await ArtworkLoader.image(for: artworkURL) else { return false }
        guard !Task.isCancelled, lastLoadedVideoId == videoId,
              Self.artworkSide(image) >= max(480, minimumArtworkSide + 1) else {
            return false
        }
        resolvedArtworkVideoId = videoId
        publishedArtwork = (videoId, artworkURL.absoluteString)
        publishArtwork(image)
        PlayerController.shared.setNowPlayingMetadata()
        return true
    }

    private static func resolveMetadataWithTimeout(
        title: String,
        artist: String,
        album: String?,
        duration: Int?,
        seconds: Double
    ) async -> ResolvedMetadata? {
        await withTaskGroup(of: ResolvedMetadata?.self) { group in
            group.addTask {
                await MetadataResolver.enrich(
                    title: title, artist: artist, album: album, duration: duration
                )
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

    /// Background metadata enrichment. Apple/iTunes is the primary catalogue
    /// (matching the app's design), with MusicBrainz/Deezer as fallback inside
    /// `MetadataResolver`. On a strict title+artist match it updates the
    /// canonical text and cover for the currently playing track.
    private func enrichArtwork(videoId: String, replaceArtwork: Bool) {
        // Radio stations already carry their own name and favicon; never match
        // them against music/podcast catalogues.
        guard playbackKind != .radio, !MusicPlaybackIdentity.isExternal(videoId) else { return }
        // Keep the track's own album artwork when it has one.
        guard replaceArtwork else { return }
        let title = title
        let artist = artist
        let song = queueSongs.first { $0.videoId == videoId }
        let kind = song?.contentKind
        guard !title.isEmpty else { return }
        enrichTask?.cancel()
        enrichTask = Task {
            guard !Task.isCancelled else { return }
            let resolved: ResolvedMetadata?
            if kind == .episode || kind == .podcast {
                resolved = await PodcastMetadataResolver.enrich(title: title, author: artist)
            } else {
                resolved = await MetadataResolver.enrich(title: title, artist: artist, album: song?.album, duration: song?.duration)
            }
            guard let resolved else { return }
            guard !Task.isCancelled, lastLoadedVideoId == videoId else { return }

            if kind != .episode && kind != .podcast {
                let query = TextMatch.recordingQuery(title: title, artist: artist)
                guard TextMatch.recordingsMatch(resolved.title, query.title) else { return }
                if !artist.isEmpty {
                    guard TextMatch.artistsMatch(resolved.artist, query.artist) else { return }
                }
            }
            self.acceptResolvedMetadata(resolved, videoId: videoId, replaceExisting: true)

            guard let artworkString = ArtworkURLs.highRes(resolved.artworkURL?.absoluteString),
                  let artworkURL = URL(string: artworkString),
                  let image = try? await ArtworkLoader.image(for: artworkURL) else {
                PlayerController.shared.setNowPlayingMetadata()
                return
            }
            guard lastLoadedVideoId == videoId else { return }
            resolvedArtworkVideoId = videoId
            publishedArtwork = (videoId, artworkURL.absoluteString)
            publishArtwork(image)
            PlayerController.shared.setNowPlayingMetadata()
        }
    }


    private func loadArtworkFromLocalFile(_ fileURL: URL, videoId: String) {
        Task {
            let asset = AVURLAsset(url: fileURL)
            let metadata = try? await asset.load(.metadata)
            var artworkImage: UIImage?
            if let metadata {
                for item in metadata {
                    if let data = try? await item.load(.dataValue),
                       let image = UIImage(data: data) {
                        artworkImage = image
                        break
                    }
                }
            }

            guard !Task.isCancelled, lastLoadedVideoId == videoId,
                  resolvedArtworkVideoId != videoId else { return }
            if let artworkImage { publishArtwork(artworkImage) }
            // Embedded artwork is often a small thumbnail. Keep it available
            // offline, but allow a genuinely larger image to replace it.
            guard artworkImage.map({ Self.artworkSide($0) < 600 }) ?? true else { return }
            let resolved = playbackKind == .music
                ? await resolveCanonicalArtwork(
                    videoId: videoId,
                    minimumArtworkSide: artworkImage.map(Self.artworkSide) ?? 0
                ) : false
            guard !Task.isCancelled, lastLoadedVideoId == videoId else { return }
            if !resolved {
                loadThumbnailFromCDN(
                    videoId: videoId,
                    thumbnailUrl: queueSongs.first { $0.videoId == videoId }?.thumbnailUrl,
                    fallbackImage: artworkImage
                )
            }
        }
    }

    /// Publishes a loaded image as the current artwork (cropped square).
    private func publishArtwork(_ image: UIImage) {
        let cropped = image.centerCroppedSquare()
        thumbnailUIImage = cropped
        displayedArtworkVideoId = videoId
        thumbnailImage = Image(uiImage: cropped)
        thumbnailVersion &+= 1
        updateDominantColors(from: cropped)
        PlayerController.shared.updateNowPlayingArtwork()
    }

    /// YouTube can return HTTP 200 with a tiny placeholder for an unavailable
    /// maxres image. Skip it so the next actual resolution can be tried.
    private static func isUsableArtwork(_ image: UIImage, for url: URL) -> Bool {
        guard MusicArtworkSelectionPolicy.isVideoThumbnail(url.absoluteString) else {
            return true
        }
        let width = image.cgImage?.width ?? Int(image.size.width * image.scale)
        let height = image.cgImage?.height ?? Int(image.size.height * image.scale)
        return MusicArtworkSelectionPolicy.acceptableVideoImageSize(
            width: width, height: height
        )
    }

    private static func artworkSide(_ image: UIImage) -> CGFloat {
        if let cgImage = image.cgImage { return CGFloat(min(cgImage.width, cgImage.height)) }
        return min(image.size.width, image.size.height) * image.scale
    }

    private func loadThumbnailFromCDN(
        videoId: String,
        thumbnailUrl: String? = nil,
        fallbackImage: UIImage? = nil,
        preferSourceArtwork: Bool = false
    ) {
        // Best source first: the track's own artwork upgraded to full
        // resolution, then ytimg step-downs, then the guaranteed hqdefault.
        var candidates: [String] = []
        if preferSourceArtwork, let thumbnailUrl, !thumbnailUrl.isEmpty {
            let upgraded = ArtworkURLs.highRes(thumbnailUrl) ?? thumbnailUrl
            candidates.append(upgraded)
            if thumbnailUrl != upgraded { candidates.append(thumbnailUrl) }
        } else if MusicPlaybackIdentity.isExternal(videoId), let thumbnailUrl {
            candidates.append(thumbnailUrl)
        } else if let upgraded = ArtworkURLs.highRes(thumbnailUrl) {
            if let maxRes = ArtworkURLs.maxResVariant(upgraded) {
                candidates.append(maxRes)
            }
            if let standard = ArtworkURLs.sdVariant(upgraded) {
                candidates.append(standard)
            }
            candidates.append(upgraded)
        }
        if !preferSourceArtwork, !MusicPlaybackIdentity.isExternal(videoId) {
            let fallback = Self.artworkURL(for: videoId)
            // Missing track metadata still deserves the complete resolution
            // ladder, not only the 480px video thumbnail.
            for candidate in [ArtworkURLs.maxResVariant(fallback), ArtworkURLs.sdVariant(fallback), fallback].compactMap({ $0 }) {
                if !candidates.contains(candidate) { candidates.append(candidate) }
            }
        }
        let urls = candidates.compactMap(URL.init(string:))
        guard !urls.isEmpty else {
            if let fallbackImage { publishArtwork(fallbackImage); return }
            thumbnailUIImage = nil
            thumbnailImage = Image(systemName: "music.note")
            thumbnailVersion &+= 1
            updateDominantColors(from: nil)
            return
        }

        // Phase 1: instant paint from the best cached candidate. A lesser
        // cached variant must not shadow a better one — Phase 2 upgrades.
        var paintedIndex: Int?
        for (index, url) in urls.enumerated() {
            if let cached = ArtworkLoader.cachedImage(for: url), Self.isUsableArtwork(cached, for: url),
               fallbackImage.map({ Self.artworkSide(cached) > Self.artworkSide($0) }) ?? true {
                publishArtwork(cached)
                publishedArtwork = (videoId, url.absoluteString)
                paintedIndex = index
                break
            }
        }

        // Phase 2: fetch candidates better than the painted one (or all of
        // them when nothing was painted). First success wins and swaps in.
        let fetchCount = paintedIndex ?? urls.count
        if fetchCount == 0 {
            return
        }
        if paintedIndex == nil, fallbackImage == nil {
            thumbnailImage = nil
        }
        Task {
            for url in urls.prefix(fetchCount) {
                guard lastLoadedVideoId == videoId, resolvedArtworkVideoId != videoId else { return }
                do {
                    let platformImage = try await ArtworkLoader.image(for: url)
                    guard Self.isUsableArtwork(platformImage, for: url),
                          fallbackImage.map({ Self.artworkSide(platformImage) > Self.artworkSide($0) }) ?? true else { continue }
                    await MainActor.run {
                        guard self.lastLoadedVideoId == videoId, self.resolvedArtworkVideoId != videoId else { return }
                        self.publishArtwork(platformImage)
                        self.publishedArtwork = (videoId, url.absoluteString)
                    }
                    return
                } catch {
                    continue
                }
            }
            if paintedIndex == nil {
                await MainActor.run {
                    guard self.lastLoadedVideoId == videoId, self.resolvedArtworkVideoId != videoId else { return }
                    if let fallbackImage {
                        publishArtwork(fallbackImage)
                    } else {
                        thumbnailImage = Image(systemName: "music.note")
                        thumbnailVersion &+= 1
                        updateDominantColors(from: nil)
                    }
                }
            }
        }
    }

    private func preloadNextTrack() {
        guard hasNext else { return }
        let nextId = queueSongs[queueIndex + 1].videoId
        if MusicPlaybackIdentity.isYouTube(nextId) {
            SponsorBlockIntegration.shared.warm(for: nextId)
        }
        loggedTask(Log.nowPlaying, "Pre-resolve failed") {
            _ = try await PlaybackManager.shared.resolve(videoId: nextId)
            Log.nowPlaying.debug("Pre-resolved next track: \(nextId)")
        }
    }

    private func startTimer() {
        stopTimer()
        Log.nowPlaying.debug("TIMER start videoId=\(self.videoId ?? "nil")")
        // Add to `.common` so progress keeps updating while the user scrolls
        // or drags the slider (the default mode pauses the timer).
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.timerTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @MainActor
    private func timerTick() {
        currentTime = PlayerController.shared.currentTime
        // `duration` arrives via mpv property events and
        // `updateNowPlayingProgress`; polling it every tick doubled the
        // synchronous mpv reads on the main actor.
        progressTick += 1
        if progressTick % 20 == 0, isPlaying,
           playbackKind != .radio, let videoId {
            let payload: [String: Any] = [
                "videoId": videoId,
                "position": currentTime,
                "at": Date().timeIntervalSince1970
            ]
            UserDefaults.standard.set(payload, forKey: Self.positionKey)
        }
        if progressTick % 4 == 0 {
            PlayerController.shared.updateNowPlayingProgress()
        }
        if MusicPlaybackIdentity.isYouTube(videoId) {
            SponsorBlockIntegration.shared.tick()
        }
        icyTick += 1
        if icyTick % 4 == 0, playbackKind == .radio {
            refreshLiveTitle()
            refreshRadioMetadataIfNeeded()
        }
        if let videoId, duration >= 600 || musicVideoType == "MUSIC_VIDEO_TYPE_PODCAST_EPISODE" {
            let vid = videoId
            let pos = currentTime
            let dur = duration
            Task {
                await EpisodePlaybackStore.shared.savePosition(videoId: vid, position: pos, duration: dur)
            }
        }
    }

    /// Reads the stream's ICY title (the live song on a Shoutcast/Icecast
    /// station) and publishes it when it changes.
    private func refreshLiveTitle() {
        guard let icy = PlayerController.shared.icyTitle(), !icy.isEmpty else { return }
        guard let parsed = ICYTitleParser.parse(icy, stationName: displayTitle) else { return }
        let display = parsed.display
        guard liveTitle != display else { return }
        applyRadioNowPlaying(RadioNowPlaying(
            artist: parsed.artist,
            title: parsed.title,
            album: nil,
            coverURL: nil
        ))
    }

    /// Broadcasters without ICY (Radio Paradise AAC/MP3, etc.) get their
    /// now-playing data from a per-station API instead.
    private func refreshRadioMetadataIfNeeded() {
        guard playbackKind == .radio,
              isPlaying,
              UIApplication.shared.applicationState == .active,
              let raw = currentStreamURL,
              let url = URL(string: raw),
              let provider = RadioMetadataProviders.provider(for: url, stationName: displayTitle) else {
            return
        }
        if let until = radioMetadataCooldownUntil, Date() < until { return }
        guard Date().timeIntervalSince(lastRadioMetadataFetch) >= 30 else { return }
        lastRadioMetadataFetch = Date()
        radioMetadataTask?.cancel()
        let stationName = displayTitle
        let identity = RadioMetadataIdentity(
            generation: playbackGeneration,
            stationID: videoId,
            streamURL: raw
        )
        radioMetadataTask = Task { [weak self] in
            let data = await provider.metadata(for: url, stationName: stationName)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isPlaying, self.playbackKind == .radio,
                      identity.matches(
                          generation: self.playbackGeneration,
                          stationID: self.videoId,
                          streamURL: self.currentStreamURL
                      ) else { return }
                if let data {
                    self.radioMetadataFailures = 0
                    self.radioMetadataCooldownUntil = nil
                    self.applyRadioNowPlaying(data)
                } else {
                    self.radioMetadataFailures += 1
                    if self.radioMetadataFailures >= 3 {
                        self.radioMetadataCooldownUntil = Date().addingTimeInterval(300)
                        self.radioMetadataFailures = 0
                    }
                }
            }
        }
    }

    private func applyRadioNowPlaying(_ data: RadioNowPlaying) {
        guard playbackKind == .radio else { return }
        let artist = data.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = data.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2 else { return }
        if title.caseInsensitiveCompare(displayTitle) == .orderedSame { return }
        let display = artist.isEmpty ? title : "\(artist) - \(title)"
        if liveTitle != display {
            liveResolveTask?.cancel()
            radioArtworkTask?.cancel()
            liveTitle = display
            liveSongInfo = LiveSongInfo(title: title, artist: artist, album: data.album, artwork: nil)
            lastRadioArtworkKey = nil
            showRadioPlaceholderArtwork()
        } else if liveSongInfo?.album == nil {
            liveSongInfo?.album = data.album
        }

        // Prefer catalogue high-resolution art, but retain the broadcaster's
        // real cover as a fallback. Cancel and verify origin across awaits.
        let key = "\(artist.lowercased())|\(title.lowercased())"
        if let liveSongInfo, liveSongInfo.artwork != nil { return }
        if lastRadioArtworkKey == key { return }
        lastRadioArtworkKey = key
        radioArtworkTask?.cancel()
        let identity = RadioMetadataIdentity(
            generation: playbackGeneration,
            stationID: videoId,
            streamURL: currentStreamURL
        )
        radioArtworkTask = Task { [weak self] in
            let resolved: ResolvedMetadata?
            if artist.isEmpty {
                resolved = nil
            } else {
                resolved = await MetadataResolver.enrich(title: title, artist: artist)
            }
            guard !Task.isCancelled else { return }
            let preferred = ArtworkURLs.highRes(resolved?.artworkURL?.absoluteString)
                .flatMap(URL.init(string:))
            let providerCover = data.coverURL?.scheme?.lowercased() == "https"
                ? data.coverURL : nil
            var image: UIImage?
            if let preferred {
                image = try? await ArtworkLoader.image(for: preferred)
            }
            if image == nil, let providerCover {
                image = try? await ArtworkLoader.image(for: providerCover)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isPlaying, self.playbackKind == .radio,
                      self.liveTitle == display,
                      identity.matches(
                          generation: self.playbackGeneration,
                          stationID: self.videoId,
                          streamURL: self.currentStreamURL
                      ) else { return }
                if let image {
                    self.publishArtwork(image)
                    self.liveSongInfo?.artwork = image.pngData()
                    if let album = resolved?.album, self.liveSongInfo?.album == nil {
                        self.liveSongInfo?.album = album
                    }
                } else if self.lastRadioArtworkKey == key {
                    // Do not permanently suppress a retry when art was missing.
                    self.lastRadioArtworkKey = nil
                }
            }
        }
    }

    /// Drops the previous song's cover as soon as a new song starts or the
    /// station stops; nothing is kept in a cover cache.
    private func showRadioPlaceholderArtwork() {
        guard playbackKind == .radio else { return }
        thumbnailUIImage = nil
        thumbnailImage = Image(systemName: "dot.radiowaves.left.and.right")
        PlayerController.shared.updateNowPlayingArtwork()
    }

    /// Splits a raw ICY stream title into artist and title.
    static func splitICY(_ raw: String) -> (artist: String, title: String) {
        if let parsed = ICYTitleParser.parse(raw) {
            return (parsed.artist, parsed.title)
        }
        return ("", raw.trimmingCharacters(in: .whitespaces))
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Sleep timer

    /// Schedules a pause after `minutes`, replacing any existing sleep timer.
    func scheduleSleepTimer(minutes: Double) {
        cancelSleepTimer()
        let endsAt = Date().addingTimeInterval(minutes * 60)
        sleepTimerEndsAt = endsAt
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(endsAt.timeIntervalSinceNow))
            guard let self, !Task.isCancelled else { return }
            self.sleepTimerEndsAt = nil
            PlayerController.shared.setPaused(true)
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndsAt = nil
    }

    @MainActor
    private func updateDominantColors(from uiImage: UIImage?) {
        guard let uiImage = uiImage else {
            self.dominantColors = [Color(red: 0.15, green: 0.15, blue: 0.2), Color(red: 0.05, green: 0.05, blue: 0.08)]
            return
        }
        self.dominantColors = [uiImage.extractDetailBackdropColor()]
    }
}

// MARK: - Module-level artist name cleaner

/// Builds a clean, comma-separated artist string from an artist array, dropping
/// names that clean down to empty (junk/blank entries) so no dangling separator
/// is left behind.
func artistDisplayString(from artists: [YTArtist]) -> String {
    artists
        .map { cleanArtistDisplay($0.name) }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
}

func cleanArtistDisplay(_ name: String) -> String {
    var tempName = name

    // Strip " - Topic"
    for suffix in [" - Topic", " - topic", " - TOPIC"] where tempName.lowercased().hasSuffix(suffix.lowercased()) {
        tempName = String(tempName.dropLast(suffix.count))
    }

    // Strip trailing year "(2025)" / "[2025]"
    if let r = try? NSRegularExpression(pattern: "\\s*[\\(\\[]\\d{4}[\\)\\]]\\s*$") {
        tempName = r.stringByReplacingMatches(
            in: tempName,
            range: NSRange(tempName.startIndex..., in: tempName),
            withTemplate: ""
        )
    }

    // Split on commas, ampersands, and bullet separators (•, ·, |) then drop junk segments
    let separatorSet = CharacterSet(charactersIn: ",&•·|")
    let parts = tempName
        .components(separatedBy: separatorSet)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .map(TextMatch.channelArtistName)
        .filter { !$0.isEmpty }

    let cleanParts = parts.filter { !_isJunkArtistSegment($0) }
    if cleanParts.isEmpty {
        return ""
    }
    return cleanParts.joined(separator: ", ")
}

private func _isJunkArtistSegment(_ segment: String) -> Bool {
    let lower = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lower.isEmpty || lower == "•" || lower == "·" { return true }

    let junkLabels: Set<String> = [
        "song", "video", "track", "music", "podcast", "episode",
        "album", "playlist", "released", "year", "plays", "views",
        "downloads", "listeners", "subscribers", "watchers", "likes"
    ]
    if junkLabels.contains(lower) { return true }

    let patterns = [
        // Number optionally followed by K/M/B/T and an optional metric word
        "^[\\d,\\.]+[KMBT]?\\s*(views|downloads|listeners|subscribers|plays|watchers|likes?)?$",
        "^\\d{4}$",              // bare year
        "^[\\d,\\.\\s]+[KMBT]?$" // purely numeric / abbreviated counts
    ]
    for pattern in patterns where lower.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
        return true
    }
    return false
}


extension Notification.Name {
    static let tropQueueChanged = Notification.Name("trop.queueChanged")
}
