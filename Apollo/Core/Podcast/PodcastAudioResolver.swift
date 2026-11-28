import Foundation

struct PodcastAudioMatch: Sendable {
    let audioURL: URL
    let feedTitle: String
    let feedAuthor: String?
    let feedURL: URL
    let episodeTitle: String
    let mimeType: String?
    let artworkURL: URL?
}

/// Resolves a Spotify podcast episode to the publisher's public RSS enclosure.
/// Spotify never provides the audio; the RSS does.
actor PodcastAudioResolver {
    static let shared = PodcastAudioResolver()

    private struct Entry {
        let match: PodcastAudioMatch?
        let at: Date
        let negative: Bool
    }

    private var cache: [String: Entry] = [:]
    private var knownFeeds: [String: URL] = [:]
    private let ttl: TimeInterval = 6 * 60 * 60
    private let negativeTTL: TimeInterval = 5 * 60

    /// Lets a caller that already fetched the show (e.g. PodcastDetailView)
    /// hand us the feed URL so the next episode skips the iTunes directory.
    func remember(feedURL: URL, for show: String) {
        let key = show.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        knownFeeds[key] = feedURL
    }

    func resolve(for song: SongItem, feedURL: URL? = nil) async -> PodcastAudioMatch? {
        guard song.contentKind == .episode || song.videoId.hasPrefix("spotify:episode:") else {
            return nil
        }
        let key = song.catalogID ?? song.videoId
        if let entry = cache[key] {
            let effective = entry.negative ? negativeTTL : ttl
            if Date().timeIntervalSince(entry.at) < effective {
                return entry.match
            }
        }

        let showName = song.artists.first?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !showName.isEmpty else {
            cache[key] = Entry(match: nil, at: Date(), negative: true)
            return nil
        }
        let showKey = showName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedURL: URL?
        if let feedURL {
            resolvedURL = feedURL
        } else if let known = knownFeeds[showKey] {
            resolvedURL = known
        } else if let feed = await ITunesPodcastDirectory.shared.feed(for: showName),
                  let url = feed.feedURL {
            knownFeeds[showKey] = url
            resolvedURL = url
        } else {
            cache[key] = Entry(match: nil, at: Date(), negative: true)
            return nil
        }

        guard let resolvedURL,
              let content = await PodcastRSSFeedLoader.shared.content(for: resolvedURL) else {
            cache[key] = Entry(match: nil, at: Date(), negative: true)
            return nil
        }

        guard let episode = bestEpisode(for: song, in: content.episodes) else {
            cache[key] = Entry(match: nil, at: Date(), negative: true)
            return nil
        }

        let match = PodcastAudioMatch(
            audioURL: episode.audioURL,
            feedTitle: content.title,
            feedAuthor: content.author,
            feedURL: resolvedURL,
            episodeTitle: episode.title,
            mimeType: episode.mimeType ?? mimeType(for: episode.audioURL),
            artworkURL: ArtworkQuality.resized(content.artworkURL, to: 1200)
        )
        cache[key] = Entry(match: match, at: Date(), negative: false)
        return match
    }

    func artwork(for show: String) async -> URL? {
        guard let feed = await ITunesPodcastDirectory.shared.feed(for: show),
              let feedURL = feed.feedURL else {
            return nil
        }
        remember(feedURL: feedURL, for: show)
        guard let content = await PodcastRSSFeedLoader.shared.content(for: feedURL) else {
            return nil
        }
        return ArtworkQuality.resized(content.artworkURL, to: 1200)
            ?? ArtworkQuality.resized(feed.artworkURL, to: 1200)
    }

    private func bestEpisode(for song: SongItem, in episodes: [PodcastEpisode]) -> PodcastEpisode? {
        let wantedTitle = TextMatch.normalizeTitle(song.title)
        guard !wantedTitle.isEmpty else { return nil }

        let scored = episodes.compactMap { episode -> (PodcastEpisode, Int)? in
            let title = TextMatch.normalizeTitle(episode.title)
            var score = 0
            if title == wantedTitle {
                score += 100
            } else if !title.isEmpty, title.contains(wantedTitle) || wantedTitle.contains(title) {
                score += 50
            } else {
                return nil
            }

            if song.duration > 0, let duration = episode.duration, duration > 0 {
                let delta = abs(duration - song.duration)
                if delta > 120 { return nil }
                score += max(0, 30 - Int(delta / 4))
            }
            return (episode, score)
        }

        return scored.max { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            // Equal titles: prefer the episode whose duration is closest.
            let lhsDelta = abs((lhs.0.duration ?? 0) - song.duration)
            let rhsDelta = abs((rhs.0.duration ?? 0) - song.duration)
            return lhsDelta > rhsDelta
        }?.0
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "ogg", "opus": return "audio/ogg"
        default: return "audio/mpeg"
        }
    }
}
