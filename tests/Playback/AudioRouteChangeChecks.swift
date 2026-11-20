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
        check(.newDeviceAvailable, builtIn: true, expected: .resume,
              "The new-device event is not an unplugged-headphone pause")
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

        print("PASS: \(checks) Bluetooth route-change recovery checks")
    }
}
