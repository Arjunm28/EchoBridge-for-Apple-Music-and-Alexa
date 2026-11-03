import Foundation
import MusicKit
import MediaPlayer

@MainActor
final class AppleMusicManager: ObservableObject {
    static let shared = AppleMusicManager()

    @Published var authorizationStatus: MusicAuthorization.Status = .notDetermined
    @Published var libraryPlaylists: [PlayableMediaItem] = []
    @Published var libraryAlbums: [PlayableMediaItem] = []
    @Published var librarySongs: [PlayableMediaItem] = []
    @Published var featuredPlaylists: [PlayableMediaItem] = []
    @Published var featuredAlbums: [PlayableMediaItem] = []
    @Published var recentSongs: [PlayableMediaItem] = []
    @Published var searchResults: [PlayableMediaItem] = []
    @Published var activeCollectionTracks: [PlayableMediaItem] = []
    @Published var isLoadingCollectionTracks: Bool = false
    @Published var systemNowPlayingItem: PlayableMediaItem?
    @Published var isSearching: Bool = false
    @Published var isLoadingLibrary: Bool = false

    private static var artworkCache: [String: (artwork: URL?, preview: URL?)] = [:]

    private init() {
        self.authorizationStatus = MusicAuthorization.currentStatus
        Task {
            await loadInitialContent()
        }
    }

    // MARK: - Authorization & Library Loading

    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        self.authorizationStatus = status
        if status == .authorized {
            await fetchUserLibrary()
            await refreshSystemNowPlayingAsync()
        }
    }

    func loadInitialContent() async {
        // Always load Apple Music catalog playlists, albums, and top songs so Home & Playlists are rich immediately
        async let topSongsTask = searchITunesCatalog(query: "top hits 2026", kind: .song, limit: 25)
        async let topAlbumsTask = searchITunesCatalog(query: "apple music top albums", kind: .album, limit: 16)
        async let curatedPlaylistsTask = loadCuratedAppleMusicPlaylists()

        let (topSongs, topAlbums, curated) = await (topSongsTask, topAlbumsTask, curatedPlaylistsTask)
        self.featuredAlbums = topAlbums
        self.featuredPlaylists = curated
        if self.recentSongs.isEmpty {
            self.recentSongs = topSongs
        }

        if authorizationStatus == .authorized {
            await fetchUserLibrary()
            await refreshSystemNowPlayingAsync()
        }
    }

    private func loadCuratedAppleMusicPlaylists() async -> [PlayableMediaItem] {
        let queries = [
            ("Today's Hits", "Apple Music Hits"),
            ("Chill Mix", "Apple Music Chill"),
            ("New Music Daily", "Apple Music"),
            ("R&B Now", "Apple Music R&B"),
            ("A-List Pop", "Apple Music Pop"),
            ("Rap Life", "Apple Music Hip-Hop"),
            ("Classic Rock Essentials", "Apple Music Rock"),
            ("Acoustic Chill", "Apple Music Acoustic")
        ]

        var playlists: [PlayableMediaItem] = []
        for (title, curator) in queries {
            let matches = await searchITunesCatalog(query: title, kind: .song, limit: 1)
            let artURL = matches.first?.artworkURL
            playlists.append(
                PlayableMediaItem(
                    id: "curated-playlist-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                    title: title,
                    subtitle: curator,
                    albumTitle: title,
                    artworkURL: artURL,
                    previewURL: matches.first?.previewURL,
                    kind: .playlist,
                    durationSeconds: nil
                )
            )
        }
        return playlists
    }

    func fetchUserLibrary() async {
        guard authorizationStatus == .authorized else { return }
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }

        // 1. Fetch Playlists via MPMediaQuery + MusicLibraryRequest
        var loadedPlaylists: [PlayableMediaItem] = []
        if let collections = MPMediaQuery.playlists().collections {
            for collection in collections.prefix(30) {
                if let playlist = collection as? MPMediaPlaylist,
                   let name = playlist.name,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let repSong = playlist.representativeItem
                    let seedTitle = repSong?.title ?? name
                    let seedArtist = repSong?.artist ?? ""
                    loadedPlaylists.append(
                        PlayableMediaItem(
                            id: "mp-playlist-\(playlist.persistentID)",
                            title: name,
                            subtitle: "\(playlist.items.count) songs • Personal Playlist",
                            albumTitle: seedTitle.isEmpty ? nil : "\(seedTitle) \(seedArtist)",
                            artworkURL: nil,
                            previewURL: nil,
                            kind: .playlist,
                            durationSeconds: nil
                        )
                    )
                }
            }
        }

        if loadedPlaylists.isEmpty {
            do {
                var playlistRequest = MusicLibraryRequest<Playlist>()
                playlistRequest.limit = 25
                let playlistResponse = try await playlistRequest.response()
                loadedPlaylists = playlistResponse.items.map { PlayableMediaItem(from: $0) }
            } catch {}
        }
        self.libraryPlaylists = loadedPlaylists

        // 2. Fetch Library Albums
        var loadedAlbums: [PlayableMediaItem] = []
        if let albumCollections = MPMediaQuery.albums().collections {
            for collection in albumCollections.prefix(25) {
                if let rep = collection.representativeItem,
                   let albumTitle = rep.albumTitle,
                   !albumTitle.isEmpty {
                    let artist = rep.albumArtist ?? rep.artist ?? "Apple Music"
                    loadedAlbums.append(
                        PlayableMediaItem(
                            id: "mp-album-\(collection.persistentID)",
                            title: albumTitle,
                            subtitle: artist,
                            albumTitle: albumTitle,
                            artworkURL: nil,
                            previewURL: nil,
                            kind: .album,
                            durationSeconds: nil
                        )
                    )
                }
            }
        }
        self.libraryAlbums = loadedAlbums

        // 3. Fetch Library Songs
        var loadedSongs: [PlayableMediaItem] = []
        if let mpSongs = MPMediaQuery.songs().items, !mpSongs.isEmpty {
            for mpItem in mpSongs.prefix(35) {
                if let title = mpItem.title, !title.isEmpty {
                    let artist = mpItem.artist ?? ""
                    loadedSongs.append(
                        PlayableMediaItem(
                            id: "mp-song-\(mpItem.persistentID)",
                            title: title,
                            subtitle: artist,
                            albumTitle: mpItem.albumTitle,
                            artworkURL: nil,
                            previewURL: nil,
                            kind: .song,
                            durationSeconds: mpItem.playbackDuration
                        )
                    )
                }
            }
        } else {
            do {
                var songRequest = MusicLibraryRequest<Song>()
                songRequest.limit = 30
                let songResponse = try await songRequest.response()
                loadedSongs = songResponse.items.map { PlayableMediaItem(from: $0) }
            } catch {}
        }

        if !loadedSongs.isEmpty {
            self.librarySongs = loadedSongs
            self.recentSongs = loadedSongs
        }

        // Enrich library items with HTTPS artwork & preview URLs concurrently
        await enrichAllMissingArtwork()
    }

    // MARK: - Load Tracks Inside an Album or Playlist

    func fetchTracks(for collectionItem: PlayableMediaItem) async {
        isLoadingCollectionTracks = true
        activeCollectionTracks = []
        defer { isLoadingCollectionTracks = false }

        // Check if this is a local MPMediaPlaylist
        if collectionItem.id.hasPrefix("mp-playlist-"),
           let collections = MPMediaQuery.playlists().collections {
            let pidString = collectionItem.id.replacingOccurrences(of: "mp-playlist-", with: "")
            if let pid = UInt64(pidString),
               let match = collections.first(where: { $0.persistentID == pid }) as? MPMediaPlaylist {
                let items = match.items.prefix(40).compactMap { mpItem -> PlayableMediaItem? in
                    guard let title = mpItem.title, !title.isEmpty else { return nil }
                    return PlayableMediaItem(
                        id: "mp-song-\(mpItem.persistentID)",
                        title: title,
                        subtitle: mpItem.artist ?? "",
                        albumTitle: mpItem.albumTitle,
                        artworkURL: collectionItem.artworkURL,
                        previewURL: nil,
                        kind: .song,
                        durationSeconds: mpItem.playbackDuration
                    )
                }
                if !items.isEmpty {
                    self.activeCollectionTracks = items
                    await enrichCollectionTracksArtwork()
                    return
                }
            }
        }

        // Otherwise fetch matching songs for this Album or Playlist from iTunes/Apple Music catalog
        let searchQuery: String
        if collectionItem.kind == .album {
            searchQuery = "\(collectionItem.title) \(collectionItem.subtitle)"
        } else {
            searchQuery = collectionItem.title
        }
        let tracks = await searchITunesCatalog(query: searchQuery, kind: .song, limit: 25)
        self.activeCollectionTracks = tracks
    }

    private func enrichCollectionTracksArtwork() async {
        for index in activeCollectionTracks.indices {
            let item = activeCollectionTracks[index]
            if item.artworkURL == nil || item.previewURL == nil {
                if let match = await lookupITunesTrack(title: item.title, artist: item.subtitle) {
                    if index < activeCollectionTracks.count {
                        activeCollectionTracks[index].artworkURL = match.artworkURL
                        activeCollectionTracks[index].previewURL = match.previewURL
                    }
                }
            }
        }
    }

    /// Resolves high-res HTTPS artwork and audio preview URLs for library songs, playlists, and albums.
    private func enrichAllMissingArtwork() async {
        for index in recentSongs.indices {
            if recentSongs[index].artworkURL == nil || recentSongs[index].previewURL == nil {
                let item = recentSongs[index]
                if let match = await lookupITunesTrack(title: item.title, artist: item.subtitle) {
                    if index < recentSongs.count {
                        recentSongs[index].artworkURL = match.artworkURL
                        recentSongs[index].previewURL = match.previewURL
                    }
                    if index < librarySongs.count && librarySongs[index].id == item.id {
                        librarySongs[index].artworkURL = match.artworkURL
                        librarySongs[index].previewURL = match.previewURL
                    }
                }
            }
        }

        for index in libraryPlaylists.indices {
            if libraryPlaylists[index].artworkURL == nil {
                let item = libraryPlaylists[index]
                let query = item.albumTitle ?? item.title
                if let match = await lookupITunesTrack(title: query, artist: "") {
                    if index < libraryPlaylists.count {
                        libraryPlaylists[index].artworkURL = match.artworkURL
                        libraryPlaylists[index].previewURL = match.previewURL
                    }
                }
            }
        }

        for index in libraryAlbums.indices {
            if libraryAlbums[index].artworkURL == nil {
                let item = libraryAlbums[index]
                if let match = await lookupITunesTrack(title: item.title, artist: item.subtitle) {
                    if index < libraryAlbums.count {
                        libraryAlbums[index].artworkURL = match.artworkURL
                        libraryAlbums[index].previewURL = match.previewURL
                    }
                }
            }
        }
    }

    func lookupITunesTrack(title: String, artist: String) async -> PlayableMediaItem? {
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if let cached = Self.artworkCache[query.lowercased()] {
            return PlayableMediaItem(
                id: "cached-\(query)",
                title: title,
                subtitle: artist,
                albumTitle: nil,
                artworkURL: cached.artwork,
                previewURL: cached.preview,
                kind: .song,
                durationSeconds: nil
            )
        }
        let results = await searchITunesCatalog(query: query, kind: .song, limit: 3)
        if let first = results.first {
            Self.artworkCache[query.lowercased()] = (first.artworkURL, first.previewURL)
            return first
        }
        return nil
    }

    // MARK: - Detect Current Track in Native iOS Apple Music App

    func refreshSystemNowPlaying() {
        Task {
            await refreshSystemNowPlayingAsync()
        }
    }

    func refreshSystemNowPlayingAsync() async {
        let nowPlaying = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem
        if let item = nowPlaying, let title = item.title, !title.isEmpty {
            let artist = item.artist ?? ""
            let album = item.albumTitle
            var mediaItem = PlayableMediaItem(
                id: "system-\(item.persistentID)",
                title: title,
                subtitle: artist,
                albumTitle: album,
                artworkURL: nil,
                previewURL: nil,
                kind: .song,
                durationSeconds: item.playbackDuration
            )
            if let match = await lookupITunesTrack(title: title, artist: artist) {
                mediaItem.artworkURL = match.artworkURL
                mediaItem.previewURL = match.previewURL
            }
            self.systemNowPlayingItem = mediaItem
        } else {
            self.systemNowPlayingItem = nil
        }
    }

    // MARK: - Catalog Search (MusicKit + iTunes Search Fallback)

    func searchCatalog(query: String, filter: MediaKind) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        // Always use iTunes Search API first or merge with MusicKit so every result is guaranteed
        // to have a valid HTTPS 600x600 artworkURL and AAC previewURL.
        let iTunesItems = await searchITunesCatalog(query: trimmed, kind: filter, limit: 25)
        if !iTunesItems.isEmpty {
            self.searchResults = iTunesItems
            return
        }

        if authorizationStatus == .authorized {
            do {
                let types: [any MusicCatalogSearchable.Type]
                switch filter {
                case .song: types = [Song.self]
                case .album: types = [Album.self]
                case .playlist: types = [Playlist.self]
                case .artist: types = [Song.self]
                }

                var request = MusicCatalogSearchRequest(term: trimmed, types: types)
                request.limit = 25
                let response = try await request.response()

                switch filter {
                case .song, .artist:
                    self.searchResults = response.songs.map { PlayableMediaItem(from: $0) }
                case .album:
                    self.searchResults = response.albums.map { PlayableMediaItem(from: $0) }
                case .playlist:
                    self.searchResults = response.playlists.map { PlayableMediaItem(from: $0) }
                }
            } catch {}
        }
    }

    func searchITunesCatalog(query: String, kind: MediaKind, limit: Int = 25) async -> [PlayableMediaItem] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        let entity: String
        switch kind {
        case .song, .artist:
            entity = "song"
        case .album:
            entity = "album"
        case .playlist:
            entity = "album"
        }

        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]

        guard let url = components.url else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            return decoded.results.compactMap { result in
                var item = result.toPlayableItem()
                if kind == .playlist {
                    item = item.map {
                        PlayableMediaItem(
                            id: "itunes-playlist-\($0.id)",
                            title: $0.title,
                            subtitle: $0.subtitle,
                            albumTitle: $0.albumTitle,
                            artworkURL: $0.artworkURL,
                            previewURL: $0.previewURL,
                            kind: .playlist,
                            durationSeconds: nil
                        )
                    }
                }
                return item
            }
        } catch {
            return []
        }
    }

    // MARK: - Apple Music URL Resolver (music.apple.com/...)

    func resolveAppleMusicURL(_ rawURL: String) async -> PlayableMediaItem? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let host = url.host, host.contains("apple.com") else {
            return nil
        }

        // 1. Check for track query item ?i=123456789
        var targetID: String?
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            targetID = components.queryItems?.first(where: { $0.name == "i" })?.value
        }

        // 2. If no ?i=, check the last path component (e.g. /album/name/123456789)
        if targetID == nil {
            let lastComponent = url.lastPathComponent
            if CharacterSet.decimalDigits.isSuperset(of: CharacterSet(charactersIn: lastComponent)) {
                targetID = lastComponent
            }
        }

        guard let id = targetID else { return nil }

        // Lookup via iTunes lookup API
        guard let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(id)") else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: lookupURL)
            let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
            return decoded.results.first?.toPlayableItem()
        } catch {
            return nil
        }
    }

    // MARK: - Auto-Radio Recommendations ("Don't Stop the Music")

    func fetchRadioRecommendations(basedOn item: PlayableMediaItem) async -> [PlayableMediaItem] {
        var query = item.primaryArtist
        if query.isEmpty {
            query = item.cleanTitle
        }
        let results = await searchITunesCatalog(query: "\(query) hits", kind: .song, limit: 12)
        return results.filter { $0.id != item.id && $0.cleanTitle.lowercased() != item.cleanTitle.lowercased() }
    }
}
