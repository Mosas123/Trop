//
//  FullPlayerView.swift
//  Trop
//
//  Created by 686udjie on 18/07/2026.
//

import SwiftUI

struct FullPlayerView: View {
    let artworkNamespace: Namespace.ID
    let usesDarkArtwork: Bool
    let onCollapse: () -> Void

    @Environment(SettingsStore.self) private var settings
    private let player = PlayerController.shared
    @Bindable private var np = NowPlaying.shared
    @State private var editingProgress: Float = 0
    @State private var isEditingSlider = false
    @State private var sheet = PlayerSheetState.shared

    @ObservedObject private var likeStore = LikeStore.shared
    private var isLiked: Bool {
        guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return false }
        return likeStore.isLiked(videoId: song.videoId)
    }
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var pendingRoute: DetailRoute?
    @State private var showSongMenu = false
    @State private var liveSaveStatus: String?
    @State private var artworkEntryOffset: CGFloat = 0
    @State private var currentLyrics: [LyricLine] = []
    @State private var canvasDominantColors: [Color]?
    @State private var showGoToMenu = false

    private var playerBackgroundColors: [Color] {
        let seed = (canvasDominantColors ?? np.dominantColors).first ?? .gray
        let palette = PlayerArtworkPalette(seed: seed, isDark: usesDarkArtwork)
        return [palette.top, palette.bottom]
    }

    /// 0 while full-screen, 1 once the card has been pulled far enough to show
    /// rounded corners — so the sheet look only appears while dismissing.
    private var cardProgress: CGFloat {
        min(1, max(0, sheet.dragOffset / 120))
    }

    var body: some View {
        GeometryReader { geometry in
            // The card fills the screen; only its content clears system insets.
            let windowInsets = (UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow })?.safeAreaInsets ?? .zero
            let topInset = max(geometry.safeAreaInsets.top, windowInsets.top)
            let bottomInset = max(geometry.safeAreaInsets.bottom, windowInsets.bottom)
            let horizontalPadding: CGFloat = geometry.size.width < 375 ? 24 : 32
            let isCompact = geometry.size.height < 700
            let globalFrame = geometry.frame(in: .global)
            let measuredMiniFrame = sheet.miniPlayerFrame
            let miniFrame = measuredMiniFrame.isEmpty
                ? CGRect(x: globalFrame.minX + 16,
                         y: globalFrame.maxY - geometry.safeAreaInsets.bottom - 110,
                         width: max(1, geometry.size.width - 32), height: 48 * 1.03)
                : measuredMiniFrame
            let isDocking = sheet.isCollapsing

            ZStack {
                if np.isVideoMode && np.hasVideo {
                    Color.black
                        .ignoresSafeArea(.container)
                } else if settings.playerBackgroundStyle == .solid {
                    Color.black
                        .ignoresSafeArea(.container)
                } else {
                    LinearGradient(
                        colors: [
                            playerBackgroundColors.first ?? Color(red: 0.15, green: 0.15, blue: 0.2),
                            playerBackgroundColors.last ?? Color(red: 0.05, green: 0.05, blue: 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(.container)
                    .animation(.easeInOut(duration: 0.8), value: playerBackgroundColors)
                }

                VStack(spacing: 0) {
                    Capsule()
                        .fill(.white.opacity(0.3))
                        .frame(width: 36, height: 5)
                        .padding(.top, topInset + 16)
                        .padding(.bottom, 16)
                        .contentShape(Rectangle().size(width: 60, height: 30))
                        .onTapGesture {
                            guard showLyrics else { return }
                            withAnimation(.easeInOut(duration: 0.3)) {
                                showLyrics = false
                            }
                        }
                        .accessibilityLabel(LocalizedStringKey(showLyrics ? "Close lyrics" : "Collapse player"))

                    if showLyrics {
                        LyricsView(
                            showLyrics: $showLyrics,
                            showQueue: $showQueue,
                            pendingRoute: $pendingRoute,
                            progressSlider: { progressSlider(horizontalPadding: horizontalPadding) }
                        )
                        .padding(.bottom, bottomInset)
                        .transition(.opacity)
                    } else if np.isVideoMode && np.hasVideo {
                        musicVideoContent
                            .padding(.bottom, bottomInset)
                        .transition(.opacity)
                    } else if showQueue {
                        QueueView(
                            showQueue: $showQueue,
                            isShuffleOn: $np.isShuffleOn,
                            isRepeatOn: $np.isRepeatOn,
                            editingProgress: $editingProgress,
                            isEditingSlider: $isEditingSlider,
                            pendingRoute: $pendingRoute,
                            progressSlider: { progressSlider(horizontalPadding: horizontalPadding) }
                        )
                        .padding(.bottom, bottomInset)
                        .transition(.opacity)
                    } else {
                        // The cover occupies the space left by the controls.
                        // Sharing this VStack prevents artwork/title collisions.
                        GeometryReader { artworkGeometry in
                            let side = max(1, min(artworkGeometry.size.width - 48,
                                                  artworkGeometry.size.height, 520))
                            artwork
                                .frame(width: side, height: side)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .matchedGeometryEffect(id: "playerArtwork", in: artworkNamespace, isSource: !sheet.isCollapsing)
                                .shadow(color: .black.opacity(0.4), radius: 28, y: 16)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(.bottom, isCompact ? 16 : 24)
                        .transition(.opacity)

                        titleAndActionsRow
                            .padding(.horizontal, horizontalPadding)
                            .padding(.bottom, isCompact ? 10 : 14)

                        if np.playbackKind == .radio, let live = np.liveSongInfo {
                            radioLiveCard(live)
                                .padding(.horizontal, horizontalPadding)
                                .padding(.bottom, 10)
                        }


                        progressSlider(horizontalPadding: horizontalPadding)
                            .padding(.top, 4)
                            .padding(.bottom, isCompact ? 8 : 12)

                        PlaybackControlsRow(
                            isPlaying: np.isPlaying,
                            hasPrevious: np.hasPrevious,
                            hasNext: np.hasNext,
                            onPrevious: { np.playPrevious() },
                            onPlayPause: { player.togglePlayPause() },
                            onNext: { np.playNext() }
                        )
                        .scaleEffect(isCompact ? 0.94 : 1)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: np.isPlaying)
                        .padding(.bottom, isCompact ? 2 : 8)

                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                            PlayerVolumeSlider()
                                .frame(height: 28)
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.bottom, 4)

                        SecondaryActionsRow(
                            showQueue: $showQueue,
                            isRepeatOn: $np.isRepeatOn,
                            showLyrics: np.playbackKind == .radio ? nil : $showLyrics,
                            showsQueueAction: np.playbackKind != .radio
                        )
                        .scaleEffect(isCompact ? 0.92 : 1)

                        // The card/background is full-bleed, but the content must
                        // clear the home indicator (safe area), per Apple's
                        // guidance: backgrounds ignore it, content respects it.
                        Color.clear.frame(
                            height: max(isCompact ? 2 : 8, bottomInset)
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(isDocking ? 0 : 1)
                .allowsHitTesting(sheet.dragOffset < 40 && !sheet.isCollapsing)
            }
            .overlay {
                if showGoToMenu {
                    goToMenuOverlay
                }
            }
            // Keep the expanded layout stable while its outer card contracts.
            // Artwork uses the shared namespace to travel into the accessory.
            .frame(width: geometry.size.width, height: geometry.size.height)
            .frame(
                width: isDocking ? miniFrame.width : geometry.size.width,
                height: isDocking ? miniFrame.height : geometry.size.height,
                alignment: .topLeading
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: isDocking ? miniFrame.height / 2 : 38 * cardProgress,
                    bottomLeadingRadius: isDocking ? miniFrame.height / 2 : 0,
                    bottomTrailingRadius: isDocking ? miniFrame.height / 2 : 0,
                    topTrailingRadius: isDocking ? miniFrame.height / 2 : 38 * cardProgress,
                    style: .continuous
                )
            )
            .opacity(isDocking ? 0 : 1)
            .ignoresSafeArea(.container, edges: .all)
            .offset(
                x: isDocking ? miniFrame.minX - globalFrame.minX : 0,
                y: isDocking ? miniFrame.minY - globalFrame.minY : sheet.dragOffset
            )
            .animation(.easeInOut(duration: 0.35), value: showQueue)
            .animation(.easeInOut(duration: 0.3), value: showLyrics)
            .simultaneousGesture(collapseDrag)
            .onChange(of: showsMainArtwork, initial: true) { _, visible in
                sheet.hasExpandedArtwork = visible
            }
            .onChange(of: np.videoId) { _, _ in
                np.isVideoMode = false
                showLyrics = false
                showQueue = false
                canvasDominantColors = nil
                preloadLyrics()
            }
            .onChange(of: np.queueSongs.count) { _, _ in
                np.preloadNeighborArtwork()
                preloadLyrics()
            }
            .onChange(of: np.queueIndex) { _, _ in
                np.preloadNeighborArtwork()
            }
            .onChange(of: showQueue) { _, newValue in
                if newValue { np.preloadNeighborArtwork() }
            }
            .task { np.preloadNeighborArtwork() }
            .task(id: np.videoId) { await loadCurrentLyrics() }
            .sheet(isPresented: $showSongMenu) {
                if let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil {
                    PlayerMenuSheet(song: song, onCollapseRequest: { onCollapse() })
                }
            }
            .background(
                Color.clear
                    .detailRouteSheet(item: $pendingRoute)
            )
        }
        .preferredColorScheme(.dark)
    }

    private var showsMainArtwork: Bool {
        !showLyrics && !showQueue && !np.isVideoMode
    }

    // MARK: - Go to album/artist

    private var currentSong: SongItem? {
        guard let videoID = np.videoId else { return nil }
        return np.queueSongs.first { $0.videoId == videoID }
    }

    private var navigationSong: SongItem? {
        guard np.playbackKind == .music, let videoID = np.videoId else { return nil }
        var song = currentSong ?? SongItem(
            videoId: videoID, title: np.displayTitle,
            artists: np.artists.isEmpty ? [YTArtist(name: np.displayArtist)] : np.artists,
            album: np.displayAlbumTitle.isEmpty ? nil : np.displayAlbumTitle,
            duration: np.duration.isFinite ? Int(max(0, np.duration)) : 0,
            thumbnailUrl: nil, isExplicit: false
        )
        if song.artists.isEmpty, !np.displayArtist.isEmpty {
            song.artists = [YTArtist(name: np.displayArtist)]
        }
        if song.album?.isEmpty != false, !np.displayAlbumTitle.isEmpty {
            song.album = np.displayAlbumTitle
        }
        return song
    }

    private var canOpenAlbum: Bool {
        guard let song = navigationSong else { return false }
        return song.albumId?.isEmpty == false || MusicPlaybackIdentity.isYouTube(song.videoId)
    }

    private var canOpenArtist: Bool {
        guard let song = navigationSong else { return false }
        return song.artists.contains { $0.id?.isEmpty == false }
            || !np.displayArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !song.artistNamesDisplay.isEmpty
    }

    private var currentAlbumSubtitle: String? {
        if !np.displayAlbumTitle.isEmpty { return np.displayAlbumTitle }
        if let album = currentSong?.album, !album.isEmpty { return album }
        return nil
    }

    private var goToMenuOverlay: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea(.container)
                .onTapGesture { showGoToMenu = false }

            VStack(spacing: 0) {
                Button { goToAlbum() } label: {
                    goToMenuRow(
                        icon: "square.stack",
                        title: "Go to Album",
                        subtitle: currentAlbumSubtitle
                    )
                }
                .disabled(!canOpenAlbum)
                .opacity(canOpenAlbum ? 1 : 0.4)

                Divider()

                Button { goToArtist() } label: {
                    goToMenuRow(
                        icon: "music.mic",
                        title: "Go to Artist",
                        subtitle: np.displayArtist
                    )
                }
                .disabled(!canOpenArtist)
                .opacity(canOpenArtist ? 1 : 0.4)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.horizontal, 28)
        }
    }

    private func goToMenuRow(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.body)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    private func goToAlbum() {
        guard let song = navigationSong, canOpenAlbum else { return }
        showGoToMenu = false
        if let albumId = song.albumId, !albumId.isEmpty {
            pendingRoute = .album(browseId: albumId)
        } else {
            pendingRoute = .songAlbum(song)
        }
    }

    private func goToArtist() {
        guard let song = navigationSong, canOpenArtist else { return }
        showGoToMenu = false
        if let id = song.artists.first(where: { $0.id?.isEmpty == false })?.id {
            pendingRoute = .artist(browseId: id)
        } else {
            let name = np.displayArtist.isEmpty ? song.artistNamesDisplay : np.displayArtist
            pendingRoute = .songArtist(song, name: name)
        }
    }

    // MARK: - Gestures

    /// Swipe left/right on the artwork to skip tracks (toggleable in Settings).
    /// Blocked at the queue's ends (no movement); on skip, the incoming
    /// artwork slides in from the swipe direction.
    private var artworkSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard settings.artworkSwipeNavigation else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -60, np.hasNext {
                    np.playNext()
                    slideInArtwork(fromLeft: false)
                } else if value.translation.width > 60, np.hasPrevious {
                    np.playPrevious()
                    slideInArtwork(fromLeft: true)
                }
            }
    }

    private func slideInArtwork(fromLeft: Bool) {
        artworkEntryOffset = fromLeft ? -600 : 600
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            artworkEntryOffset = 0
        }
    }

    /// Swipe down anywhere to collapse. Vertical-dominant drags only.
    private var collapseDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !sheet.isCollapsing, value.translation.height > 0,
                      value.translation.height > abs(value.translation.width) else { return }
                // Track the finger 1:1 while the content behind stays in place.
                sheet.dragOffset = value.translation.height
            }
            .onEnded { value in
                guard !sheet.isCollapsing else { return }
                let isVertical = value.translation.height > abs(value.translation.width)
                if isVertical, value.translation.height > 140 {
                    // Finish the current drag using the same dismissal transition.
                    onCollapse()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        sheet.dragOffset = 0
                    }
                }
            }
    }

    // MARK: - Player Content

    private func preloadLyrics() {
        guard settings.lyricsEnabled, np.playbackKind == .music else { return }
        guard let id = np.videoId else { return }
        let upcoming = np.upcomingSongs(prefixLimit: 3).map(\.videoId)
        Task { await LyricsService.shared.preload(videoId: id, upcoming: upcoming) }
    }

    private func loadCurrentLyrics() async {
        guard settings.lyricsEnabled, np.playbackKind == .music else {
            currentLyrics = []
            return
        }
        guard let videoId = np.videoId else {
            currentLyrics = []
            return
        }
        currentLyrics = []
        guard let lines = try? await LyricsService.shared.fetchLyrics(videoId: videoId),
              !Task.isCancelled,
              np.videoId == videoId else { return }
        currentLyrics = lines
    }

    private func radioLiveCard(_ live: LiveSongInfo) -> some View {
        HStack(spacing: 10) {
            Group {
                if let data = live.artwork, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.12))
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(.white.opacity(0.5))
                        }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(liveSaveStatus ?? String(localized: "On Air Now"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Text(live.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text([live.artist, live.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                Task { await saveLive(live) }
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save song")
        }
        .padding(10)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func saveLive(_ live: LiveSongInfo) async {
        liveSaveStatus = String(localized: "Saving…")
        liveSaveStatus = await RadioLiveSaver.download(artist: live.artist, title: live.title)
        try? await Task.sleep(for: .seconds(3))
        liveSaveStatus = nil
    }

    private var playerArtistLine: String {
        if np.playbackKind == .radio, let live = np.liveTitle, !live.isEmpty { return live }
        return np.displayArtist
    }

    private var titleAndActionsRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if np.playbackKind != .music {
                    Text(np.playbackKind == .radio ? "RADIO" : "PODCAST")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.6))
                }
                if (settings.apoloBetaEnabled && np.playbackKind == .music)
                    || (settings.apoloRadioBetaEnabled && np.playbackKind == .radio) {
                    Text(np.activePlaybackEngine.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.7))
                }
                PlayerTitleBlock(
                    title: np.displayTitle,
                    artist: playerArtistLine,
                    spacing: 5,
                    titleFont: .title2.weight(.bold),
                    titleHeight: 32,
                    artistFont: .title3
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .contentShape(Rectangle())
            .onTapGesture { showGoToMenu = true }

            HStack(spacing: 8) {
                Button {
                    guard let song = np.queueSongs.indices.contains(np.queueIndex) ? np.queueSongs[np.queueIndex] : nil else { return }
                    Task { await likeStore.toggle(song: song) }
                } label: {
                    Image(systemName: isLiked ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey(isLiked ? "Favorited" : "Favorite"))

                if np.queueSongs.indices.contains(np.queueIndex) {
                    PlayerOptionsButton {
                        showSongMenu = true
                    }
                }
            }
        }
    }

    private var musicVideoContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        np.isVideoMode = false
                        showQueue = false
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.48), in: Circle())
                }
                .accessibilityLabel("Return to artwork player")

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            musicVideoStage

            QueueView(
                showQueue: $showQueue,
                isShuffleOn: $np.isShuffleOn,
                isRepeatOn: $np.isRepeatOn,
                editingProgress: $editingProgress,
                isEditingSlider: $isEditingSlider,
                pendingRoute: $pendingRoute,
                progressSlider: { progressSlider(horizontalPadding: 32) },
                isVideoMode: true
            )
            .frame(maxHeight: .infinity)
        }
    }

    private var musicVideoStage: some View {
        artwork
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
    }

    @ViewBuilder
    private var artwork: some View {
        Group {
            if np.isVideoMode, np.hasVideo, !settings.apoloBetaEnabled {
                ZStack {
                    VideoPlayerView()
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .white, location: 0.12),
                                    .init(color: .white, location: 0.95),
                                    .init(color: .clear, location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    if !np.isVideoReady {
                        artworkImage
                            .transition(.opacity)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .animation(.easeOut(duration: 0.2), value: np.isVideoReady)
            } else {
                ZStack {
                    artworkImage
                    CanvasVideoView(
                        videoId: np.videoId,
                        title: np.displayTitle,
                        artist: np.displayArtist,
                        album: np.displayAlbumTitle.isEmpty ? nil : np.displayAlbumTitle,
                        isPlaying: np.isPlaying,
                        enabled: settings.canvasEnabled && !settings.apoloBetaEnabled,
                        onDominantColorsChange: { canvasDominantColors = $0 }
                    )
                }
                .onTapGesture {
                    guard np.hasVideo, !settings.apoloBetaEnabled else { return }
                    showQueue = true
                    player.setVideoMode()
                }
            }
        }
        .offset(x: artworkEntryOffset)
        .gesture(artworkSwipe)
    }

    /// Song artwork (or placeholder), filling its container.
    private var artworkImage: some View {
        ZStack {
            if let uiImage = np.thumbnailUIImage {
                // `thumbnailUIImage` is already center-cropped by NowPlaying.
                GeometryReader { geo in
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                ZStack {
                    Color.white.opacity(0.1)
                    Image(systemName: "music.note")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
    }

    private func progressSlider(horizontalPadding: CGFloat) -> some View {
        VStack(spacing: 6) {
            if np.playbackKind == .radio {
                // Radio has no seekable duration: never display a frozen
                // 0:00 / -0:00 slider while audio is actually playing.
                HStack(spacing: 8) {
                    if np.radioPlaybackStatus == .connecting
                        || np.radioPlaybackStatus == .reconnecting {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    } else {
                        Circle()
                            .fill(np.radioPlaybackStatus == .live
                                  ? Color.red : Color.white.opacity(0.55))
                            .frame(width: 7, height: 7)
                    }
                    Text(np.radioPlaybackStatus.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("LIVE RADIO")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.9)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(height: 27)
                .accessibilityElement(children: .combine)

                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 3)
            } else {
                ProgressBar(
                progress: Binding(
                    get: { isEditingSlider ? editingProgress : np.progress },
                    set: { editingProgress = $0 }
                ),
                accentColor: np.dominantColors.first ?? .white,
                isPlaying: np.isPlaying,
                onEditingChanged: { editing in
                    if editing {
                        editingProgress = np.progress
                    } else {
                        let target = TimeInterval(editingProgress) * np.duration
                        player.seek(to: target)
                        np.currentTime = target
                        player.updateNowPlayingProgress()
                    }
                    isEditingSlider = editing
                }
            )

            let current = isEditingSlider ? TimeInterval(editingProgress) * np.duration : np.currentTime
            let remaining = max(0, np.duration - current)

            HStack {
                Text(DurationFormat.playbackTime(current))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.numericText())

                Spacer()

                Text("-\(DurationFormat.playbackTime(remaining))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.numericText())
            }
            .overlay {
                if np.isUpgradingQuality || np.qualityBadgeLabel != nil {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                        Text(np.isUpgradingQuality ? "Upgrading…" : (np.qualityBadgeLabel ?? "Standard"))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.12)))
                }
            }
            }
        }
        .padding(.horizontal, horizontalPadding)
    }

}
