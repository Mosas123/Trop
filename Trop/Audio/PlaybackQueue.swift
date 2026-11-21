//
//  PlaybackQueue.swift
//  Trop
//
// Created by 686udjie on 12/09/2026.
//

import Foundation

/// Shared queue setup + resolve-and-play flows used by every tap-to-play site.
/// Each entry sets the queue on `NowPlaying` and resolves the stream via
/// `PlaybackManager`, logging failures instead of going silent.
@MainActor
enum PlaybackQueue {
    /// Plays `songs[startIndex]` (clamped). Used by detail play-all / play-song.
    static func play(_ songs: [SongItem], startIndex: Int = 0, log: AppLogger, context: String) {
        guard !songs.isEmpty else { return }
        NowPlaying.shared.isSurpriseSession = false
        let index = min(max(startIndex, 0), songs.count - 1)
        let first = songs[index]
        NowPlaying.shared.setQueue(songs, startIndex: index)
        let intent = NowPlaying.shared.playbackGeneration
        PlayerController.shared.markExplicitSelectionForInterruptionRecovery(
            videoId: first.videoId, generation: intent
        )
        loggedTask(log, "\(context) failed") {
            try await PlaybackManager.shared.resolveAndPlay(
                videoId: first.videoId,
                intent: intent
            )
        }
    }

    /// Shuffled variant of `play(_:startIndex:)`.
    static func playShuffled(_ songs: [SongItem], log: AppLogger, context: String) {
        guard !songs.isEmpty else { return }
        play(songs.shuffled(), log: log, context: context)
    }

    /// Plays `song`, reusing `songs` as the queue when it contains it.
    static func play(_ song: SongItem, in songs: [SongItem], log: AppLogger, context: String) {
        if let index = songs.firstIndex(where: { $0.videoId == song.videoId }) {
            play(songs, startIndex: index, log: log, context: context)
        } else {
            play([song], log: log, context: context)
        }
    }

    /// Starts a radio queue for `song`: plays it first unless already current,
    /// then replaces the queue with the fetched radio. Used by the song and
    /// player "Start Radio" menu actions.
    static func startRadio(for song: SongItem, options: RadioOptions = .default) {
        guard MusicPlaybackIdentity.isYouTube(song.videoId) else { return }
        let isCurrentSong = NowPlaying.shared.videoId == song.videoId
        if !isCurrentSong {
            NowPlaying.shared.setQueue([song], startIndex: 0)
            let intent = NowPlaying.shared.playbackGeneration
            PlayerController.shared.markExplicitSelectionForInterruptionRecovery(
                videoId: song.videoId, generation: intent
            )
            Task {
                try? await PlaybackManager.shared.resolveAndPlay(
                    videoId: song.videoId,
                    intent: intent
                )
            }
        }
        Task {
            guard let radio = try? await PersonalizationService.shared.fetchRadio(videoId: song.videoId, options: options),
                  radio.songs.count > 1 else { return }
            guard NowPlaying.shared.videoId == song.videoId else { return }
            NowPlaying.shared.queueSongs = preservingArtists(radio.songs, over: NowPlaying.shared.queueSongs)
            NowPlaying.shared.queueIndex = radio.currentIndex
            NowPlaying.shared.queueDidChange()
        }
    }

    /// Plays a single song, then continues with its radio queue when available.
    /// Used by Home/Search/Explore tap-to-play.
    static func playSingleWithRadio(_ song: SongItem, log: AppLogger) {
        NowPlaying.shared.setQueue([song], startIndex: 0)
        let intent = NowPlaying.shared.playbackGeneration
        PlayerController.shared.markExplicitSelectionForInterruptionRecovery(
            videoId: song.videoId, generation: intent
        )
        Task { @MainActor in
            do {
                try await PlaybackManager.shared.resolveAndPlay(
                    videoId: song.videoId,
                    intent: intent
                )
            } catch is CancellationError {
                return
            } catch {
                log.error("Playback failed: \(error)")
                return
            }
            guard MusicPlaybackIdentity.isYouTube(song.videoId),
                  let radio = try? await PersonalizationService.shared.fetchRadio(videoId: song.videoId),
                  radio.songs.count > 1,
                  NowPlaying.shared.videoId == song.videoId else { return }
            NowPlaying.shared.queueSongs = preservingArtists(radio.songs, over: NowPlaying.shared.queueSongs)
            NowPlaying.shared.queueIndex = radio.currentIndex
            NowPlaying.shared.queueDidChange()
        }
    }

    private static func preservingArtists(_ songs: [SongItem], over current: [SongItem]) -> [SongItem] {
        guard !current.isEmpty else { return songs }
        let existingById = Dictionary(current.map { ($0.videoId, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.map { song in
            guard let old = existingById[song.videoId], old.artists.count > song.artists.count else { return song }
            var merged = song
            merged.artists = old.artists
            return merged
        }
    }
}
