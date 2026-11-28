//
//  SponsorBlock.swift
//  Apollo
//
//  Created by 686udjie on 23/07/2026.
//

import CryptoKit
import Foundation

enum SponsorBlock {
    private static let enabledKey = "sponsorBlockEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func save(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }

    private static let skipIntroKey = "sponsorBlockSkipIntroAtStart"

    /// Off by default: inaccurate segment boundaries could skip into the vocals.
    static var skipsIntroAtStart: Bool {
        UserDefaults.standard.bool(forKey: skipIntroKey)
    }

    static func saveSkipIntroAtStart(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: skipIntroKey)
    }
}

@MainActor
final class SponsorBlockIntegration {
    static let shared = SponsorBlockIntegration()

    private struct Segment: Sendable {
        let start: Double
        let end: Double
        let category: String
    }

    private var videoId: String?
    private var lastObservedPosition: Double = 0
    private var segments: [Segment] = []
    private var skipped: Set<Int> = []
    private var prefetchedSegments: [String: [Segment]] = [:]
    private var prefetchOrder: [String] = []
    private var prefetchedAt: [String: Date] = [:]
    private let cacheTTL: TimeInterval = 24 * 3600
    private var fetchTasks: [String: Task<[Segment], Never>] = [:]

    private init() {}

    func warm(for videoId: String?) {
        guard SponsorBlock.isEnabled, let videoId else { return }
        _ = fetchTask(for: videoId)
    }

    func preloadedStartOffset(for videoId: String?) async -> Double {
        guard SponsorBlock.isEnabled,
              SponsorBlock.skipsIntroAtStart,
              let videoId else { return 0 }
        let found: [Segment]
        if let cached = prefetchedSegments[videoId] {
            found = cached
        } else if let task = fetchTasks[videoId] {
            found = await task.value
        } else {
            return 0
        }
        guard SponsorBlock.isEnabled,
              let first = found
                  .filter({ $0.category == "music_offtopic" })
                  .min(by: { $0.start < $1.start }),
              first.start < 0.5,
              first.end <= 25
        else { return 0 }
        return first.end
    }

    /// Called by NowPlaying's timer after it updates the position.
    func tick() {
        let nowPlaying = NowPlaying.shared
        // Podcasts only participate when their audio is the YouTube carrier;
        // RSS audio has a different ad layout and must never be seeked.
        guard nowPlaying.playbackKind == .music || nowPlaying.playbackKind == .podcast,
              SponsorBlock.isEnabled,
              let id = nowPlaying.videoId else { return }
        if id != videoId {
            videoId = id
            lastObservedPosition = 0
            segments = []
            skipped = []
            if let found = prefetchedSegments[id] {
                segments = found.sorted { $0.start < $1.start }
            } else {
                _ = fetchTask(for: id)
            }
            return
        }
        guard nowPlaying.isPlaying else { return }
        // The queue may retain the original video ID while the *audio*
        // comes from a verified ATV album track. SponsorBlock timestamps
        // belong to the original video and must not seek the studio master.
        // Also wait until Now Playing has published the current stream.
        guard let source = nowPlaying.currentResult,
              source.videoId == id,
              source.streamUrl == nowPlaying.currentStreamURL,
              // Video timestamps must never skip an independently resolved
              // addon/Qobuz/FLAC master just because its queue ID is YouTube.
              SponsorBlockSkipPolicy.allowsSource(clientName: source.clientName)
        else { return }
        let player = PlayerController.shared
        guard player.currentVideoId == id, player.pendingVideoId == nil else { return }
        let position = nowPlaying.currentTime
        // Replaying the same video (or seeking back) starts a new pass over
        // the segments; otherwise a second play silently skips nothing.
        if position + 1 < lastObservedPosition { skipped.removeAll() }
        lastObservedPosition = position
        let allowedCategories: Set<String> = nowPlaying.playbackKind == .podcast
            ? ["sponsor", "selfpromo"]
            : ["music_offtopic"]
        for (index, segment) in segments.enumerated()
        where !skipped.contains(index) && allowedCategories.contains(segment.category) {
            guard SponsorBlockSkipPolicy.shouldSkip(
                start: segment.start,
                end: segment.end,
                position: position,
                skipIntroAtStart: SponsorBlock.skipsIntroAtStart,
                allowAnyStartSegment: nowPlaying.playbackKind == .podcast
            ) else { continue }
            skipped.insert(index)
            Log.sponsorBlock.notice(
                "SponsorBlock seek category=\(segment.category) source=YouTube "
                    + "start=\(segment.start) end=\(segment.end) observed=\(position)"
            )
            player.seek(to: segment.end)
            return
        }
    }

    private func fetchTask(for videoId: String) -> Task<[Segment], Never> {
        if let task = fetchTasks[videoId] {
            return task
        }
        if let cached = prefetchedSegments[videoId],
           let fetched = prefetchedAt[videoId],
           Date().timeIntervalSince(fetched) < cacheTTL {
            return Task { cached }
        }

        let task = Task { await Self.fetchSegments(videoId: videoId) }
        fetchTasks[videoId] = task
        Task { [weak self] in
            let found = await task.value
            guard let self else { return }
            self.fetchTasks.removeValue(forKey: videoId)
            self.prefetchedSegments[videoId] = found.sorted { $0.start < $1.start }
            self.prefetchedAt[videoId] = Date()
            if !self.prefetchOrder.contains(videoId) {
                self.prefetchOrder.append(videoId)
            }
            while self.prefetchedSegments.count > 64, let oldest = self.prefetchOrder.first {
                self.prefetchOrder.removeFirst()
                self.prefetchedSegments.removeValue(forKey: oldest)
                self.prefetchedAt.removeValue(forKey: oldest)
            }
            if self.videoId == videoId {
                self.segments = found.sorted { $0.start < $1.start }
            }
        }
        return task
    }

    private struct VideoSegments: Decodable {
        struct Raw: Decodable {
            let category: String
            let actionType: String?
            let segment: [Double]
        }

        let videoID: String
        let segments: [Raw]
    }

    /// Returns non-music segments for a video, or an empty list when they
    /// aren't available.
    private nonisolated static func fetchSegments(videoId: String) async -> [Segment] {
        let hash = SHA256.hash(data: Data(videoId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        var components = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments/\(hash.prefix(4))")
        components?.queryItems = [
            URLQueryItem(name: "categories", value: "[\"music_offtopic\",\"sponsor\",\"selfpromo\"]"),
            URLQueryItem(name: "actionTypes", value: "[\"skip\"]")
        ]
        guard let url = components?.url else {
            Log.sponsorBlock.error("Could not build SponsorBlock URL videoId=\(videoId)")
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2.5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Log.sponsorBlock.error("Invalid SponsorBlock response videoId=\(videoId)")
                return []
            }
            guard http.statusCode == 200 else {
                Log.sponsorBlock.error("SponsorBlock HTTP \(http.statusCode) videoId=\(videoId)")
                return []
            }
            let videos = try JSONDecoder().decode([VideoSegments].self, from: data)
            guard let video = videos.first(where: { $0.videoID == videoId }) else { return [] }
            let allowed: Set<String> = ["music_offtopic", "sponsor", "selfpromo"]
            return video.segments
            .filter {
                allowed.contains($0.category)
                    && ($0.actionType ?? "skip") == "skip"
                    && $0.segment.count == 2
                    && $0.segment[1] > $0.segment[0]
            }
            .map { Segment(start: $0.segment[0], end: $0.segment[1], category: $0.category) }
            .sorted { $0.start < $1.start }
        } catch {
            Log.sponsorBlock.error("SponsorBlock fetch failed videoId=\(videoId): \(error.localizedDescription)")
            return []
        }
    }
}
