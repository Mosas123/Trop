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

    var body: some View {
        GeometryReader { geometry in
            if let sourceCover = song.thumbnailUrl, !sourceCover.isEmpty {
                // The selected row's cover is the release identity chosen by
                // the user. Never swap it for a different catalogue edition.
                AsyncImageView(url: sourceCover)
            } else if let image = NowPlaying.shared.artwork(for: song.videoId) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                AsyncImageView(url: NowPlaying.shared.metadataSnapshot(for: song.videoId)?.artworkURL
                               ?? (resolvedKey == taskKey ? resolvedURL : nil))
            }
        }
            .task(id: taskKey) {
                resolvedURL = nil
                resolvedKey = taskKey
                // Don't make an external release lookup just to overwrite a
                // valid selected cover. This also avoids per-row network work.
                guard song.thumbnailUrl?.isEmpty != false,
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
                var coverURL = metadata?.artworkURL
                if coverURL == nil, let album = identity.album, !album.isEmpty {
                    coverURL = await MetadataResolver.albumArtwork(title: album, artist: identity.artist)
                }
                guard !Task.isCancelled else { return }
                resolvedURL = coverURL?.absoluteString
                if let metadata {
                    NowPlaying.shared.acceptResolvedMetadata(metadata, videoId: song.videoId)
                    onMetadataResolved?(metadata)
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
