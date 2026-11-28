//
//  DownloadManager.swift
//  Apollo
//
//  Created by 686udjie on 19/07/2026.
//

import AVFoundation
import Combine
import Foundation
import GRDB
import Network
import Nuke
import QuartzCore
import SwiftUI
import UIKit
@preconcurrency import ffmpegkit

/// Per-download progress cell. Isolating the high-frequency 0–99% updates in
/// a per-id object means only that row re-renders, not every row observing
/// the manager.
@MainActor
final class DownloadProgressBox: ObservableObject {
    @Published var fraction: Double = 0
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var downloads: [String: DownloadState] = [:]
    @Published private(set) var tracks: [DownloadedTrackEntity] = []
    @Published private(set) var persistedDownloadCount = 0
    @Published private(set) var isLoaded = false

    /// Lossless files above this size ask for confirmation first: a hi-res
    /// album can easily reach gigabytes.
    nonisolated static let largeDownloadBytes: Int64 = 60 * 1024 * 1024

    struct LargeDownloadRequest: Identifiable, Equatable {
        let id: String
        let title: String
        let artist: String
        let megabytes: Int
        let quality: String?
    }

    @Published var largeDownloadRequest: LargeDownloadRequest?
    private var pendingLargeDownload: (song: SongItem, source: DownloadSource)?

    private struct AddonQualityPreference {
        let requireCD: Bool
        let preferHiRes: Bool
        let preferAtmos: Bool
    }

    private var addonPreference: AddonQualityPreference? {
        guard SettingsStore.shared.hasMusicAddons else { return nil }
        // Downloads follow their own tier; Atmos stays off because offline
        // files reject E-AC3 and resolving it would still start a torrent.
        return AddonQualityPreference(
            requireCD: false,
            preferHiRes: SettingsStore.shared.downloadTier == .hiRes,
            preferAtmos: false
        )
    }

    enum DownloadState: Equatable {
        case notStarted
        /// Looking for a lossless source on the installed add-ons before downloading.
        case preparing
        case downloading(Double)
        case completed
        case failed(String)
    }

    nonisolated private static let minimumAudioBytes = 8_192

    private let fileManager = FileManager.default
    private let pathMonitor = NWPathMonitor()
    private var currentPath: NWPath?
    private var isReloading = false
    private var cancelledDownloadIds: Set<String> = []
    private var lastReportedProgress: [String: Double] = [:]
    private var lastProgressTime: [String: CFTimeInterval] = [:]
    private var progressBoxes: [String: DownloadProgressBox] = [:]
    private var activeFFmpegSessions: [String: FFmpegSession] = [:]
    /// A late completion must not unregister a newer session for this ID.
    private var activeFFmpegTokens: [String: UUID] = [:]

    private var tracksById: [String: DownloadedTrackEntity] = [:]

    private var downloadsDir: URL {
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.currentPath = path
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.cl0udly.apollo.network"))

        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reload()
            }
        }

        Task { await reload() }
    }

    private var isOnWiFi: Bool {
        // Until the first path update arrives, don't block downloads.
        guard let currentPath else { return true }
        return currentPath.usesInterfaceType(.wifi) == true
            || currentPath.usesInterfaceType(.wiredEthernet) == true
    }

    // MARK: - Paths

    func fileURL(for song: SongItem, fileExtension: String = "m4a") async -> URL {
        await displayDestinationURL(
            title: song.title,
            artist: song.artists.map(\.name).joined(separator: ", "),
            videoId: song.videoId,
            fileExtension: fileExtension
        )
    }

    func displayDestinationURL(
        title: String,
        artist: String,
        videoId: String,
        fileExtension: String = "m4a"
    ) async -> URL {
        ensureDirectories()
        let rawStem = title.isEmpty ? videoId : (artist.isEmpty ? title : "\(artist) - \(title)")
        let fileName = LocalAudioFilePolicy.storedFilename(
            title: rawStem,
            videoId: videoId,
            fileExtension: fileExtension
        )
        return downloadsDir.appendingPathComponent(fileName)
    }

    /// Imports an audio file from Files into this app's sandbox. Copying it
    /// means the player does not need to keep an external security-scoped URL
    /// alive after the picker closes, even across launches or offline use.
    /// The copy is done off-main and never loads the whole file into RAM.
    func importLocalAudio(from sourceURL: URL) async throws {
        guard LocalAudioFilePolicy.supports(sourceURL) else {
            throw LocalAudioImportError.unsupportedFormat
        }
        guard ensureDirectories() else {
            throw LocalAudioImportError.unavailableDestination
        }
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let title = Self.sanitizeFileName(sourceName)
        let newId = "local:\(UUID().uuidString)"
        let fileName = LocalAudioFilePolicy.storedFilename(
            title: title,
            videoId: newId,
            fileExtension: sourceURL.pathExtension
        )
        let destination = downloadsDir.appendingPathComponent(fileName)
        try await Task.detached(priority: .userInitiated) {
            let scoped = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { sourceURL.stopAccessingSecurityScopedResource() }
            }
            guard let properties = try? sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), properties.isRegularFile == true,
                LocalAudioFilePolicy.isValidAudioSize(properties.fileSize ?? 0)
            else { throw LocalAudioImportError.invalidFile }

            do {
                try FileManager.default.copyItem(
                    at: sourceURL, to: destination
                )
            } catch {
                // File-provider transfers can fail mid-copy or run out of disk
                // space. Do not leave a damaged file for the scanner to adopt.
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }.value

        let entity = DownloadedTrackEntity(
            id: newId,
            title: title,
            artist: "",
            duration: 0,
            thumbnailUrl: nil,
            localPath: storedPath(for: destination),
            downloadedAt: Date()
        )
        do {
            _ = try await DatabaseService.shared.insertOrReplace(entity)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
        tracksById[newId] = entity
        apply(tracksById)
        isLoaded = true
        Log.downloadManager.notice("Imported local audio format=\(sourceURL.pathExtension.lowercased())")
    }

    /// Strips characters illegal on filesystems, trims whitespace/dots and
    /// caps length for APFS's 255-byte limit.
    nonisolated static func sanitizeFileName(_ name: String) -> String {
        var stem = name.replacingOccurrences(of: "/", with: "-")
        let illegal = CharacterSet(charactersIn: ":\\?%*|\"<>").union(.controlCharacters)
        stem = stem.components(separatedBy: illegal).joined(separator: "-")
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        while stem.utf8.count > 150 { stem = String(stem.dropLast()) }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return stem.isEmpty ? "Untitled" : stem
    }

    /// AAC transcode bitrate for the download quality preference.
    nonisolated static func transcodeBitrate(for quality: DownloadQuality) -> Int {
        switch quality {
        case .auto, .high: return 192_000
        case .lossless: return 256_000
        case .standard: return 96_000
        }
    }

    @discardableResult
    func ensureDirectories() -> Bool {
        do {
            try fileManager.createDirectory(
                at: downloadsDir, withIntermediateDirectories: true
            )
            return true
        } catch {
            Log.downloadManager.error(
                "Unable to create Downloads folder: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func resolvedURL(for track: DownloadedTrackEntity) -> URL? {
        let stored = track.localPath
        let url: URL
        if stored.hasPrefix("/") {
            url = URL(fileURLWithPath: stored)
        } else {
            url = downloadsDir.appendingPathComponent(stored)
        }
        if fileManager.fileExists(atPath: url.path) { return url }

        let fileName = (stored as NSString).lastPathComponent
        if !fileName.isEmpty {
            let byName = downloadsDir.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: byName.path) { return byName }
        }

        return nil
    }

    private func storedPath(for url: URL) -> String {
        url.lastPathComponent
    }

    // MARK: - Reload / reconciliation

    /// Rebuilds the library from the database and the Downloads directory.
    /// Orphaned files are adopted, rows whose files vanished are dropped and
    /// stale absolute paths are rewritten relative to the current container.
    func reload() async {
        guard !isReloading else { return }
        isReloading = true
        defer { isReloading = false }

        ensureDirectories()
        let scanned = await Self.scanDownloads(downloadsDir)

        var rebuilt: [String: DownloadedTrackEntity] = [:]
        let databaseTracks = await fetchAllFromDatabase()

        for track in databaseTracks {
            guard let url = resolvedURL(for: track) ?? scanned[track.id] else {
                _ = try? await DatabaseService.shared.delete(track)
                continue
            }
            var fixed = track
            fixed.localPath = storedPath(for: url)
            if fixed.localPath != track.localPath {
                try? await DatabaseService.shared.save(fixed)
            }
            rebuilt[fixed.id] = fixed
        }

        for (videoId, url) in scanned where rebuilt[videoId] == nil {
            let metadata = await songMetadata(for: videoId)
            let entity = DownloadedTrackEntity(
                id: videoId,
                title: metadata?.title ?? Self.displayTitle(from: url),
                artist: metadata?.artistName ?? "",
                duration: metadata?.duration ?? 0,
                thumbnailUrl: metadata?.thumbnailUrl,
                localPath: storedPath(for: url),
                downloadedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date()
            )
            _ = try? await DatabaseService.shared.insertOrReplace(entity)
            rebuilt[videoId] = entity
            Log.downloadManager.notice("Recovered orphaned download \(videoId) from \(url.lastPathComponent)")
        }

        apply(rebuilt)
        isLoaded = true
    }

    func reconcileDownloadedFiles() async {
        await reload()
    }

    private func apply(_ newTracks: [String: DownloadedTrackEntity]) {
        tracksById = newTracks
        let sorted = newTracks.values.sorted { $0.downloadedAt > $1.downloadedAt }
        if tracks != sorted { tracks = sorted }
        if persistedDownloadCount != newTracks.count { persistedDownloadCount = newTracks.count }
    }

    /// Directory scan is disk-heavy; run it off the main actor.
    nonisolated private static func scanDownloads(_ dir: URL) async -> [String: URL] {
        await Task.detached(priority: .utility) { scanDownloadsSync(dir) }.value
    }

    nonisolated private static func scanDownloadsSync(_ dir: URL) -> [String: URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var found: [String: URL] = [:]
        var dates: [String: Date] = [:]

        for url in urls where LocalAudioFilePolicy.supports(url) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard LocalAudioFilePolicy.isValidAudioSize(
                values?.fileSize ?? 0
            ) else { continue }
            guard let videoId = Self.videoId(from: url.lastPathComponent) else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            if let existingDate = dates[videoId], existingDate >= modified { continue }
            found[videoId] = url
            dates[videoId] = modified
        }
        return found
    }

    /// Extracts the video id from `Artist - Title [<id>].m4a`.
    nonisolated static func videoId(from fileName: String) -> String? {
        LocalAudioFilePolicy.videoId(from: fileName)
    }

    nonisolated private static func displayTitle(from url: URL) -> String {
        var base = (url.lastPathComponent as NSString).deletingPathExtension
        if let range = base.range(of: #"\s*\[[A-Za-z0-9_:-]{6,}\]$"#, options: .regularExpression) {
            base.removeSubrange(range)
        }
        return base.isEmpty ? url.lastPathComponent : base
    }

    private func songMetadata(for videoId: String) async -> SongEntity? {
        try? await DatabaseService.shared.fetchOne(SongEntity.self, key: videoId)
    }
}

// MARK: - Download

extension DownloadManager {

    /// Downloads a whole list with bounded concurrency (default 3) instead of
    /// spawning one unbounded task per track.
    func downloadAll(_ songs: [SongItem], maxConcurrent: Int = 3) async {
        guard !songs.isEmpty else { return }
        let limit = max(1, maxConcurrent)
        let manager = DownloadManager.shared
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < songs.count {
                let batch = min(limit, songs.count - next)
                for _ in 0..<batch {
                    let song = songs[next]
                    next += 1
                    group.addTask {
                        await manager.download(song: song, allowLosslessSource: false)
                    }
                }
                await group.next()
            }
        }
    }

    func download(
        song inputSong: SongItem,
        allowLosslessSource: Bool = true,
        confirmedLarge: Bool = false,
        preResolved: DownloadSource? = nil,
        retried: Bool = false
    ) async {
        let song: SongItem
        if SpotifyCatalogID.isSpotify(inputSong.videoId) {
            guard let resolved = await SpotifyAudioResolver.shared.resolve(inputSong) else {
                Log.downloadManager.error("No audio match for Spotify track \(inputSong.videoId)")
                return
            }
            song = resolved
        } else {
            song = inputSong
        }
        let videoId = song.videoId
        if case .downloading = downloads[videoId] {
            Log.downloadManager.debug("Download already in progress for \(videoId)")
            return
        }
        if case .preparing = downloads[videoId] {
            Log.downloadManager.debug("Download source already being prepared for \(videoId)")
            return
        }

        if let existing = await localURL(for: videoId),
           let size = try? existing.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size >= Self.minimumAudioBytes {
            downloads[videoId] = .completed
            if tracksById[videoId] == nil {
                await adoptExistingFile(at: existing, song: song)
            }
            return
        }

        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "apollo-download-\(videoId)") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer {
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }

        cancelledDownloadIds.remove(videoId)
        clearProgress(for: videoId)
        let artist = song.artists.map(\.name).joined(separator: ", ")
        let downloadStart = CFAbsoluteTimeGetCurrent()
        Log.downloadManager.debug("Starting download: \(artist) - \(song.title) (\(videoId))")

        if SettingsStore.shared.wifiOnlyDownloads, !isOnWiFi {
            downloads[videoId] = .failed("Wi-Fi Only is enabled and you are not on Wi-Fi.")
            return
        }

        let willTryLossless = preResolved == nil
            && allowLosslessSource
            && !MusicPlaybackIdentity.isExternal(videoId)
            && SettingsStore.shared.losslessDownloads
            && SettingsStore.shared.hasMusicAddons
        if willTryLossless {
            downloads[videoId] = .preparing
        }
        setProgress(0.02, for: videoId)
        var destinationURL: URL?
        var failedAddonKey: String?
        do {
            async let artworkData = prefetchArtwork(for: song)

            setProgress(0.05, for: videoId)
            let resolveStart = CFAbsoluteTimeGetCurrent()
            let source: DownloadSource
            if let preResolved {
                source = preResolved
            } else {
                source = try await downloadSource(for: song, allowLossless: allowLosslessSource)
            }
            // This is what makes the existing retry path reachable. It was
            // declared but never assigned, so a failed add-on never cooled
            // down or retried on another installation.
            failedAddonKey = source.addonKey
            let knownBytes: Int64?
            if let known = source.knownSizeBytes {
                knownBytes = Int64(known)
            } else {
                knownBytes = await contentLength(of: source.url)
            }
            if !confirmedLarge, source.format == .flac,
               let bytes = knownBytes,
               bytes > Self.largeDownloadBytes {
                pendingLargeDownload = (song, source)
                downloads[videoId] = .notStarted
                largeDownloadRequest = LargeDownloadRequest(
                    id: videoId,
                    title: song.title,
                    artist: artist,
                    megabytes: Int((bytes + 1_048_575) / 1_048_576),
                    quality: source.qualityLabel
                )
                Log.downloadManager.debug("Large lossless download \(bytes / 1_048_576)MB — waiting for confirmation")
                return
            }
            downloads[videoId] = .downloading(0)
            let resolveElapsed = CFAbsoluteTimeGetCurrent() - resolveStart
            let format = source.format
            Log.downloadManager.debug(
                "RESOLVE \(String(format: "%.1f", resolveElapsed))s codec=\(source.mimeType) format=\(format.fileExtension)"
            )

            let fileURL = await fileURL(for: song, fileExtension: format.fileExtension)
            destinationURL = fileURL
            if fileManager.fileExists(atPath: fileURL.path) {
                try? fileManager.removeItem(at: fileURL)
            }

            let tempDownload = fileManager.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).\(format.tempExtension)")
            defer { try? fileManager.removeItem(at: tempDownload) }
            let dlStart = CFAbsoluteTimeGetCurrent()
            let stallWatcher = Task { [weak self] in
                var lastSize: Int64 = -1
                var stalled = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if Task.isCancelled { return }
                    guard let self else { return }
                    let size = Int64((try? tempDownload.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    if size <= lastSize { stalled += 1 } else { stalled = 0 }
                    lastSize = size
                    if stalled >= 4 {
                        await MainActor.run { self.activeFFmpegSessions[videoId]?.cancel() }
                        return
                    }
                }
            }
            defer { stallWatcher.cancel() }
            try await downloadToFile(
                from: source.url,
                to: tempDownload,
                videoId: videoId
            )
            let dlElapsed = CFAbsoluteTimeGetCurrent() - dlStart
            let dlSize = (try? tempDownload.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            Log.downloadManager.debug("DOWNLOAD \(String(format: "%.1f", dlElapsed))s \(dlSize / 1024)KB")
            // Some origins close the connection early; a truncated FLAC still
            // starts with the right magic bytes, so compare the byte count.
            if source.format != .other, let expected = knownBytes, expected > 0,
               Int64(dlSize) < expected - 262_144 {
                Log.downloadManager.error("Truncated download: got \(dlSize) of \(expected) bytes")
                throw DownloadError.incompleteTransfer
            }

            var artwork = await artworkData
            if let sourceArtwork = source.artworkURL,
               let better = await prefetchArtwork(from: sourceArtwork.absoluteString) {
                artwork = better
            }
            let album = source.album ?? song.album

            ensureDirectories()
            setProgress(0.88, for: videoId)
            let ffmpegStart = CFAbsoluteTimeGetCurrent()
            switch format {
            case .flac:
                // Lossless stays bit-perfect: no transcode. Embed the cover when
                // the FLAC muxer allows it, otherwise keep plain metadata.
                try validateFLACFile(at: tempDownload)
                do {
                    try await attachMetadata(
                        to: tempDownload,
                        fileExtension: "flac",
                        title: song.title,
                        artist: artist,
                        album: album,
                        artworkData: artwork,
                        videoId: videoId
                    )
                } catch {
                    Log.downloadManager.debug("FLAC artwork skipped: \(error.localizedDescription)")
                    do {
                        try await attachMetadata(
                            to: tempDownload,
                            fileExtension: "flac",
                            title: song.title,
                            artist: artist,
                            album: album,
                            artworkData: nil,
                            videoId: videoId
                        )
                    } catch {
                        Log.downloadManager.debug("FLAC tags skipped: \(error.localizedDescription)")
                    }
                }
                try fileManager.moveItem(at: tempDownload, to: fileURL)
            case .mp3:
                try await attachMetadata(
                    to: tempDownload,
                    fileExtension: "mp3",
                    title: song.title,
                    artist: artist,
                    album: album,
                    artworkData: artwork,
                    videoId: videoId
                )
                try fileManager.moveItem(at: tempDownload, to: fileURL)
            case .aac:
                // AVFoundation can open AAC/MP4; validate before remux.
                let validateStart = CFAbsoluteTimeGetCurrent()
                try await validateDownloadedFile(at: tempDownload)
                Log.downloadManager.debug("VALIDATE \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - validateStart))s")

                Log.downloadManager.debug("FFMPEG remux (AAC passthrough)...")
                try await attachMetadata(
                    to: tempDownload,
                    fileExtension: "m4a",
                    title: song.title,
                    artist: artist,
                    album: album,
                    artworkData: artwork,
                    videoId: videoId
                )
                try fileManager.moveItem(at: tempDownload, to: fileURL)
            case .other:
                // WebM/Opus is not readable by AVFoundation — transcode first,
                // then validate the generated .m4a.
                Log.downloadManager.debug("FFMPEG transcode (Opus -> AAC)...")
                try await processAudio(
                    TranscodeRequest(
                        inputURL: tempDownload,
                        outputURL: fileURL,
                        title: song.title,
                        artist: artist,
                        album: album,
                        artworkData: artwork
                    ),
                    videoId: videoId
                )
                let validateStart = CFAbsoluteTimeGetCurrent()
                do {
                    try await validateDownloadedFile(at: fileURL)
                } catch {
                    try? fileManager.removeItem(at: fileURL)
                    throw error
                }
                Log.downloadManager.debug("VALIDATE \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - validateStart))s")
            }
            Log.downloadManager.debug("FFMPEG \(String(format: "%.1f", CFAbsoluteTimeGetCurrent() - ffmpegStart))s")

            if cancelledDownloadIds.contains(videoId) {
                cancelledDownloadIds.remove(videoId)
                clearProgress(for: videoId)
                try? fileManager.removeItem(at: fileURL)
                downloads[videoId] = .notStarted
                return
            }

            let entity = DownloadedTrackEntity(
                id: videoId,
                title: song.title,
                artist: artist,
                duration: song.duration,
                thumbnailUrl: source.artworkURL?.absoluteString ?? song.thumbnailUrl,
                localPath: storedPath(for: fileURL),
                downloadedAt: Date()
            )
            await register(entity)

            downloads[videoId] = .completed
            clearProgress(for: videoId)
            let totalElapsed = CFAbsoluteTimeGetCurrent() - downloadStart
            Log.downloadManager.debug("DONE \(String(format: "%.1f", totalElapsed))s total: \(artist) - \(song.title)")
        } catch is CancellationError {
            cancelledDownloadIds.remove(videoId)
            clearProgress(for: videoId)
            if let destinationURL { try? fileManager.removeItem(at: destinationURL) }
            downloads[videoId] = .notStarted
        } catch {
            let cancelled = cancelledDownloadIds.contains(videoId)
                || (error as? URLError)?.code == .cancelled
                || error is CancellationError
            if let key = failedAddonKey, !cancelled {
                await AddonHealth.shared.recordFailure(key)
            }
            // A second addon/copy is often enough: the failed one is cooling
            // now, so the next lookup goes elsewhere instead of giving up.
            if !cancelled, !retried, failedAddonKey != nil {
                clearProgress(for: videoId)
                if let destinationURL { try? fileManager.removeItem(at: destinationURL) }
                downloads[videoId] = .notStarted
                Log.downloadManager.debug("Retrying \(videoId) on another addon copy")
                await download(
                    song: song,
                    allowLosslessSource: allowLosslessSource,
                    retried: true
                )
                return
            }
            if cancelled {
                cancelledDownloadIds.remove(videoId)
                clearProgress(for: videoId)
                if let destinationURL { try? fileManager.removeItem(at: destinationURL) }
                downloads[videoId] = .notStarted
                return
            }
            if downloads[videoId] != .completed, let destinationURL {
                try? fileManager.removeItem(at: destinationURL)
            }
            downloads[videoId] = .failed(userFacingDownloadError(error))
            clearProgress(for: videoId)
            Log.downloadManager.error("Failed download \(videoId): \(error.localizedDescription)")
        }
    }

    // MARK: - Source selection

    enum DownloadFormat {
        case flac
        case mp3
        case aac
        case other

        var fileExtension: String {
            switch self {
            case .flac: return "flac"
            case .mp3: return "mp3"
            case .aac: return "m4a"
            case .other: return "m4a"
            }
        }

        var tempExtension: String {
            switch self {
            case .flac: return "flac"
            case .mp3: return "mp3"
            case .aac: return "m4a"
            case .other: return "webm"
            }
        }
    }

    struct DownloadSource: Sendable {
        let url: URL
        let mimeType: String
        let format: DownloadFormat
        var album: String? = nil
        var artworkURL: URL? = nil
        var qualityLabel: String? = nil
        var knownSizeBytes: Int? = nil
        var addonKey: String? = nil
    }

    /// Picks what to download: an add-on track resolves its own stream; a
    /// YouTube song tries a lossless add-on match when the user prefers
    /// lossless, and falls back to the YouTube stream.
    private func downloadSource(for song: SongItem, allowLossless: Bool = true) async throws -> DownloadSource {
        let preference = addonPreference
        // Playback may prefer Dolby Atmos, but Downloads must save a file
        // whose codec matches its extension. Atmos add-ons often serve
        // E-AC3, which cannot be copied into a FLAC container. Seek an
        // actual FLAC (or a normal AAC fallback) for offline playback.
        let offlinePreferAtmos = false
        if let ref = AddonPlaybackID.decode(song.videoId) {
            guard let installation = MusicAddonsStore.shared.installation(key: ref.k) else {
                throw MusicCatalogError.unavailableTrack
            }
            let client = try MusicAddonClient(installation: installation)
            let quality: AddonStreamQuality
            if preference?.requireCD == true {
                quality = .lossless
            } else {
                quality = (preference?.preferHiRes ?? false) ? .hires : .lossless
            }
            let stream = try await client.resolveStream(
                type: ref.t,
                id: ref.i,
                preferAtmos: offlinePreferAtmos,
                quality: quality
            )
            guard !stream.isEncrypted,
                  stream.qualityTier != "Atmos" else {
                throw MusicCatalogError.unavailableTrack
            }
            switch stream.kind {
            case .youtube(let youTubeId):
                let resolved = try await PlaybackManager.shared.resolve(
                    videoId: youTubeId,
                    forDownload: true,
                    song: song
                )
                guard let url = URL(string: resolved.streamUrl) else { throw DownloadError.invalidStreamURL }
                return DownloadSource(
                    url: url,
                    mimeType: resolved.mimeType,
                    format: Self.format(mime: resolved.mimeType, url: url)
                )
            case .url(let url):
                return DownloadSource(
                    url: url,
                    mimeType: stream.mimeType,
                    format: Self.format(mime: stream.mimeType, url: url),
                    album: song.album,
                    artworkURL: song.thumbnailUrl.flatMap(URL.init(string:)),
                    qualityLabel: Self.qualityLabel(for: stream),
                    knownSizeBytes: stream.sizeBytes,
                    addonKey: installation.key
                )
            }
        }

        // Bulk downloads skip the lossless lookup: it can cost seconds per
        // track and a queue of 50 would stall for minutes.
        if allowLossless,
           song.contentKind != .episode,
           song.contentKind != .podcast,
           !MusicPlaybackIdentity.isExternal(song.videoId),
           SettingsStore.shared.losslessDownloads,
           let preference,
           let lossless = await raceLosslessSource(
               for: song,
               requireCD: preference.requireCD,
               preferAtmos: offlinePreferAtmos,
               preferHiRes: preference.preferHiRes
           ) {
            Log.downloadManager.debug("Lossless source for \(song.videoId)")
            return lossless
        }

        // Audius, Qobuz and JioSaavn tracks resolve to direct URLs,
        // so they can be downloaded like everything else.
        let resolved = try await PlaybackManager.shared.resolve(
            videoId: song.videoId,
            forDownload: true,
            song: song
        )
        guard let url = URL(string: resolved.streamUrl) else { throw DownloadError.invalidStreamURL }
        return DownloadSource(
            url: url,
            mimeType: resolved.mimeType,
            format: Self.format(mime: resolved.mimeType, url: url)
        )
    }

    private func contentLength(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 || http.statusCode == 206 else { return nil }
        let length = http.expectedContentLength
        return length > 0 ? length : nil
    }

    /// Called from the confirmation alert; resumes with the already-resolved
    /// source so nothing is looked up twice.
    func confirmLargeDownload() {
        guard let pending = pendingLargeDownload else { return }
        pendingLargeDownload = nil
        largeDownloadRequest = nil
        Task { await download(song: pending.song, confirmedLarge: true, preResolved: pending.source) }
    }

    func cancelLargeDownload() {
        pendingLargeDownload = nil
        largeDownloadRequest = nil
    }

    private static func qualityLabel(for stream: AddonStream) -> String? {
        if stream.qualityTier == "Atmos" { return "Dolby Atmos" }
        guard stream.qualityTier == "Lossless" else { return nil }
        return stream.isHiRes ? "FLAC · Hi-Res" : "FLAC · CD"
    }

    private static func format(mime: String, url: URL) -> DownloadFormat {
        let type = mime.lowercased()
        let ext = url.pathExtension.lowercased()
        if type.contains("flac") || ext == "flac" { return .flac }
        if type.contains("mpeg") || ext == "mp3" { return .mp3 }
        if type.contains("mp4a") || type.contains("aac") || ext == "m4a" || ext == "mp4" {
            return .aac
        }
        return .other
    }

    /// Asks the installed addons for a lossless source; the first answer wins.
    /// hit wins and the other lookup is cancelled. YouTube is the fallback.
    private func raceLosslessSource(
        for song: SongItem,
        seconds: Double = 45,
        requireCD: Bool = false,
        preferAtmos: Bool = false,
        preferHiRes: Bool = false
    ) async -> DownloadSource? {
        await withTimeout(seconds: seconds) {
            await self.addonDownloadSource(
                for: song,
                seconds: seconds,
                requireCD: requireCD,
                preferAtmos: preferAtmos,
                preferHiRes: preferHiRes
            )
        }
    }

    /// Best lossless addon stream for a YouTube song, probed before use.
    private func addonDownloadSource(
        for song: SongItem,
        seconds: Double = 45,
        requireCD: Bool = false,
        preferAtmos: Bool = false,
        preferHiRes: Bool = false
    ) async -> DownloadSource? {
        guard let match = await bestAddonMatch(
                  for: song,
                  seconds: seconds,
                  requireCD: requireCD,
                  preferAtmos: preferAtmos,
                  preferHiRes: preferHiRes
              ),
              case .url(let url) = match.stream.kind,
              OfflineAudioFormatPolicy.isVerifiedFLAC(
                  qualityTier: match.stream.qualityTier,
                  mimeType: match.stream.mimeType,
                  pathExtension: url.pathExtension
              )
        else { return nil }
        // Some addons report a size but answer HEAD badly; trust the size.
        // Never label a compressed Atmos/E-AC3 bitstream as FLAC.
        if match.stream.sizeBytes == nil, !(await probeAudioURL(url)) {
            await AddonHealth.shared.recordFailure(match.track.installationKey)
            return nil
        }
        return DownloadSource(
            url: url,
            mimeType: match.stream.mimeType,
            format: .flac,
            album: match.track.album,
            artworkURL: match.track.poster,
            qualityLabel: Self.qualityLabel(for: match.stream),
            knownSizeBytes: match.stream.sizeBytes,
            addonKey: match.track.installationKey
        )
    }

    /// Bounded add-on lookup so a slow addon can't stall the download; without
    /// a match the YouTube stream is used.
    private func bestAddonMatch(
        for song: SongItem,
        seconds: Double = 12,
        requireCD: Bool = false,
        preferAtmos: Bool = false,
        preferHiRes: Bool = false
    ) async -> AddonSourceResolver.Match? {
        await withTimeout(seconds: seconds) {
            await AddonSourceResolver.bestMatch(
                for: song,
                requireCD: requireCD,
                preferAtmos: preferAtmos,
                preferHiRes: preferHiRes
            )
        }
    }

    /// Runs an optional lookup with a deadline; nil on timeout.
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Cheap reachability check so a dead add-on URL doesn't kill the download
    /// instead of falling back to YouTube. HEAD only: a Range GET would pull the
    /// whole FLAC when the server ignores the header.
    private func probeAudioURL(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        // Signed URLs often reject HEAD (403/405) while GET works, so only
        // treat clearly dead targets as failures.
        switch http.statusCode {
        case 404, 410, 500...599: return false
        default: return true
        }
    }

    private func validateFLACFile(at url: URL) throws {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= Self.minimumAudioBytes else {
            Log.downloadManager.error("Downloaded FLAC too small (\(size) bytes)")
            throw DownloadError.invalidStreamURL
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = try handle.read(upToCount: 4) ?? Data()
        guard magic == Data("fLaC".utf8) else {
            Log.downloadManager.error("Downloaded file is not FLAC — rejecting as invalid stream")
            throw DownloadError.invalidStreamURL
        }
    }

    private func adoptExistingFile(at url: URL, song: SongItem) async {
        let entity = DownloadedTrackEntity(
            id: song.videoId,
            title: song.title,
            artist: song.artists.map(\.name).joined(separator: ", "),
            duration: song.duration,
            thumbnailUrl: song.thumbnailUrl,
            localPath: storedPath(for: url),
            downloadedAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
        )
        await register(entity)
    }

    private func register(_ entity: DownloadedTrackEntity) async {
        tracksById[entity.id] = entity
        apply(tracksById)
        do {
            try await DatabaseService.shared.insertOrReplace(entity)
        } catch {
            Log.downloadManager.error("Failed to persist download \(entity.id): \(error)")
        }
    }

    // MARK: - Validation & Errors

    private func validateDownloadedFile(at url: URL) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = values.fileSize ?? 0
        // Real audio streams are well above this; error/HTML bodies are not.
        guard size >= Self.minimumAudioBytes else {
            Log.downloadManager.error("Downloaded file too small (\(size) bytes) — likely a dead stream URL")
            throw DownloadError.invalidStreamURL
        }

        let asset = AVURLAsset(url: url)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            Log.downloadManager.error("Cannot open downloaded file as audio: \(error.localizedDescription)")
            throw DownloadError.invalidStreamURL
        }
        guard !audioTracks.isEmpty else {
            Log.downloadManager.error("Downloaded file has no audio track — rejecting as invalid stream")
            throw DownloadError.invalidStreamURL
        }
    }

    private func userFacingDownloadError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "No internet connection.")
            case .timedOut:
                return String(localized: "The download timed out.")
            default:
                break
            }
        }
        if let downloadError = error as? DownloadError {
            return downloadError.errorDescription ?? String(localized: "Download failed. Try again.")
        }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            return String(localized: "Could not process this track for offline playback. Try again.")
        }
        return String(localized: "Download failed. Try again.")
    }

    // MARK: - State

    static func shouldRefreshPersistedLibrary(
        old: [String: DownloadState],
        new: [String: DownloadState]
    ) -> Bool {
        for (videoId, newState) in new {
            let oldState = old[videoId] ?? .notStarted
            if oldState == newState { continue }
            switch (oldState, newState) {
            case (.downloading, .completed), (.downloading, .failed),
                 (.completed, .notStarted), (.failed, .notStarted),
                 (.notStarted, .completed):
                return true
            default:
                continue
            }
        }
        for (videoId, oldState) in old where new[videoId] == nil {
            if case .completed = oldState { return true }
        }
        return false
    }

    private func cancelAllActiveDownloads() {
        for (videoId, state) in downloads {
            if case .downloading = state {
                cancelledDownloadIds.insert(videoId)
            }
        }
        for (videoId, session) in activeFFmpegSessions {
            cancelledDownloadIds.insert(videoId)
            session.cancel()
        }
        activeFFmpegSessions.removeAll()
        activeFFmpegTokens.removeAll()
    }

    func progressBox(for videoId: String) -> DownloadProgressBox {
        if let box = progressBoxes[videoId] { return box }
        let box = DownloadProgressBox()
        progressBoxes[videoId] = box
        return box
    }

    private func clearProgress(for videoId: String) {
        lastReportedProgress.removeValue(forKey: videoId)
        lastProgressTime.removeValue(forKey: videoId)
        progressBoxes[videoId]?.fraction = 0
    }

    private func setProgress(_ fraction: Double, for videoId: String) {
        let clamped = min(0.99, max(0, fraction))
        let last = lastReportedProgress[videoId] ?? -1
        guard clamped >= 0.99 || last < 0 || clamped - last >= 0.02 else { return }
        // Cap the published bar to ~5 Hz; the per-id box re-renders only the
        // one row, while the coarse `.downloading` state stays in `downloads`.
        if clamped < 0.99 {
            let now = CACurrentMediaTime()
            if now - (lastProgressTime[videoId] ?? 0) < 0.2 { return }
            lastProgressTime[videoId] = now
        }
        lastReportedProgress[videoId] = clamped
        switch downloads[videoId] ?? .notStarted {
        case .downloading, .preparing:
            break
        default:
            downloads[videoId] = .downloading(0)
        }
        progressBox(for: videoId).fraction = clamped
    }

    private func prefetchArtwork(for song: SongItem) async -> Data? {
        if !MusicPlaybackIdentity.isExternal(song.videoId),
           song.contentKind == nil || song.contentKind == .music {
            let artist = cleanArtistDisplay(song.artists.first?.name ?? "")
            if !artist.isEmpty,
               let metadata = await MetadataResolver.enrich(title: song.title, artist: artist, album: song.album) {
                func identity(_ text: String) -> String {
                    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
                }
                if identity(metadata.title) == identity(song.title),
                   identity(metadata.artist) == identity(artist),
                   let artwork = await prefetchArtwork(from: metadata.artworkURL?.absoluteString) {
                    return artwork
                }
            }
        }
        return await prefetchArtwork(from: song.thumbnailUrl)
    }

    private func prefetchArtwork(from thumbnailUrl: String?) async -> Data? {
        guard let thumbUrl = ArtworkURLs.highRes(thumbnailUrl),
              let url = URL(string: thumbUrl) else { return nil }
        guard let image = try? await ArtworkLoader.image(for: url) else { return nil }
        return image.jpegData(compressionQuality: 0.9)
    }

    // MARK: - File Transfer (ffmpeg)

    private func downloadToFile(
        from url: URL,
        to destination: URL,
        videoId: String
    ) async throws {
        guard let caPath = Bundle.main.path(forResource: "cacert", ofType: "pem") else {
            throw NSError(
                domain: "DownloadManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "CA certificate bundle not found"]
            )
        }

        let args = [
            "-y",
            "-rw_timeout", "30000000",
            "-cafile", caPath,
            "-headers", "User-Agent: Mozilla/5.0\r\n",
            "-i", url.absoluteString,
            "-c", "copy",
            destination.path
        ]

        try await runFFmpeg(arguments: args, videoId: videoId) { [weak self] size in
            // The bridge delivers progress on MainActor already.
            // Asymptotic map so unknown Content-Length still moves the bar.
            let fraction = 0.05 + 0.80 * (1 - exp(-Double(size) / 5_000_000))
            self?.setProgress(fraction, for: videoId)
        }
    }

    /// Runs FFmpeg off the main actor via the async API; optionally reports size
    /// stats. Cancelling the calling task also cancels the FFmpeg session.
    private func runFFmpeg(
        arguments: [String],
        videoId: String? = nil,
        onSize: (@MainActor @Sendable (Int64) -> Void)? = nil
    ) async throws {
        let token = UUID()
        if let videoId { activeFFmpegTokens[videoId] = token }
        let sessionBox = FFmpegSessionBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = Self.startFFmpeg(
                    arguments: arguments,
                    continuation: continuation,
                    sessionBox: sessionBox,
                    onSize: onSize,
                    onCompletion: { [weak self] _ in
                        guard let self, let videoId,
                              self.activeFFmpegTokens[videoId] == token else { return }
                        self.activeFFmpegTokens.removeValue(forKey: videoId)
                        self.activeFFmpegSessions.removeValue(forKey: videoId)
                    }
                )
                sessionBox.set(session)
                // Register synchronously on MainActor, before the completion
                // task can remove it. A previous session cannot remove its successor.
                if let videoId, let session {
                    activeFFmpegSessions[videoId] = session
                } else if let videoId {
                    activeFFmpegTokens.removeValue(forKey: videoId)
                }
                if Task.isCancelled { session?.cancel() }
            }
        } onCancel: {
            sessionBox.current?.cancel()
        }
    }

    /// Objective-C invokes these blocks on its worker queues. Creating them
    /// inside the MainActor-isolated method above makes Swift 6 assert actor
    /// isolation on callback entry, before even an inner Task can hop actors.
    nonisolated private static func startFFmpeg(
        arguments: [String],
        continuation: CheckedContinuation<Void, Error>,
        sessionBox: FFmpegSessionBox,
        onSize: (@MainActor @Sendable (Int64) -> Void)?,
        onCompletion: @escaping @MainActor @Sendable (Int?) -> Void
    ) -> FFmpegSession? {
        let lock = NSLock()
        var finished = false
        let finish: (Result<Void, Error>) -> Void = { result in
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            continuation.resume(with: result)
        }

        let session = FFmpegKit.execute(
            withArgumentsAsync: arguments,
            withCompleteCallback: { session in
                sessionBox.set(nil)
                Task { @MainActor in onCompletion(nil) }
                let rc = session?.getReturnCode()
                if ReturnCode.isSuccess(rc) {
                    finish(.success(Void()))
                } else if ReturnCode.isCancel(rc) {
                    finish(.failure(CancellationError()))
                } else {
                    let output = session?.getOutput() ?? "unknown"
                    Log.downloadManager.debug("FFmpeg output: \(output)")
                    finish(.failure(NSError(
                        domain: "DownloadManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "FFmpeg processing failed"]
                    )))
                }
            },
            withLogCallback: nil,
            withStatisticsCallback: { statistics in
                guard let statistics else { return }
                let size = Int64(statistics.getSize())
                // Pass only the numeric snapshot across the actor boundary,
                // never FFmpeg's non-Sendable Statistics object.
                Task { @MainActor in onSize?(size) }
            }
        )
        if session == nil {
            finish(.failure(NSError(
                domain: "DownloadManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not start audio processing"]
            )))
        }
        return session
    }

}

// MARK: - Delete & queries

extension DownloadManager {
    func delete(videoId: String) async {
        cancelledDownloadIds.insert(videoId)
        if let session = activeFFmpegSessions.removeValue(forKey: videoId) {
            session.cancel()
        }
        activeFFmpegTokens.removeValue(forKey: videoId)
        clearProgress(for: videoId)
        downloads[videoId] = .notStarted
        tracksById.removeValue(forKey: videoId)

        if let entity = try? await DatabaseService.shared.fetchOne(DownloadedTrackEntity.self, key: videoId) {
            if let url = resolvedURL(for: entity) {
                try? fileManager.removeItem(at: url)
            }
            _ = try? await DatabaseService.shared.delete(entity)
        }
        // Also remove any orphaned file matching this id.
        let scannedFiles = await Self.scanDownloads(downloadsDir)
        if let scanned = scannedFiles[videoId] {
            try? fileManager.removeItem(at: scanned)
        }

        apply(tracksById)
    }

    func deleteAll() async {
        cancelAllActiveDownloads()

        // Remove files directly (off-main) so orphaned downloads are cleaned too.
        let scanned = await Self.scanDownloads(downloadsDir)
        let urls = Array(scanned.values)
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            for url in urls { try? fm.removeItem(at: url) }
        }.value
        // One DELETE instead of a round-trip per downloaded row.
        try? await DatabaseService.shared.write { db in
            try db.execute(sql: "DELETE FROM downloaded_track")
        }

        tracksById.removeAll()
        downloads.removeAll()
        // Keep cancelledDownloadIds so in-flight download(song:) ops still see cancel.
        lastReportedProgress.removeAll()
        apply([:])
    }

    // MARK: - Local URL Resolution

    func localURL(for videoId: String) async -> URL? {
        if let track = tracksById[videoId], let url = resolvedURL(for: track) {
            repairStoredPathIfNeeded(track, url: url)
            return url
        }

        guard let entity = try? await DatabaseService.shared.fetchOne(
            DownloadedTrackEntity.self,
            key: videoId
        ) else {
            Log.downloadManager.debug("localURL: no DB entity for \(videoId)")
            return nil
        }

        guard let url = resolvedURL(for: entity) else {
            Log.downloadManager.debug("localURL: \(videoId) file not found (stored=\(entity.localPath))")
            return nil
        }

        var fixed = entity
        fixed.localPath = storedPath(for: url)
        tracksById[fixed.id] = fixed
        if fixed.localPath != entity.localPath {
            try? await DatabaseService.shared.save(fixed)
        }
        apply(tracksById)
        return url
    }

    private func repairStoredPathIfNeeded(_ track: DownloadedTrackEntity, url: URL) {
        let current = storedPath(for: url)
        guard track.localPath != current else { return }
        var fixed = track
        fixed.localPath = current
        tracksById[fixed.id] = fixed
        apply(tracksById)
        Task { try? await DatabaseService.shared.save(fixed) }
    }

    // MARK: - Query Helpers

    func isDownloaded(videoId: String) -> Bool {
        tracksById[videoId] != nil
    }

    func fetchAll() async -> [DownloadedTrackEntity] {
        Array(tracksById.values)
    }

    func fetchAllSorted() async -> [DownloadedTrackEntity] {
        tracks
    }

    private func fetchAllFromDatabase() async -> [DownloadedTrackEntity] {
        (try? await DatabaseService.shared.fetchAll(DownloadedTrackEntity.self)) ?? []
    }

    var activeDownloads: [(videoId: String, progress: Double)] {
        downloads.compactMap { videoId, state in
            switch state {
            case .downloading, .preparing:
                return (videoId, progressBoxes[videoId]?.fraction ?? 0)
            default:
                return nil
            }
        }
        .sorted { $0.progress > $1.progress }
    }

    func totalStorageBytes() async -> Int64 {
        let dir = downloadsDir
        let tracks = Array(tracksById.values)
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var total: Int64 = 0
            for track in tracks {
                let url = track.localPath.hasPrefix("/")
                    ? URL(fileURLWithPath: track.localPath)
                    : dir.appendingPathComponent(track.localPath)
                guard fm.fileExists(atPath: url.path) else { continue }
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }.value
    }

    func state(for videoId: String) -> DownloadState {
        if let state = downloads[videoId], state != .notStarted {
            return state
        }
        return tracksById[videoId] != nil ? .completed : .notStarted
    }

    private func ffmpegMetadataArgs(title: String, artist: String, album: String? = nil) -> [String] {
        var args = ["-metadata", "title=\(title)", "-metadata", "artist=\(artist)"]
        if let album, !album.isEmpty {
            args += ["-metadata", "album=\(album)"]
        }
        return args
    }

    private func writeTempArtwork(_ data: Data?) throws -> URL? {
        guard let data else { return nil }
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try data.write(to: url)
        return url
    }

    /// Uses ffmpeg to remux an existing AAC file with metadata (title/artist/artwork).
    /// `-c copy` avoids re-encoding — just copies the audio stream and injects metadata atoms.
    private func attachMetadata(
        to fileURL: URL,
        fileExtension: String,
        title: String,
        artist: String,
        album: String? = nil,
        artworkData: Data?,
        videoId: String
    ) async throws {
        let tempOutput = fileManager.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        let artworkURL = try writeTempArtwork(artworkData)
        defer {
            try? fileManager.removeItem(at: tempOutput)
            if let artworkURL {
                try? fileManager.removeItem(at: artworkURL)
            }
        }

        var args = ["-y", "-i", fileURL.path]
        if let artworkURL {
            args += [
                "-i", artworkURL.path,
                "-map", "0:a",
                "-map", "1",
                "-c:a", "copy",
                "-c:v", "mjpeg",
                "-disposition:v", "attached_pic"
            ]
        } else {
            args += ["-c", "copy"]
        }
        args += ffmpegMetadataArgs(title: title, artist: artist, album: album)
        args.append(tempOutput.path)

        try await runFFmpeg(arguments: args, videoId: videoId)
        try? fileManager.removeItem(at: fileURL)
        try fileManager.moveItem(at: tempOutput, to: fileURL)
    }

    /// Transcodes a non-AAC stream (Opus, etc.) to AAC with metadata using ffmpeg.
    private func processAudio(_ request: TranscodeRequest, videoId: String) async throws {
        let bitrate = Self.transcodeBitrate(for: SettingsStore.shared.downloadQuality)
        let tempOutput = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        let artworkURL = try writeTempArtwork(request.artworkData)
        defer {
            try? fileManager.removeItem(at: tempOutput)
            if let artworkURL {
                try? fileManager.removeItem(at: artworkURL)
            }
        }

        var args = ["-y", "-i", request.inputURL.path]
        if let artworkURL {
            args += [
                "-i", artworkURL.path,
                "-map", "0:a",
                "-map", "1",
                "-c:a", "aac",
                "-b:a", "\(bitrate)",
                "-c:v", "mjpeg",
                "-disposition:v", "attached_pic"
            ]
        } else {
            args += ["-c:a", "aac", "-b:a", "\(bitrate)"]
        }
        args += ffmpegMetadataArgs(title: request.title, artist: request.artist, album: request.album)
        args.append(tempOutput.path)

        try await runFFmpeg(arguments: args, videoId: videoId)
        try? fileManager.removeItem(at: request.outputURL)
        try fileManager.moveItem(at: tempOutput, to: request.outputURL)
    }

    private struct TranscodeRequest {
        let inputURL: URL
        let outputURL: URL
        let title: String
        let artist: String
        let album: String?
        let artworkData: Data?
    }
}

enum LocalAudioImportError: LocalizedError {
    case unsupportedFormat
    case invalidFile
    case unavailableDestination

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file format is not supported for local audio."
        case .invalidFile:
            return "The selected audio file is missing, incomplete or unreadable."
        case .unavailableDestination:
            return "Apollo could not create its local audio folder."
        }
    }
}

enum DownloadError: Error, LocalizedError {
    case invalidStreamURL
    case transcodeFailed
    case incompleteTransfer

    var errorDescription: String? {
        switch self {
        case .invalidStreamURL:
            return String(localized: "The stream URL returned by the server was invalid")
        case .transcodeFailed:
            return String(localized: "Could not convert this track for offline playback.")
        case .incompleteTransfer:
            return String(localized: "The server closed the download early. Try again.")
        }
    }
}

// MARK: - Environment

private struct DownloadManagerEnvironmentKey: EnvironmentKey {
    static var defaultValue: DownloadManager {
        MainActor.assumeIsolated { DownloadManager.shared }
    }
}

extension EnvironmentValues {
    var downloadManager: DownloadManager {
        get { self[DownloadManagerEnvironmentKey.self] }
        set { self[DownloadManagerEnvironmentKey.self] = newValue }
    }
}


/// Lets the cancellation handler reach the FFmpeg session created inside the
/// continuation without sharing non-Sendable state unsafely.
private final class FFmpegSessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: FFmpegSession?

    func set(_ session: FFmpegSession?) {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    var current: FFmpegSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }
}
