import SwiftUI
import MusicKit

enum BrowseSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case playlists = "Playlists"
    case albums = "Albums"
    case songs = "Songs"
    case stations = "Stations"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .home: return "house.fill"
        case .playlists: return "music.note.list"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note"
        case .stations: return "dot.radiowaves.left.and.right"
        }
    }
}

struct LibraryAndSearchView: View {
    @ObservedObject var musicManager = AppleMusicManager.shared
    @ObservedObject var alexaClient = AlexaAPIClient.shared
    @ObservedObject var authManager = AlexaAuthManager.shared
    @ObservedObject var coordinator = PlaybackCoordinator.shared

    var onOpenSpeakers: () -> Void
    var onOpenNowPlaying: (() -> Void)? = nil

    @State private var selectedSection: BrowseSection = .home
    @State private var searchText: String = ""
    @State private var selectedFilter: MediaKind = .song
    @State private var customPhraseText: String = ""
    @State private var showCustomPhraseAlert: Bool = false
    @State private var selectedCollectionItem: PlayableMediaItem?

    private let appleMusicStations: [(title: String, subtitle: String, phrase: String, icon: String, colors: [Color])] = [
        ("My Discovery Station", "Personalized Music Mix", "my station", "sparkles", [.pink, .purple]),
        ("Tamil & South Hits", "Latest Kollywood & Melody Hits", "Tamil hits songs", "music.quarternote.3", [.orange, .red]),
        ("Today's Hits Station", "Non-stop Pop & Top 40", "Today's Hits station", "flame.fill", [.pink, .orange]),
        ("Chill Radio", "Lo-Fi, Ambient & Acoustic", "Chill radio station", "leaf.fill", [.teal, .blue]),
        ("A.R. Rahman Essentials", "Timeless Tamil & Hindi Classics", "A R Rahman Tamil songs", "pianokeys", [.indigo, .purple]),
        ("Anirudh Ravichander", "High-Energy Tamil Blockbusters", "Anirudh Ravichander songs", "waveform", [.purple, .pink]),
        ("90s & 2000s Throwbacks", "Classic Pop, R&B & Rock", "2000s hits station", "guitars.fill", [.blue, .indigo]),
        ("Workout Energy", "High-Tempo Cardio & Gym Mix", "Workout music playlist", "figure.run", [.green, .teal])
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Quick Target Strip (Speaker Groups & Echo Speakers)
                    quickSpeakerStrip

                    // Category Navigation Pills (Home, Playlists, Albums, Songs, Stations)
                    sectionNavigationStrip

                    // Status or Error Banner if any
                    if let error = coordinator.errorMessage {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(error)
                                .font(.caption)
                            Spacer()
                            Button("Dismiss") {
                                coordinator.errorMessage = nil
                            }
                            .font(.caption.weight(.bold))
                        }
                        .padding(12)
                        .background(Color.red.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 16)
                    } else if let status = coordinator.statusBanner {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(status)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                    }

                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        searchResultsSection
                    } else {
                        switch selectedSection {
                        case .home:
                            homeSectionContent
                        case .playlists:
                            playlistsFullSection
                        case .albums:
                            albumsFullSection
                        case .songs:
                            songsFullSection
                        case .stations:
                            stationsFullSection
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 24)
            }
            .navigationTitle("Apple Music")
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search songs, Tamil hits, albums, playlists..."
            )
            .onChange(of: searchText) { _, newValue in
                Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard newValue == searchText else { return }
                    await musicManager.searchCatalog(query: newValue, filter: selectedFilter)
                }
            }
            .onChange(of: selectedFilter) { _, newFilter in
                if !searchText.isEmpty {
                    Task {
                        await musicManager.searchCatalog(query: searchText, filter: newFilter)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        Button {
                            showCustomPhraseAlert = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "waveform.badge.mic")
                                Text("Ask Alexa")
                                    .font(.caption.weight(.semibold))
                            }
                        }

                        if coordinator.isPlaying || coordinator.currentItem != nil {
                            Button {
                                Task {
                                    await coordinator.stopAllPlayback()
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "stop.fill")
                                    Text("Stop")
                                        .font(.caption.weight(.bold))
                                }
                                .foregroundStyle(.red)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSpeakers) {
                        HStack(spacing: 6) {
                            Image(systemName: coordinator.selectedTarget.iconName)
                            Text(coordinator.selectedTarget.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(coordinator.selectedTarget.isAlexaTarget ? Color.green.opacity(0.2) : Color(.secondarySystemBackground))
                        )
                        .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .primary)
                    }
                }
            }
            .alert("Ask Alexa on \(coordinator.selectedTarget.displayName)", isPresented: $showCustomPhraseAlert) {
                TextField("e.g. Anirudh Tamil songs, or 'stop'", text: $customPhraseText)
                Button("Send") {
                    let text = customPhraseText
                    customPhraseText = ""
                    Task {
                        await coordinator.handleVoiceRequest(text)
                    }
                }
                Button("Stop Speaker Now", role: .destructive) {
                    customPhraseText = ""
                    Task {
                        await coordinator.stopAllPlayback()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a song, artist, or playlist to play, or tap 'Stop Speaker Now' to stop all playback on \(coordinator.selectedTarget.displayName).")
            }
            .sheet(item: $selectedCollectionItem) { collection in
                CollectionDetailSheet(collection: collection)
            }
        }
    }

    // MARK: - Apple Music Category Navigation Strip

    private var sectionNavigationStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BrowseSection.allCases) { section in
                    let isSelected = (selectedSection == section)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedSection = section
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: section.iconName)
                                .font(.caption)
                            Text(section.rawValue)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(isSelected ? Color.pink : Color(.secondarySystemBackground))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Home Section

    private var homeSectionContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            // MusicKit Authorization Banner if not yet authorized
            if musicManager.authorizationStatus != .authorized {
                musicKitAuthCard
            }

            // Personal Playlists + Featured Apple Music Playlists
            playlistsCarouselSection

            // Quick Stations & Mixes Strip
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Stations & Artist Mixes")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Button("See All") {
                        selectedSection = .stations
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.pink)
                }
                .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(appleMusicStations.prefix(6), id: \.title) { station in
                            stationCard(station, width: 168)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // Top Albums Carousel
            if !musicManager.featuredAlbums.isEmpty {
                albumsCarouselSection
            }

            // Songs List
            songsSection
        }
    }

    // MARK: - Playlists Full Tab

    private var playlistsFullSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Library Playlists")
                        .font(.title3.weight(.bold))
                    Text("Tap a playlist to view & play individual songs, or tap Play to stream the playlist")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if musicManager.authorizationStatus == .authorized {
                    Button {
                        Task { await musicManager.fetchUserLibrary() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .padding(.horizontal, 16)

            if musicManager.authorizationStatus != .authorized {
                musicKitAuthCard
            } else if musicManager.libraryPlaylists.isEmpty {
                Text("No personal playlists found in your iPhone Music Library yet. Browse Curated Playlists below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(musicManager.libraryPlaylists) { playlist in
                        CollectionItemRow(
                            item: playlist,
                            onTapOpen: { selectedCollectionItem = playlist },
                            onTapPlay: {
                                Task { await coordinator.play(playlist) }
                            }
                        )
                    }
                }
            }

            Text("Apple Music Curated Playlists")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)
                .padding(.top, 6)

            LazyVStack(spacing: 6) {
                ForEach(musicManager.featuredPlaylists) { playlist in
                    CollectionItemRow(
                        item: playlist,
                        onTapOpen: { selectedCollectionItem = playlist },
                        onTapPlay: {
                            Task { await coordinator.play(playlist) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Albums Full Tab

    private var albumsFullSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !musicManager.libraryAlbums.isEmpty {
                Text("Your Saved Albums")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)

                LazyVStack(spacing: 6) {
                    ForEach(musicManager.libraryAlbums) { album in
                        CollectionItemRow(
                            item: album,
                            onTapOpen: { selectedCollectionItem = album },
                            onTapPlay: {
                                Task { await coordinator.play(album) }
                            }
                        )
                    }
                }
            }

            Text("Featured Albums")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            LazyVStack(spacing: 6) {
                ForEach(musicManager.featuredAlbums) { album in
                    CollectionItemRow(
                        item: album,
                        onTapOpen: { selectedCollectionItem = album },
                        onTapPlay: {
                            Task { await coordinator.play(album) }
                        }
                    )
                }
            }
        }
    }

    // MARK: - Songs Full Tab

    private var songsFullSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(musicManager.librarySongs.isEmpty ? "Top Songs" : "Your Library Songs")
                    .font(.title3.weight(.bold))
                Spacer()
                if !musicManager.recentSongs.isEmpty {
                    Button {
                        if let first = musicManager.recentSongs.first {
                            Task { await coordinator.play(first, inQueue: musicManager.recentSongs) }
                        }
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)

            LazyVStack(spacing: 4) {
                ForEach(musicManager.recentSongs) { song in
                    MediaItemRow(item: song, queue: musicManager.recentSongs)
                }
            }
        }
    }

    // MARK: - Stations Full Tab

    private var stationsFullSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stations & Artist Mixes")
                    .font(.title3.weight(.bold))
                Text("One-tap continuous mixes streamed directly on \(coordinator.selectedTarget.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(appleMusicStations, id: \.title) { station in
                    stationCard(station, width: nil)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func stationCard(
        _ station: (title: String, subtitle: String, phrase: String, icon: String, colors: [Color]),
        width: CGFloat?
    ) -> some View {
        Button {
            let stationItem = PlayableMediaItem(
                id: "station-\(station.title)",
                title: station.phrase,
                subtitle: "Apple Music Custom Request",
                albumTitle: station.title,
                artworkURL: nil,
                previewURL: nil,
                kind: .song,
                durationSeconds: nil
            )
            Task {
                await coordinator.play(stationItem)
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: station.icon)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer(minLength: 4)
                Text(station.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(station.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: width ?? .infinity, minHeight: 100, alignment: .leading)
            .background(
                LinearGradient(
                    colors: station.colors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick Horizontal Speaker & Group Strip

    private var quickSpeakerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                speakerChip(target: .localDevice, badge: nil)

                ForEach(alexaClient.speakerGroups) { group in
                    speakerChip(
                        target: .alexaDevice(group),
                        badge: "GROUP"
                    )
                }

                ForEach(alexaClient.individualSpeakers) { speaker in
                    speakerChip(
                        target: .alexaDevice(speaker),
                        badge: nil
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func speakerChip(target: PlaybackTarget, badge: String?) -> some View {
        let isSelected = (coordinator.selectedTarget == target)

        return Button {
            Task {
                await coordinator.selectTarget(target)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: target.iconName)
                    .font(.caption)
                Text(target.displayName)
                    .font(.caption.weight(.semibold))
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(isSelected ? Color.black.opacity(0.25) : Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.green : Color(.secondarySystemBackground))
            .foregroundStyle(isSelected ? .black : .primary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - MusicKit Authorization Prompt Card

    private var musicKitAuthCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "applelogo")
                .font(.title2)
                .foregroundStyle(.pink)
                .frame(width: 40, height: 40)
                .background(Color.pink.opacity(0.15))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Connect Apple Music Library")
                    .font(.subheadline.weight(.semibold))
                Text("Authorize MusicKit to load your personal playlists & saved songs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Authorize") {
                Task {
                    await musicManager.requestAuthorization()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: - Search Results Section

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Filter", selection: $selectedFilter) {
                Text("Songs").tag(MediaKind.song)
                Text("Albums").tag(MediaKind.album)
                Text("Playlists").tag(MediaKind.playlist)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            if musicManager.isSearching {
                HStack {
                    Spacer()
                    ProgressView("Searching...")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if musicManager.searchResults.isEmpty {
                Text("No results found for \"\(searchText)\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(musicManager.searchResults) { item in
                        if item.kind == .album || item.kind == .playlist {
                            CollectionItemRow(
                                item: item,
                                onTapOpen: { selectedCollectionItem = item },
                                onTapPlay: {
                                    Task { await coordinator.play(item) }
                                }
                            )
                        } else {
                            MediaItemRow(item: item, queue: musicManager.searchResults)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Playlists Carousel

    private var playlistsCarouselSection: some View {
        let combinedPlaylists = musicManager.libraryPlaylists + musicManager.featuredPlaylists
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(musicManager.libraryPlaylists.isEmpty ? "Featured Playlists" : "Your Playlists")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("See All") {
                    selectedSection = .playlists
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.pink)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(combinedPlaylists.prefix(12)) { playlist in
                        Button {
                            selectedCollectionItem = playlist
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ZStack(alignment: .bottomTrailing) {
                                    ArtworkThumbnailView(url: playlist.artworkURL, size: 136)
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .shadow(radius: 4)
                                        .padding(6)
                                }
                                Text(playlist.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(playlist.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 136)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Albums Carousel

    private var albumsCarouselSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Top Albums")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("See All") {
                    selectedSection = .albums
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.pink)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(musicManager.featuredAlbums.prefix(10)) { album in
                        Button {
                            selectedCollectionItem = album
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkThumbnailView(url: album.artworkURL, size: 136)
                                Text(album.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(album.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 136)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Songs List Section

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(musicManager.authorizationStatus == .authorized ? "Your Recent & Top Songs" : "Featured Songs")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("See All") {
                    selectedSection = .songs
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.pink)
            }
            .padding(.horizontal, 16)

            LazyVStack(spacing: 4) {
                ForEach(musicManager.recentSongs) { song in
                    MediaItemRow(item: song, queue: musicManager.recentSongs)
                }
            }
        }
    }
}

// MARK: - Row for Playlists & Albums (Tap to Open Tracks OR Play Directly)

struct CollectionItemRow: View {
    let item: PlayableMediaItem
    let onTapOpen: () -> Void
    let onTapPlay: () -> Void
    @ObservedObject var coordinator = PlaybackCoordinator.shared

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTapOpen) {
                HStack(spacing: 12) {
                    ArtworkThumbnailView(url: item.artworkURL, size: 56)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(item.kind.rawValue.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.pink.opacity(0.15))
                                .foregroundStyle(.pink)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onTapPlay) {
                Image(systemName: coordinator.selectedTarget.isAlexaTarget ? "play.circle.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .pink)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Playlist / Album Detail Sheet

struct CollectionDetailSheet: View {
    let collection: PlayableMediaItem
    @ObservedObject var musicManager = AppleMusicManager.shared
    @ObservedObject var coordinator = PlaybackCoordinator.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Header Artwork & Play Button
                    VStack(spacing: 12) {
                        ArtworkThumbnailView(url: collection.artworkURL, size: 180)
                            .shadow(color: .black.opacity(0.25), radius: 14, x: 0, y: 8)

                        Text(collection.title)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)

                        Text(collection.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button {
                            Task {
                                if let firstTrack = musicManager.activeCollectionTracks.first {
                                    await coordinator.play(firstTrack, inQueue: musicManager.activeCollectionTracks)
                                } else {
                                    await coordinator.play(collection)
                                }
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("Play on \(coordinator.selectedTarget.displayName)")
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(coordinator.selectedTarget.isAlexaTarget ? Color.green : Color.pink)
                            .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .black : .white)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 16)

                    Divider()

                    // Tracks inside this Playlist/Album
                    if musicManager.isLoadingCollectionTracks {
                        ProgressView("Loading tracks...")
                            .padding(.vertical, 32)
                    } else if musicManager.activeCollectionTracks.isEmpty {
                        Text("Tap Play above to stream this \(collection.kind.rawValue.lowercased()) directly on \(coordinator.selectedTarget.displayName).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(musicManager.activeCollectionTracks) { track in
                                MediaItemRow(item: track, queue: musicManager.activeCollectionTracks)
                            }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
            .navigationTitle(collection.kind.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await musicManager.fetchTracks(for: collection)
            }
        }
    }
}

struct MediaItemRow: View {
    let item: PlayableMediaItem
    var queue: [PlayableMediaItem]? = nil
    @ObservedObject var coordinator = PlaybackCoordinator.shared

    var isCurrentItem: Bool {
        coordinator.currentItem?.id == item.id
    }

    var body: some View {
        Button {
            Task {
                await coordinator.play(item, inQueue: queue)
            }
        } label: {
            HStack(spacing: 12) {
                ArtworkThumbnailView(url: item.artworkURL, size: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.cleanTitle)
                        .font(.body.weight(isCurrentItem ? .semibold : .regular))
                        .foregroundStyle(isCurrentItem ? .green : .primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let movie = item.extractedMovieName {
                            Text(movie.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.pink.opacity(0.16))
                                .foregroundStyle(.pink)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .lineLimit(1)
                        } else {
                            Text(item.kind.rawValue.uppercased())
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.18))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isCurrentItem && coordinator.isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: coordinator.selectedTarget.isAlexaTarget ? "play.circle.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
