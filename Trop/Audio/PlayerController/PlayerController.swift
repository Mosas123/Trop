//
//  PlayerController.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Foundation
import ApoloEngine
import Synchronization
import Libmpv
import MediaPlayer
import Combine
import AVFoundation
import UIKit
import Metal

// MARK: - DetectedCrop (parsed from mpv log)

struct DetectedCrop {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
}

// MARK: - PlayerController

/// Mutable state shared between the mpv event-loop thread and the main actor.
/// Guarded by a single mutex; `String?` fields are read cross-thread, which is
/// the one thing a torn read can actually crash on.
/// A `@unchecked Sendable` box for non-Sendable handles (`OpaquePointer`, `Thread`)
/// whose access is serialized by `mpvAccessQueue` or written once and never read.
private final class SendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private struct MPVSharedState: Sendable {
    var isRunning = false
    var currentVideoId: String?
    var pendingVideoId: String?
    var desiredPlaying = false
    var videoFlipAwaitingRestart = false
}

@MainActor
final class PlayerController {
    static let shared = PlayerController()

    nonisolated private let sharedState = Mutex(MPVSharedState())

    /// MainActor-safe reads for external consumers (e.g. SponsorBlock).
    var currentVideoId: String? { sharedState.withLock { $0.currentVideoId } }
    var pendingVideoId: String? { sharedState.withLock { $0.pendingVideoId } }

    /// `UIImage` is not Sendable, but `MPMediaItemArtwork`'s request handler runs
    /// on a background queue. Wrap the rendered image so the `@Sendable` handler
    /// can capture it without inheriting `@MainActor` isolation.
    private final class SendableArtwork: @unchecked Sendable {
        let image: UIImage
        init(_ image: UIImage) { self.image = image }
    }

    /// Builds the artwork on a nonisolated context so its request handler closure
    /// does not inherit `@MainActor` isolation (which traps under Swift 6).
    private nonisolated static func makeArtwork(from image: UIImage) -> MPMediaItemArtwork {
        let box = SendableArtwork(image)
        return MPMediaItemArtwork(boundsSize: image.size) { _ in box.image }
    }

    nonisolated private let mpvHandle = Mutex<SendableBox<OpaquePointer>?>(nil)
    /// Serial queue for all mpv property read/write calls
    let mpvAccessQueue = DispatchQueue(label: "com.686udjie.PlayerController.mpvAccess")

    nonisolated private let mpvThread = Mutex<SendableBox<Thread>?>(nil)

    private var lastDetectedCrop: String?
    private var detectedCropRepeatCount = 0
    var currentLoudnessDb: Double?
    var pendingURL: String?
    struct PendingMetadata {
        let title: String
        let artist: String?
        let videoId: String
        let artists: [YTArtist]
        let thumbnailUrl: String?
    }

    /// Deferred title/artwork metadata, applied when mpv actually starts the
    /// new file (FILE_LOADED) so the UI never shows a new title while the
    /// previous song is still audibly playing.
    private var pendingMetadata: PendingMetadata?
    private var wasPlayingBeforeInterruption = false
    private var interruptedPlaybackIdentity: (id: String?, generation: Int)?
    private var headsetHandoffIntent: AudioRouteHandoffIntent?
    private var apoloAudioInterruptionActive = false
    private var apoloLastInterruptionEndedAt: Date?
    /// Ignore stale route notifications and avoid overriding a newer Play/Pause.
    private var routeChangeGeneration: UInt64 = 0
    private var playbackCommandGeneration: UInt64 = 0
    // Diagnostics only. Never used to decide when to resume or fall back.
    private var recoveryID: UInt64 = 0
    private var recoveryBegin: TimeInterval?
    private var recoveryEnd: TimeInterval?
    private var recoveryPositionAtEnd: TimeInterval?
    private var recoveryAdvanced = false
    private var recoveryObservedState: String?

    /// Video-mode state. Reads happen on the event loop thread from event handlers;
    /// writes happen on the main actor from `setVideoMode` / `loadFileReplacing`.
    /// Cross-thread access is serialized by the event loop reading these values
    /// synchronously before dispatching work to the main actor.
    var videoModeSwitchInFlight = false
    var loadedMuxedURL: String?
    var loadedVideoOnlyURL: String?
    var voWarmedVideoId: String?
    var muxedActive = false
    var muxedVideoId: String?
    var hasPresentedVideo = false
    var voInitDrawableSize: CGSize = .zero
    private var lastGeometryRefreshAt = Date.distantPast
    private var videoAttachTask: Task<Bool, Never>?
    private var videoAttachTaskId: String?

    var videoLayer: CAMetalLayer = {
        let layer = CAMetalLayer()
        layer.device = MTLCreateSystemDefaultDevice()
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = 1
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = UIColor.clear.cgColor
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        layer.frame = bounds
        layer.drawableSize = CGSize(
            width: bounds.width * layer.contentsScale,
            height: bounds.height * layer.contentsScale
        )
        return layer
    }()

    let playState = CurrentValueSubject<State, Never>(.stopped)
    var pendingResumeAt: TimeInterval = 0
    var nowPlayingInfo = [String: Any]()
    /// Temporary volume (0…1) used to mask the lossless hot-swap. `nil` means
    /// follow the user setting.
    private var volumeOverride: Double?
    private var pendingSeek: (target: TimeInterval, deadline: Date)?
    private var metadataDebounceTask: Task<Void, Never>?

    // Opt-in audio-only beta. Thrum retains queue, system commands and session.
    private var apoloBackend: ApoloAudioBackend?
    private var apoloIsActive = false
    private var apoloGeneration: UInt64 = 0
    /// Every explicit source load, not only queue-owned intents, receives a
    /// serial token. Older async operations cannot publish onto a new load.
    private var playRequestSerial: UInt64 = 0
    private var apoloMonitorTask: Task<Void, Never>?
    private var apoloTrackingTask: Task<Void, Never>?
    var isApoloActive: Bool { apoloIsActive }

    var currentTime: TimeInterval {
        if apoloIsActive { return apoloBackend?.currentTime ?? 0 }
        return withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
    }

    var duration: TimeInterval {
        if apoloIsActive { return max(apoloBackend?.duration ?? 0, NowPlaying.shared.duration) }
        return withMpv { mpv in
            var val = Double(0)
            mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &val)
            return val
        } ?? 0
    }

    enum State: Equatable { case stopped, playing, paused }

    private init() {
        assertAudioSession()
        setupRemoteCommands()
        observeInterruptions()
        observeAudioSessionReset()
        startMpv()
    }

    deinit {
        sharedState.withLock { $0.isRunning = false }
        mpvHandle.withLock { if let box = $0 { mpv_wakeup(box.value) } }
    }

    /// Radio titles come from whichever engine actually owns playback.
    /// Never read a stale mpv ICY property while Apolo plays a station.
    func icyTitle() -> String? {
        if apoloIsActive { return apoloBackend?.liveTitle }
        return withMpv { mpv -> String? in
            guard let cstr = mpv_get_property_string(mpv, "icy-title") else { return nil }
            defer { mpv_free(UnsafeMutableRawPointer(cstr)) }
            let value = String(cString: cstr)
            return value.isEmpty ? nil : value
        } ?? nil
    }

    nonisolated func withMpv<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) -> T) -> T? {
        var result: T?
        mpvHandle.withLock { box in
            guard let box else { return }
            result = body(box.value)
        }
        return result
    }

    // MARK: - Layer helper

    func clearVideoLayer() {
        guard let device = videoLayer.device,
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let drawable = videoLayer.nextDrawable() else { return }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.endEncoding()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    @MainActor
    func applyPendingResumeIfNeeded() {
        guard pendingResumeAt > 0 else { return }
        let target = pendingResumeAt
        pendingResumeAt = 0
        seek(to: target)
    }
}

// MARK: - Playback

extension PlayerController {
    /// Ignore only truly identical, already-playing/connecting radio requests.
    /// This guard precedes all source-load serial and AVPlayer teardown work.
    private func shouldSuppressDuplicateLiveRadioLoad(
        url: URL,
        videoId: String?,
        bypassApolo: Bool
    ) -> Bool {
        guard videoId?.hasPrefix(NowPlaying.radioPrefix) == true else { return false }
        let isApoloLoadingOrPlaying: Bool
        switch apoloBackend?.state {
        case .some(.loading), .some(.playing):
            isApoloLoadingOrPlaying = true
        default:
            isApoloLoadingOrPlaying = false
        }
        let activeSession = LiveRadioDuplicateRequestPolicy.ActiveSession(
            stationID: currentVideoId,
            streamURL: NowPlaying.shared.currentStreamURL.flatMap(URL.init(string:)),
            apoloActive: apoloIsActive,
            apoloRadioEnabled: SettingsStore.shared.apoloRadioBetaEnabled,
            isLoadingOrPlaying: isApoloLoadingOrPlaying,
            desiredPlaying: sharedState.withLock { $0.desiredPlaying },
            isInterrupted: apoloAudioInterruptionActive
        )
        let shouldSuppress = LiveRadioDuplicateRequestPolicy.shouldSuppress(
            requestedID: videoId,
            requestedURL: url,
            bypassApolo: bypassApolo,
            active: activeSession
        )
        if shouldSuppress {
            // No request serial/metadata/AVPlayerItem modification.
            Log.player.info("RADIO_DUPLICATE_SUPPRESSED videoId=\(videoId ?? "nil")")
        }
        return shouldSuppress
    }
    @MainActor
    func play(
        url: String,
        title: String? = nil,
        artist: String? = nil,
        videoId: String? = nil,
        duration: TimeInterval? = nil,
        artists: [YTArtist] = [],
        loudnessDb: Double? = nil,
        thumbnailUrl: String? = nil,
        losslessLabel: String? = nil,
        qualityLabel: String? = nil,
        startAt: TimeInterval = 0,
        bypassApolo: Bool = false,
        intentGeneration: Int? = nil,
        sourceMIMEType: String? = nil,
        isAtmos: Bool = false,
        bypassSponsorBlock: Bool = false
    ) async {
        if let intentGeneration,
           intentGeneration != NowPlaying.shared.playbackGeneration {
            Log.player.info(
                "PLAY_INTENT drop gen=\(intentGeneration) current=\(NowPlaying.shared.playbackGeneration) videoId=\(videoId ?? "nil")"
            )
            return
        }
        let candidateURL = URL(string: url)
        if let candidateURL,
           shouldSuppressDuplicateLiveRadioLoad(
               url: candidateURL,
               videoId: videoId,
               bypassApolo: bypassApolo
           ) {
            return
        }
        playRequestSerial &+= 1
        let requestSerial = playRequestSerial
        guard let url = candidateURL else {
            Log.player.error("Invalid playback source URL")
            return
        }

        // SponsorBlock may await its segment prefetch. Do not change the
        // displayed title, stream quality or progress until the request still
        // owns the player after that asynchronous boundary.
        var skipStart: Double = 0
        if !bypassSponsorBlock,
           SponsorBlock.skipsIntroAtStart,
           MusicPlaybackIdentity.isYouTube(videoId) {
            skipStart = await SponsorBlockIntegration.shared.preloadedStartOffset(for: videoId)
        }
        if let intentGeneration,
           intentGeneration != NowPlaying.shared.playbackGeneration {
            Log.player.info(
                "PLAY_INTENT drop post-await gen=\(intentGeneration) current=\(NowPlaying.shared.playbackGeneration) videoId=\(videoId ?? "nil")"
            )
            return
        }
        guard PlaybackIntentGuard.isLatest(
            serial: requestSerial, latestSerial: playRequestSerial
        ) else {
            Log.player.info(
                "PLAY_INTENT drop superseded source request videoId=\(videoId ?? "nil") serial=\(requestSerial)"
            )
            return
        }
        if let videoId, let title, videoId != NowPlaying.shared.videoId {
            NowPlaying.shared.beginTransition(to: videoId)
            pendingMetadata = PendingMetadata(
                title: title,
                artist: artist,
                videoId: videoId,
                artists: artists,
                thumbnailUrl: thumbnailUrl
            )
            NowPlaying.shared.videoId = videoId
        }
        guard NowPlaying.shared.videoId == videoId else { return }
        if headsetHandoffIntent?.playbackID != videoId {
            // A new selection supersedes any old Bluetooth handoff.
            headsetHandoffIntent = nil
        }
        if apoloAudioInterruptionActive {
            // A new song selected during interruption is the latest intent.
            interruptedPlaybackIdentity = (
                id: videoId, generation: NowPlaying.shared.playbackGeneration
            )
            wasPlayingBeforeInterruption = true
        }

        currentLoudnessDb = loudnessDb
        NowPlaying.shared.losslessFormatLabel = losslessLabel
        NowPlaying.shared.isLosslessStream = losslessLabel != nil
        NowPlaying.shared.qualityBadgeLabel = qualityLabel ?? losslessLabel
        NowPlaying.shared.currentStreamURL = url.absoluteString
        NowPlaying.shared.currentLosslessLabel = losslessLabel

        // The three Apolo beta routes are independent. Thrum still owns
        // queue, session and remote commands. Podcasts are finite/seekeable;
        // only the radio route uses Apolo.loadLive.
        let playbackKind = NowPlaying.shared.playbackKind
        let isLiveRadio = playbackKind == .radio
        if isLiveRadio {
            NowPlaying.shared.radioPlaybackStatus = .connecting
        }
        let useApolo: Bool
        switch playbackKind {
        case .radio: useApolo = SettingsStore.shared.apoloRadioBetaEnabled
        case .podcast: useApolo = SettingsStore.shared.apoloPodcastsBetaEnabled
        case .music: useApolo = SettingsStore.shared.apoloBetaEnabled
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if !bypassApolo,
           useApolo,
           (isLiveRadio
                ? ["http", "https"].contains(scheme)
                : ["file", "http", "https"].contains(scheme)) {
            // A station is a continuous live session: no intro skip or
            // saved playback position may be applied to it.
            var playbackStart = isLiveRadio ? 0 : (startAt > 0 ? startAt : skipStart)
            if !isLiveRadio, startAt == 0,
               let resume = NowPlaying.shared.takeResumePosition(for: videoId),
               resume > 5,
               resume < (duration ?? .greatestFiniteMagnitude) - 5 {
                playbackStart = resume
            }
            await playWithApolo(
                url: url,
                videoId: videoId,
                title: title,
                artist: artist,
                duration: duration,
                startAt: playbackStart,
                sourceMIMEType: sourceMIMEType,
                isAtmos: isAtmos,
                isLiveRadio: isLiveRadio
            )
            return
        }
        deactivateApoloPlayback()
        NowPlaying.shared.activePlaybackEngine = bypassApolo ? "MPVKit (Fallback)" : "MPVKit"

        let prevVideoId = sharedState.withLock { $0.currentVideoId }
        let isNewSong = prevVideoId != nil && videoId != prevVideoId

        sharedState.withLock { $0.desiredPlaying = true }
        assertAudioSession()
        loadedMuxedURL = nil
        loadedVideoOnlyURL = nil
        voWarmedVideoId = nil
        muxedActive = false
        muxedVideoId = nil
        pendingResumeAt = 0
        pendingSeek = nil
        videoModeSwitchInFlight = false
        sharedState.withLock { $0.videoFlipAwaitingRestart = false }
        NowPlaying.shared.isVideoMode = false
        NowPlaying.shared.isVideoReady = false
        if hasPresentedVideo { clearVideoLayer() }
        let isReady = withMpv { _ in true } ?? false
        guard isReady else {
            Log.player.info("mpv not ready yet, parking URL for deferred load")
            pendingURL = url.absoluteString
            sharedState.withLock { $0.pendingVideoId = videoId }
            return
        }

        applyPlaybackSettings()
        setVideoCrop(.none)

        sharedState.withLock { $0.pendingVideoId = videoId }
        // `startAt` lets an in-place quality upgrade resume at the same
        // position instead of restarting the track.
        var playbackStart = startAt > 0 ? startAt : skipStart
        if startAt == 0,
           let resume = NowPlaying.shared.takeResumePosition(for: videoId),
           resume > 5,
           resume < (duration ?? .greatestFiniteMagnitude) - 5 {
            playbackStart = resume
        }
        let loadStart = playbackStart > 0 ? Int(playbackStart.rounded(.up)) : 0
        let loadArguments = loadStart > 0
            ? ["loadfile", url.absoluteString, "replace", "-1", "start=\(loadStart)"]
            : ["loadfile", url.absoluteString, "replace"]
        Log.player.info(
            "TRANSITION play videoId=\(videoId ?? "nil") isNewSong=\(isNewSong) muxedActive=\(muxedActive) "
                + "source=\(Self.apoloSource(url))"
        )
        let holdForInterruption = apoloAudioInterruptionActive
        let cmdResult = withMpv { mpv -> Int32 in
            mpv_set_property_string(
                mpv, "pause", holdForInterruption ? "yes" : "no"
            )
            return loadArguments.withUnsafeCArg { mpv_command(mpv, $0) }
        } ?? -1
        if cmdResult != 0 {
            Log.player.error("mpv_command loadfile failed result=\(cmdResult)")
            sharedState.withLock { $0.pendingVideoId = nil }
            if let videoId {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    NowPlaying.shared.reportPlaybackFailure(videoId: videoId)
                }
            }
            return
        }
        if isNewSong {
            await PlaybackStateService.shared.stopTracking()
        }
        guard PlaybackIntentGuard.isLatest(
            serial: requestSerial, latestSerial: playRequestSerial
        ) else { return }
        if let videoId { await PlaybackStateService.shared.startTracking(videoId: videoId) }
        guard PlaybackIntentGuard.isLatest(
            serial: requestSerial, latestSerial: playRequestSerial
        ) else { return }
        let canStartAudio = !apoloAudioInterruptionActive
            && sharedState.withLock { $0.desiredPlaying }
        if apoloAudioInterruptionActive {
            interruptedPlaybackIdentity = (
                id: videoId, generation: NowPlaying.shared.playbackGeneration
            )
        }
        playState.send(canStartAudio ? .playing : .paused)
        NowPlaying.shared.isPlaying = canStartAudio
        NowPlaying.shared.currentTime = playbackStart
        NowPlaying.shared.duration = max(0, duration ?? 0)
        setNowPlayingMetadata()
        if startAt == 0, losslessLabel == nil {
            volumeOverride = 0
            applyPlayerVolume()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard let self,
                      self.playRequestSerial == requestSerial else { return }
                await self.fadeVolume(to: SettingsStore.shared.playerVolume, duration: 0.3)
                guard self.playRequestSerial == requestSerial else { return }
                self.setVolumeOverride(nil)
            }
        }
    }

    func seek(to time: TimeInterval) {
        // A live station is nonseekable, regardless of MPV or Apolo route.
        guard NowPlaying.shared.playbackKind != .radio else { return }
        pendingSeek = (time, Date().addingTimeInterval(1.5))
        NowPlaying.shared.currentTime = time
        if apoloIsActive {
            let generation = apoloGeneration
            Task { @MainActor [weak self] in
                guard let self, self.apoloIsActive,
                      self.apoloGeneration == generation else { return }
                await self.apoloBackend?.seek(to: time)
                self.updateNowPlayingProgress()
            }
            return
        }
        withMpv { mpv in
            var val = time
            let result = mpv_set_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
            if result < 0 { Log.player.error("seek failed: mpv error \(result)") }
        }
    }

    func setPaused(
        _ paused: Bool,
        forceBackendCommand: Bool = false,
        systemRecovery: Bool = false
    ) {
        if paused && !systemRecovery {
            // An explicit Pause cancels every pending automatic resume.
            wasPlayingBeforeInterruption = false
            headsetHandoffIntent = nil
        }
        if !paused { traceRecovery("playRequested") }
        playbackCommandGeneration &+= 1
        sharedState.withLock { $0.desiredPlaying = !paused }
        if !paused && apoloAudioInterruptionActive {
            // iOS still owns the audio session. Remember Play but do not
            // announce playback or command Apolo/AVPlayer/mpv prematurely.
            wasPlayingBeforeInterruption = true
            traceRecovery("playDeferredUntilInterruptionEnds")
            return
        }
        let currentlyPaused = playState.value != .playing
        // A route handoff can pause/stall the renderer without first changing
        // the UI's optimistic .playing state. Never discard a real Play command.
        let apoloNeedsResume: Bool
        if !paused, apoloIsActive {
            if case .some(.playing) = apoloBackend?.state {
                apoloNeedsResume = false
            } else {
                apoloNeedsResume = true
            }
        } else {
            apoloNeedsResume = false
        }
        guard currentlyPaused != paused || forceBackendCommand || apoloNeedsResume else {
            updateNowPlayingProgress()
            return
        }
        // Restore the session *before* asking AVPlayer/FFmpeg/mpv to resume.
        // On Bluetooth handoff, the previous ordering could publish Play
        // while the audio session had not yet been reactivated.
        if !paused { assertAudioSession(reason: "setPaused") }
        if apoloIsActive {
            if paused { apoloBackend?.pause() } else { apoloBackend?.play() }
        } else {
            withMpv { mpv in
                var flag: Int32 = paused ? 1 : 0
                mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
            }
        }
        playState.send(paused ? .paused : .playing)
        NowPlaying.shared.isPlaying = !paused
        if !paused { traceRecovery("uiPlaying.notAudioConfirmed") }
        if NowPlaying.shared.playbackKind == .radio {
            NowPlaying.shared.radioPlaybackStatus = paused
                ? .paused : (apoloIsActive ? .connecting : .live)
        }
        updateNowPlayingProgress()
    }

    func togglePlayPause() {
        setPaused(playState.value == .playing)
    }

    func setVolumeOverride(_ value: Double?) {
        volumeOverride = value
        applyPlayerVolume()
    }

    func applyPlayerVolume() {
        let vol = volumeOverride ?? SettingsStore.shared.playerVolume
        if apoloIsActive {
            apoloBackend?.volume = Float(max(0, min(1, vol)))
            return
        }
        withMpv { mpv in
            var val = Double(vol * 100)
            mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &val)
        }
    }

    /// Short volume ramp so a stream swap doesn't click or pop.
    func fadeVolume(to fraction: Double, duration: TimeInterval) async {
        let start = volumeOverride ?? SettingsStore.shared.playerVolume
        let steps = 6
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            setVolumeOverride(start + (fraction - start) * progress)
            try? await Task.sleep(for: .seconds(duration / Double(steps)))
        }
    }

    func applyPlaybackSettings() {
        if apoloIsActive {
            // Beta intentionally uses Apolo's default flat DSP. The existing
            // mpv ten-band EQ cannot be mapped one-to-one to Apolo's five bands.
            applyPlayerVolume()
            return
        }
        let settings = SettingsStore.shared
        let loudness = currentLoudnessDb
        let eqEnabled = settings.equalizerEnabled
        let eqGains = settings.equalizerGains
        let gapless = settings.gaplessPlayback
        let norm = settings.audioNormalization

        let chain: String = {
            var filters: [String] = []
            if eqEnabled {
                let entries = zip(equalizerFrequencies, eqGains)
                    .map { "entry(\(Self.fmt($0.0)),\(Self.fmt($0.1)))" }
                    .joined(separator: ";")
                if !entries.isEmpty {
                    filters.append("firequalizer=gain_entry=\"\(entries)\"")
                }
            }
            if norm, let loudness, loudness.isFinite {
                let gain = max(-12, min(12, -14 - loudness))
                filters.append("volume=\(Self.fmt(gain))dB")
            }
            return filters.joined(separator: ",")
        }()

        withMpv { mpv in
            mpv_set_property_string(mpv, "gapless-audio", gapless ? "yes" : "no")
            let result = mpv_set_property_string(mpv, "af", chain.isEmpty ? "" : chain)
            if result < 0 { Log.player.error("Failed to set af chain '\(chain)': mpv error \(result)") }
        }
        applyPlayerVolume()
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

// MARK: - mpv lifecycle & event loop

extension PlayerController {
    fileprivate func startMpv() {
        mpvAccessQueue.async { [weak self] in
            guard let self else { return }
            guard let mpv = mpv_create() else {
                Log.player.error("mpv_create failed")
                return
            }

            _ = setenv("MVK_CONFIG_LOG_LEVEL", "1", 1)

            mpv_request_log_messages(mpv, "warn")
            Self.applyMpvStartupOptions(mpv)

            Log.player.info("mpv initializing...")
            let initResult = mpv_initialize(mpv)
            guard initResult >= 0 else {
                let errStr = String(cString: mpv_error_string(initResult))
                Log.player.error("mpv_initialize failed: \(initResult) (\(errStr))")
                mpv_destroy(mpv)
                return
            }
            Log.player.info("mpv initialized successfully")

            Self.applyPostInitProperties(mpv)
            Self.applyObservedProperties(mpv)

            mpvHandle.withLock { $0 = SendableBox(mpv) }
            Log.player.info("mpv handle published — event loop starting")

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPlaybackSettings()
                if let url = self.pendingURL {
                    self.pendingURL = nil
                    Log.player.info("mpv ready: loading deferred URL \(url.prefix(80))")
                    _ = self.withMpv { mpv in
                        mpv_set_property_string(mpv, "pause", "no")
                        return ["loadfile", url, "replace"].withUnsafeCArg { mpv_command(mpv, $0) }
                    }
                }
            }

            let thread = Thread { [weak self] in
                guard let self else { return }
                self.sharedState.withLock { $0.isRunning = true }
                self.eventLoop(mpv)
            }
            mpvThread.withLock { $0 = SendableBox(thread) }
            thread.name = "com.686udjie.PlayerController.eventLoop"
            thread.start()
        }
    }

    nonisolated private static func applyMpvStartupOptions(_ mpv: OpaquePointer) {
        mpv_set_option_string(mpv, "vo", "null")
        mpv_set_option_string(mpv, "vid", "no")
        mpv_set_option_string(mpv, "force-window", "no")
        mpv_set_option_string(mpv, "msg-level", "all=error")

        #if targetEnvironment(simulator)
        mpv_set_option_string(mpv, "hwdec", "no")
        mpv_set_option_string(mpv, "audio-exclusive", "no")
        #else
        mpv_set_option_string(mpv, "hwdec", "videotoolbox")
        mpv_set_option_string(mpv, "audio-exclusive", "yes")
        #endif

        mpv_set_option_string(mpv, "keep-open", "no")
        mpv_set_option_string(mpv, "cache", "yes")
        mpv_set_option_string(mpv, "cache-secs", "120")
        mpv_set_option_string(mpv, "demuxer-max-bytes", "200M")
        mpv_set_option_string(mpv, "gapless-audio", "yes")
    }

    nonisolated private static func applyPostInitProperties(_ mpv: OpaquePointer) {
        if let caPath = Bundle.main.path(forResource: "cacert", ofType: "pem") {
            mpv_set_property_string(mpv, "tls-ca-file", caPath)
            Log.player.info("mpv tls-ca-file set: \(caPath)")
        } else {
            Log.player.warning("mpv cacert.pem not found in main bundle")
        }
        let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15" +
            " (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        mpv_set_property_string(mpv, "user-agent", userAgent)
        mpv_set_property_string(mpv, "video-unscaled", "no")
        mpv_set_property_string(mpv, "keepaspect", "no")
    }

    nonisolated private static func applyObservedProperties(_ mpv: OpaquePointer) {
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 1, "video-params/w", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 2, "video-out-params", MPV_FORMAT_NODE)
    }

    nonisolated fileprivate func eventLoop(_ mpv: OpaquePointer) {
        while sharedState.withLock({ $0.isRunning }) {
            guard let event = mpv_wait_event(mpv, 0.2) else { continue }
            switch event.pointee.event_id {
            case MPV_EVENT_NONE:
                break
            case MPV_EVENT_LOG_MESSAGE:
                handleLogMessage(event)
            case MPV_EVENT_FILE_LOADED:
                handleFileLoaded(mpv)
            case MPV_EVENT_PROPERTY_CHANGE:
                handlePropertyChange(event)
            case MPV_EVENT_START_FILE:
                Log.player.debug("TRANSITION START_FILE")
            case MPV_EVENT_END_FILE:
                handleEndFile(event)
            case MPV_EVENT_VIDEO_RECONFIG:
                handleVideoReconfig()
            case MPV_EVENT_PLAYBACK_RESTART:
                handlePlaybackRestart()
            default:
                break
            }
        }
        mpvHandle.withLock { $0 = nil }
        mpv_destroy(mpv)
    }

    nonisolated private func handleLogMessage(_ event: UnsafeMutablePointer<mpv_event>) {
        if let prop = event.pointee.data?.load(as: mpv_event_log_message.self),
           let textPtr = prop.text {
            let text = String(cString: textPtr)
            let prefix = prop.prefix.map { String(cString: $0) } ?? ""
            let level = prop.level.map { String(cString: $0) } ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if trimmed.range(of: "primitive restart", options: .caseInsensitive) != nil { return }
                Log.mpv.debug("[\(prefix)] [\(level)] \(trimmed)")
                if let crop = detectedCrop(from: trimmed) {
                    Task { @MainActor in self.applyDetectedCrop(crop) }
                }
            }
        }
    }

    nonisolated private func handleFileLoaded(_ mpv: OpaquePointer) {
        var pauseFlag = Int32(1)
        mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag)
        if pauseFlag != 0, sharedState.withLock({ $0.desiredPlaying }) {
            var unpause = Int32(0)
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &unpause)
            mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &pauseFlag)
        }
        let actuallyPlaying = pauseFlag == 0
        let pendingVideoId = self.sharedState.withLock { $0.pendingVideoId }
        Task { @MainActor [weak self] in
            guard let self, !self.apoloIsActive else { return }
            if let meta = self.pendingMetadata {
                self.pendingMetadata = nil
                NowPlaying.shared.update(
                    title: meta.title,
                    artist: meta.artist,
                    videoId: meta.videoId,
                    artists: meta.artists,
                    thumbnailUrl: meta.thumbnailUrl,
                    preserveMissingArtist: true
                )
            }
            Log.player.debug("TRANSITION FILE_LOADED videoId=\(pendingVideoId ?? "nil") playing=\(actuallyPlaying)")
            self.playState.send(actuallyPlaying ? .playing : .paused)
            NowPlaying.shared.isPlaying = actuallyPlaying
            if NowPlaying.shared.playbackKind == .radio {
                NowPlaying.shared.radioPlaybackStatus = actuallyPlaying ? .live : .paused
            }
            self.sharedState.withLock { $0.currentVideoId = pendingVideoId }
            self.sharedState.withLock { $0.pendingVideoId = nil }
            self.assertAudioSession()
            self.setNowPlayingMetadata()
            self.applyPendingResumeIfNeeded()
            let checkId = pendingVideoId
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard self.sharedState.withLock({ $0.currentVideoId }) == checkId else { return }
                self.updateNowPlayingArtwork()
                self.updateNowPlayingProgress()
            }
        }
    }

    nonisolated private func handlePropertyChange(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let prop = event.pointee.data?.load(as: mpv_event_property.self),
              let namePtr = prop.name else { return }
        let name = String(cString: namePtr)

        if name == "duration", prop.format == MPV_FORMAT_DOUBLE {
            let newDur: Double = prop.data?.load(as: Double.self) ?? 0
            if newDur > 0 {
                Task { @MainActor in
                    guard !self.apoloIsActive else { return }
                    NowPlaying.shared.duration = newDur
                    // mpv can emit several duration updates as a stream
                    // settles; coalesce the (expensive) metadata rebuild.
                    self.scheduleNowPlayingMetadata()
                }
            }
        } else if name == "video-params/w", prop.format == MPV_FORMAT_INT64 {
            let width: Int64 = prop.data?.load(as: Int64.self) ?? 0
            if width > 0 {
                Task { @MainActor in
                    let ok = self.muxedActive && NowPlaying.shared.videoId == self.muxedVideoId
                    guard ok else { return }
                    if self.hasPresentedVideo { self.clearVideoLayer() }
                    // Only the flip owns the mount; background prerender must
                    // never pop the UI (ready is still recorded below).
                    if self.videoModeSwitchInFlight { NowPlaying.shared.isVideoMode = true }
                    self.hasPresentedVideo = true
                }
            }
        } else if name == "video-out-params", prop.format == MPV_FORMAT_NODE {
            Task { @MainActor in
                let ok = self.muxedActive && NowPlaying.shared.videoId == self.muxedVideoId
                guard ok else { return }
                if self.videoModeSwitchInFlight { NowPlaying.shared.isVideoMode = true }
                NowPlaying.shared.isVideoReady = true
                self.hasPresentedVideo = true
            }
        }
    }

    nonisolated private func handleVideoReconfig() {
        Task { @MainActor in
            let ok = self.muxedActive && NowPlaying.shared.videoId == self.muxedVideoId
            guard ok else { return }
            if self.videoModeSwitchInFlight { NowPlaying.shared.isVideoMode = true }
            NowPlaying.shared.isVideoReady = true
            self.hasPresentedVideo = true
        }
    }

    nonisolated private func handlePlaybackRestart() {
        let flipPending = self.sharedState.withLock { $0.videoFlipAwaitingRestart }
        Task { @MainActor in
            guard flipPending else { return }
            let ok = self.muxedActive && NowPlaying.shared.videoId == self.muxedVideoId
            self.sharedState.withLock { $0.videoFlipAwaitingRestart = false }
            guard ok else { return }
            if self.videoModeSwitchInFlight { NowPlaying.shared.isVideoMode = true }
            NowPlaying.shared.isVideoReady = true
            self.hasPresentedVideo = true
        }
    }

    nonisolated private func handleEndFile(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let data = event.pointee.data else { return }
        let endFile = data.load(as: mpv_event_end_file.self)
        let reason = endFile.reason
        let isEof = reason == MPV_END_FILE_REASON_EOF
        let isError = reason == MPV_END_FILE_REASON_ERROR
        let stoppedVideoId = self.sharedState.withLock { $0.currentVideoId }
        Task { @MainActor [weak self] in
            guard let self, !self.apoloIsActive else { return }
            let videoId = stoppedVideoId
            Log.player.debug(
                "TRANSITION END_FILE reason=\(reason.rawValue) isEof=\(isEof) isError=\(isError) stoppedVideoId=\(videoId ?? "nil")"
            )
            if isError, videoId != nil {
                Task { await PlaybackStateService.shared.stopTracking() }
            }
            if isEof {
                self.playState.send(.stopped)
                NowPlaying.shared.stopped(videoId: videoId, isEof: true)
            } else if isError {
                self.sharedState.withLock { $0.currentVideoId = nil }
                self.playState.send(.stopped)
                NowPlaying.shared.stopped(videoId: videoId, isEof: false)
            } else {
                Log.player.debug("END_FILE non-EOF ignored for auto-advance")
            }
        }
    }
}

// MARK: - Video mode

extension PlayerController {
    func setVideoMode() {
        guard !SettingsStore.shared.apoloBetaEnabled, !apoloIsActive else { return }
        // No real video (e.g. art-track): stay in the big player, do nothing.
        guard NowPlaying.shared.hasVideo else { return }
        guard let videoId = NowPlaying.shared.videoId else { return }
        if muxedActive {
            NowPlaying.shared.isVideoMode = true
            NowPlaying.shared.isVideoReady = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard NowPlaying.shared.videoId == videoId,
                      NowPlaying.shared.isVideoMode else { return }
                guard self.videoLayerDrifted() else { return }
                NowPlaying.shared.isVideoReady = false
                self.setVideoTrack()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard NowPlaying.shared.videoId == videoId,
                      NowPlaying.shared.isVideoMode,
                      !NowPlaying.shared.isVideoReady else { return }
                NowPlaying.shared.isVideoReady = true
            }
            return
        }
        guard !videoModeSwitchInFlight else { return }
        videoModeSwitchInFlight = true
        NowPlaying.shared.isVideoMode = true
        NowPlaying.shared.isVideoReady = false
        Task {
            defer { videoModeSwitchInFlight = false }
            if loadedVideoOnlyURL != nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard NowPlaying.shared.videoId == videoId else { return }
            }
            do {
                guard await ensureVideoAttached(videoId: videoId) else {
                    throw StreamError.noSuitableFormat
                }
                guard NowPlaying.shared.videoId == videoId, NowPlaying.shared.isVideoMode else { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard NowPlaying.shared.videoId == videoId, NowPlaying.shared.isVideoMode else { return }
                Log.player.debug("TRANSITION video flipped videoId=\(videoId)")
                NowPlaying.shared.isVideoReady = true
                return
            } catch {
                Log.player.debug("video attach failed, falling back to EDL replace: \(error)")
            }
            do {
                sharedState.withLock { $0.videoFlipAwaitingRestart = false }
                let resumeAt = currentTime
                let url: String
                if let loaded = loadedMuxedURL {
                    url = loaded
                } else {
                    url = try await PlaybackManager.shared.resolveMuxedURL(videoId: videoId)
                    guard NowPlaying.shared.videoId == videoId else { return }
                    loadedMuxedURL = url
                }
                guard NowPlaying.shared.videoId == videoId else { return }
                setVideoTrack()
                Log.player.debug("TRANSITION entering video mode videoId=\(videoId) url=\(url.prefix(80))")
                muxedVideoId = videoId
                sharedState.withLock { $0.pendingVideoId = videoId }
                loadFileReplacing(url, startAt: resumeAt)
                muxedActive = true
            } catch {
                Log.player.error("setVideoMode failed: \(error)")
                NowPlaying.shared.isVideoMode = false
                NowPlaying.shared.isVideoReady = false
            }
        }
    }

    func ensureVideoAttached(videoId: String) async -> Bool {
        if muxedActive, muxedVideoId == videoId { return true }
        if let task = videoAttachTask, videoAttachTaskId == videoId {
            return await task.value
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.attachVideoTrack(videoId: videoId)
        }
        videoAttachTask = task
        videoAttachTaskId = videoId
        let result = await task.value
        if videoAttachTaskId == videoId {
            videoAttachTask = nil
            videoAttachTaskId = nil
        }
        return result
    }

    private func attachVideoTrack(videoId: String) async -> Bool {
        do {
            // Already initialized at the right size by preload? Don't churn.
            if voWarmedVideoId != videoId || videoLayerDrifted() {
                setVideoTrack()
            }
            let videoURL: String
            if let preloaded = loadedVideoOnlyURL {
                videoURL = preloaded
            } else {
                videoURL = try await PlaybackManager.shared.resolveVideoOnlyURL(videoId: videoId)
                guard NowPlaying.shared.videoId == videoId else { return false }
                loadedVideoOnlyURL = videoURL
            }
            guard NowPlaying.shared.videoId == videoId else { return false }
            let addResult = withMpv { mpv in
                ["video-add", videoURL, "select"].withUnsafeCArg { mpv_command(mpv, $0) }
            } ?? -1
            guard addResult == 0 else { throw StreamError.noSuitableFormat }
            guard await waitForVideoTrack(videoId: videoId) else { throw StreamError.noSuitableFormat }
            guard NowPlaying.shared.videoId == videoId else { return false }
            muxedVideoId = videoId
            muxedActive = true
            voInitDrawableSize = videoLayer.drawableSize
            // video-add starts at 0 while audio is live — seek both to now.
            let syncAt = currentTime
            sharedState.withLock { $0.videoFlipAwaitingRestart = true }
            let seekResult = withMpv { mpv in
                ["seek", String(syncAt), "absolute"].withUnsafeCArg { mpv_command(mpv, $0) }
            } ?? -1
            guard seekResult == 0 else {
                sharedState.withLock { $0.videoFlipAwaitingRestart = false }
                throw StreamError.noSuitableFormat
            }
            _ = await waitForFlipRestart(videoId: videoId)
            guard NowPlaying.shared.videoId == videoId else { return false }
            sharedState.withLock { $0.videoFlipAwaitingRestart = false }
            return true
        } catch {
            sharedState.withLock { $0.videoFlipAwaitingRestart = false }
            Log.player.debug("video attach failed videoId=\(videoId): \(error)")
            return false
        }
    }

    private func waitForVideoTrack(videoId: String) async -> Bool {
        for _ in 0..<60 {
            guard NowPlaying.shared.videoId == videoId else { return false }
            let width: Int64 = withMpv { mpv in
                var w = Int64(0)
                mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &w)
                return w
            } ?? 0
            if width > 0 { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func waitForFlipRestart(videoId: String) async -> Bool {
        for _ in 0..<50 {
            guard NowPlaying.shared.videoId == videoId else { return false }
            if !sharedState.withLock({ $0.videoFlipAwaitingRestart }) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func preloadVideoURL() {
        guard let videoId = NowPlaying.shared.videoId else { return }
        guard !isVideoPrerendered(videoId: videoId) else { return }
        Task {
            if loadedVideoOnlyURL == nil {
                do {
                    let url = try await PlaybackManager.shared.resolveVideoOnlyURL(videoId: videoId)
                    guard NowPlaying.shared.videoId == videoId, loadedVideoOnlyURL == nil else { return }
                    loadedVideoOnlyURL = url
                } catch {
                    Log.player.error("Video preload failed: \(error)")
                    return
                }
            }
        }
    }

    private func isVideoPrerendered(videoId: String) -> Bool {
        loadedVideoOnlyURL != nil && voWarmedVideoId == videoId
            && muxedActive && muxedVideoId == videoId
    }

    func handleVideoStreamFailure() {
        guard muxedActive || videoModeSwitchInFlight else { return }
        loadedMuxedURL = nil
        loadedVideoOnlyURL = nil
        voWarmedVideoId = nil
        muxedActive = false
        muxedVideoId = nil
        videoModeSwitchInFlight = false
        sharedState.withLock { $0.videoFlipAwaitingRestart = false }
        NowPlaying.shared.isVideoMode = false
        NowPlaying.shared.isVideoReady = false
    }

    private func setVideoTrack() {
        lastDetectedCrop = nil
        detectedCropRepeatCount = 0
        if videoLayer.superlayer == nil {
            presizeVideoLayerForExpectedFrame()
        }
        voInitDrawableSize = videoLayer.drawableSize
        let wid: Int64 = unsafeBitCast(videoLayer, to: Int64.self)
        withMpv { mpv in
            mpv_set_property_string(mpv, "vo", "null")
            mpv_set_property_string(mpv, "vo", "gpu-next")
            mpv_set_property_string(mpv, "gpu-api", "vulkan")
            mpv_set_property_string(mpv, "gpu-context", "moltenvk")
            var widCopy = wid
            mpv_set_property(mpv, "wid", MPV_FORMAT_INT64, &widCopy)
            mpv_set_property_string(mpv, "vid", "auto")
        }
        setVideoCrop(.none)
    }

    private func presizeVideoLayerForExpectedFrame() {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        guard let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first else { return }
        let width = window.bounds.width - 64
        guard width > 0 else { return }
        let height = width * 9 / 16
        let scale = window.screen.nativeScale > 0 ? window.screen.nativeScale : 3
        videoLayer.frame = CGRect(x: 0, y: 0, width: width, height: height)
        videoLayer.contentsScale = scale
        videoLayer.drawableSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
    }

    func videoLayerDrifted() -> Bool {
        let baseline = voInitDrawableSize
        guard baseline.width > 0, baseline.height > 0 else { return false }
        let current = videoLayer.drawableSize
        return abs(current.width - baseline.width) > 2 || abs(current.height - baseline.height) > 2
    }

    func refreshVideoGeometryIfNeeded() {
        guard muxedActive || hasPresentedVideo else { return }
        guard videoLayerDrifted() else { return }
        guard Date().timeIntervalSince(lastGeometryRefreshAt) > 0.5 else { return }
        lastGeometryRefreshAt = Date()
        Log.player.debug("TRANSITION video VO restart for geometry")
        setVideoTrack()
    }

    nonisolated private func detectedCrop(from log: String) -> DetectedCrop? {
        guard let marker = log.range(of: "crop=") else { return nil }
        let values = log[marker.upperBound...]
            .split(whereSeparator: { $0 == Character(":") || $0 == Character(" ") || $0 == Character("\n") })
            .prefix(4)
            .compactMap { Int($0) }
        guard values.count == 4 else { return nil }
        return DetectedCrop(width: values[0], height: values[1], x: values[2], y: values[3])
    }

    private func applyDetectedCrop(_ crop: DetectedCrop) {
        guard crop.width > 0, crop.height > 0 else { return }
        let signature = "\(crop.width)x\(crop.height)+\(crop.x)+\(crop.y)"
        if lastDetectedCrop == signature {
            detectedCropRepeatCount += 1
        } else {
            lastDetectedCrop = signature
            detectedCropRepeatCount = 1
        }
        guard detectedCropRepeatCount >= 2 else { return }
        _ = withMpv { mpv in
            mpv_set_property_string(mpv, "video-crop", signature)
        }
    }

    enum VideoCropMode { case none, square }

    private struct VideoDims: Sendable {
        var width: Int64
        var height: Int64
        var hasVid: Bool
    }

    private func setVideoCrop(_ mode: VideoCropMode) {
        switch mode {
        case .none:
            _ = withMpv { mpv in
                mpv_set_property_string(mpv, "video-crop", "")
            }
        case .square:
            let dims: VideoDims = withMpv { mpv in
                var w = Int64(0), h = Int64(0)
                mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &w)
                mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &h)
                var vid: UnsafeMutablePointer<CChar>?
                defer { if let vid { mpv_free(vid) } }
                let hasVid = mpv_get_property(mpv, "vid", MPV_FORMAT_STRING, &vid) == 0
                    && vid.map { String(cString: $0) != "no" } ?? false
                return VideoDims(width: w, height: h, hasVid: hasVid)
            } ?? VideoDims(width: 0, height: 0, hasVid: false)
            if dims.width > 0, dims.height > 0 {
                let side = min(dims.width, dims.height)
                _ = withMpv { mpv in
                    mpv_set_property_string(mpv, "video-crop", "\(side)x\(side)")
                }
            } else if dims.hasVid {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.setVideoCrop(.square)
                }
            }
        }
    }

    private func loadFileReplacing(_ url: String, startAt: TimeInterval = 0) {
        pendingResumeAt = startAt
        Log.player.debug("TRANSITION loadFileReplacing startAt=\(startAt) url=\(url.prefix(80))")
        withMpv { mpv in
            let args = ["loadfile", url, "replace"]
            _ = args.withUnsafeCArg { mpv_command(mpv, $0) }
        }
    }
}

// MARK: - Audio session / interruption handling

extension PlayerController {
    private func traceRecovery(_ event: String) {
        guard let start = recoveryBegin else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = Int((now - start) * 1000)
        let postEnd = recoveryEnd.map { Int((now - $0) * 1000) } ?? -1
        let uptimeMs = Int(now * 1000)
        Log.player.info("AUDIO_RECOVERY id=\(self.recoveryID) event=\(event) uptimeMs=\(uptimeMs) sinceBeginMs=\(elapsed) sinceEndMs=\(postEnd)")
    }

    func assertAudioSession(reason: String = "unspecified") {
        let session = AVAudioSession.sharedInstance()
        let start = ProcessInfo.processInfo.systemUptime
        var stage = "category"
        do {
            if session.category != .playback || session.mode != .default {
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            }
            stage = "multichannel"
            try? session.setSupportsMultichannelContent(true)
            stage = "activation"
            try session.setActive(true)
            let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let uptimeMs = Int(ProcessInfo.processInfo.systemUptime * 1000)
            Log.player.info("AUDIO_SESSION_ACTIVATION reason=\(reason) result=success ms=\(ms) uptimeMs=\(uptimeMs)")
            traceRecovery("activation.success.\(reason)")
        } catch {
            let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let code = (error as NSError).code
            let uptimeMs = Int(ProcessInfo.processInfo.systemUptime * 1000)
            Log.player.error("AUDIO_SESSION_ACTIVATION reason=\(reason) result=failed stage=\(stage) code=\(code) ms=\(ms) uptimeMs=\(uptimeMs)")
            traceRecovery("activation.failed.\(reason)")
            Log.player.error("Failed to assert audio session: \(error)")
        }
    }

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        // Modern iOS 27 AVAudioSession APIs are unavailable in the
        // Xcode 26.6 / iOS 26.5 SDK used by CI. Legacy interruption,
        // UIKit lifecycle and renderer timing remain fully instrumented.
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            recoveryID &+= 1
            recoveryBegin = ProcessInfo.processInfo.systemUptime
            recoveryEnd = nil
            recoveryPositionAtEnd = nil
            recoveryAdvanced = false
            recoveryObservedState = nil
            apoloAudioInterruptionActive = true
            interruptedPlaybackIdentity = (
                id: NowPlaying.shared.videoId,
                generation: NowPlaying.shared.playbackGeneration
            )
            traceRecovery("legacyBegan")
            let wasSuspended = (userInfo[AVAudioSessionInterruptionWasSuspendedKey] as? Bool) ?? false
            Log.player.info("AUDIO_RECOVERY_LEGACY wasSuspended=\(wasSuspended) uptimeMs=\(Int(ProcessInfo.processInfo.systemUptime * 1000))")
            Log.player.info("AUDIO_INTERRUPTION began")
            wasPlayingBeforeInterruption = sharedState.withLock({ $0.desiredPlaying }) || playState.value == .playing
            if playState.value == .playing {
                Task { @MainActor in
                    self.setPaused(true, systemRecovery: true)
                    self.sharedState.withLock { $0.desiredPlaying = self.wasPlayingBeforeInterruption }
                }
            }
        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let systemAllowsResume = options.contains(.shouldResume) || wasPlayingBeforeInterruption
            apoloAudioInterruptionActive = false
            apoloLastInterruptionEndedAt = Date()
            if recoveryBegin == nil {
                recoveryID &+= 1
                recoveryBegin = ProcessInfo.processInfo.systemUptime
            }
            recoveryEnd = ProcessInfo.processInfo.systemUptime
            recoveryPositionAtEnd = apoloIsActive ? apoloBackend?.currentTime : nil
            traceRecovery("legacyEnded.systemAllowsResume=\(systemAllowsResume)")
            Log.player.info("AUDIO_INTERRUPTION ended")
            let interruptedIdentity = interruptedPlaybackIdentity
            Task { @MainActor in
                guard let interruptedIdentity,
                      interruptedIdentity.id == NowPlaying.shared.videoId,
                      interruptedIdentity.generation == NowPlaying.shared.playbackGeneration
                else {
                    self.traceRecovery("resumeDroppedChangedPlayback")
                    return
                }
                let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let outputIsBuiltIn = outputs.isEmpty || outputs.allSatisfy {
                    $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
                }
                let handoffAllowed = self.headsetHandoffIntent?.permitsResume(
                    playbackID: NowPlaying.shared.videoId,
                    playbackGeneration: NowPlaying.shared.playbackGeneration,
                    outputIsBuiltIn: outputIsBuiltIn,
                    isInterrupted: self.apoloAudioInterruptionActive
                ) ?? false
                let userWantsPlaying = self.sharedState.withLock { $0.desiredPlaying }
                let autoResumeAllowed = userWantsPlaying && systemAllowsResume
                    && (self.headsetHandoffIntent == nil || handoffAllowed)
                guard handoffAllowed || autoResumeAllowed else {
                    self.traceRecovery("resumeBlocked.userOrSpeakerOrIdentity")
                    self.wasPlayingBeforeInterruption = false
                    return
                }
                self.traceRecovery("resumeTask")
                self.assertAudioSession(reason: "legacyInterruptionEnded")
                // Explicit Play during interruption and a verified headphone
                // handoff both require a real backend resume, not just UI state.
                self.headsetHandoffIntent = nil
                self.wasPlayingBeforeInterruption = false
                self.setPaused(false, forceBackendCommand: true, systemRecovery: true)
            }
        @unknown default:
            break
        }
    }

    private func observeAudioSessionReset() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    @objc private func handleAudioSessionReset() {
        Log.player.notice("AUDIO_SESSION reset")
        Task { @MainActor in
            self.assertAudioSession()
            self.setNowPlayingMetadata()
            if self.sharedState.withLock({ $0.desiredPlaying }), self.playState.value != .playing {
                self.setPaused(false)
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        Log.player.info("ROUTE_CHANGE reason=\(reason.rawValue)")
        let event: AudioRouteChangePolicy.Event
        switch reason {
        case .newDeviceAvailable:
            event = .newDeviceAvailable
        case .oldDeviceUnavailable:
            event = .oldDeviceUnavailable
        default:
            return
        }

        routeChangeGeneration &+= 1
        let routeGeneration = routeChangeGeneration
        let commandGeneration = playbackCommandGeneration
        let requestSerial = playRequestSerial
        let selectedID = NowPlaying.shared.videoId
        Task { @MainActor [weak self] in
            guard let self else { return }
            if case .oldDeviceUnavailable = event {
                // A headset-to-headset handoff can briefly report the old
                // output disappearing before the new Bluetooth route settles.
                // Do not turn that transient gap into a user-requested pause.
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
            }
            let sameRequest = self.routeChangeGeneration == routeGeneration
                && self.playbackCommandGeneration == commandGeneration
                && self.playRequestSerial == requestSerial
                && NowPlaying.shared.videoId == selectedID
            let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            let builtInOutput = outputs.isEmpty || outputs.allSatisfy {
                $0.portType == .builtInSpeaker || $0.portType == .builtInReceiver
            }
            let desired = self.sharedState.withLock { $0.desiredPlaying }
            if case .oldDeviceUnavailable = event,
               sameRequest, builtInOutput, let selectedID,
               desired || self.wasPlayingBeforeInterruption {
                // Preserve short-term intent ONLY for an external replacement.
                // Never auto-resume through the built-in iPhone speaker.
                self.headsetHandoffIntent = AudioRouteHandoffIntent(
                    playbackID: selectedID,
                    playbackGeneration: NowPlaying.shared.playbackGeneration,
                    expiresAt: Date().addingTimeInterval(15)
                )
                if self.apoloAudioInterruptionActive {
                    self.sharedState.withLock { $0.desiredPlaying = false }
                }
            }
            let handoffAllowed = self.headsetHandoffIntent?.permitsResume(
                playbackID: NowPlaying.shared.videoId,
                playbackGeneration: NowPlaying.shared.playbackGeneration,
                outputIsBuiltIn: builtInOutput,
                isInterrupted: self.apoloAudioInterruptionActive
            ) ?? false
            let action = AudioRouteChangePolicy.action(
                for: event,
                desiredPlaying: desired || handoffAllowed,
                isInterrupted: self.apoloAudioInterruptionActive,
                isCurrentRequest: sameRequest,
                outputIsBuiltIn: builtInOutput
            )
            switch action {
            case .pause:
                // Do not convert the automatic privacy pause into user Pause.
                self.setPaused(true, systemRecovery: true)
            case .resume:
                self.headsetHandoffIntent = nil
                self.setPaused(false, forceBackendCommand: true, systemRecovery: true)
            case .ignore:
                break
            }
            Log.player.info(
                "ROUTE_RECOVERY reason=\(reason.rawValue) action=\(String(describing: action)) builtIn=\(builtInOutput) current=\(sameRequest)"
            )
        }
    }
}

// MARK: - Now Playing info / lock-screen

extension PlayerController {
    /// Coalesced variant of `setNowPlayingMetadata()` for high-frequency
    /// duration updates.
    private func scheduleNowPlayingMetadata() {
        metadataDebounceTask?.cancel()
        metadataDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.setNowPlayingMetadata()
        }
    }

    func setNowPlayingMetadata() {
        assertAudioSession(reason: "metadata")
        let np = NowPlaying.shared
        let isLiveRadio = np.playbackKind == .radio
        nowPlayingInfo.removeAll()

        let liveDur: Double = apoloIsActive
            ? (apoloBackend?.duration ?? 0)
            : (withMpv { mpv in
                var val = Double(0)
                mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &val)
                return val
            } ?? 0)
        let duration = liveDur > 0 ? liveDur : np.duration
        if !isLiveRadio, duration > 0 { np.duration = duration }

        let livePos: Double = apoloIsActive
            ? (apoloBackend?.currentTime ?? 0)
            : (withMpv { mpv in
                var val = Double(0)
                mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &val)
                return val
            } ?? 0)
        let elapsed = livePos > 0 ? livePos : np.currentTime

        nowPlayingInfo[MPMediaItemPropertyTitle] = np.displayTitle
        nowPlayingInfo[MPMediaItemPropertyArtist] = np.displayArtist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = np.displayAlbumTitle
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1 : 0
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1
        // Tell iOS this is a true non-seekable live broadcast rather than a
        // zero-length file. Never publish fake elapsed/duration values for radio.
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = NSNumber(value: isLiveRadio)
        if !isLiveRadio {
            if duration > 0 { nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration }
            nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !isLiveRadio
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueIndex] = np.queueIndex
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackQueueCount] = np.queueSongs.count
        if let image = np.thumbnailUIImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = Self.makeArtwork(from: image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = np.isPlaying ? .playing : .paused
        Log.player.info(
            "NOW_PLAYING_PUBLISH title='\(np.displayTitle)' artist='\(np.displayArtist)' " +
            "duration=\(duration) rate=\(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] ?? 0) " +
            "artwork=\(np.thumbnailUIImage != nil) keys=\(nowPlayingInfo.keys.count)"
        )
    }

    func updateNowPlayingArtwork() {
        let np = NowPlaying.shared
        if let image = np.thumbnailUIImage {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = Self.makeArtwork(from: image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func updateNowPlayingProgress() {
        let np = NowPlaying.shared
        if np.playbackKind == .radio {
            // Keep the live marker even across pause, audio route changes and
            // periodic progress refreshes. Fake 0:00 makes iOS show --:--.
            var info = nowPlayingInfo
            info[MPNowPlayingInfoPropertyIsLiveStream] = NSNumber(value: true)
            info.removeValue(forKey: MPMediaItemPropertyPlaybackDuration)
            info.removeValue(forKey: MPNowPlayingInfoPropertyElapsedPlaybackTime)
            info.removeValue(forKey: MPNowPlayingInfoPropertyPlaybackProgress)
            info[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1 : 0
            nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState =
                np.isPlaying ? .playing : .paused
            return
        }
        let props: (dur: Double, pos: Double)? = apoloIsActive
            ? (max(apoloBackend?.duration ?? 0, np.duration),
               apoloBackend?.currentTime ?? 0)
            : withMpv { mpv in
                var dur = Double(0)
                mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &dur)
                var pos = Double(0)
                mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &pos)
                return (dur, pos)
            }
        guard var props else { return }
        guard props.dur > 0 else { return }

        if let seek = pendingSeek {
            if abs(props.pos - seek.target) > 1, Date() < seek.deadline {
                props.pos = seek.target
            } else {
                pendingSeek = nil
            }
        }

        var info = nowPlayingInfo
        info[MPMediaItemPropertyPlaybackDuration] = props.dur
        np.duration = props.dur
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = props.pos
        np.currentTime = props.pos
        info[MPNowPlayingInfoPropertyPlaybackRate] = np.isPlaying ? 1 : 0
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = np.queueIndex
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = np.queueSongs.count
        nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = np.isPlaying ? .playing : .paused
    }
}

// MARK: - Remote commands

extension PlayerController {
    nonisolated static func registerRemoteControlSupport() {
        MainActor.assumeIsolated {
            UIApplication.shared.beginReceivingRemoteControlEvents()
            Log.player.info("REMOTE_COMMANDS launch-time beginReceivingRemoteControlEvents")
        }
    }

    fileprivate func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND play fired")
            Task { @MainActor [weak self] in self?.setPaused(false) }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND pause fired")
            Task { @MainActor [weak self] in self?.setPaused(true) }
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Log.player.info("REMOTE_COMMAND togglePlayPause fired")
            Task { @MainActor [weak self] in self?.togglePlayPause() }
            return .success
        }

        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { _ in
            Log.player.info("REMOTE_COMMAND next fired")
            Task { @MainActor in NowPlaying.shared.playNext() }
            return .success
        }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in
            Log.player.info("REMOTE_COMMAND previous fired")
            Task { @MainActor in NowPlaying.shared.playPrevious() }
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Log.player.info("REMOTE_COMMAND seek fired to=\(position)")
            Task { @MainActor [weak self] in
                self?.seek(to: position)
                self?.updateNowPlayingProgress()
            }
            return .success
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Log.player.info("AUDIO_RECOVERY_APP didEnterBackground uptimeMs=\(Int(ProcessInfo.processInfo.systemUptime * 1000))")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.traceRecovery("appBackground")
                // Keep the audio session alive while the screen is locked so
                // auto-advance can keep playing without user interaction.
                if self.sharedState.withLock({ $0.desiredPlaying }) {
                    self.assertAudioSession(reason: "didEnterBackground")
                }
                self.setNowPlayingMetadata()
                self.updateNowPlayingProgress()
            }
            for delaySeconds in [0.6, 3] as [Double] {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    guard let self, UIApplication.shared.applicationState != .active else { return }
                    self.setNowPlayingMetadata()
                    self.updateNowPlayingProgress()
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Log.player.info("AUDIO_RECOVERY_APP willEnterForeground uptimeMs=\(Int(ProcessInfo.processInfo.systemUptime * 1000))")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.traceRecovery("appForeground")
                self.assertAudioSession(reason: "willEnterForeground")
                self.updateNowPlayingProgress()
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Log.player.info("AUDIO_RECOVERY_APP didBecomeActive uptimeMs=\(Int(ProcessInfo.processInfo.systemUptime * 1000))")
            Task { @MainActor [weak self] in self?.traceRecovery("appActive") }
        }
    }
}

extension Array where Element == String {
    func withUnsafeCArg<T>(_ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> T) -> T {
        let cstrings = map { strdup($0) }
        defer { cstrings.forEach { free($0) } }
        var ptrs = cstrings.map { UnsafePointer($0) } + [nil]
        return ptrs.withUnsafeMutableBufferPointer { buf in
            body(buf.baseAddress)
        }
    }
}

// MARK: - ApoloEngine beta (music, podcasts, and opt-in live radio)

extension PlayerController {
    /// Releases the experimental renderer before mpv takes over. Also makes
    /// outstanding FFmpeg probe results and monitor ticks obsolete.
    private func deactivateApoloPlayback() {
        apoloGeneration &+= 1
        apoloMonitorTask?.cancel()
        apoloMonitorTask = nil
        apoloTrackingTask?.cancel()
        apoloTrackingTask = nil
        if apoloIsActive {
            apoloBackend?.stop()
            apoloIsActive = false
        }
    }

    /// Log-safe source description: scheme, extension and MIME only. Never
    /// the signed URL or its headers.
    private static func apoloSource(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let mime = components?.queryItems?
            .first { $0.name.lowercased() == "mime" }?
            .value ?? "-"
        let ext = url.pathExtension.isEmpty ? "-" : url.pathExtension
        return "\(url.scheme ?? "-")/\(ext)/\(mime)"
    }

    private static func msSince(_ date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }

    private func playWithApolo(
        url: URL,
        videoId: String?,
        title: String?,
        artist: String?,
        duration: TimeInterval?,
        startAt: TimeInterval,
        sourceMIMEType: String? = nil,
        isAtmos: Bool = false,
        isLiveRadio: Bool = false
    ) async {
        let oldId = sharedState.withLock { $0.currentVideoId }
        let isNewSong = oldId != nil && oldId != videoId
        let pending = pendingMetadata
        deactivateApoloPlayback()
        apoloIsActive = true
        switch NowPlaying.shared.playbackKind {
        case .radio: NowPlaying.shared.activePlaybackEngine = "ApoloEngine (Radio Beta)"
        case .podcast: NowPlaying.shared.activePlaybackEngine = "ApoloEngine (Podcast Beta)"
        case .music: NowPlaying.shared.activePlaybackEngine = "ApoloEngine (Beta)"
        }
        let generation = apoloGeneration
        pendingURL = nil
        pendingMetadata = nil
        pendingSeek = nil
        loadedMuxedURL = nil
        loadedVideoOnlyURL = nil
        muxedActive = false
        muxedVideoId = nil
        NowPlaying.shared.isVideoMode = false
        NowPlaying.shared.isVideoReady = false
        sharedState.withLock {
            $0.currentVideoId = videoId
            $0.pendingVideoId = nil
            $0.desiredPlaying = true
        }
        // Stop mpv before Apolo starts; an EOF emitted by the old mpv item
        // must never advance Thrum's queue while Apolo owns playback.
        _ = withMpv { mpv in
            ["stop"].withUnsafeCArg { mpv_command(mpv, $0) }
        }
        assertAudioSession()
        guard apoloIsActive, apoloGeneration == generation,
              NowPlaying.shared.videoId == videoId else { return }

        // Initialize the player state once, before audio starts. `update`
        // starts the timer and requests this song's artwork; `isPlaying`
        // stays false so SponsorBlock cannot seek before the backend plays.
        NowPlaying.shared.isPlaying = false
        if let pending,
           pending.videoId == videoId,
           NowPlaying.shared.videoId == videoId,
           generation == apoloGeneration {
            NowPlaying.shared.update(
                title: pending.title,
                artist: pending.artist,
                videoId: pending.videoId,
                artists: pending.artists,
                thumbnailUrl: pending.thumbnailUrl,
                preserveMissingArtist: true
            )
            NowPlaying.shared.isPlaying = false
            if let duration {
                NowPlaying.shared.duration = max(0, duration)
            }
            Log.player.info(
                "APOLO_BETA metadata videoId=\(pending.videoId) gen=\(generation) source=\(Self.apoloSource(url))"
            )
        } else if let pending {
            Log.player.info(
                "APOLO_BETA metadata dropped videoId=\(pending.videoId) current=\(NowPlaying.shared.videoId ?? "nil")"
            )
        } else {
            Log.player.info(
                "APOLO_BETA metadata already initialized videoId=\(videoId ?? "nil") gen=\(generation)"
            )
        }

        let backend: ApoloAudioBackend
        if let existing = apoloBackend {
            backend = existing
        } else {
            backend = ApoloAudioBackend()
            apoloBackend = backend
        }
        backend.volume = Float(max(0, min(1, SettingsStore.shared.playerVolume)))
        let apoloBegan = Date()
        // The watchdog must cover the load itself: a slow asset track lookup
        // must be able to fall back instead of waiting forever.
        monitorApolo(
            url: url, videoId: videoId,
            generation: generation, isLiveRadio: isLiveRadio
        )
        Log.player.info(
            "APOLO_BETA begin videoId=\(videoId ?? "nil") kind=\(NowPlaying.shared.playbackKind) source=\(Self.apoloSource(url))"
        )
        do {
            if isLiveRadio {
                try await backend.loadLive(
                    stationURL: url,
                    title: title ?? NowPlaying.shared.displayTitle,
                    artist: artist ?? NowPlaying.shared.displayArtist,
                    sourceMIMEType: sourceMIMEType
                )
            } else {
                try await backend.load(
                    audioURL: url,
                    title: title ?? NowPlaying.shared.displayTitle,
                    artist: artist ?? NowPlaying.shared.displayArtist,
                    sourceMIMEType: sourceMIMEType,
                    isAtmos: isAtmos
                )
            }
            Log.player.info(
                "APOLO_BETA loadReturned videoId=\(videoId ?? "nil") ms=\(Self.msSince(apoloBegan))"
            )
            guard apoloIsActive, apoloGeneration == generation,
                  NowPlaying.shared.videoId == videoId else { return }
            // Live streams have no seekable timeline or resume position.
            if !isLiveRadio, startAt > 0 {
                await backend.seek(to: startAt)
            }
            guard apoloIsActive, apoloGeneration == generation else { return }
            let canStartAudio = !apoloAudioInterruptionActive
                && sharedState.withLock { $0.desiredPlaying }
            if canStartAudio {
                backend.play()
            } else {
                // The new recording may finish loading while iOS is still
                // interrupted. Keep it paused for the guarded resume event.
                backend.pause()
                if apoloAudioInterruptionActive {
                    interruptedPlaybackIdentity = (
                        id: videoId, generation: NowPlaying.shared.playbackGeneration
                    )
                }
            }
            playState.send(canStartAudio ? .playing : .paused)
            NowPlaying.shared.isPlaying = canStartAudio
            NowPlaying.shared.currentTime = isLiveRadio ? 0 : startAt
            NowPlaying.shared.duration = isLiveRadio ? 0 : max(0, duration ?? 0)
            setNowPlayingMetadata()
            if !isLiveRadio {
                scheduleApoloTracking(
                    isNewSong: isNewSong,
                    videoId: videoId,
                    generation: generation
                )
            } else if isNewSong {
                // Leaving music for a station must stop the previous song's
                // listening-history timer without creating a fake radio song.
                Task { @MainActor [weak self] in
                    guard let self, self.apoloGeneration == generation else { return }
                    await PlaybackStateService.shared.stopTracking()
                }
            }
            Log.player.info(
                "APOLO_BETA active kind=\(isLiveRadio ? "radio" : "audio") videoId=\(videoId ?? "nil")"
            )
        } catch {
            guard apoloIsActive, apoloGeneration == generation else { return }
            Log.player.error("APOLO_BETA load failed: \(error)")
            fallbackFromApolo(url: url, videoId: videoId, generation: generation)
        }
    }

    /// Playback must not wait for the history service: the mpv path loads
    /// first and books the play afterwards too. The generation guard keeps a
    /// fast skip from starting tracking for a stale song.
    private func scheduleApoloTracking(
        isNewSong: Bool,
        videoId: String?,
        generation: UInt64
    ) {
        apoloTrackingTask?.cancel()
        apoloTrackingTask = Task { @MainActor [weak self] in
            guard let self, self.apoloGeneration == generation else { return }
            if isNewSong {
                await PlaybackStateService.shared.stopTracking()
            }
            guard self.apoloGeneration == generation else { return }
            if let videoId {
                await PlaybackStateService.shared.startTracking(videoId: videoId)
            }
        }
    }

    private func monitorApolo(
        url: URL,
        videoId: String?,
        generation: UInt64,
        isLiveRadio: Bool
    ) {
        apoloMonitorTask?.cancel()
        apoloMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let begun = Date()
            var loggedPlaying = false
            var liveRadioWatchdog = ApoloLiveRadioWatchdog()
            var finiteAudioWatchdog = ApoloFiniteAudioWatchdog()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, self.apoloIsActive,
                      self.apoloGeneration == generation,
                      NowPlaying.shared.videoId == videoId,
                      let backend = self.apoloBackend else { return }
                // Sample transitions while an interruption trace is active.
                // This is observer-only: no backend state is modified.
                if self.recoveryBegin != nil {
                    let observed: String
                    switch backend.state {
                    case .idle: observed = "idle"
                    case .loading: observed = "loading"
                    case .playing: observed = "playing"
                    case .paused: observed = "paused"
                    case .finished: observed = "finished"
                    case .failed: observed = "failed"
                    }
                    if observed != self.recoveryObservedState {
                        self.recoveryObservedState = observed
                        self.traceRecovery("apoloState.\(observed)")
                    }
                }
                if self.recoveryEnd != nil,
                   !self.recoveryAdvanced,
                   case .playing = backend.state,
                   let previousPosition = self.recoveryPositionAtEnd,
                   backend.currentTime > previousPosition + 0.15 {
                    self.recoveryAdvanced = true
                    self.traceRecovery("apoloClockAdvanced.notAcousticProof")
                }
                switch backend.state {
                case .finished:
                    if isLiveRadio {
                        // A live station ending is a stream error, not an EOF
                        // that advances the user's music queue.
                        self.fallbackFromApolo(url: url, videoId: videoId, generation: generation)
                    } else {
                        self.playState.send(.stopped)
                        NowPlaying.shared.stopped(videoId: videoId, isEof: true)
                    }
                    return
                case .failed(let message):
                    if isLiveRadio {
                        NowPlaying.shared.radioPlaybackStatus = .reconnecting
                        // Apolo itself owns three bounded reconnect attempts.
                        // Give those a grace window before switching to mpv.
                        // Share one deadline across .failed/.loading/.idle,
                        // but never reuse a station-age deadline after a
                        // successful .playing state or iOS interruption.
                        if !liveRadioWatchdog.hasTimedOut(
                            now: Date(),
                            timeout: 35,
                            isInterrupted: self.apoloAudioInterruptionActive,
                            interruptionEndedAt: self.apoloLastInterruptionEndedAt
                        ) {
                            continue
                        }
                    }
                    Log.player.error("APOLO_BETA renderer error: \(message)")
                    self.fallbackFromApolo(url: url, videoId: videoId, generation: generation)
                    return
                case .loading:
                    if isLiveRadio {
                        NowPlaying.shared.radioPlaybackStatus =
                            loggedPlaying ? .reconnecting : .connecting
                    }
                    if isLiveRadio {
                        if liveRadioWatchdog.hasTimedOut(
                            now: Date(),
                            timeout: 40,
                            isInterrupted: self.apoloAudioInterruptionActive,
                            interruptionEndedAt: self.apoloLastInterruptionEndedAt
                        ) {
                            Log.player.warning("APOLO_BETA radio continuous loading timeout; using mpv fallback")
                            self.fallbackFromApolo(
                                url: url, videoId: videoId, generation: generation
                            )
                            return
                        }
                    } else if finiteAudioWatchdog.hasTimedOut(
                        now: Date(),
                        isInterrupted: self.apoloAudioInterruptionActive,
                        interruptionEndedAt: self.apoloLastInterruptionEndedAt
                    ) {
                        Log.player.warning("APOLO_BETA recovery loading timeout; using mpv fallback")
                        self.fallbackFromApolo(
                            url: url, videoId: videoId, generation: generation
                        )
                        return
                    }
                case .playing:
                    finiteAudioWatchdog.reset()
                    liveRadioWatchdog.reset()
                    if isLiveRadio {
                        NowPlaying.shared.radioPlaybackStatus = .live
                    }
                    if !loggedPlaying {
                        loggedPlaying = true
                        self.traceRecovery("apoloPlaying")
                        Log.player.info(
                            "APOLO_BETA firstPlaying videoId=\(videoId ?? "nil") ms=\(Self.msSince(begun))"
                        )
                    }
                    if self.playState.value != .playing {
                        self.playState.send(.playing)
                        NowPlaying.shared.isPlaying = true
                    }
                case .paused:
                    finiteAudioWatchdog.reset()
                    liveRadioWatchdog.reset()
                    if isLiveRadio {
                        NowPlaying.shared.radioPlaybackStatus = .paused
                    }
                    if self.playState.value != .paused {
                        self.playState.send(.paused)
                        NowPlaying.shared.isPlaying = false
                    }
                case .idle:
                    if isLiveRadio {
                        NowPlaying.shared.radioPlaybackStatus =
                            loggedPlaying ? .reconnecting : .connecting
                    }
                    let idleTimedOut = isLiveRadio
                        ? liveRadioWatchdog.hasTimedOut(
                            now: Date(),
                            timeout: 40,
                            isInterrupted: self.apoloAudioInterruptionActive,
                            interruptionEndedAt: self.apoloLastInterruptionEndedAt
                        )
                        : finiteAudioWatchdog.hasTimedOut(
                            now: Date(),
                            isInterrupted: self.apoloAudioInterruptionActive,
                            interruptionEndedAt: self.apoloLastInterruptionEndedAt
                        )
                    if idleTimedOut {
                        Log.player.warning(
                            "APOLO_BETA idle timeout; using mpv fallback"
                        )
                        self.fallbackFromApolo(
                            url: url,
                            videoId: videoId,
                            generation: generation
                        )
                        return
                    }
                }
                if backend.duration > 0, NowPlaying.shared.duration <= 0 {
                    NowPlaying.shared.duration = backend.duration
                }
            }
        }
    }

    private func fallbackFromApolo(url: URL, videoId: String?, generation: UInt64) {
        guard apoloIsActive, apoloGeneration == generation,
              NowPlaying.shared.videoId == videoId else { return }
        let isLiveRadio = NowPlaying.shared.playbackKind == .radio
        if isLiveRadio {
            NowPlaying.shared.radioPlaybackStatus = .connecting
        }
        let position = isLiveRadio ? 0 : currentTime
        traceRecovery("mpvFallback")
        if !isLiveRadio {
            NowPlaying.shared.rememberInterruptedPlayback(position, for: videoId)
        }
        let title = NowPlaying.shared.displayTitle
        let artist = NowPlaying.shared.displayArtist
        let duration = NowPlaying.shared.duration
        deactivateApoloPlayback()
        // The fallback is queued onto the main actor. Another song selection
        // can supersede it before this Task executes; don't let an old mpv
        // fallback steal the player from that newer request (including ABA).
        let fallbackRequestSerial = playRequestSerial
        Log.player.notice("APOLO_BETA switching back to mpv")
        Task { @MainActor [weak self] in
            guard let self, NowPlaying.shared.videoId == videoId,
                  PlaybackIntentGuard.isLatest(
                      serial: fallbackRequestSerial,
                      latestSerial: self.playRequestSerial
                  ) else { return }
            await self.play(
                url: url.absoluteString,
                title: title,
                artist: artist,
                videoId: videoId,
                duration: duration,
                startAt: position,
                bypassApolo: true
            )
        }
    }
}
