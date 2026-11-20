import Foundation

/// Pure ownership fence for asynchronous playback work. Track identity
/// alone is insufficient: A -> B -> A is an ABA transition, so the monotonic
/// intent generation must match as well.
enum PlaybackIntentGuard {
    static func owns(
        expectedGeneration: Int,
        expectedVideoId: String,
        generation: Int,
        videoId: String?
    ) -> Bool {
        expectedGeneration == generation && expectedVideoId == videoId
    }

    static func isLatest(
        serial: UInt64,
        latestSerial: UInt64
    ) -> Bool {
        serial == latestSerial
    }
}


/// A pause belongs to a playback selection, not to an audio backend.
///
/// A new *user selection* may begin playing after an older selection was
/// paused. A delayed load, quality switch or Apolo -> mpv fallback for the
/// SAME selection must never turn an explicit Pause into Play.
enum PlaybackPausePolicy {
    static func shouldPlay(
        generation: Int,
        explicitlyPausedGeneration: Int?,
        desiredPlaying: Bool,
        isNewSelection: Bool,
        isEngineFallback: Bool
    ) -> Bool {
        if explicitlyPausedGeneration == generation { return false }
        if isEngineFallback { return desiredPlaying }
        return isNewSelection || desiredPlaying
    }

    static func shouldAdvanceAutomatically(
        generation: Int,
        explicitlyPausedGeneration: Int?,
        desiredPlaying: Bool
    ) -> Bool {
        desiredPlaying && explicitlyPausedGeneration != generation
    }

    /// An intentionally paused decoder is not stalled. Re-start the timeout
    /// budget only after the user asks the backend to play again.
    static func watchdogIsSuspended(
        desiredPlaying: Bool,
        audioInterruptionActive: Bool
    ) -> Bool {
        !desiredPlaying || audioInterruptionActive
    }
}


/// Diagnostic classification only: never changes EOF handling or the queue.
/// Not every reported duration is exact; require both a meaningful absolute
/// and relative gap before flagging a suspicious early finish in device logs.
enum PlaybackEndEvidence {
    static func isMateriallyEarly(
        decoderPosition: TimeInterval,
        expectedDuration: TimeInterval
    ) -> Bool {
        guard decoderPosition.isFinite,
              expectedDuration.isFinite,
              decoderPosition >= 0,
              expectedDuration >= 30 else { return false }
        let missing = expectedDuration - decoderPosition
        return missing >= 8 && missing / expectedDuration >= 0.05
    }
}
