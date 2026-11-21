import Foundation

@main
struct RadioAdvancedChecks {
    private static var passed = 0

    private static func expect(_ condition: Bool, _ label: String) {
        precondition(condition, label)
        passed += 1
    }

    static func main() {
        // HTTP ICY metadata is not the legacy "ICY 200 OK" transport.
        let mp3 = RadioTransportResolver.classifyHeaders(
            contentType: "audio/mpeg", icyMetaInt: "16000"
        )
        expect(mp3.transport == .icy && mp3.hint == "audio/mpeg",
               "HTTP MP3 with icy-metaint stays native, never application/x-icy")
        let aac = RadioTransportResolver.classifyHeaders(
            contentType: "audio/aacp; charset=utf-8", icyMetaInt: "8192"
        )
        expect(aac.transport == .icy && aac.hint == "audio/aac",
               "HTTP AAC with icy-metaint is not a legacy raw ICY response")
        let opaque = RadioTransportResolver.classifyHeaders(
            contentType: "application/octet-stream", icyMetaInt: "8192"
        )
        expect(opaque.transport == .icy && opaque.hint == nil,
               "Opaque HTTP ICY headers do not force the FFmpeg route")
        let hls = RadioTransportResolver.classifyHeaders(
            contentType: "application/vnd.apple.mpegurl", icyMetaInt: nil
        )
        expect(hls.transport == .hls && hls.hint == "application/vnd.apple.mpegurl",
               "Actual HLS MIME remains on AVFoundation HLS")
        let opus = RadioTransportResolver.classifyHeaders(
            contentType: "audio/ogg", icyMetaInt: nil
        )
        expect(opus.transport == .ffmpeg && opus.hint == "audio/ogg",
               "Ogg uses exotic FFmpeg route")
        let direct = RadioTransportResolver.classifyHeaders(
            contentType: "audio/mpeg", icyMetaInt: nil
        )
        expect(direct.transport == .direct && direct.hint == "audio/mpeg",
               "Ordinary HTTP MP3 stays native")

        // Old station's replies must not touch the current station or song.
        let old = RadioMetadataIdentity(
            generation: 11,
            stationID: "radio:station-A",
            streamURL: "https://radio.example/one"
        )
        expect(old.matches(
            generation: 11, stationID: "radio:station-A",
            streamURL: "https://radio.example/one"
        ), "Same station and generation accepted")
        expect(!old.matches(
            generation: 12, stationID: "radio:station-A",
            streamURL: "https://radio.example/one"
        ), "Later selection invalidates old metadata")
        expect(!old.matches(
            generation: 11, stationID: "radio:station-B",
            streamURL: "https://radio.example/one"
        ), "Station change invalidates old metadata")
        expect(!old.matches(
            generation: 11, stationID: "radio:station-A",
            streamURL: "https://radio.example/two"
        ), "Resolved stream change invalidates old metadata")

        let track = ICYTitleParser.parse("The Beatles - Come Together")
        expect(track?.artist == "The Beatles" && track?.title == "Come Together",
               "ICY Artist - Title parsed")
        let reverse = ICYTitleParser.parse("Hotel California by Eagles")
        expect(reverse?.artist == "Eagles" && reverse?.title == "Hotel California",
               "ICY Title by Artist parsed")
        expect(ICYTitleParser.parse("BBC Radio 1", stationName: "BBC Radio 1") == nil,
               "Station-name-only metadata is rejected")
        expect(ICYTitleParser.parse("https://suspicious.example/track") == nil,
               "URL metadata is not a song title")
        expect(ICYTitleParser.parse("jingle") == nil,
               "Generic station jingles are rejected")
        let suffix = ICYTitleParser.parse(
            "Fleetwood Mac - Dreams - Classic Vinyl on walmradio.com"
        )
        expect(suffix?.artist == "Fleetwood Mac" && suffix?.title == "Dreams",
               "Broadcaster slogan suffix is stripped")

        let tritonURL = URL(string: "https://playerservices.streamtheworld.com/api/livestream-redirect/CARACOL_RADIOAAC_SC")!
        let mounts = TritonProvider.mounts(for: tritonURL)
        expect(mounts.contains("CARACOL_RADIOAAC") && mounts.contains("CARACOL_RADIO"),
               "Triton mount strips _SC and AAC variants")
        expect(BBCRadioProvider.serviceID(
            streamURL: URL(string: "https://example.com/live")!,
            stationName: "BBC Radio 6 Music"
        ) == "bbc_6music", "BBC service id mapped without trusting URL host")
        expect(RadioFranceProvider.stationID(
            streamURL: URL(string: "https://stream.radiofrance.fr/fip")!,
            stationName: "FIP"
        ) == 7, "Radio France station identity resolved")


        // Real FIP URLs include the legacy fipradio.fr hostname; the provider
        // must identify them even though they are outside radiofrance.fr.
        let fipURL = URL(string: "https://direct.fipradio.fr/live/fip-hifi.aac")!
        expect(RadioFranceProvider.matches(streamURL: fipURL, stationName: "FIP"),
               "FIP direct host is eligible for Radio France now-playing")
        expect(RadioFranceProvider.stationID(streamURL: fipURL, stationName: "FIP") == 7,
               "Main FIP resolves to station 7")
        let jazzURL = URL(string: "https://icecast.radiofrance.fr/fipjazz-hifi.aac")!
        expect(RadioFranceProvider.stationID(streamURL: jazzURL, stationName: "FIP Jazz") == nil,
               "FIP Jazz must never show the main FIP song")
        expect(!RadioFranceProvider.matches(streamURL: jazzURL, stationName: "FIP Jazz"),
               "Unknown specialty station does not use main FIP metadata")
        // levels[0] is authoritative; dates in steps alone are not.
        let fipPayload: [String: Any] = [
            "levels": [["position": 1, "items": ["older", "current"]]],
            "steps": [
                "older": ["title": "Old Tune", "authors": ["Old Artist"]],
                "current": [
                    "title": "Current Tune",
                    "authors": ["Current Artist"],
                    "titreAlbum": "Current Album",
                    "visual": "https://example.org/cover.jpg"
                ]
            ]
        ]
        let current = RadioFranceProvider.nowPlaying(from: fipPayload)
        expect(current?.title == "Current Tune" && current?.artist == "Current Artist",
               "FIP current level position selects actual playing title")
        expect(current?.album == "Current Album" && current?.coverURL != nil,
               "FIP uses current album and artwork")
        let stringAuthor: [String: Any] = [
            "levels": [["position": 0, "items": ["track"]]],
            "steps": ["track": ["title": "Track", "authors": "Solo Artist"]]
        ]
        expect(RadioFranceProvider.nowPlaying(from: stringAuthor)?.artist == "Solo Artist",
               "FIP also accepts single-string author fields")
        let wrongPosition: [String: Any] = [
            "levels": [["position": 4, "items": ["track"]]],
            "steps": ["track": ["title": "Track", "authors": ["Artist"]]]
        ]
        expect(RadioFranceProvider.nowPlaying(from: wrongPosition) == nil,
               "Out-of-range FIP level must not publish stale metadata")

        // Background audio is allowed to refresh station metadata, but an
        // inactive transition or paused/unrelated media must not poll.
        expect(RadioBackgroundMetadataPolicy.shouldRefresh(
            isRadio: true, isPlaying: true, appState: .active
        ), "Foreground radio playback polls station metadata")
        expect(RadioBackgroundMetadataPolicy.shouldRefresh(
            isRadio: true, isPlaying: true, appState: .background
        ), "Background audio playback polls station metadata")
        expect(!RadioBackgroundMetadataPolicy.shouldRefresh(
            isRadio: true, isPlaying: true, appState: .inactive
        ), "Transient inactive app does not initiate a network refresh")
        expect(!RadioBackgroundMetadataPolicy.shouldRefresh(
            isRadio: true, isPlaying: false, appState: .background
        ), "Paused background radio never polls")
        expect(!RadioBackgroundMetadataPolicy.shouldRefresh(
            isRadio: false, isPlaying: true, appState: .background
        ), "Music playback never polls a station provider")

        let liveFields = RadioBackgroundMetadataPolicy.lockScreenFields(
            stationTitle: "Radio Paradise", stationArtist: "",
            songTitle: "Come Together", songArtist: "The Beatles"
        )
        expect(liveFields.title == "Come Together"
               && liveFields.artist == "The Beatles"
               && liveFields.album == "Radio Paradise",
               "Now Playing shows the song and retains the station")
        let noArtist = RadioBackgroundMetadataPolicy.lockScreenFields(
            stationTitle: "FIP", stationArtist: "",
            songTitle: "Unknown Composition", songArtist: ""
        )
        expect(noArtist.title == "Unknown Composition"
               && noArtist.artist == "FIP" && noArtist.album == "FIP",
               "Missing artist falls back to the station")
        let noSong = RadioBackgroundMetadataPolicy.lockScreenFields(
            stationTitle: "BBC Radio 6 Music", stationArtist: "BBC",
            songTitle: nil, songArtist: nil
        )
        expect(noSong.title == "BBC Radio 6 Music"
               && noSong.artist == "BBC" && noSong.album.isEmpty,
               "No broadcaster song keeps original station metadata")
        let stationEcho = RadioBackgroundMetadataPolicy.lockScreenFields(
            stationTitle: "BBC Radio 6 Music", stationArtist: "BBC",
            songTitle: "BBC Radio 6 Music", songArtist: "BBC"
        )
        expect(stationEcho == noSong,
               "Station-name-only titles never masquerade as a detected song")

        // Do not expose cached ICY metadata from station A while station B
        // is being selected or while mpv has not committed the new stream.
        expect(RadioBackgroundMetadataPolicy.mayReadICY(
            isRadio: true, selectedStationID: "radio:B",
            activeStationID: "radio:B", pendingStationID: nil
        ), "Current fully loaded radio can publish ICY metadata")
        expect(!RadioBackgroundMetadataPolicy.mayReadICY(
            isRadio: true, selectedStationID: "radio:B",
            activeStationID: "radio:A", pendingStationID: "radio:B"
        ), "Old station ICY blocked during replacement")
        expect(!RadioBackgroundMetadataPolicy.mayReadICY(
            isRadio: true, selectedStationID: "radio:B",
            activeStationID: "radio:B", pendingStationID: "radio:B"
        ), "Pending new mpv load blocks premature ICY metadata")
        expect(!RadioBackgroundMetadataPolicy.mayReadICY(
            isRadio: false, selectedStationID: "video:one",
            activeStationID: "video:one", pendingStationID: nil
        ), "Music never inherits stale radio title")

        let broadcastSong = RadioNowPlaying(
            artist: "Sting", title: "Desert Rose",
            album: "Brand New Day", coverURL: nil
        )
        let previousSong = RadioNowPlaying(
            artist: "Sting", title: "Fields of Gold",
            album: nil, coverURL: nil
        )
        expect(RadioBackgroundMetadataPolicy.acceptsProvider(
            broadcastSong, currentICYRaw: nil, stationName: "FIP"
        ), "Non-ICY stations may use provider current song")
        expect(RadioBackgroundMetadataPolicy.acceptsProvider(
            broadcastSong,
            currentICYRaw: "Sting - Desert Rose", stationName: "FIP"
        ), "Aligned ICY and broadcaster API can enrich artwork")
        expect(!RadioBackgroundMetadataPolicy.acceptsProvider(
            previousSong,
            currentICYRaw: "Sting - Desert Rose", stationName: "FIP"
        ), "Late provider response cannot overwrite newer in-stream title")
        expect(!RadioBackgroundMetadataPolicy.acceptsProvider(
            RadioNowPlaying(
                artist: "Another Artist", title: "Desert Rose",
                album: nil, coverURL: nil
            ),
            currentICYRaw: "Sting - Desert Rose", stationName: "FIP"
        ), "Conflicting artist cannot replace actual in-stream recording")
        expect(RadioBackgroundMetadataPolicy.acceptsProvider(
            broadcastSong, currentICYRaw: "FIP", stationName: "FIP"
        ), "Station-only ICY remains eligible for broadcaster API fallback")

        // Repeated ICY ticks for a song with no match must not query the
        // artwork catalogue once per second; a fresh broadcaster URL may.
        let artworkClock = Date(timeIntervalSince1970: 1_700_000_000)
        let artworkRetry = artworkClock.addingTimeInterval(60)
        expect(RadioBackgroundMetadataPolicy.mayAttemptArtwork(
            key: "sting|desert rose|", failedKey: nil,
            retryAfter: nil, now: artworkClock
        ), "First live cover lookup proceeds immediately")
        expect(!RadioBackgroundMetadataPolicy.mayAttemptArtwork(
            key: "sting|desert rose|", failedKey: "sting|desert rose|",
            retryAfter: artworkRetry, now: artworkClock.addingTimeInterval(1)
        ), "Failed live cover is not retried on the next ICY tick")
        expect(RadioBackgroundMetadataPolicy.mayAttemptArtwork(
            key: "sting|desert rose|", failedKey: "sting|desert rose|",
            retryAfter: artworkRetry, now: artworkRetry
        ), "Failed cover becomes eligible again when cooldown expires")
        expect(RadioBackgroundMetadataPolicy.mayAttemptArtwork(
            key: "sting|desert rose|https://example.org/cover.jpg",
            failedKey: "sting|desert rose|", retryAfter: artworkRetry,
            now: artworkClock.addingTimeInterval(1)
        ), "New broadcaster cover bypasses a failed catalogue-only lookup")
        expect(RadioBackgroundMetadataPolicy.mayAttemptArtwork(
            key: "sting|desert rose|brand new day|",
            failedKey: "sting|desert rose||", retryAfter: artworkRetry,
            now: artworkClock.addingTimeInterval(1)
        ), "New album credits bypass a failed no-album lookup")
        expect(RadioBackgroundMetadataPolicy.mayPublishStationArtwork(
            isRadio: true, liveSongHasArtwork: false
        ), "Radio station logo may show until song art arrives")
        expect(!RadioBackgroundMetadataPolicy.mayPublishStationArtwork(
            isRadio: true, liveSongHasArtwork: true
        ), "Late radio station logo never replaces identified song artwork")
        expect(RadioBackgroundMetadataPolicy.mayPublishStationArtwork(
            isRadio: false, liveSongHasArtwork: true
        ), "Regular song artwork continues to use its own thumbnail pipeline")

        print("PASS: \(passed) radio transport / metadata / station race checks")
    }
}
