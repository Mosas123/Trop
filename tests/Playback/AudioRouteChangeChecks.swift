import Foundation

@main
struct AudioRouteChangeChecks {
    private static var checks = 0

    private static func check(
        _ event: AudioRouteChangePolicy.Event,
        desired: Bool = true,
        interrupted: Bool = false,
        current: Bool = true,
        builtIn: Bool = false,
        expected: AudioRouteChangePolicy.Action,
        _ label: String
    ) {
        let actual = AudioRouteChangePolicy.action(
            for: event,
            desiredPlaying: desired,
            isInterrupted: interrupted,
            isCurrentRequest: current,
            outputIsBuiltIn: builtIn
        )
        precondition(actual == expected, label)
        checks += 1
    }

    static func main() {
        check(.newDeviceAvailable, expected: .resume,
              "Connecting AirPods resumes the current radio")
        check(.newDeviceAvailable, builtIn: true, expected: .ignore,
              "Unsettled new-device route must not play through the speaker")
        check(.oldDeviceUnavailable, builtIn: true, expected: .pause,
              "Unplugging headphones to the built-in speaker pauses for privacy")
        check(.oldDeviceUnavailable, builtIn: false, expected: .resume,
              "Switching between external outputs preserves playback")

        check(.newDeviceAvailable, desired: false, expected: .ignore,
              "A new device never overrides an explicit user pause")
        check(.oldDeviceUnavailable, desired: false, builtIn: true,
              expected: .ignore, "Route removal does not repeat a user pause")
        check(.newDeviceAvailable, interrupted: true, expected: .ignore,
              "Do not race with an active iOS interruption")
        check(.oldDeviceUnavailable, interrupted: true, builtIn: true,
              expected: .ignore, "A route event does not override interruption handling")
        check(.newDeviceAvailable, current: false, expected: .ignore,
              "A stale route event cannot restart a newly selected station")
        check(.oldDeviceUnavailable, current: false, builtIn: true,
              expected: .ignore, "A delayed unplug event cannot pause a later Play command")

        // iOS 27.3 reproduction: old headphones disappear, iOS interrupts
        // the session and a new Bluetooth output arrives several seconds later.
        // Only the same playback identity may resume on an external route.
        let createdAt = Date(timeIntervalSince1970: 100)
        let handoff = AudioRouteHandoffIntent(
            playbackID: "radio:station-a",
            playbackGeneration: 8,
            expiresAt: createdAt.addingTimeInterval(15)
        )
        func permitted(
            id: String? = "radio:station-a",
            generation: Int = 8,
            at offset: TimeInterval = 8,
            builtIn: Bool = false,
            interrupted: Bool = false
        ) -> Bool {
            handoff.permitsResume(
                playbackID: id,
                playbackGeneration: generation,
                now: createdAt.addingTimeInterval(offset),
                outputIsBuiltIn: builtIn,
                isInterrupted: interrupted
            )
        }
        precondition(permitted(), "Same station may recover on replacement AirPods")
        checks += 1
        precondition(!permitted(builtIn: true),
                     "Never auto-play on the phone speaker after unplugging")
        checks += 1
        precondition(!permitted(interrupted: true),
                     "Do not attempt to play before iOS interruption ends")
        checks += 1
        precondition(!permitted(id: "radio:station-b"),
                     "A station change cancels the previous route resume")
        checks += 1
        precondition(!permitted(generation: 9),
                     "A new user playback intent cancels a stale handoff")
        checks += 1
        precondition(!permitted(at: 15),
                     "Expired auto-resume permissions are never valid")
        checks += 1
        precondition(!permitted(at: 120),
                     "A long-disconnected headset must not auto-play")
        checks += 1
        precondition(!permitted(id: nil),
                     "Without an active playback ID do not resume")
        checks += 1

        // iOS 27.3 beta: AirPods removal -> privacy pause -> legacy
        // interruption began, but .ended may never be delivered. Only a
        // real Play from the matching selection can request reactivation.
        let manual = HeadphoneUnplugManualPlayPermit(
            playbackID: "song:track-a",
            playbackGeneration: 42,
            routeGeneration: 7,
            expectsBuiltInOutput: true
        )
        func canManuallyRecover(
            id: String? = "song:track-a",
            generation: Int = 42,
            routeGeneration: UInt64 = 7,
            userCommand: Bool = true,
            builtIn: Bool = true
        ) -> Bool {
            manual.permitsExplicitPlay(
                playbackID: id,
                playbackGeneration: generation,
                routeGeneration: routeGeneration,
                isUserCommand: userCommand,
                outputIsBuiltIn: builtIn
            )
        }
        precondition(canManuallyRecover(),
                     "A real user Play may retry activation after unplug")
        checks += 1
        precondition(!canManuallyRecover(userCommand: false),
                     "A route callback cannot auto-play through the speaker")
        checks += 1
        precondition(!canManuallyRecover(builtIn: false),
                     "Never use old speaker permit after external rerouting")
        checks += 1
        precondition(!canManuallyRecover(id: "song:track-b"),
                     "Changed track invalidates stale manual resume")
        checks += 1
        precondition(!canManuallyRecover(generation: 43),
                     "Changed playback generation invalidates manual resume")
        checks += 1
        precondition(!canManuallyRecover(routeGeneration: 8),
                     "Changed route invalidates manual speaker resume")
        checks += 1

        // iOS 27.3 real-device: removal without putting AirPods in their
        // case -> route #2, legacy interruption begins, route #1 appears
        // again, but the interruption-ended notification never arrives.
        // Only the next explicit Play on that new external output may ask
        // iOS to activate. Do not automatically play on device reconnection.
        let reconnected = manual.transferredToExternalRoute(generation: 8)
        func canPlayOnReconnectedAirPods(
            id: String? = "song:track-a",
            generation: Int = 42,
            routeGeneration: UInt64 = 8,
            userCommand: Bool = true,
            builtIn: Bool = false
        ) -> Bool {
            reconnected.permitsExplicitPlay(
                playbackID: id,
                playbackGeneration: generation,
                routeGeneration: routeGeneration,
                isUserCommand: userCommand,
                outputIsBuiltIn: builtIn
            )
        }
        precondition(canPlayOnReconnectedAirPods(),
                     "Explicit Play must be allowed on reconnected AirPods")
        checks += 1
        precondition(!canPlayOnReconnectedAirPods(userCommand: false),
                     "Bluetooth reconnection cannot auto-play")
        checks += 1
        precondition(!canPlayOnReconnectedAirPods(builtIn: true),
                     "New external permit must not play on phone speaker")
        checks += 1
        precondition(!canPlayOnReconnectedAirPods(routeGeneration: 7),
                     "Previous speaker route cannot reuse the new permit")
        checks += 1
        precondition(!canPlayOnReconnectedAirPods(routeGeneration: 9),
                     "A subsequent route change invalidates the permit")
        checks += 1
        precondition(!canPlayOnReconnectedAirPods(id: "song:track-b"),
                     "Selecting another track invalidates the manual permit")
        checks += 1
        precondition(!canPlayOnReconnectedAirPods(generation: 43),
                     "Playback generation must match after reconnection")
        checks += 1
        let unplugAgain = reconnected.transferredToExternalRoute(generation: 9)
        precondition(
            unplugAgain.permitsExplicitPlay(
                playbackID: "song:track-a",
                playbackGeneration: 42,
                routeGeneration: 9,
                isUserCommand: true,
                outputIsBuiltIn: false
            ),
            "Repeated AirPods flapping must not strand the next manual Play"
        )
        checks += 1

        print("PASS: \(checks) Bluetooth route-change recovery checks")
    }
}
