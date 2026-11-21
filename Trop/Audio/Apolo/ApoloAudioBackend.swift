import Foundation
import ApoloEngine

/// First-stage audio backend for the Thrum music-only beta.
///
/// This adapter deliberately does NOT register system media commands or own
/// AVAudioSession: Thrum already owns both. The application will route sources
/// to it in a separate PR after the mixed FFmpeg/MPVKit build is validated.
@MainActor
final class ApoloAudioBackend {
    private let engine = ApoloEngine(
        managesSystemMediaControls: false,
        managesAudioSession: false
    )

    init() {
        // Apolo emits numeric telemetry only: no source URL or HTTP headers.
        // The existing serialized file logger makes these metrics available
        // in the iPhone Files app without any Mac/Xcode connection.
        engine.setDiagnosticHandler { event in
            Log.player.info("APOLO_DIAG \(event)")
        }
    }

    var state: PlaybackState { engine.state }
    var currentTime: TimeInterval { engine.currentTime }
    var duration: TimeInterval { engine.duration }
    /// Live ID3/ICY station song title from Apolo; the app owns enrichment.
    var liveTitle: String? { engine.liveTitle }

    var volume: Float {
        get { engine.volume }
        set { engine.volume = max(0, min(1, newValue)) }
    }

    func load(
        audioURL: URL,
        httpHeaders: [String: String] = [:],
        title: String,
        artist: String,
        album: String? = nil,
        artworkData: Data? = nil,
        sourceMIMEType: String? = nil,
        isAtmos: Bool = false
    ) async throws {
        try await engine.load(
            url: audioURL,
            httpHeaders: httpHeaders,
            metadata: NowPlayingMetadata(
                title: title,
                artist: artist,
                album: album,
                artworkData: artworkData
            ),
            sourceMIMEType: sourceMIMEType,
            isAtmos: isAtmos
        )
    }

    /// Continuous internet radio: do not use the finite-file `load` path.
    /// Thrum still owns session, lock-screen metadata, and playback commands.
    func loadLive(
        stationURL: URL,
        httpHeaders: [String: String] = [:],
        title: String,
        artist: String,
        artworkData: Data? = nil,
        sourceMIMEType: String? = nil
    ) async throws {
        try await engine.loadLive(
            url: stationURL,
            httpHeaders: httpHeaders,
            metadata: NowPlayingMetadata(
                title: title,
                artist: artist,
                artworkData: artworkData
            ),
            sourceMIMEType: sourceMIMEType
        )
    }

    func play() { engine.play() }
    func pause() { engine.pause() }
    func seek(to seconds: TimeInterval) async { await engine.seek(to: seconds) }
    func stop() { engine.stop() }
}
