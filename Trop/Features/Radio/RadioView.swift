import SwiftUI

/// Internet radio (Radio Browser). Sits in the tab bar in place of Explore,
/// matching the Apple Music layout: Home · Radio · Library · Search.
struct RadioView: View {
    @Environment(\.settingsStore) private var settings

    @State private var stations: [RadioStation] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var query = ""
    @State private var selectedTag = "Top"

    private let tags = [
        "Top", "Pop", "Rock", "Jazz", "Classical", "Electronic",
        "Hip-Hop", "Chillout", "Latin", "News"
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    tagChips
                }

                if let errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button("Try again") { Task { await load() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                } else if isLoading && stations.isEmpty {
                    Section {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } else if stations.isEmpty {
                    Section {
                        Text("No stations found.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(stations) { station in
                            stationRow(station)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Radio")
            .searchable(text: $query, prompt: "Search stations")
            .miniPlayerTracksScroll()
        }
        .task(id: loadKey) {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
            }
            await load()
        }
    }

    private var loadKey: String {
        let term = query.trimmingCharacters(in: .whitespaces)
        return term.isEmpty ? "tag:\(selectedTag)" : "search:\(term)"
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    let isOn = selectedTag == tag && query.isEmpty
                    Button {
                        selectedTag = tag
                        query = ""
                    } label: {
                        Text(tag)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                isOn ? settings.accentColor.opacity(0.22) : Color(uiColor: .tertiarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(isOn ? settings.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .listRowSeparator(.hidden)
    }

    private func stationRow(_ station: RadioStation) -> some View {
        Button {
            play(station)
        } label: {
            HStack(spacing: 12) {
                AsyncImageView(url: station.iconURL)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(station.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(settings.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        let term = query.trimmingCharacters(in: .whitespaces)
        do {
            let loaded: [RadioStation]
            if !term.isEmpty {
                loaded = try await RadioBrowser.search(term)
            } else if selectedTag == "Top" {
                loaded = try await RadioBrowser.topStations()
            } else {
                loaded = try await RadioBrowser.stations(tag: selectedTag.lowercased())
            }
            stations = loaded
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func play(_ station: RadioStation) {
        guard let stream = station.streamURL else { return }
        Task { @MainActor in
            // Preserve the main-branch marker used to distinguish UI selection
            // from an engine reconnect, without logging signed stream URLs.
            Log.player.info("RADIO_UI selection stationId=\(station.stationuuid)")
            NowPlaying.shared.bumpPlaybackIntent()
            let generation = NowPlaying.shared.playbackGeneration
            // Apolo needs to know whether the station is HLS, ICY or an
            // exotic container; probing is only worth it on the Apolo beta.
            let hint: String?
            if SettingsStore.shared.apoloRadioBetaEnabled {
                hint = await RadioTransportResolver.shared.hint(for: station)
            } else {
                hint = station.apoloMIMEHint
            }
            // The user may have picked another station while we probed.
            guard generation == NowPlaying.shared.playbackGeneration else { return }
            await PlayerController.shared.play(
                url: stream,
                title: station.name,
                artist: station.subtitle.isEmpty ? nil : station.subtitle,
                videoId: NowPlaying.radioPrefix + station.stationuuid,
                duration: nil,
                thumbnailUrl: station.iconURL,
                sourceMIMEType: hint
            )
        }
    }
}
