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

/// Authorization for a **user-initiated** Play after headphones were
/// removed. iOS can send another route notification while AirPods remain
/// outside the case, without ending the original legacy interruption.
/// The permit is bound to the current route *and output kind*. It never
/// authorizes automatic route/interruption resumes.
struct HeadphoneUnplugManualPlayPermit: Sendable {
    let playbackID: String
    let playbackGeneration: Int
    let routeGeneration: UInt64
    let expectsBuiltInOutput: Bool

    /// Reconnect carries only the right to a later *manual* Play to the
    /// newly observed external route. It does not itself start playback.
    func transferredToExternalRoute(
        generation: UInt64
    ) -> HeadphoneUnplugManualPlayPermit {
        HeadphoneUnplugManualPlayPermit(
            playbackID: playbackID,
            playbackGeneration: playbackGeneration,
            routeGeneration: generation,
            expectsBuiltInOutput: false
        )
    }

    func permitsExplicitPlay(
        playbackID: String?,
        playbackGeneration: Int,
        routeGeneration: UInt64,
        isUserCommand: Bool,
        outputIsBuiltIn: Bool
    ) -> Bool {
        isUserCommand && outputIsBuiltIn == expectsBuiltInOutput
            && self.playbackID == playbackID
            && self.playbackGeneration == playbackGeneration
            && self.routeGeneration == routeGeneration
    }
}


/// On iOS 27 the legacy interruption-began notification may have no paired
/// .ended. Foreground user intent can request a fresh session activation only
/// when the audio route has stayed stable since the interruption. A changed
/// route must use the separate headset-removal permit instead.
enum ForegroundInterruptionRecoveryPolicy {
    static func mayAttemptActivation(
        isInterrupted: Bool,
        isExplicitUserIntent: Bool,
        isAppForegroundActive: Bool,
        hasCurrentSelection: Bool,
        routeChangedSinceInterruption: Bool
    ) -> Bool {
        isInterrupted && isExplicitUserIntent && isAppForegroundActive
            && hasCurrentSelection && !routeChangedSinceInterruption
    }

    static func matchesExplicitSelection(
        expectedID: String?,
        expectedGeneration: Int?,
        currentID: String?,
        currentGeneration: Int,
        desiredPlaying: Bool
    ) -> Bool {
        desiredPlaying && expectedID != nil
            && expectedID == currentID
            && expectedGeneration == currentGeneration
    }
}
