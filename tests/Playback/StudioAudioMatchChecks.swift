import Foundation

@main
struct StudioAudioMatchChecks {
    private static func verified(
        title: String = "Moscow Mule",
        artist: String = "Bad Bunny",
        album: String? = "Un Verano Sin Ti",
        duration: Int = 245,
        candidateTitle: String = "Moscow Mule",
        candidateArtist: [String] = ["Bad Bunny"],
        candidateAlbum: String? = "Un Verano Sin Ti",
        candidateDuration: Int = 245,
        candidateType: String? = "MUSIC_VIDEO_TYPE_ATV",
        originalWasVideo: Bool = false
    ) -> Bool {
        MusicRecordingSelectionPolicy.verifiedAlbumAudio(
            wanted: .init(
                title: title, artist: artist, album: album, duration: duration,
                originalWasVideo: originalWasVideo
            ),
            candidate: .init(
                title: candidateTitle, artists: candidateArtist,
                album: candidateAlbum, duration: candidateDuration, type: candidateType
            )
        )
    }

    private static func sourceVerified(
        title: String = "Moscow Mule",
        artist: String = "Bad Bunny",
        album: String? = "Un Verano Sin Ti",
        duration: Int? = 245,
        candidateTitle: String = "Moscow Mule",
        candidateArtist: String? = "Bad Bunny",
        candidateAlbum: String? = "Un Verano Sin Ti",
        candidateDuration: Int? = 245
    ) -> Bool {
        TextMatch.verifiedAudioSource(
            wantedTitle: title, wantedArtist: artist,
            wantedAlbum: album, wantedDuration: duration,
            candidateTitle: candidateTitle, candidateArtist: candidateArtist,
            candidateAlbum: candidateAlbum, candidateDuration: candidateDuration
        )
    }

    static func main() {
        precondition(MusicRecordingSelectionPolicy.isMusicVideo(
            isVideo: nil, type: "MUSIC_VIDEO_TYPE_OMV"
        ), "Official videos must not be mislabeled Songs")
        precondition(MusicRecordingSelectionPolicy.isMusicVideo(
            isVideo: nil, type: "MUSIC_VIDEO_TYPE_UGC"
        ), "UGC videos must not be mislabeled Songs")
        precondition(!MusicRecordingSelectionPolicy.isMusicVideo(
            isVideo: nil, type: "MUSIC_VIDEO_TYPE_ATV"
        ), "Official album art tracks are Songs")
        precondition(MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
            selectedVideo: false,
            rowType: nil, sourceType: "MUSIC_VIDEO_TYPE_OMV"
        ), "A legacy song entry can rematch an OMV stream")
        precondition(!MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
            selectedVideo: true,
            rowType: "MUSIC_VIDEO_TYPE_OMV",
            sourceType: "MUSIC_VIDEO_TYPE_OMV"
        ), "Explicit video playback must never rematch")
        precondition(!MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
            selectedVideo: false, rowType: nil, sourceType: nil
        ), "Unknown type must not trigger unsafe rematching")
        precondition(verified(), "Same artist, album and title ATV accepted")
        precondition(verified(candidateTitle: "Moscow Mule (Official Audio)"),
            "Official-audio suffix does not change the recording")
        precondition(!verified(candidateType: "MUSIC_VIDEO_TYPE_OMV"),
            "A music video is not a verified album master")
        precondition(!verified(candidateArtist: ["Bad Bunny Tribute"]),
            "Artist mismatch should reject cover")
        precondition(!verified(candidateTitle: "Moscow Mule (Live)"),
            "Do not turn a live version into studio audio")
        precondition(!verified(candidateTitle: "Moscow Mule (Remix)"),
            "Do not turn a remix into original audio")
        precondition(!verified(candidateTitle: "Other Song"),
            "Exact recording title is mandatory")
        precondition(!verified(candidateAlbum: "Different Album"),
            "Different release should not match")
        precondition(verified(candidateDuration: 260),
            "An album-verified studio recording can omit video-only intro")
        precondition(!verified(candidateDuration: 330),
            "Excessive duration mismatch must still be rejected")
        precondition(!verified(album: nil, candidateAlbum: nil,
                               candidateDuration: 270),
            "Without release proof, large duration mismatches are rejected")
        precondition(verified(candidateDuration: 252),
            "A small duration difference is acceptable")
        precondition(!verified(album: nil, duration: 0),
            "No duration/album cannot verify identity")
        precondition(verified(duration: 0),
            "Exact album match substitutes for unknown duration")
        precondition(!verified(candidateArtist: []),
            "Do not trust candidates with missing performer credits")
        precondition(!verified(artist: ""),
            "Do not rematch when source artist is unknown")
        // Repro: NUEVAYoL was presented as a 3:42 video soundtrack,
        // while the original album recording is ~3:03 (39s shorter).
        precondition(verified(
            title: "NUEVAYoL", album: "DeBÍ TiRAR MáS FOToS",
            duration: 222, candidateTitle: "NUEVAYoL",
            candidateAlbum: "DeBÍ TiRAR MáS FOToS",
            candidateDuration: 183
        ), "NUEVAYoL album recording must survive the video intro offset")
        precondition(verified(
            title: "NUEVAYoL", album: nil, duration: 222,
            candidateTitle: "NUEVAYoL", candidateAlbum: "DeBÍ TiRAR MáS FOToS",
            candidateDuration: 183, originalWasVideo: true
        ), "Known video intro can differ 39s even if old row lacks album")
        precondition(!verified(
            title: "NUEVAYoL", album: nil, duration: 222,
            candidateTitle: "NUEVAYoL", candidateAlbum: "DeBÍ TiRAR MáS FOToS",
            candidateDuration: 183, originalWasVideo: false
        ), "An unknown source cannot permit a 39s duration mismatch")
        precondition(MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
            selectedVideo: false,
            rowType: "MUSIC_VIDEO_TYPE_OMV",
            sourceType: "MUSIC_VIDEO_TYPE_OMV",
            rowIsVideo: true
        ), "Songs tap must seek album audio even for an OMV-classified row")
        precondition(!MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
            selectedVideo: true,
            rowType: "MUSIC_VIDEO_TYPE_OMV",
            sourceType: "MUSIC_VIDEO_TYPE_OMV",
            rowIsVideo: true
        ), "Videos tap must keep the intentionally selected video audio")
        precondition(MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
            selectedVideo: false, rowType: nil, sourceType: nil,
            albumKnown: true, expectedDuration: 222, resolvedDuration: 222
        ), "Untyped album rows must seek a verified ATV when possible")
        precondition(!MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
            selectedVideo: false, rowType: nil,
            sourceType: "MUSIC_VIDEO_TYPE_ATV",
            albumKnown: true
        ), "A verified album track must not be searched again")
        precondition(!MusicRecordingSelectionPolicy.shouldFindAlbumAudio(
            selectedVideo: false, rowType: nil, sourceType: nil,
            albumKnown: false, expectedDuration: 222, resolvedDuration: 222
        ), "Untyped no-album entries should not cause extra searches")
        precondition(!verified(
            title: "NUEVAYoL", album: "DeBÍ TiRAR MáS FOToS",
            duration: 222, candidateTitle: "NUEVAYoL",
            candidateAlbum: "Different Album", candidateDuration: 183,
            originalWasVideo: true
        ), "Even video intro allowance must reject a different album")
        // Hard gate used by BOTH add-on search/album cache and JioSaavn.
        precondition(sourceVerified(), "Verified exact original must remain playable")
        precondition(sourceVerified(candidateTitle: "Moscow Mule (Official Audio)"),
                     "Official audio is a presentation label, not another recording")
        precondition(sourceVerified(candidateArtist: "Bad Bunny - Topic"),
                     "Canonical Topic channel is the same primary artist")
        precondition(sourceVerified(candidateArtist: "Bad Bunny, Mora"),
                     "Featured artists may follow the same primary performer")
        precondition(!sourceVerified(candidateTitle: "Moscow Mule (Remix)"),
                     "Remix cannot replace the original even in FLAC")
        precondition(!sourceVerified(candidateTitle: "Moscow Mule (Instrumental)"),
                     "Vocal recording cannot become instrumental")
        precondition(!sourceVerified(candidateTitle: "Moscow Mule (Radio Edit)"),
                     "Radio edit is a different source recording")
        precondition(!sourceVerified(candidateTitle: "Moscow Mule (Extended Mix)"),
                     "Extended mix must not leak into original")
        precondition(!sourceVerified(candidateArtist: "Bad Bunny Tribute"),
                     "Tribute performers cannot inherit metadata")
        precondition(!sourceVerified(candidateArtist: "Drake"),
                     "Same title by a different performer is not a match")
        precondition(!sourceVerified(candidateArtist: nil),
                     "Missing provider credits are not confirmation")
        precondition(!sourceVerified(artist: ""),
                     "Missing requested artist must not trigger cross-source playback")
        precondition(!sourceVerified(candidateAlbum: "Other Release"),
                     "An incompatible known release is disallowed")
        precondition(!sourceVerified(candidateDuration: 280),
                     "A materially different length must be rejected")
        precondition(!sourceVerified(album: nil, candidateAlbum: nil,
                                     candidateDuration: nil),
                     "Without album and duration there is no independent verification")
        precondition(!sourceVerified(candidateAlbum: nil,
                                     candidateDuration: nil),
                     "An empty candidate release cannot replace a missing duration")
        precondition(sourceVerified(candidateDuration: nil),
                     "An exact shared album can verify a missing duration")
        precondition(!sourceVerified(album: "Deluxe Edition",
                                     candidateAlbum: "Standard Edition",
                                     candidateDuration: nil),
                     "Missing time cannot hide a mismatched edition")

        // Large negative fixture matrix: every unsafe title and artist is
        // rejected even if the provider advertises a superior quality tier.
        let wrongVersions = [
            "(Remix)", "(Instrumental)", "(Karaoke)", "(Live)",
            "(Acoustic)", "(Demo)", "(Cover)", "(Slowed)",
            "(Nightcore)", "(Clean)", "(Explicit)", "(Extended Mix)",
            "(Radio Edit)", "(Club Mix)", "(Bootleg)", "(Mashup)",
            "(Medley)", "(Rework)", "(Remastered 2016)", "(Sped Up)",
            "(A Cappella)", "(Reverb)", "(Tribute)",
            "- Live", "- Radio Edit", "- Original Mix",
            "- Single Version", "- Album Version", "(En Vivo)"
        ]
        let wrongArtists = [
            "Bad Bunny Tribute", "Bad Bunny Covers", "Drake",
            "Bunny Bad", "Bad Bunny Bell", "Mora", "Sech",
            "Bad Bunny Tribute Band"
        ]
        var negativeCases = 0
        for version in wrongVersions {
            let variant = "Moscow Mule " + version
            for candidateArtist in ["Bad Bunny", "Drake", "Bad Bunny Tribute"] {
                precondition(!sourceVerified(candidateTitle: variant,
                                             candidateArtist: candidateArtist),
                             "Rejected source version: \(variant) / \(candidateArtist)")
                negativeCases += 1
            }
        }
        for wrongArtist in wrongArtists {
            for duration in [243, 245, 247] {
                precondition(!sourceVerified(candidateArtist: wrongArtist,
                                             candidateDuration: duration),
                             "Rejected wrong performer: \(wrongArtist)")
                negativeCases += 1
            }
        }
        precondition(negativeCases >= 100, "Negative fixture coverage regressed")
        print("PASS: \(negativeCases) wrong recording/artist fixtures plus positive checks")
        // Bug #001: BAILE INoLVIDABLE / video screenshot is not
        // the album cover, regardless of whether the audio says Lossless.
        let videoFrame = "https://i.ytimg.com/vi/example/hqdefault.jpg"
        let albumArt = "https://lh3.googleusercontent.com/example=w120-h120"
        precondition(MusicArtworkSelectionPolicy.isVideoThumbnail(videoFrame),
                     "ytimg frames must not be classified as album artwork")
        precondition(!MusicArtworkSelectionPolicy.isVideoThumbnail(albumArt),
                     "Music catalogue album-art URLs are not video stills")
        precondition(MusicArtworkSelectionPolicy.shouldResolveVerifiedCover(
            thumbnailURL: videoFrame, isVideo: nil, musicVideoType: nil
        ), "Untyped ytimg thumbnails require a verified album lookup")
        precondition(MusicArtworkSelectionPolicy.shouldResolveVerifiedCover(
            thumbnailURL: albumArt, isVideo: true, musicVideoType: "MUSIC_VIDEO_TYPE_OMV"
        ), "Video-classified selection requires verified art even if the CDN is Music")
        precondition(!MusicArtworkSelectionPolicy.shouldResolveVerifiedCover(
            thumbnailURL: albumArt, isVideo: false, musicVideoType: "MUSIC_VIDEO_TYPE_ATV"
        ), "Verified album audio artwork must not be replaced")
        precondition(MusicArtworkSelectionPolicy.shouldResolveVerifiedCover(
            thumbnailURL: nil, isVideo: nil, musicVideoType: nil
        ), "Missing artwork must still search canonical releases")
        precondition(MusicArtworkSelectionPolicy.matchesRequestedRelease(
            requested: "DeBÍ TiRAR MáS FOToS", candidate: "DEBI TIRAR MAS FOTOS"
        ), "Diacritics/case do not change album identity")
        precondition(!MusicArtworkSelectionPolicy.matchesRequestedRelease(
            requested: "DeBÍ TiRAR MáS FOToS", candidate: "Un Verano Sin Ti"
        ), "A wrong album must never supply player artwork")
        precondition(!MusicArtworkSelectionPolicy.matchesRequestedRelease(
            requested: "Un Verano Sin Ti", candidate: "Un Verano Sin Ti (Deluxe)"
        ), "Alternate release editions may have different artwork")
        precondition(!MusicArtworkSelectionPolicy.matchesRequestedRelease(
            requested: "DeBÍ TiRAR MáS FOToS", candidate: nil
        ), "An unknown release cannot overwrite a known album")
        precondition(!MusicArtworkSelectionPolicy.acceptableVideoImageSize(
            width: 120, height: 90
        ), "Tiny hqdefault previews must not be stretched full-screen")
        precondition(!MusicArtworkSelectionPolicy.acceptableVideoImageSize(
            width: 320, height: 180
        ), "Low-resolution video stills are not large artwork")
        precondition(MusicArtworkSelectionPolicy.acceptableVideoImageSize(
            width: 640, height: 480
        ), "sddefault may be used as a last-resort fallback")
        print("PASS: 13 verified-album cover, edition and preview-size checks")
        // Source-first regression (IPA #398): no cached upgrade must not
        // turn a song selection into an unsolicited OMV soundtrack.
        precondition(MusicRecordingSelectionPolicy.shouldProbeSourcesBeforeYouTube(
            mode: "lossless", hasAddons: true, prefers320: false
        ), "Best FLAC requires a cold-start provider lookup")
        precondition(MusicRecordingSelectionPolicy.shouldProbeSourcesBeforeYouTube(
            mode: "cd", hasAddons: true, prefers320: false
        ), "CD FLAC requires a cold-start provider lookup")
        precondition(MusicRecordingSelectionPolicy.shouldProbeSourcesBeforeYouTube(
            mode: "high", hasAddons: true, prefers320: true
        ), "High must search verified 320 kbps sources first")
        precondition(MusicRecordingSelectionPolicy.shouldProbeSourcesBeforeYouTube(
            mode: "auto", hasAddons: true, prefers320: true
        ), "Auto with addons must search before using video soundtrack")
        precondition(MusicRecordingSelectionPolicy.shouldProbeSourcesBeforeYouTube(
            mode: "high", hasAddons: false, prefers320: true
        ), "High without addons must still consider JioSaavn")
        precondition(!MusicRecordingSelectionPolicy.shouldProbeSourcesBeforeYouTube(
            mode: "off", hasAddons: false, prefers320: false
        ), "Off mode cannot demand unavailable providers")
        precondition(MusicRecordingSelectionPolicy.forbidsVideoSoundtrack(
            selectedVideo: false,
            rowType: "MUSIC_VIDEO_TYPE_OMV", sourceType: nil
        ), "NUEVAYoL album selection must not silently play the OMV mix")
        precondition(MusicRecordingSelectionPolicy.forbidsVideoSoundtrack(
            selectedVideo: false,
            rowType: nil, sourceType: "MUSIC_VIDEO_TYPE_UGC"
        ), "A UGC result cannot replace a selected studio recording")
        precondition(MusicRecordingSelectionPolicy.forbidsVideoSoundtrack(
            selectedVideo: false,
            rowType: nil, sourceType: nil, rowIsVideo: true
        ), "Explicitly classified video rows are not audio masters")
        precondition(!MusicRecordingSelectionPolicy.forbidsVideoSoundtrack(
            selectedVideo: true,
            rowType: "MUSIC_VIDEO_TYPE_OMV", sourceType: nil
        ), "Explicit music-video choice may play the chosen soundtrack")
        precondition(!MusicRecordingSelectionPolicy.forbidsVideoSoundtrack(
            selectedVideo: false,
            rowType: "MUSIC_VIDEO_TYPE_OMV",
            sourceType: "MUSIC_VIDEO_TYPE_ATV"
        ), "Positively verified ATV takes precedence over stale row markers")
        precondition(!MusicRecordingSelectionPolicy.forbidsVideoSoundtrack(
            selectedVideo: false, rowType: nil, sourceType: nil
        ), "Unknown song types must not be rejected without evidence")
        precondition(MusicRecordingSelectionPolicy.acceptsPrefetchedQuality(
            mode: "high", quality: "addon-aac-320"
        ), "High accepts validated addon AAC 320")
        precondition(MusicRecordingSelectionPolicy.acceptsPrefetchedQuality(
            mode: "high", quality: "jiosaavn-320"
        ), "High accepts validated JioSaavn 320")
        precondition(!MusicRecordingSelectionPolicy.acceptsPrefetchedQuality(
            mode: "high", quality: "addon-hi-res"
        ), "High must not silently re-use a cached FLAC from Best FLAC mode")
        precondition(!MusicRecordingSelectionPolicy.acceptsPrefetchedQuality(
            mode: "high", quality: "addon-atmos"
        ), "High must not unexpectedly choose an Atmos stream")
        precondition(MusicRecordingSelectionPolicy.acceptsPrefetchedQuality(
            mode: "lossless", quality: "addon-cd"
        ), "Best FLAC remains eligible for verified lossless")
        print("PASS: 5 quality-tier cache policies")
        print("PASS: 12 source-first and forbidden-video soundtrack policies")
        print("PASS: 31 studio album-audio vs music-video matching assertions")
    }
}
