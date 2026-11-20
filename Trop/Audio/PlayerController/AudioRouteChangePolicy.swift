import Foundation

/// A short-lived, playback-bound permission to resume on a replacement
/// headset. It never authorizes audio through a built-in speaker and expires
/// if the user switches songs, dismisses the handoff or waits too long.
struct AudioRouteHandoffIntent: Sendable {
    let playbackID: String
    let playbackGeneration: Int
    let expiresAt: Date

    func permitsResume(
        playbackID: String?,
        playbackGeneration: Int,
        now: Date = Date(),
        outputIsBuiltIn: Bool,
        isInterrupted: Bool
    ) -> Bool {
        !isInterrupted && !outputIsBuiltIn
            && now < expiresAt
            && self.playbackID == playbackID
            && self.playbackGeneration == playbackGeneration
    }
}

/// Pure decision policy for audio-route handoffs. Callers must verify the
/// output route only after old-device removal has had time to settle.
enum AudioRouteChangePolicy {
    enum Event: Sendable {
        case newDeviceAvailable
        case oldDeviceUnavailable
    }

    enum Action: Equatable, Sendable {
        case ignore
        case pause
        case resume
    }

    static func action(
        for event: Event,
        desiredPlaying: Bool,
        isInterrupted: Bool,
        isCurrentRequest: Bool,
        outputIsBuiltIn: Bool
    ) -> Action {
        // A user pause, real interruption, or newer selection always wins.
        guard desiredPlaying, !isInterrupted, isCurrentRequest else {
            return .ignore
        }
        switch event {
        case .newDeviceAvailable:
            // A connection notification can precede the route becoming
            // external. Never force playback through the built-in speaker.
            return outputIsBuiltIn ? .ignore : .resume
        case .oldDeviceUnavailable:
            // Avoid blasting audio through the phone speaker when headphones
            // are unplugged, but preserve live radio on a new external route.
            return outputIsBuiltIn ? .pause : .resume
        }
    }
}
