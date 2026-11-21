import Foundation

/// YouTube Music distinguishes a label's audio-only art track (ATV) from
/// an official music video (OMV) or user-uploaded video (UGC). A stream URL
/// with audio channels does NOT mean its recording is the album audio.
enum MusicRecordingSelectionPolicy {
    static func isVideoRecording(_ type: String?) -> Bool {
        type == "MUSIC_VIDEO_TYPE_OMV" || type == "MUSIC_VIDEO_TYPE_UGC"
    }

    static func isStudioAudio(_ type: String?) -> Bool {
        type == "MUSIC_VIDEO_TYPE_ATV"
    }

    static func isMusicVideo(isVideo: Bool?, type: String?) -> Bool {
        isVideo == true || isVideoRecording(type)
    }

    /// Only rematch when the request was for a *song* and the resolved source
    /// is positively identified as a video. Unknown types stay untouched.
    static func shouldFindAlbumAudio(
        selectedVideo: Bool,
        rowType: String?,
        sourceType: String?,
        rowIsVideo: Bool = false,
        albumKnown: Bool = false,
        expectedDuration: Int = 0,
        resolvedDuration: Int = 0
    ) -> Bool {
        // A video ID is not an explicit request to hear its soundtrack.
        // Only a user choosing Videos asks for the video recording.
        guard !selectedVideo, !isStudioAudio(sourceType) else { return false }
        if rowIsVideo || isVideoRecording(rowType)
            || isVideoRecording(sourceType) { return true }

        // Old saved library rows and some InnerTube responses omit
        // musicVideoType. With a known album, an untyped source merits a
        // verified ATV lookup, particularly if its timing is inconsistent.
        if albumKnown, sourceType == nil { return true }
        return albumKnown && expectedDuration > 0
            && resolvedDuration > 0
            && abs(expectedDuration - resolvedDuration) > 18
    }

    /// A song selection (including a song surfaced by an album) is not consent
    /// to substitute the soundtrack of an OMV/UGC clip. If the verified ATV
    /// lookup fails, the caller must try a separately verified music source
    /// or report unavailable rather than silently playing that video mix.
    static func forbidsVideoSoundtrack(
        selectedVideo: Bool,
        rowType: String?,
        sourceType: String?,
        rowIsVideo: Bool = false
    ) -> Bool {
        !selectedVideo && !isStudioAudio(sourceType) && (
            rowIsVideo || isVideoRecording(rowType)
                || isVideoRecording(sourceType)
        )
    }

    /// Source-first lookup is required when a user explicitly prefers an
    /// external quality tier and music addons are configured. Auto/High can
    /// also check independently verified 320 kbps sources. Playback never
    /// skips this step merely because the song was not prefetched.
    static func shouldProbeSourcesBeforeYouTube(
        mode: String,
        hasAddons: Bool,
        prefers320: Bool
    ) -> Bool {
        (hasAddons && mode != "off") || prefers320
    }

    /// The High (320 kbps) tier must not quietly reuse a prior FLAC
    /// prefetch from a different setting. Auto/FLAC settings keep their own
    /// acceptance rules in PlaybackManager.
    static func acceptsPrefetchedQuality(mode: String, quality: String) -> Bool {
        guard mode == "high" else { return true }
        let label = quality.lowercased()
        return label.contains("jiosaavn") || label.contains("addon-aac")
    }

    /// Do not use fuzzy substring title matches for audio substitution.
    /// Exact recording title, real performer credits and close duration or
    /// verified album identity are required. Remixes/live/covers must not
    /// silently become the studio version or vice versa.
    /// Strongly typed groups prevent positional mix-ups between the expected
    /// album recording and a returned YouTube Music candidate.
    struct WantedRecording {
        let title: String
        let artist: String
        let album: String?
        let duration: Int
        let originalWasVideo: Bool
    }

    struct CandidateRecording {
        let title: String
        let artists: [String]
        let album: String?
        let duration: Int
        let type: String?
    }

    static func verifiedAlbumAudio(
        wanted: WantedRecording,
        candidate: CandidateRecording
    ) -> Bool {
        guard isStudioAudio(candidate.type),
              !wanted.artist.isEmpty,
              candidate.artists.contains(where: {
                  // Cross-catalogue fuzzy artist matching accepts
                  // "Bad Bunny Tribute" as a substring of "Bad Bunny".
                  // Recording substitution requires stricter identity.
                  TextMatch.normalizeArtist($0)
                      == TextMatch.normalizeArtist(wanted.artist)
              }),
              TextMatch.recordingsMatch(wanted.title, candidate.title),
              !TextMatch.isSuspiciousVersion(candidate.title)
        else { return false }

        let targetAlbum = TextMatch.normalizeTitle(wanted.album ?? "")
        let sourceAlbum = TextMatch.normalizeTitle(candidate.album ?? "")
        if !targetAlbum.isEmpty, !sourceAlbum.isEmpty,
           !TextMatch.albumsMatch(wanted.album ?? "", candidate.album ?? "") {
            return false
        }

        // An album match can substitute for missing duration. Otherwise
        // demand time alignment; two same-name recordings can be different.
        let sameAlbum = !targetAlbum.isEmpty
            && !sourceAlbum.isEmpty
            && TextMatch.albumsMatch(wanted.album ?? "", candidate.album ?? "")
        if wanted.duration <= 0 || candidate.duration <= 0 {
            return sameAlbum
        }
        // A music video may include a spoken introduction or outro that
        // is absent from the official studio master. The exact release
        // identity allows a wider range than a title/artist-only match.
        // A confirmed video often has a 30–60 second scene around a
        // 3-minute song. Exact artist/title plus an official ATV identity
        // justify the wider limit even if the old video row has no album.
        let maxDifference = (sameAlbum || wanted.originalWasVideo) ? 60 : 20
        return abs(wanted.duration - candidate.duration) <= maxDifference
    }
}


/// Decides when a selected image is a VIDEO preview rather than reliable
/// music-release artwork. Audio quality and artwork quality are independent:
/// a lossless stream may be paired with a 120px YouTube frame.
enum MusicArtworkSelectionPolicy {
    static func isVideoThumbnail(_ thumbnailURL: String?) -> Bool {
        guard let thumbnailURL, let url = URL(string: thumbnailURL),
              let host = url.host?.lowercased() else { return false }
        return host == "ytimg.com" || host.hasSuffix(".ytimg.com")
    }

    /// A known official ATV/release image can be rendered immediately.
    /// Video stills and unknown covers should FIRST try a catalogue-verified
    /// album cover, but retain the original as fallback when offline.
    static func shouldResolveVerifiedCover(
        thumbnailURL: String?,
        isVideo: Bool?,
        musicVideoType: String?
    ) -> Bool {
        if isVideo == true || MusicRecordingSelectionPolicy.isVideoRecording(musicVideoType) {
            return true
        }
        guard let thumbnailURL, !thumbnailURL.isEmpty else { return true }
        return isVideoThumbnail(thumbnailURL)
    }

    static func matchesRequestedRelease(
        requested: String?,
        candidate: String?
    ) -> Bool {
        guard let requested, !requested.isEmpty else { return true }
        guard let candidate, !candidate.isEmpty else { return false }
        // A similarly titled single/compilation must not replace an album.
        return TextMatch.normalize(requested) == TextMatch.normalize(candidate)
    }

    static func acceptableVideoImageSize(width: Int, height: Int) -> Bool {
        // 120x90 and 320x180 frames are inappropriate for large artwork.
        // Accept hqdefault (480x360) only as a final fallback when neither
        // maxres nor sddefault exists and no verified cover is available.
        min(width, height) >= 320
    }
}
