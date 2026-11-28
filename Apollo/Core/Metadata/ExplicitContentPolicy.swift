import Foundation

/// One gate for the "Hide explicit content" setting. Home already honored it;
/// search, albums, playlists and artist pages must not bypass it.
enum ExplicitContentPolicy {
    static var hidesExplicit: Bool { SettingsStore.shared.hideExplicit }

    static func allows(_ isExplicit: Bool) -> Bool {
        !hidesExplicit || !isExplicit
    }
}
