//
//  MiniPlayerBarView.swift
//  Trop
//
//  Created by 686udjie on 18/07/2026.
//

import SwiftUI
import Nuke

/// The mini player bar, hosted as the TabView's native bottom accessory.
/// Swiping left/right pages through the queue with the artwork and text sliding
/// together, exactly tracking the drag state. When the tab bar minimizes on
/// scroll the bar collapses into a compact inline form that merges with the
/// tab bar, matching the Apple Music behavior; otherwise it renders as the
/// 48pt floating glass capsule with a bottom progress line.
struct MiniPlayerBarView: View {
    let artworkNamespace: Namespace.ID
    let onExpand: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared
    @State private var sheet = PlayerSheetState.shared

    @State private var dragOffset: CGFloat = 0
    @State private var dragAxis: DragAxis?
    @State private var isCommitting = false

    private enum DragAxis {
        case horizontal
        case vertical
    }

    private var barHeight: CGFloat {
        48 * 1.03
    }

    private var artworkSize: CGFloat {
        30 * 1.03
    }

    // Environment-driven: the previous scene/window walk ran on every body
    // evaluation (this view re-renders at progress rate and per drag frame).
    private var isDarkMode: Bool {
        colorScheme == .dark
    }

    private var titleColor: Color {
        isDarkMode ? .white : .black
    }

    private var artistColor: Color {
        isDarkMode ? Color.white.opacity(0.85) : Color.black.opacity(0.80)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if isDetached {
                    detachedNowPlaying
                } else {
                    pagingArea
                }
                playPauseButton
                    .frame(width: 44, height: barHeight)
                if geometry.size.width >= 300 && np.hasNext {
                    nextButton
                        .frame(width: 44, height: barHeight)
                }
            }
            .padding(.trailing, 8)
        }
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { frame in
            if frame.width > 0, frame.height > 0 {
                sheet.miniPlayerFrame = frame
            }
        }
        .overlay(alignment: .bottom) { progressLine }
        .clipShape(Capsule())
        .opacity(miniPlayerVisibility)
        .allowsHitTesting(!sheet.isExpanded)
        .accessibilityHidden(sheet.isExpanded)
        .onChange(of: np.videoId) { _, _ in
            dragOffset = 0
            preloadLyrics()
        }
        .onChange(of: np.queueSongs.count) { _, _ in
            dragOffset = 0
            np.preloadNeighborArtwork()
        }
        .onChange(of: np.queueIndex) { _, _ in
            dragOffset = 0
            np.preloadNeighborArtwork()
        }
        .task { np.preloadNeighborArtwork() }
    }

    /// Reveal the accessory contents as the full player moves toward them.
    private var miniPlayerVisibility: Double {
        guard sheet.isExpanded, !sheet.isCollapsing else { return 1 }
        let revealDistance = max(UIScreen.main.bounds.height * 0.65, 1)
        return Double(min(max(sheet.dragOffset / revealDistance, 0), 1))
    }

    private func preloadLyrics() {
        guard np.playbackKind == .music, let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    // MARK: - Paging area

    private var pagingArea: some View {
        GeometryReader { geo in
            let pageWidth = geo.size.width
            ZStack(alignment: .center) {
                if let prev = prevSong {
                    page(for: prev, width: pageWidth)
                        .offset(x: -pageWidth)
                }
                if let current = currentSong {
                    page(for: current, width: pageWidth)
                }
                if let next = nextSong {
                    page(for: next, width: pageWidth)
                        .offset(x: pageWidth)
                }
            }
            .frame(width: pageWidth, height: barHeight, alignment: .center)
            .offset(x: dragOffset)
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(pageWidth: pageWidth))
            .onTapGesture { onExpand() }
        }
        .frame(height: barHeight)
    }

    private func page(for song: SongItem, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            barArtwork(for: song.videoId)

            VStack(alignment: .leading, spacing: 0) {
                MarqueeText(
                    text: np.metadataSnapshot(for: song.videoId)?.title ?? song.title,
                    font: .system(size: 13, weight: .semibold),
                    frameHeight: 16,
                    textColor: titleColor
                )

                Text(artistLine(for: song))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(artistColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(width: width, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func barArtwork(for videoId: String) -> some View {
        let isCurrent = videoId == np.videoId
        ZStack {
            if isCurrent, let uiImage = np.thumbnailUIImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                MiniArtworkView(videoId: videoId)
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .modifier(PlayerArtworkMatch(
            namespace: artworkNamespace,
            isCurrent: isCurrent,
            isSource: miniArtworkIsSource,
            isEnabled: miniArtworkMatchingEnabled
        ))
    }

    /// A hidden accessory must not become a destination when the full player
    /// switches to queue, lyrics or video. Reconnect only for presentation/docking.
    private var miniArtworkMatchingEnabled: Bool {
        !sheet.isExpanded || sheet.isCollapsing
    }

    private var miniArtworkIsSource: Bool {
        !sheet.isExpanded || sheet.isCollapsing
    }

    private var playPauseButton: some View {
        Button(action: { player.togglePlayPause() }, label: {
            Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 17))
                .foregroundStyle(titleColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        })
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(np.isPlaying ? "Pause" : "Play"))
        .sensoryFeedback(.impact(weight: .light), trigger: np.isPlaying)
    }

    private var nextButton: some View {
        Button { np.playNext() } label: {
            Image(systemName: "forward.fill")
                .font(.system(size: 17))
                .foregroundStyle(titleColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Next track")
    }

    private var progressLine: some View {
        GeometryReader { geo in
            if np.playbackKind != .radio {
                let progressWidth = max(
                    0, min(geo.size.width, geo.size.width * CGFloat(np.progress))
                )
                Rectangle()
                    .fill(.tint)
                    .frame(width: progressWidth, height: 2)
            }
            // A live station is nonseekable. Show state in the text row,
            // not a false 0% song progress bar.
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }

    // MARK: - Data

    /// Radio shows the live ICY song when present; otherwise the station's own
    /// metadata (country • codec), never an empty line.
    private var nowPlayingArtistLine: String {
        if np.playbackKind == .radio, let live = np.liveTitle, !live.isEmpty {
            return live
        }
        return np.displayArtist
    }

    private var currentSong: SongItem? {
        guard np.queueSongs.indices.contains(np.queueIndex) else { return nil }
        return np.queueSongs[np.queueIndex]
    }

    /// True when the current playback isn't backed by the queue (e.g. internet
    /// radio), so the bar must read live NowPlaying data instead of queueSongs.
    private var isDetached: Bool {
        guard let videoId = np.videoId else { return false }
        guard let current = currentSong else { return true }
        return current.videoId != videoId
    }

    private var detachedNowPlaying: some View {
        HStack(spacing: 8) {
            ZStack {
                if let image = np.thumbnailUIImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.12)
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 14))
                        .foregroundStyle(titleColor.opacity(0.6))
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .modifier(PlayerArtworkMatch(
                namespace: artworkNamespace,
                isCurrent: true,
                isSource: miniArtworkIsSource,
                isEnabled: miniArtworkMatchingEnabled
            ))

            VStack(alignment: .leading, spacing: 0) {
                Text(np.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(titleColor)
                if np.playbackKind == .radio {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(np.radioPlaybackStatus == .live
                                  ? Color.red : Color.orange)
                            .frame(width: 5, height: 5)
                        Text(np.radioPlaybackStatus.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(artistColor)
                        Text(nowPlayingArtistLine)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(artistColor)
                    }
                } else {
                    Text(nowPlayingArtistLine)
                        .font(.system(size: 12, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(artistColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onExpand() }
    }

    private var prevSong: SongItem? {
        guard np.queueSongs.indices.contains(np.queueIndex - 1) else { return nil }
        return np.queueSongs[np.queueIndex - 1]
    }

    /// Artist line for a queued song, falling back to the resolved author
    /// (what the big player shows via `displayArtist`) when the queued item
    /// carries no artist runs — e.g. videos or cache-repaired songs.
    private func artistLine(for song: SongItem) -> String {
        if let metadata = np.metadataSnapshot(for: song.videoId) { return metadata.artist }
        let own = artistDisplayString(from: song.artists)
        if !own.isEmpty { return own }
        return own
    }

    private var nextSong: SongItem? {
        guard np.queueSongs.indices.contains(np.queueIndex + 1) else { return nil }
        return np.queueSongs[np.queueIndex + 1]
    }

    // MARK: - Gesture

    private func dragGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard !isCommitting else { return }
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal
                        : .vertical
                }
                guard dragAxis == .horizontal else { return }

                let minOffset = nextSong != nil ? -pageWidth : 0
                let maxOffset = prevSong != nil ? pageWidth : 0
                dragOffset = min(max(value.translation.width, minOffset), maxOffset)
            }
            .onEnded { value in
                guard !isCommitting else { return }
                defer { dragAxis = nil }

                switch dragAxis {
                case .horizontal:
                    if dragOffset <= -pageWidth * 0.35, nextSong != nil {
                        commitSwipe(to: .next, pageWidth: pageWidth)
                    } else if dragOffset >= pageWidth * 0.35, prevSong != nil {
                        commitSwipe(to: .previous, pageWidth: pageWidth)
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
                case .vertical:
                    if value.translation.height < -40 {
                        onExpand()
                    }
                case nil:
                    break
                }
            }
    }

    private enum SwipeDirection {
        case next
        case previous
    }

    private func commitSwipe(to direction: SwipeDirection, pageWidth: CGFloat) {
        isCommitting = true
        let target: CGFloat = direction == .next ? -pageWidth : pageWidth
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            dragOffset = target
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 220_000_000)
            switch direction {
            case .next: np.playNext()
            case .previous: np.playPrevious()
            }
            withAnimation(nil) { dragOffset = 0 }
            isCommitting = false
        }
    }
}

private struct PlayerArtworkMatch: ViewModifier {
    let namespace: Namespace.ID
    let isCurrent: Bool
    let isSource: Bool
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCurrent && isEnabled {
            content.matchedGeometryEffect(id: "playerArtwork", in: namespace, isSource: isSource)
        } else {
            content
        }
    }
}

// MARK: - Per-song artwork (memory-cache fast path)

@MainActor
private struct MiniArtworkView: View {
    let videoId: String

    @State private var uiImage: UIImage?

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.12)
                Image(systemName: "music.note")
                    .font(.system(size: 20))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .onAppear { load() }
    }

    private func load() {
        if let cached = cachedArtwork(for: videoId) {
            uiImage = cached
            return
        }
        guard let url = URL(string: NowPlaying.artworkURL(for: videoId)) else { return }
        loggedTask(Log.nowPlaying, "Mini artwork load failed") {
            let image = try await ArtworkLoader.image(for: url)
            let cropped = image.centerCroppedSquare()
            await MainActor.run { uiImage = cropped }
        }
    }
}

@MainActor
private func cachedArtwork(for videoId: String) -> UIImage? {
    guard let url = URL(string: NowPlaying.artworkURL(for: videoId)) else { return nil }
    return ArtworkLoader.cachedImage(for: url)?.centerCroppedSquare()
}
