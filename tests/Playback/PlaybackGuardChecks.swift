import Foundation

/// Regression checks compile the exact Foundation-only policies used by the
/// iOS app, not copies of their production conditionals.
@main
struct PlaybackGuardChecks {
    static func main() {
        let segment = SponsorBlockSkipPolicy.shouldSkip
        precondition(
            !segment(0, 20, 0, false),
            "Disabled intro opt-in must prevent the startup skip"
        )
        precondition(
            segment(0, 20, 0, true),
            "Enabled intro opt-in should allow a short intro skip"
        )
        precondition(
            !segment(0, 30, 0, true),
            "Even an opted-in intro over 25 s must remain untouched"
        )
        precondition(
            !segment(0.2, 15, 0.2, false),
            "Near-zero intros must also respect the opt-in"
        )
        precondition(
            segment(10, 25, 12, false),
            "Mid-track nonmusic skipping remains available"
        )
        precondition(
            !segment(10, 25, 9.7, false),
            "Do not prefire beyond the 250 ms boundary"
        )
        precondition(
            !segment(10, 25, 24.2, false),
            "Do not seek in the last second of a segment"
        )
        precondition(
            !segment(.nan, 20, 1, true),
            "Malformed remote segments must not trigger a seek"
        )
        precondition(
            !segment(5, .infinity, 7, true),
            "Unbounded segment endpoints must be rejected"
        )
        precondition(PlaybackIntentGuard.owns(
            expectedGeneration: 4, expectedVideoId: "MONACO",
            generation: 4, videoId: "MONACO"
        ), "Current resolver may publish")
        precondition(!PlaybackIntentGuard.owns(
            expectedGeneration: 4, expectedVideoId: "MONACO",
            generation: 5, videoId: "NADIE SABE"
        ), "Old resolver must not auto-advance a new track")
        precondition(!PlaybackIntentGuard.owns(
            expectedGeneration: 4, expectedVideoId: "MONACO",
            generation: 6, videoId: "MONACO"
        ), "A -> B -> A must not revive stale work")
        precondition(!PlaybackIntentGuard.owns(
            expectedGeneration: 4, expectedVideoId: "MONACO",
            generation: 4, videoId: "NADIE SABE"
        ), "Same-generation wrong track cannot publish")
        precondition(!PlaybackIntentGuard.isLatest(
            serial: 12, latestSerial: 13
        ), "A superseded load must not publish the old quality badge")
        precondition(PlaybackIntentGuard.isLatest(
            serial: 13, latestSerial: 13
        ), "The active source request may publish")

        // IPA #398: PERFuMITO NUEVO was still .loading after the user
        // paused, then Apolo timed out and mpv auto-started. Pauses are
        // selection-scoped and must be preserved across every backend.
        func wantsAudio(
            generation: Int = 6,
            paused: Int? = nil,
            desired: Bool,
            fresh: Bool = false,
            fallback: Bool = false
        ) -> Bool {
            PlaybackPausePolicy.shouldPlay(
                generation: generation,
                explicitlyPausedGeneration: paused,
                desiredPlaying: desired,
                isNewSelection: fresh,
                isEngineFallback: fallback
            )
        }
        precondition(wantsAudio(desired: false, fresh: true),
                     "Initial explicit song selection starts from stopped state")
        precondition(!wantsAudio(paused: 6, desired: false, fresh: true),
                     "Pause during a new song's resolution cannot be overwritten")
        precondition(!wantsAudio(paused: 6, desired: false),
                     "Delayed Apolo load must honor the latest Pause")
        precondition(!wantsAudio(paused: 6, desired: false, fallback: true),
                     "Apolo to mpv fallback cannot turn paused into playing")
        precondition(!wantsAudio(desired: false, fallback: true),
                     "An internal system pause is also preserved by fallback")
        precondition(wantsAudio(desired: true, fallback: true),
                     "Genuine playable fallback still starts when requested")
        precondition(wantsAudio(generation: 7, paused: 6, desired: false, fresh: true),
                     "Explicit selection of another track may start after old Pause")
        precondition(!wantsAudio(generation: 7, paused: 7, desired: false, fresh: true),
                     "Pause on the new track beats the pending load")
        precondition(!wantsAudio(paused: 6, desired: false, fresh: false),
                     "A paused in-place quality upgrade stays paused")
        precondition(wantsAudio(desired: true, fresh: false),
                     "An ordinary in-place quality change remains playing")
        precondition(!wantsAudio(desired: false, fresh: false),
                     "A backend retry of a system-paused selection remains paused")
        precondition(!PlaybackPausePolicy.shouldAdvanceAutomatically(
            generation: 6, explicitlyPausedGeneration: 6, desiredPlaying: true
        ), "A stale EOF callback must not advance after an explicit Pause")
        precondition(!PlaybackPausePolicy.shouldAdvanceAutomatically(
            generation: 6, explicitlyPausedGeneration: nil, desiredPlaying: false
        ), "Automatic queue transition cannot start on system pause")
        precondition(PlaybackPausePolicy.shouldAdvanceAutomatically(
            generation: 6, explicitlyPausedGeneration: 5, desiredPlaying: true
        ), "Normal EOF advances while music is requested")
        precondition(PlaybackPausePolicy.watchdogIsSuspended(
            desiredPlaying: false, audioInterruptionActive: false
        ), "Paused loading must not burn the finite-audio timeout budget")
        precondition(PlaybackPausePolicy.watchdogIsSuspended(
            desiredPlaying: true, audioInterruptionActive: true
        ), "An iOS interruption must suspend loading timeout")
        precondition(!PlaybackPausePolicy.watchdogIsSuspended(
            desiredPlaying: true, audioInterruptionActive: false
        ), "Real active loading remains under the watchdog")
        // Exact background reproduction: Apolo was .loading for 90 seconds
        // while the user had paused. No mpv swap should be authorized.
        let at: (Double) -> Date = { Date(timeIntervalSince1970: $0) }
        var pausedLoading = ApoloFiniteAudioWatchdog()
        precondition(!pausedLoading.hasTimedOut(
            now: at(0), isInterrupted: false, interruptionEndedAt: nil
        ), "Loading begins with an ordinary 20s watchdog")
        precondition(!pausedLoading.hasTimedOut(
            now: at(25),
            isInterrupted: PlaybackPausePolicy.watchdogIsSuspended(
                desiredPlaying: false, audioInterruptionActive: false
            ),
            interruptionEndedAt: nil
        ), "Pause must suspend watchdog, even after 20s")
        precondition(!pausedLoading.hasTimedOut(
            now: at(90),
            isInterrupted: PlaybackPausePolicy.watchdogIsSuspended(
                desiredPlaying: false, audioInterruptionActive: false
            ),
            interruptionEndedAt: nil
        ), "90 seconds paused is not a stream stall")
        precondition(!pausedLoading.hasTimedOut(
            now: at(100),
            isInterrupted: PlaybackPausePolicy.watchdogIsSuspended(
                desiredPlaying: true, audioInterruptionActive: false
            ),
            interruptionEndedAt: nil
        ), "The watchdog resumes with a fresh deadline on explicit Play")
        precondition(!pausedLoading.hasTimedOut(
            now: at(119.9), isInterrupted: false, interruptionEndedAt: nil
        ), "Real loading still has 20 seconds after Play")
        precondition(pausedLoading.hasTimedOut(
            now: at(120.1), isInterrupted: false, interruptionEndedAt: nil
        ), "An actual stall after Play must still reach the mpv fallback")
        // Diagnostic policy must not mislabel ordinary or unknown-duration EOFs.
        precondition(PlaybackEndEvidence.isMateriallyEarly(
            decoderPosition: 162.786,
            expectedDuration: 183.685
        ), "NUEVAYoL early EOF must be visible in diagnostics")
        precondition(!PlaybackEndEvidence.isMateriallyEarly(
            decoderPosition: 182.5,
            expectedDuration: 183.685
        ), "Natural end with encoder padding must not be flagged")
        precondition(!PlaybackEndEvidence.isMateriallyEarly(
            decoderPosition: 150,
            expectedDuration: 0
        ), "Unknown stream duration is not an early EOF")
        precondition(!PlaybackEndEvidence.isMateriallyEarly(
            decoderPosition: 19,
            expectedDuration: 25
        ), "A short clip is not a long-track early-EOF signal")
        precondition(!PlaybackEndEvidence.isMateriallyEarly(
            decoderPosition: 10,
            expectedDuration: .nan
        ), "Invalid media durations must never create a false alarm")
        precondition(!PlaybackEndEvidence.isMateriallyEarly(
            decoderPosition: .infinity,
            expectedDuration: 180
        ), "Invalid decoder positions must never create a false alarm")
        precondition(!PlaybackEndEvidence.isMateriallyEarly(
            decoderPosition: 175,
            expectedDuration: 180
        ), "Under 8 seconds deficit is not materially early")
        precondition(!PlaybackEndEvidence.isMateriallyEarly(
            decoderPosition: 192,
            expectedDuration: 200
        ), "At least 5 percent difference is also required")
        // Apple Music -> Trop: an unsuccessful AVAudioSession activation
        // leaves Play deferred; only the same generation's live intent may
        // retry when the app becomes active. Explicit Pause always wins.
        func canRetrySession(
            pendingID: String? = "KETU",
            pendingGeneration: Int = 4,
            currentID: String? = "KETU",
            currentGeneration: Int = 4,
            desired: Bool = true,
            interrupted: Bool = false,
            explicitlyPaused: Bool = false
        ) -> Bool {
            AudioSessionResumePolicy.shouldRetry(
                pendingVideoId: pendingID,
                pendingGeneration: pendingGeneration,
                currentVideoId: currentID,
                currentGeneration: currentGeneration,
                desiredPlaying: desired,
                interruptionActive: interrupted,
                explicitlyPaused: explicitlyPaused
            )
        }
        precondition(canRetrySession(),
                     "Foreground may retry a denied Play for same selection")
        precondition(!canRetrySession(desired: false),
                     "Explicit Pause revokes delayed background Play")
        precondition(!canRetrySession(explicitlyPaused: true),
                     "Selection-scoped pause cannot be overridden by activation")
        precondition(!canRetrySession(interrupted: true),
                     "Never resume while iOS interruption remains active")
        precondition(!canRetrySession(currentID: "BOKeTE"),
                     "Old song's pending resume must not start the next song")
        precondition(!canRetrySession(currentGeneration: 5),
                     "ABA transition cannot revive older session resume")
        precondition(canRetrySession(pendingID: nil, currentID: nil),
                     "Podcast/radio selections may have nil identity")
        precondition(!canRetrySession(pendingID: "KETU", currentID: nil),
                     "Pending ID must match current source identity")
        print("PASS: 8 audio-session activation and deferred-resume checks")

        print("PASS: 8 early-EOF evidence classification regression checks")

        print("PASS: 6 real finite-audio watchdog pause/resume/timeout checks")

        print("PASS: 17 pause/EOF/fallback/quality-change intent regression checks")

        print("PASS: 15 playback startup/skip/ABA regression checks")
    }
}
