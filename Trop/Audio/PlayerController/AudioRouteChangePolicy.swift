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
            // A device being connected is not a headphone-disconnect pause.
            return .resume
        case .oldDeviceUnavailable:
            // Avoid blasting audio through the phone speaker when headphones
            // are unplugged, but preserve live radio on a new external route.
            return outputIsBuiltIn ? .pause : .resume
        }
    }
}
