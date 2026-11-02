import Foundation
import MusicKit

// MARK: - Unified Playable Media Model

enum MediaKind: String, Codable, CaseIterable {
    case song = "Song"
    case album = "Album"
    case playlist = "Playlist"
    case artist = "Artist"
}

struct PlayableMediaItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let albumTitle: String?
    var artworkURL: URL?
    var previewURL: URL?
    let kind: MediaKind
    let durationSeconds: TimeInterval?
    /// Native MusicKit Song if available for local playback
    var musicKitSong: Song?
    /// Native MusicKit Playlist if available
    var musicKitPlaylist: Playlist?
    /// Native MusicKit Album if available
    var musicKitAlbum: Album?

    /// Extracts the clean song title without movie tags like `(From "Scene")` or `[Original Motion Picture Soundtrack]`
    var cleanTitle: String {
        Self.stripMetadataTags(from: title)
    }

    /// Extracts the movie/soundtrack name if the title contains `(From "MovieName")`
    var extractedMovieName: String? {
        let pattern = #"(?i)\(\s*from\s+["']?([^"')]+)["']?\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else {
            return nil
        }
        let movie = String(title[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return movie.isEmpty ? nil : movie
    }

    /// Extracts only the primary artist (dropping secondary comma/ampersand/featuring credits that confuse Alexa)
    var primaryArtist: String {
        var s = subtitle
        if s == "Apple Music Custom Request" || s.contains("Personal Playlist") {
            return ""
        }
        // Split on comma, ampersand, feat., ft.
        let separators = [",", "&", " feat.", " Feat.", " ft.", " Ft.", " featuring ", "•"]
        for sep in separators {
            if let range = s.range(of: sep) {
                s = String(s[..<range.lowerBound])
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ordered candidate search phrases for Alexa (from most natural to broadest fallback)
    /// so Tamil, Indian, and Soundtrack songs resolve accurately on both Apple Music and Amazon Music.
    var alexaCandidatePhrases: [String] {
        switch kind {
        case .song:
            if subtitle == "Apple Music Custom Request" {
                return [title]
            }
            var candidates: [String] = []
            let clean = cleanTitle
            let movie = extractedMovieName
            let artist = primaryArtist

            // 1. If it's a movie soundtrack song (e.g., "Aeroplane (From \"Scene\")"),
            // "<CleanTitle> from <Movie>" is how Alexa & Amazon/Apple Music index Indian/Tamil movie songs!
            if let movie, !clean.isEmpty {
                candidates.append("\(clean) from \(movie)")
            }
            // 2. "<CleanTitle> by <PrimaryArtist>"
            if !clean.isEmpty && !artist.isEmpty {
                candidates.append("\(clean) by \(artist)")
            }
            // 3. "<CleanTitle> song"
            if !clean.isEmpty {
                candidates.append("\(clean) song")
                candidates.append(clean)
            }
            // 4. Original title fallback
            if !candidates.contains(title) {
                candidates.append(title)
            }
            return candidates

        case .album:
            let clean = Self.stripMetadataTags(from: title)
            let artist = primaryArtist
            if !artist.isEmpty {
                return ["album \(clean) by \(artist)", clean]
            }
            return ["album \(clean)", clean]

        case .playlist:
            let clean = Self.stripMetadataTags(from: title)
            return ["\(clean) playlist", clean]

        case .artist:
            return ["songs by \(title)", title]
        }
    }

    /// Primary search phrase for Alexa
    var alexaSearchPhrase: String {
        alexaCandidatePhrases.first ?? title
    }

    private static func stripMetadataTags(from text: String) -> String {
        var result = text
        // Remove parenthetical (...) and bracketed [...] soundtrack/version suffixes
        let patterns = [
            #"\s*\([^)]*\)"#,
            #"\s*\[[^\]]*\]"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }
        // Remove trailing "- Single", "- EP", "- From ..."
        if let dashRange = result.range(of: " - ") {
            result = String(result[..<dashRange.lowerBound])
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    static func == (lhs: PlayableMediaItem, rhs: PlayableMediaItem) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.artworkURL == rhs.artworkURL
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
        hasher.combine(artworkURL)
    }
}

// MARK: - MusicKit Conversions

extension PlayableMediaItem {
    init(from song: Song) {
        self.id = song.id.rawValue
        self.title = song.title
        self.subtitle = song.artistName
        self.albumTitle = song.albumTitle
        self.artworkURL = song.artwork?.url(width: 600, height: 600)
        self.previewURL = song.previewAssets?.first?.url
        self.kind = .song
        self.durationSeconds = song.duration
        self.musicKitSong = song
    }

    init(from album: Album) {
        self.id = album.id.rawValue
        self.title = album.title
        self.subtitle = album.artistName
        self.albumTitle = album.title
        self.artworkURL = album.artwork?.url(width: 600, height: 600)
        self.previewURL = nil
        self.kind = .album
        self.durationSeconds = nil
        self.musicKitAlbum = album
    }

    init(from playlist: Playlist) {
        self.id = playlist.id.rawValue
        self.title = playlist.name
        self.subtitle = playlist.curatorName ?? "Apple Music Playlist"
        self.albumTitle = nil
        self.artworkURL = playlist.artwork?.url(width: 600, height: 600)
        self.previewURL = nil
        self.kind = .playlist
        self.durationSeconds = nil
        self.musicKitPlaylist = playlist
    }
}

// MARK: - Public iTunes Catalog Fallback Models

struct ITunesSearchResponse: Codable {
    let resultCount: Int
    let results: [ITunesSearchResult]
}

struct ITunesSearchResult: Codable {
    let wrapperType: String?
    let kind: String?
    let trackId: Int?
    let collectionId: Int?
    let artistName: String?
    let collectionName: String?
    let trackName: String?
    let artworkUrl100: String?
    let previewUrl: String?
    let trackTimeMillis: Int?

    func toPlayableItem() -> PlayableMediaItem? {
        let highResArtwork = artworkUrl100?
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "http://", with: "https://")
        let artURL = highResArtwork.flatMap { URL(string: $0) }
        let prevURL = previewUrl
            .map { $0.replacingOccurrences(of: "http://", with: "https://") }
            .flatMap { URL(string: $0) }

        if wrapperType == "collection" {
            guard let id = collectionId, let name = collectionName else { return nil }
            return PlayableMediaItem(
                id: "itunes-album-\(id)",
                title: name,
                subtitle: artistName ?? "",
                albumTitle: name,
                artworkURL: artURL,
                previewURL: prevURL,
                kind: .album,
                durationSeconds: nil
            )
        } else {
            guard let id = trackId, let name = trackName else { return nil }
            let duration = trackTimeMillis.map { Double($0) / 1000.0 }
            return PlayableMediaItem(
                id: "itunes-song-\(id)",
                title: name,
                subtitle: artistName ?? "",
                albumTitle: collectionName,
                artworkURL: artURL,
                previewURL: prevURL,
                kind: .song,
                durationSeconds: duration
            )
        }
    }
}
