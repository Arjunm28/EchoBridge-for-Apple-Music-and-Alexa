import SwiftUI
import MusicKit

enum MusicBrowserMode {
    case home
    case library
}

enum LibrarySegment: String, CaseIterable, Identifiable {
    case playlists = "Playlists"
    case albums = "Albums"
    case songs = "Songs"
    case stations = "Stations"

    var id: String { rawValue }
}

struct LibraryAndSearchView: View {
    @ObservedObject var musicManager = AppleMusicManager.shared
    @ObservedObject var alexaClient = AlexaAPIClient.shared
    @ObservedObject var authManager = AlexaAuthManager.shared
    @ObservedObject var coordinator = PlaybackCoordinator.shared

    var mode: MusicBrowserMode = .home
    var onOpenSpeakers: () -> Void
    var onOpenNowPlaying: (() -> Void)? = nil

    @State private var selectedLibrarySegment: LibrarySegment = .playlists
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
                VStack(alignment: .leading, spacing: 22) {
                    // Subtle Status or Error Banner (only when active)
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
                    } else if mode == .home {
                        homeSectionContent
                    } else {
                        librarySectionContent
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .navigationTitle(mode == .home ? "Home" : "Library")
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
                    Button {
                        showCustomPhraseAlert = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform.badge.mic")
                                .font(.subheadline)
                            Text("Ask Alexa")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.pink)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSpeakers) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(coordinator.selectedTarget.isAlexaTarget ? Color.green : Color.secondary)
                                .frame(width: 7, height: 7)
                            Image(systemName: coordinator.selectedTarget.iconName)
                                .font(.caption)
                            Text(coordinator.selectedTarget.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(coordinator.selectedTarget.isAlexaTarget ? Color.green.opacity(0.16) : Color(.secondarySystemBackground))
                        )
                        .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .primary)
                    }
                }
            }
            .alert("Ask Alexa on \(coordinator.selectedTarget.displayName)", isPresented: $showCustomPhraseAlert) {
                TextField("e.g. Anirudh Tamil songs, or 'stop'", text: $customPhraseText)
                Button("Play on Speaker") {
                    let text = customPhraseText
                    customPhraseText = ""
                    Task {
                        await coordinator.handleVoiceRequest(text)
                    }
                }
                if coordinator.isPlaying || coordinator.currentItem != nil {
                    Button("Stop All Speakers", role: .destructive) {
                        customPhraseText = ""
                        Task {
                            await coordinator.stopAllPlayback()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Type any song, movie, artist, or station to request directly on \(coordinator.selectedTarget.displayName).")
            }
            .sheet(item: $selectedCollectionItem) { collection in
                CollectionDetailSheet(collection: collection)
            }
        }
    }

    // MARK: - Home Tab Content (Clean, Uncluttered Discovery)

    private var homeSectionContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            if musicManager.authorizationStatus != .authorized {
                musicKitAuthCard
            }

            // 1. Quick Stations & Mixes Carousel
            VStack(alignment: .leading, spacing: 12) {
                Text("Stations & Artist Mixes")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(appleMusicStations, id: \.title) { station in
                            stationCard(station, width: 172)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // 2. Playlists Carousel
            playlistsCarouselSection

            // 3. Top Albums Carousel
            if !musicManager.featuredAlbums.isEmpty {
                albumsCarouselSection
            }

            // 4. Recent & Featured Songs
            songsSection
        }
    }

    // MARK: - Library Tab Content (Clean Segmented Browser)

    private var librarySectionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Library Section", selection: $selectedLibrarySegment) {
                ForEach(LibrarySegment.allCases) { segment in
                    Text(segment.rawValue).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            switch selectedLibrarySegment {
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

    // MARK: - Playlists Full Section

    private var playlistsFullSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if musicManager.authorizationStatus != .authorized {
                musicKitAuthCard
            } else if !musicManager.libraryPlaylists.isEmpty {
                HStack {
                    Text("Your Playlists")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Button {
                        Task { await musicManager.fetchUserLibrary() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, 16)

                LazyVStack(spacing: 2) {
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

            Text("Featured Playlists")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            LazyVStack(spacing: 2) {
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

    // MARK: - Albums Full Section

    private var albumsFullSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !musicManager.libraryAlbums.isEmpty {
                Text("Saved Albums")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)

                LazyVStack(spacing: 2) {
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

            LazyVStack(spacing: 2) {
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

    // MARK: - Songs Full Section

    private var songsFullSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(musicManager.librarySongs.isEmpty ? "Top Songs" : "Your Songs")
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

            LazyVStack(spacing: 2) {
                ForEach(musicManager.recentSongs) { song in
                    MediaItemRow(item: song, queue: musicManager.recentSongs)
                }
            }
        }
    }

    // MARK: - Stations Full Section

    private var stationsFullSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("One-Tap Radio Stations")
                .font(.title3.weight(.bold))
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
                subtitle: "Apple Music Station",
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
                        .font(.title3.weight(.semibold))
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
            .frame(maxWidth: width ?? .infinity, minHeight: 96, alignment: .leading)
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
                Text("Authorize to load your personal playlists & saved songs.")
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
                    ProgressView("Searching Apple Music...")
                    Spacer()
                }
                .padding(.vertical, 24)
            } else if musicManager.searchResults.isEmpty {
                Text("No results found for \"\(searchText)\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                LazyVStack(spacing: 2) {
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
            Text(musicManager.libraryPlaylists.isEmpty ? "Featured Playlists" : "Playlists")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(combinedPlaylists.prefix(12)) { playlist in
                        Button {
                            selectedCollectionItem = playlist
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkThumbnailView(url: playlist.artworkURL, size: 140)
                                Text(playlist.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(playlist.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 140)
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
            Text("Top Albums")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(musicManager.featuredAlbums.prefix(10)) { album in
                        Button {
                            selectedCollectionItem = album
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkThumbnailView(url: album.artworkURL, size: 140)
                                Text(album.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(album.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: 140)
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
                Text(musicManager.authorizationStatus == .authorized ? "Recent & Top Songs" : "Top Songs")
                    .font(.title3.weight(.bold))
                Spacer()
                if !musicManager.recentSongs.isEmpty {
                    Button {
                        if let first = musicManager.recentSongs.first {
                            Task { await coordinator.play(first, inQueue: musicManager.recentSongs) }
                        }
                    } label: {
                        Text("Play All")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.pink)
                    }
                }
            }
            .padding(.horizontal, 16)

            LazyVStack(spacing: 2) {
                ForEach(musicManager.recentSongs) { song in
                    MediaItemRow(item: song, queue: musicManager.recentSongs)
                }
            }
        }
    }
}

// MARK: - Clean Row for Playlists & Albums

struct CollectionItemRow: View {
    let item: PlayableMediaItem
    let onTapOpen: () -> Void
    let onTapPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTapOpen) {
                HStack(spacing: 12) {
                    ArtworkThumbnailView(url: item.artworkURL, size: 54)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onTapPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.pink.opacity(0.85))
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
                    VStack(spacing: 12) {
                        ArtworkThumbnailView(url: collection.artworkURL, size: 175)
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
                            .background(Color.pink)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 16)

                    Divider()

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
                        LazyVStack(spacing: 2) {
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

// MARK: - Clean Apple Music-Style Song Row (Tap Row to Play + Ellipsis Menu for Queue)

struct MediaItemRow: View {
    let item: PlayableMediaItem
    var queue: [PlayableMediaItem]? = nil
    @ObservedObject var coordinator = PlaybackCoordinator.shared

    var isCurrentItem: Bool {
        coordinator.currentItem?.id == item.id
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await coordinator.play(item, inQueue: queue)
                }
            } label: {
                HStack(spacing: 12) {
                    ArtworkThumbnailView(url: item.artworkURL, size: 50)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if isCurrentItem && coordinator.isPlaying {
                                Image(systemName: "waveform")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.pink)
                            }
                            Text(item.cleanTitle)
                                .font(.body.weight(isCurrentItem ? .semibold : .regular))
                                .foregroundStyle(isCurrentItem ? .pink : .primary)
                                .lineLimit(1)
                        }

                        if let movie = item.extractedMovieName {
                            Text("\(item.primaryArtist) • \(movie)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
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

            Menu {
                Button {
                    Task { await coordinator.play(item, inQueue: queue) }
                } label: {
                    Label("Play Now on \(coordinator.selectedTarget.displayName)", systemImage: "play.fill")
                }

                Button {
                    coordinator.playNext(item)
                } label: {
                    Label("Play Next", systemImage: "text.insert")
                }

                Button {
                    coordinator.addToQueue(item)
                } label: {
                    Label("Add to Queue", systemImage: "text.append")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }
}
