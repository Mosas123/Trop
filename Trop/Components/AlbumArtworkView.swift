import SwiftUI

/// One catalogue lookup policy for song rows and the player. Never interpret
/// an arbitrary subtitle (duration, playlist name, etc.) as an album search.
struct SongArtworkView: View {
    let song: SongItem
    var onMetadataResolved: ((ResolvedMetadata) -> Void)? = nil

    @State private var resolvedURL: String?
    @State private var resolvedKey: String?

    private var taskKey: String {
        "\(song.videoId)|\(song.title)|\(song.artists.map(\.name).joined(separator: ", "))|\(song.album ?? "")|\(song.duration)"
    }

    private var needsVerifiedCover: Bool {
        MusicArtworkSelectionPolicy.shouldResolveVerifiedCover(
            thumbnailURL: song.thumbnailUrl,
            isVideo: song.isVideo,
            musicVideoType: song.musicVideoType
        )
    }

    var body: some View {
        GeometryReader { geometry in
            if !needsVerifiedCover, let sourceCover = song.thumbnailUrl,
               !sourceCover.isEmpty {
                // Known release art is stable across the row and full player.
                AsyncImageView(url: sourceCover)
            } else if resolvedKey == taskKey, let resolvedURL {
                // Do not allow a still image already cached by NowPlaying to
                // shadow the newly verified release artwork in this row.
                AsyncImageView(url: resolvedURL)
            } else if let image = NowPlaying.shared.artwork(for: song.videoId) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                // An unverified ytimg/video still is the LAST fallback.
                AsyncImageView(url: NowPlaying.shared.metadataSnapshot(for: song.videoId)?.artworkURL
                               ?? song.thumbnailUrl)
            }
        }
            .task(id: taskKey) {
                resolvedURL = nil
                resolvedKey = taskKey
                guard needsVerifiedCover,
                      song.contentKind == nil || song.contentKind == .music,
                      !MusicPlaybackIdentity.isExternal(song.videoId) else { return }
                let identity = TrackIdentity.make(from: song)
                let metadata = await MetadataResolver.enrich(
                    title: identity.title,
                    artist: identity.artist,
                    album: identity.album,
                    duration: identity.durationSeconds
                )
                guard !Task.isCancelled else { return }
                let verified = metadata.flatMap { candidate -> ResolvedMetadata? in
                    guard TextMatch.recordingsMatch(candidate.title, identity.title),
                          TextMatch.normalizeArtist(candidate.artist)
                              == TextMatch.normalizeArtist(identity.artist),
                          MusicArtworkSelectionPolicy.matchesRequestedRelease(
                              requested: identity.album, candidate: candidate.album
                          ) else { return nil }
                    return candidate
                }
                var coverURL = verified?.artworkURL
                if coverURL == nil, let album = identity.album, !album.isEmpty {
                    coverURL = await MetadataResolver.albumArtwork(
                        title: album, artist: identity.artist
                    )
                }
                guard !Task.isCancelled else { return }
                resolvedURL = coverURL?.absoluteString
                if let verified {
                    NowPlaying.shared.acceptResolvedMetadata(verified, videoId: song.videoId)
                    onMetadataResolved?(verified)
                }
            }
    }
}

extension SongArtworkView {
    /// Saved-library rows store `SongEntity`; map it to the player item shape.
    init(song entity: SongEntity, onMetadataResolved: ((ResolvedMetadata) -> Void)? = nil) {
        self.init(
            song: SongItem(
                videoId: entity.id,
                title: entity.title,
                artists: entity.artistName.map { [YTArtist(name: $0, id: nil)] } ?? [],
                album: entity.albumName,
                albumId: nil,
                duration: entity.duration,
                thumbnailUrl: entity.thumbnailUrl,
                isExplicit: false,
                playlistId: nil,
                likeStatus: nil
            ),
            onMetadataResolved: onMetadataResolved
        )
    }
}
