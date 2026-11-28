//
//  ArtistDetailView.swift
//  Apollo
//
//  Created by 686udjie on 03/07/2026.
//

@preconcurrency import ApolloTube
import Nuke
import SwiftUI
import UIKit

// MARK: - View Model

@MainActor
@Observable
final class ArtistDetailViewModel {
    let browseId: String
    var artist: ArtistDetailInfo?
    var isLoading = true
    var error: Error?

    private let innerTube = InnerTubeClient.apolloShared

    init(browseId: String) {
        self.browseId = browseId
    }

    /// Fetches artist browse page from InnerTube and parses the response.
    func load() async {
        isLoading = true
        error = nil

        if SpotifyCatalogID.isSpotify(browseId) {
            do {
                let id = SpotifyCatalogID.rawID(browseId) ?? browseId
                var parsed = try await SpotifyDetailService.shared.artistDetail(id: id)
                if let saved = try? await DatabaseService.shared.fetchOne(
                    ArtistEntity.self,
                    key: browseId
                ) {
                    parsed.isSubscribed = saved.bookmarkedAt != nil
                }
                artist = parsed
                isLoading = false
            } catch {
                self.error = error
                isLoading = false
            }
            return
        }

        do {
            let json = try await innerTube.browse(browseId: browseId).value
            var parsed = Self.parseArtistDetail(from: json, browseId: browseId)
            let saved = try? await DatabaseService.shared.fetchOne(ArtistEntity.self, key: browseId)
            parsed.isSubscribed = saved?.bookmarkedAt != nil
            Self.preloadHeroArtwork(for: parsed.thumbnailUrl)
            artist = parsed
            isLoading = false
            // Preserve the requested profile's photo. A fallback must match
            // its recordings as well as the artist's display name.
            let ytURL = parsed.thumbnailUrl.flatMap(URL.init(string:))
            let referenceTracks = parsed.songs.filter { song in
                song.artists.contains { $0.id == browseId }
            }.map(\.title)
            let resolved = await ArtistImageResolver.preferredImageURL(
                name: parsed.name,
                youTubeURL: ytURL,
                artistID: browseId,
                referenceTracks: referenceTracks
            )
            guard !Task.isCancelled else { return }
            if let resolved {
                artist?.heroImageURL = resolved.absoluteString
            }
            // Unblock the hero either way (falls back to the YouTube thumbnail).
            artist?.heroImageResolved = true
        } catch {
            self.error = error
            isLoading = false
        }
    }
}

// MARK: - Parser

extension ArtistDetailViewModel {
    /// Parses InnerTube browse JSON into an ArtistDetailInfo.
    /// Handles both musicImmersiveHeaderRenderer and musicResponsiveHeaderRenderer for the header,
    /// then extracts top songs from musicShelfRenderer and albums, singles, videos,
    /// playlists and related artists from musicCarouselShelfRenderer shelves.
    static func parseArtistDetail(from json: [String: Any], browseId: String) -> ArtistDetailInfo {
        var name = "Unknown Artist"
        var thumbnailUrl: String?
        var subscriberCountText: String?
        var descriptionText: String?
        var isSubscribed = false
        var subscriptionChannelId: String?
        var songs: [SongItem] = []
        var buckets = ArtistCarouselBuckets()

        // --- Header ---
        // Artist pages can use either an immersive header (large background image)
        // or a responsive header (smaller, more compact).
        if let header = json["header"] as? [String: Any] {
            if let immersive = header["musicImmersiveHeaderRenderer"] as? [String: Any] {
                name = InnerTubeJSON.runsText(immersive["title"] as? [String: Any]) ?? "Unknown Artist"
                thumbnailUrl = InnerTubeJSON.musicThumbnailURL(immersive)
                let subscription = extractSubscriptionDetails(from: immersive)
                isSubscribed = subscription.isSubscribed ?? false
                subscriberCountText = subscription.subscriberCountText
                subscriptionChannelId = subscription.channelId
                if let descDict = immersive["description"] as? [String: Any] {
                    let shelf = descDict["musicDescriptionShelfRenderer"] as? [String: Any]
                    descriptionText = (shelf?["description"] as? [String: Any]).flatMap { InnerTubeJSON.runsText($0) }
                        ?? InnerTubeJSON.runsText(descDict)
                }
            } else if let responsive = header["musicResponsiveHeaderRenderer"] as? [String: Any] {
                name = InnerTubeJSON.runsText(responsive["title"] as? [String: Any]) ?? "Unknown Artist"
                thumbnailUrl = InnerTubeJSON.musicThumbnailURL(responsive)
                let subscription = extractSubscriptionDetails(from: responsive)
                isSubscribed = subscription.isSubscribed ?? false
                subscriberCountText = subscription.subscriberCountText
                subscriptionChannelId = subscription.channelId
                if descriptionText == nil, let descDict = responsive["description"] as? [String: Any] {
                    let shelf = descDict["musicDescriptionShelfRenderer"] as? [String: Any]
                    descriptionText = (shelf?["description"] as? [String: Any]).flatMap { InnerTubeJSON.runsText($0) }
                        ?? InnerTubeJSON.runsText(descDict)
                }
            }
        }

        if name == "Unknown Artist" || thumbnailUrl == nil,
           let microformat = json["microformat"] as? [String: Any],
           let mfRenderer = microformat["microformatDataRenderer"] as? [String: Any] {
            if name == "Unknown Artist", let mfTitle = mfRenderer["title"] as? String {
                name = mfTitle
            }
            if thumbnailUrl == nil, let thumb = mfRenderer["thumbnail"] as? [String: Any],
               let thumbnails = thumb["thumbnails"] as? [[String: Any]],
               let last = thumbnails.last,
               let url = last["url"] as? String {
                thumbnailUrl = url
            }
            if descriptionText == nil, let desc = mfRenderer["description"] as? String {
                descriptionText = desc
            }
        }

        // --- Sections ---
        if let sections = BrowseLens.browseSections(json) {

            for sectionDict in sections {
                if descriptionText == nil,
                   let descShelf = sectionDict["musicDescriptionShelfRenderer"] as? [String: Any],
                   let desc = (descShelf["description"] as? [String: Any]).flatMap({ InnerTubeJSON.runsText($0) }),
                   !desc.isEmpty {
                    descriptionText = desc
                }

                // musicShelfRenderer typically contains a list of songs
                if let shelf = sectionDict["musicShelfRenderer"] as? [String: Any],
                   let items = shelf["contents"] as? [[String: Any]] {
                    for itemDict in items {
                        if let renderer = itemDict["musicResponsiveListItemRenderer"] as? [String: Any],
                           let song = SongItem.from(renderer) {
                            songs.append(song)
                        }
                    }
                }

                // musicCarouselShelfRenderer holds albums, singles, videos,
                // playlists and related artists — classified per shelf below.
                if let carousel = sectionDict["musicCarouselShelfRenderer"] as? [String: Any],
                   let items = carousel["contents"] as? [[String: Any]] {
                    let shelfTitle = extractCarouselTitle(carousel)
                    for itemDict in items {
                        guard let twoRow = itemDict["musicTwoRowItemRenderer"] as? [String: Any] else { continue }
                        classifyCarouselItem(twoRow, shelfTitle: shelfTitle, buckets: &buckets)
                    }
                }
            }
        }

        return ArtistDetailInfo(
            name: name,
            thumbnailUrl: thumbnailUrl,
            subscriberCountText: subscriberCountText,
            descriptionText: descriptionText,
            isSubscribed: isSubscribed,
            browseId: browseId,
            songs: songs,
            albums: buckets.albums,
            singles: buckets.singles,
            videos: buckets.videos,
            playlists: buckets.playlists,
            relatedArtists: buckets.relatedArtists,
            subscriptionChannelId: subscriptionChannelId
        )
    }

    /// Buckets for one artist page's carousel shelves.
    private struct ArtistCarouselBuckets {
        var albums: [AlbumItem] = []
        var singles: [AlbumItem] = []
        var videos: [SongItem] = []
        var playlists: [PlaylistItem] = []
        var relatedArtists: [ArtistItem] = []
    }

    /// Routes one carousel tile into albums, singles, videos, playlists or
    /// related artists based on its page type (and shelf/subtitle hints for
    /// singles & EPs, which share the album page type).
    private static func classifyCarouselItem(
        _ twoRow: [String: Any],
        shelfTitle: String,
        buckets: inout ArtistCarouselBuckets
    ) {
        let pageType = HomePageParser.extractPageType(twoRow)
        switch pageType {
        case "MUSIC_PAGE_TYPE_ALBUM", "MUSIC_PAGE_TYPE_AUDIOBOOK":
            guard let albumItem = AlbumItem.from(twoRow) else { return }
            if isSingleOrEP(shelfTitle: shelfTitle, renderer: twoRow) {
                buckets.singles.append(albumItem)
            } else {
                buckets.albums.append(albumItem)
            }
        case "MUSIC_PAGE_TYPE_ARTIST", "MUSIC_PAGE_TYPE_USER_CHANNEL":
            if let artistItem = ArtistItem.from(twoRow) {
                buckets.relatedArtists.append(artistItem)
            }
        case "MUSIC_PAGE_TYPE_PLAYLIST":
            if let playlistItem = PlaylistItem.from(twoRow) {
                buckets.playlists.append(playlistItem)
            }
        default:
            // Music videos expose a watch endpoint instead of a browse page.
            if pageType == "MUSIC_PAGE_TYPE_VIDEO" || HomePageParser.hasWatchEndpoint(twoRow),
               let video = SongItem.from(twoRow) {
                buckets.videos.append(video)
            }
        }
    }

    /// Singles & EPs share the album page type, so the shelf title
    /// ("Singles & EPs") or subtitle ("Single • 2024") decides.
    private static let singleOrEPWords: Set<String> = ["single", "singles", "ep", "eps"]

    private static func words(in text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
    }

    private static func isSingleOrEP(shelfTitle: String, renderer: [String: Any]) -> Bool {
        if words(in: shelfTitle).contains(where: singleOrEPWords.contains) {
            return true
        }
        let subtitleWords = InnerTubeJSON.runsTexts(renderer["subtitle"] as? [String: Any])
            .flatMap { words(in: $0) }
        return subtitleWords.contains(where: singleOrEPWords.contains)
    }

    /// Warms Nuke's cache before the artist screen appears, avoiding a second
    /// visible loading state for the immersive header artwork.
    private static func preloadHeroArtwork(for thumbnailUrl: String?) {
        guard let artworkURL = ArtworkURLs.highRes(thumbnailUrl),
              let url = URL(string: artworkURL) else {
            return
        }

        ArtworkLoader.warm(url)
    }

    /// YouTube Music subscription payloads vary: the subscribed state is in `subscriptionButton`, 
    /// the count in `subscriptionButton2`, and older responses include a notification toggle.
    private static func extractSubscriptionDetails(
        from header: [String: Any]
    ) -> (isSubscribed: Bool?, subscriberCountText: String?, channelId: String?) {
        var isSubscribed: Bool?
        var subscriberCountText: String?

        let buttons = ["subscriptionButton2", "subscriptionButton"]
            .compactMap { header[$0] as? [String: Any] }

        for button in buttons {
            if let subscribe = button["subscribeButtonRenderer"] as? [String: Any] {
                if isSubscribed == nil {
                    isSubscribed = subscribe["subscribed"] as? Bool
                }

                if subscriberCountText == nil {
                    for key in ["subscriberCountWithSubscribeText", "longSubscriberCountText", "shortSubscriberCountText"] {
                        if let count = InnerTubeJSON.runsText(subscribe[key] as? [String: Any]), !count.isEmpty {
                            subscriberCountText = count
                            break
                        }
                    }
                }
            }

            if let toggle = button["subscriptionNotificationToggleButtonRenderer"] as? [String: Any] {
                if isSubscribed == nil {
                    isSubscribed = toggle["subscribed"] as? Bool
                }
                if subscriberCountText == nil,
                   let count = InnerTubeJSON.runsText(toggle["subscribedText"] as? [String: Any]),
                   !count.isEmpty {
                    subscriberCountText = count
                }
            }
        }

        // Restrict the walk to the subscription button, not related artists.
        func channel(in value: Any) -> String? {
            if let dictionary = value as? [String: Any] {
                if let id = dictionary["channelId"] as? String, !id.isEmpty { return id }
                if let ids = dictionary["channelIds"] as? [String], let id = ids.first, !id.isEmpty { return id }
                for key in dictionary.keys.sorted() {
                    if let nested = dictionary[key], let id = channel(in: nested) { return id }
                }
            } else if let array = value as? [Any] {
                for item in array { if let id = channel(in: item) { return id } }
            }
            return nil
        }
        return (isSubscribed, subscriberCountText, buttons.compactMap { channel(in: $0) }.first)
    }

    /// Extracts the title from a musicCarouselShelfBasicHeaderRenderer.
    private static func extractCarouselTitle(_ carousel: [String: Any]) -> String {
        guard let header = carousel["header"] as? [String: Any],
              let basicHeader = header["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any],
              let title = InnerTubeJSON.runsText(basicHeader["title"] as? [String: Any]) else {
            return "Unknown"
        }
        return title
    }
}

// MARK: - View

struct ArtistDetailView: View {
    let browseId: String
    @State private var viewModel: ArtistDetailViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var scrollOffset: CGFloat = 0
    @State private var linkCopied = false
    @State private var showInfo = false
    @State private var isUpdatingSubscription = false
    @State private var showSubscriptionError = false
    @State private var subscriptionErrorMessage = ""
    @State private var infoGenre: String?
    @State private var infoBio: ArtistBioResolver.Bio?
    @State private var backdropColors: [Color] = []
    @Environment(\.colorScheme) private var colorScheme
    @State private var linkResetTask: Task<Void, Never>?

    init(browseId: String) {
        self.browseId = browseId
        _viewModel = State(initialValue: ArtistDetailViewModel(browseId: browseId))
    }

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .top) {
            ScrollView {
                DetailStateContainer(
                    isLoading: viewModel.isLoading,
                    error: viewModel.error,
                    data: viewModel.artist,
                    noun: "artist",
                    emptyIcon: "music.mic"
                ) { artist in
                    artistContent(for: artist)
                        .environment(\.colorScheme, .dark)
                        .foregroundStyle(.white)
                }
            }
            .scrollDisabled(viewModel.isLoading || viewModel.error != nil || viewModel.artist == nil)
            .miniPlayerTracksScroll().scrollEdgeEffectHidden(true, for: .bottom)
            .onScrollGeometryChange(
                for: CGFloat.self,
                of: { $0.contentOffset.y },
                action: { _, newOffset in
                    // Publish only coarse steps: writing this @State on every
                    // scroll pixel re-evaluated the whole page and re-blurred
                    // the banner per frame.
                    let clamped = max(0, newOffset)
                    if abs(clamped - scrollOffset) >= 12 { scrollOffset = clamped }
                }
            )
            .ignoresSafeArea(.container, edges: .top)
            .toolbar(.hidden, for: .navigationBar)
            .background(artistBackdrop)
            .task {
                guard viewModel.isLoading else { return }
                await viewModel.load()
            }

            customTopBar
                .padding(.top, geo.safeAreaInsets.top)
                .zIndex(1)
        }
        .ignoresSafeArea(.container, edges: .top)
        }
        .sheet(isPresented: $showInfo) {
            if let artist = viewModel.artist {
                artistInfoSheet(for: artist)
            }
        }
        .alert("Couldn't update favorite", isPresented: $showSubscriptionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(subscriptionErrorMessage)
        }
        .onDisappear { linkResetTask?.cancel() }
    }

    private var customTopBar: some View {
        HStack(spacing: 8) {
            topBarBackButton

            Spacer(minLength: 0)

            if let artist = viewModel.artist,
               let url = SpotifyCatalogID.shareURL(for: artist.browseId) ?? URL(string: "https://music.youtube.com/channel/\(artist.browseId)") {
                HStack(spacing: 0) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Share artist")
                    topBarMenuButton
                }
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var topBarBackButton: some View {
        topBarCircleButton(
            systemName: "chevron.left",
            accessibilityLabel: "Back",
            action: { dismiss() }
        )
    }

    private var topBarMenuButton: some View {
        Menu {
            if let artist = viewModel.artist,
               let url = SpotifyCatalogID.shareURL(for: artist.browseId) ?? URL(string: "https://music.youtube.com/channel/\(artist.browseId)") {
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button { copyArtistLink() } label: {
                Label(LocalizedStringKey(linkCopied ? "Link Copied" : "Copy Link"),
                      systemImage: linkCopied ? "checkmark" : "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .disabled(viewModel.artist == nil)
        .accessibilityLabel("Artist options")
    }

    private func topBarCircleButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action, label: {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .background(.ultraThinMaterial, in: Circle())
        })
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func copyArtistLink() {
        guard let artist = viewModel.artist,
              let url = SpotifyCatalogID.shareURL(for: artist.browseId) ?? URL(string: "https://music.youtube.com/channel/\(artist.browseId)") else { return }
        UIPasteboard.general.string = url.absoluteString
        linkCopied = true
        linkResetTask?.cancel()
        linkResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            linkCopied = false
        }
    }

    @ViewBuilder
    private func artistContent(for artist: ArtistDetailInfo) -> some View {
        LazyVStack(spacing: 0) {
            header(for: artist)

            if let featured = artist.albums.first {
                featuredAlbumCard(featured)
            }

            if !artist.songs.isEmpty {
                songsSection(artist: artist)
            }

            if !artist.albums.isEmpty {
                albumsSection(albums: artist.albums)
            }

            if !artist.singles.isEmpty {
                singlesSection(singles: artist.singles)
            }

            if !artist.videos.isEmpty {
                videosSection(videos: artist.videos)
            }

            if !artist.playlists.isEmpty {
                playlistsSection(playlists: artist.playlists)
            }

            if !artist.relatedArtists.isEmpty {
                relatedArtistsSection(artists: artist.relatedArtists)
            }

            if artist.songs.isEmpty && artist.albums.isEmpty && artist.singles.isEmpty
                && artist.videos.isEmpty && artist.playlists.isEmpty && artist.relatedArtists.isEmpty {
                VStack(spacing: 8) {
                    Spacer().frame(height: 40)
                    Text("No content found")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func header(for artist: ArtistDetailInfo) -> some View {
        if horizontalSizeClass == .regular {
            GeometryReader { proxy in
                headerBanner(
                    for: artist,
                    size: CGSize(width: proxy.size.width, height: Self.iPadBannerHeight)
                )
            }
            .frame(height: Self.iPadBannerHeight)
            .accessibilityElement(children: .contain)
        } else {
            // iPhone: full-width square banner.
            GeometryReader { proxy in
                headerBanner(for: artist, size: proxy.size)
            }
            .aspectRatio(0.85, contentMode: .fit)
            .accessibilityElement(children: .contain)
        }
    }

    private static let iPadBannerHeight: CGFloat = 400

    private func headerBanner(for artist: ArtistDetailInfo, size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            ZStack {
                Color(.systemGray5)

                AnimatedDistortion(size: size, isPlaying: NowPlaying.shared.isPlaying && scrollOffset < size.height, amplitude: 6) {
                    Group {
                        if artist.heroImageResolved {
                            AsyncImageView(
                                url: ArtworkURLs.highRes(artist.heroImageURL ?? artist.thumbnailUrl),
                                contentMode: .fill,
                                onImageLoaded: { image in
                                    guard backdropColors.isEmpty else { return }
                                    withAnimation(.easeInOut(duration: 0.4)) {
                                        backdropColors = image.extractDominantColors()
                                    }
                                }
                            )
                        } else {
                            AsyncImageView(
                                url: ArtworkURLs.sized(artist.thumbnailUrl, width: 600, height: 600),
                                contentMode: .fill
                            )
                            .blur(radius: 30)
                            .opacity(0.5)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .blur(radius: min(max(scrollOffset, 0) / 20, 12))
                }

                // Fades the photo into the artist's dominant color so the page reads
                // as one surface (Apple Music artist page).
                LinearGradient(
                    colors: [.clear, artworkPalette.top.opacity(0.35), artworkPalette.top],
                    startPoint: .center,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [.clear, .black.opacity(0.25), .black.opacity(0.45)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .mask {
                artistImageFade
            }

            VStack(spacing: 16) {
                Text(artist.name)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)

                HStack(spacing: 28) {
                    Button { showInfo = true } label: {
                        Image(systemName: "info")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(.white.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Artist info")

                    Button { playArtist(artist) } label: {
                        ZStack {
                            Circle().fill(.white)
                            Image(systemName: "play.fill")
                                .font(.system(size: 28, weight: .bold))
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                        .frame(width: 70, height: 70)
                    }
                    .buttonStyle(.plain)
                    .disabled(artist.songs.isEmpty)
                    .accessibilityLabel("Play artist")

                    Button { toggleSubscribe(artist) } label: {
                        Image(systemName: artist.isSubscribed ? "star.fill" : "star")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(.white.opacity(0.22)))
                    }
                    .buttonStyle(.plain)
                    .disabled(isUpdatingSubscription)
                    .accessibilityLabel(LocalizedStringKey(artist.isSubscribed ? "Unfollow artist" : "Follow artist"))
                }

            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }

    private var artworkPalette: DetailArtworkPalette {
        DetailArtworkPalette(seed: backdropColors.first ?? .gray, isDark: colorScheme == .dark, surface: .artist)
    }

    private var backdropColor: Color { artworkPalette.top }

    private var artistImageFade: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.90),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var artistBackdrop: some View {
        LinearGradient(
            stops: [
                .init(color: artworkPalette.top, location: 0),
                .init(color: artworkPalette.bottom, location: 0.75),
                .init(color: artworkPalette.bottom, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea(.container)
    }


    private func artistInfoSheet(for artist: ArtistDetailInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    ZStack {
                        Group {
                            if artist.heroImageResolved {
                                AsyncImageView(
                                    url: ArtworkURLs.highRes(artist.heroImageURL ?? artist.thumbnailUrl),
                                    contentMode: .fill
                                )
                            } else {
                                AsyncImageView(
                                    url: ArtworkURLs.sized(artist.thumbnailUrl, width: 600, height: 600),
                                    contentMode: .fill
                                )
                                .blur(radius: 30)
                                .opacity(0.5)
                            }
                        }
                        .frame(height: UIScreen.main.bounds.height * 0.52)
                        .clipped()

                        LinearGradient(
                            colors: [.clear, backdropColor.opacity(0.45), backdropColor.opacity(0.45)],
                            startPoint: .center,
                            endPoint: .bottom
                        )

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.3), .black.opacity(0.5)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    }
                    .mask { artistImageFade }

                    Text(artist.name)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }

                VStack(alignment: .leading, spacing: 20) {
                    if let born = infoBio?.born {
                        infoField("Born", born)
                    }
                    if let from = infoBio?.from {
                        infoField("From", from)
                    }
                    if let genre = infoGenre {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Genre")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text(genre)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(.quaternary))
                        }
                    }

                    if let description = artist.descriptionText, !description.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About")
                                .font(.title3.bold())
                            Text(description)
                                .font(.body)
                        }
                    }

                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(artistBackdrop)
        .ignoresSafeArea(.container, edges: .bottom)
        .overlay(alignment: .topLeading) {
            ArtistBiographyCloseButton()
                .padding(.top, 14)
                .padding(.leading, 16)
                .zIndex(1)
        }
        .task {
            async let genre = ArtistGenreResolver.genre(for: artist.name)
            async let bio = ArtistBioResolver.bio(for: artist.name)
            infoGenre = await genre
            infoBio = await bio
        }
        .presentationDragIndicator(.hidden)
        .presentationDetents([.large])
    }

    private func infoField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(LocalizedStringKey(label))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
        }
    }

    private func subscriberLabel(for count: String) -> String {
        if count.localizedCaseInsensitiveContains("subscriber") {
            return count
        }
        return String(format: NSLocalizedString("%@ subscribers", comment: "Artist subscribers count"), count)
    }

    private func featuredAlbumCard(_ album: AlbumItem) -> some View {
        ZStack(alignment: .trailing) {
            NavigationLink(value: DetailRoute.album(browseId: album.browseId)) {
                HStack(spacing: 12) {
                    SmartArtwork(
                        url: album.thumbnailUrl,
                        subject: .album(
                            title: album.title,
                            artist: album.artists.map(\.name).joined(separator: ", ")
                        )
                    )
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Featured Album")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(album.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(featuredSubtitle(album))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 48)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .buttonStyle(.plain)

            Button { AlbumActions.toggleSave(album) } label: {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save album")
            .padding(.trailing, 12)
        }
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func featuredSubtitle(_ album: AlbumItem) -> String {
        var parts: [String] = []
        let artists = album.artists.map(\.name).joined(separator: ", ")
        if !artists.isEmpty { parts.append(artists) }
        if let year = album.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func songsSection(artist: ArtistDetailInfo) -> some View {
        let songs = artist.songs
        return VStack(alignment: .leading, spacing: 4) {
            NavigationLink {
                ArtistTopSongsView(songs: artist.songs, artistName: artist.name)
            } label: {
                HStack(spacing: 6) {
                    Text("Top Songs")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ForEach(Array(songs.enumerated()), id: \.element.videoId) { index, song in
                SongRowView(
                    song: song,
                    onTap: { playSong(song) },
                    onNavigate: { AppRouter.shared.open($0) }
                )
                .id(song.videoId)

                if index < songs.count - 1 {
                    Divider()
                        .padding(.leading, 68)
                }
            }
        }
    }

    @ViewBuilder
    private func albumsSection(albums: [AlbumItem]) -> some View {
        carouselSection(title: "Albums") {
            ForEach(albums, id: \.browseId) { album in
                NavigationLink(value: DetailRoute.album(browseId: album.browseId)) {
                    MediaGridCell(
                        thumbnailUrl: album.thumbnailUrl,
                        title: album.title,
                        subtitle: album.artists.map(\.name).joined(separator: ", "),
                        size: 156,
                        artworkSubject: .album(
                            title: album.title,
                            artist: album.artists.map(\.name).joined(separator: ", ")
                        )
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { AlbumContextMenu(album: album) }
            }
        }
    }

    @ViewBuilder
    private func singlesSection(singles: [AlbumItem]) -> some View {
        carouselSection(title: "Singles & EPs") {
            ForEach(singles, id: \.browseId) { single in
                NavigationLink(value: DetailRoute.album(browseId: single.browseId)) {
                    MediaGridCell(
                        thumbnailUrl: single.thumbnailUrl,
                        title: single.title,
                        subtitle: single.artists.map(\.name).joined(separator: ", "),
                        size: 156,
                        artworkSubject: .album(
                            title: single.title,
                            artist: single.artists.map(\.name).joined(separator: ", ")
                        )
                    )
                }
                .buttonStyle(.plain)
                .contextMenu { AlbumContextMenu(album: single) }
            }
        }
    }

    @ViewBuilder
    private func videosSection(videos: [SongItem]) -> some View {
        carouselSection(title: "Videos") {
            ForEach(videos, id: \.videoId) { video in
                Button(action: { playVideo(video) }, label: {
                    VStack(alignment: .leading, spacing: 6) {
                        SmartArtwork(
                            url: video.thumbnailUrl,
                            subject: .track(
                                title: video.title,
                                artist: video.artists.map(\.name).joined(separator: ", "),
                                album: video.album,
                                duration: video.duration
                            )
                        )
                            .frame(width: 200, height: 112)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(video.title)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(2)
                            .frame(width: 200, alignment: .leading)
                        if !video.duration.formattedDuration.isEmpty {
                            Text(video.duration.formattedDuration)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                })
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func playlistsSection(playlists: [PlaylistItem]) -> some View {
        carouselSection(title: "Playlists") {
            ForEach(playlists, id: \.id) { playlist in
                NavigationLink(value: DetailRoute.playlist(playlistId: playlist.id)) {
                    MediaGridCell(
                        thumbnailUrl: playlist.thumbnailUrl,
                        title: playlist.title,
                        subtitle: playlistSubtitle(playlist.author),
                        size: 156
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func relatedArtistsSection(artists: [ArtistItem]) -> some View {
        carouselSection(title: "Fans Also Like", spacing: 16) {
            ForEach(artists, id: \.browseId) { related in
                NavigationLink(value: DetailRoute.artist(browseId: related.browseId)) {
                    VStack(spacing: 8) {
                        ArtistAvatarImageView(
                            name: related.name,
                            fallbackURL: related.thumbnailUrl,
                            artistID: related.browseId
                        )
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                        Text(related.name)
                            .lineLimit(1)
                            .font(.callout)
                    }
                    .frame(width: 120)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Shared shell for the artist page's horizontal carousels.
    @ViewBuilder
    private func carouselSection<Content: View>(
        title: String,
        spacing: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 16)
                .padding(.top, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    content()
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Actions

    private func playArtist(_ artist: ArtistDetailInfo) {
        PlaybackQueue.play(artist.songs, log: Log.artistDetail, context: "Artist playback")
    }

    private func shufflePlay(_ artist: ArtistDetailInfo) {
        PlaybackQueue.playShuffled(artist.songs, log: Log.artistDetail, context: "Shuffle playback")
    }

    private func playSong(_ song: SongItem) {
        guard let artist = viewModel.artist else { return }
        PlaybackQueue.play(song, in: artist.songs, log: Log.artistDetail, context: "Playback")
    }

    private func playVideo(_ video: SongItem) {
        guard let artist = viewModel.artist else { return }
        PlaybackQueue.play(video, in: artist.videos, log: Log.artistDetail, context: "Video playback")
    }

    /// The tile subtitle's first run is the generic "Playlist" type label —
    /// redundant under the Playlists header, so only show a real author.
    private func playlistSubtitle(_ author: String?) -> String? {
        guard let author, !author.isEmpty,
              author.localizedCaseInsensitiveCompare("playlist") != .orderedSame else { return nil }
        return author
    }

    private func toggleSubscribe(_ artist: ArtistDetailInfo) {
        guard !isUpdatingSubscription else { return }
        isUpdatingSubscription = true
        let desiredState = !artist.isSubscribed
        // Change only the flag; retain the resolved hero and its loading state.
        viewModel.artist?.isSubscribed = desiredState

        Task { @MainActor in
            defer { isUpdatingSubscription = false }
            var failureStage = "local storage"
            do {
                let previous = try await DatabaseService.shared.fetchOne(ArtistEntity.self, key: artist.browseId)
                var entity = previous ?? ArtistEntity(
                    id: artist.browseId, name: artist.name,
                    thumbnailUrl: artist.thumbnailUrl, bookmarkedAt: nil,
                    isPodcastChannel: false, channelId: artist.browseId
                )
                entity.bookmarkedAt = desiredState ? Date() : nil
                let channelId = artist.subscriptionChannelId ?? entity.channelId ?? artist.browseId
                entity.channelId = channelId
                do {
                    try await DatabaseService.shared.save(entity)
                    NotificationCenter.default.post(name: Notification.Name("apollo.libraryChanged"), object: nil)
                } catch {
                    if let previous {
                        try? await DatabaseService.shared.save(previous)
                    } else {
                        entity.bookmarkedAt = nil
                        try? await DatabaseService.shared.save(entity)
                    }
                    throw error
                }
                NotificationCenter.default.post(name: .personalizationDataUpdated, object: nil)
            } catch {
                Log.artistDetail.error("Artist favorite failed stage=\(failureStage) artistId=\(artist.browseId) target=\(desiredState) error=\(error)")
                if viewModel.artist?.browseId == artist.browseId {
                    viewModel.artist?.isSubscribed = artist.isSubscribed
                    subscriptionErrorMessage = failureStage == "local storage"
                        ? String(localized: "Couldn't save the favorite on this device. Your previous selection was restored.")
                        : Self.subscriptionFailureMessage(error)
                    showSubscriptionError = true
                }
            }
        }
    }

    private static func subscriptionFailureMessage(_ error: Error) -> String {
        if let apiError = error as? InnerTubeError {
            switch apiError {
            case .sessionExpired:
                return String(localized: "Your YouTube Music session has expired. Sign in again to update your subscription.")
            case .httpError(let code, _):
                if code == 401 || code == 403 {
                    return String(localized: "YouTube Music couldn't authorize this change. Sign in again and retry.")
                }
                return String.localizedStringWithFormat(
                    NSLocalizedString(
                        "YouTube Music rejected the change (HTTP %ld). Your previous selection was restored.",
                        comment: "Favorite update rejected"
                    ),
                    code
                )
            default: break
            }
        }
        if error is URLError {
            return String(localized: "Couldn't connect to YouTube Music. Check your connection and try again.")
        }
        return String(localized: "Couldn't save the change. Your previous selection was restored. Please try again.")
    }

}

/// Read dismiss inside the presented sheet, not from ArtistDetailView's
/// parent navigation/presentation environment.
private struct ArtistBiographyCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close biography")
    }
}
