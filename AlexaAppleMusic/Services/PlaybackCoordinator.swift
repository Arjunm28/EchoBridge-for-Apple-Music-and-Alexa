import Foundation
import MusicKit
import MediaPlayer
import AVFoundation
import UIKit
import Combine

@MainActor
final class PlaybackCoordinator: ObservableObject {
    static let shared = PlaybackCoordinator()

    @Published var selectedTarget: PlaybackTarget = .localDevice
    @Published var currentItem: PlayableMediaItem?
    @Published var requestedItem: PlayableMediaItem?
    @Published var liveSpeakerReport: AlexaLiveTrackReport?
    @Published var isSpeakerMismatch: Bool = false
    @Published var autoCorrectWrongSong: Bool = true

    /// Software Multi-Room Bridge: Echo / Sonos speakers that should ALWAYS play alongside the active group (e.g. Sonos Era 100 + Everywhere)
    @Published var linkedCompanionSerials: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(linkedCompanionSerials), forKey: Self.linkedCompanionsKey)
        }
    }
    /// Also play locally via iPhone / AirPlay 2 (for Sonos Era 100 via AirPlay 2) while casting to Alexa Echo speakers!
    @Published var bridgeAirPlayWithAlexa: Bool = false {
        didSet {
            UserDefaults.standard.set(bridgeAirPlayWithAlexa, forKey: Self.bridgeAirPlayKey)
        }
    }
    /// Sync Offset (in seconds) between Sonos / Companion speakers and the Echo Multi-Room Group.
    /// Positive values (e.g. +1.8s) trigger Sonos BEFORE the Echo group so Sonos has time to buffer and starts in sync!
    /// Negative values (e.g. -1.0s) delay Sonos (or AirPlay 2) if the Echo group takes longer to start.
    @Published var sonosSyncOffsetSeconds: Double = 1.8 {
        didSet {
            UserDefaults.standard.set(sonosSyncOffsetSeconds, forKey: Self.sonosSyncOffsetKey)
        }
    }

    @Published var activeQueue: [PlayableMediaItem] = []
    @Published var isPlaying: Bool = false
    @Published var isTransferring: Bool = false
    @Published var volumeLevel: Double = 50
    @Published var roomVolumes: [String: Double] = [:] // serialNumber -> 0...100
    @Published var isShuffleEnabled: Bool = false
    @Published var isAutoAdvanceEnabled: Bool = true
    @Published var providerPreference: AlexaMusicProviderPreference = .auto {
        didSet {
            UserDefaults.standard.set(providerPreference.rawValue, forKey: Self.providerPrefKey)
        }
    }
    @Published var elapsedSeconds: Double = 0
    @Published var sleepTimerMinutesRemaining: Int = 0
    @Published var statusBanner: String?
    @Published var errorMessage: String?

    private static let savedSpeakerSerialKey = "alexa_saved_target_serial"
    private static let providerPrefKey = "alexa_music_provider_pref"
    private static let customPhraseMapKey = "alexa_custom_phrase_map"
    private static let linkedCompanionsKey = "alexa_linked_companion_serials"
    private static let bridgeAirPlayKey = "alexa_bridge_airplay_enabled"
    private static let sonosSyncOffsetKey = "alexa_sonos_sync_offset_sec"

    private let alexaClient = AlexaAPIClient.shared
    private var pollingTask: Task<Void, Never>?
    private var progressTimerTask: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?
    private var avPlayer: AVPlayer?
    private var isUsingAVPlayer: Bool = false
    private var lastManualCommandTime: Date = .distantPast
    private var customPhraseMap: [String: String] = [:]
    private var sleepTimerSecondsLeft: Int = 0
    private var cachedArtworkURL: URL?
    private var cachedArtworkImage: UIImage?

    private init() {
        if let savedPref = UserDefaults.standard.string(forKey: Self.providerPrefKey),
           let pref = AlexaMusicProviderPreference(rawValue: savedPref) {
            self.providerPreference = pref
        }
        if let savedMap = UserDefaults.standard.dictionary(forKey: Self.customPhraseMapKey) as? [String: String] {
            self.customPhraseMap = savedMap
        }
        if let savedCompanions = UserDefaults.standard.stringArray(forKey: Self.linkedCompanionsKey) {
            self.linkedCompanionSerials = Set(savedCompanions)
        }
        self.bridgeAirPlayWithAlexa = UserDefaults.standard.bool(forKey: Self.bridgeAirPlayKey)
        if UserDefaults.standard.object(forKey: Self.sonosSyncOffsetKey) != nil {
            self.sonosSyncOffsetSeconds = UserDefaults.standard.double(forKey: Self.sonosSyncOffsetKey)
        } else {
            self.sonosSyncOffsetSeconds = 1.8
        }

        configureAudioSession()
        setupRemoteCommandCenter()
        startPollingAlexaState()
        startProgressAndAutoAdvanceTimer()
    }

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
    }

    // MARK: - iOS Lock Screen, Control Center & Dynamic Island Remote Controls

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if !self.isPlaying {
                    await self.togglePlayPause()
                }
            }
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                if self.isPlaying {
                    await self.togglePlayPause()
                }
            }
            return .success
        }

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.togglePlayPause()
            }
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.skipNext()
            }
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.skipPrevious()
            }
            return .success
        }
    }

    func updateLockScreenNowPlayingInfo() {
        guard let item = currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: selectedTarget.isAlexaTarget
                ? "\(item.subtitle) • \(selectedTarget.displayName)"
                : item.subtitle,
            MPMediaItemPropertyPlaybackDuration: item.durationSeconds ?? 210,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        if let album = item.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = album
        }

        if let image = cachedArtworkImage, cachedArtworkURL == item.artworkURL {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else if let url = item.artworkURL {
            Task {
                if let (data, _) = try? await URLSession.shared.data(from: url),
                   let image = UIImage(data: data) {
                    self.cachedArtworkURL = url
                    self.cachedArtworkImage = image
                    self.updateLockScreenNowPlayingInfo()
                }
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Sonos / Companion Speaker Multi-Room Linking & Sync

    func isCompanionLinked(_ device: AlexaDevice) -> Bool {
        linkedCompanionSerials.contains(device.serialNumber)
    }

    func toggleCompanionSpeaker(_ device: AlexaDevice) {
        if linkedCompanionSerials.contains(device.serialNumber) {
            linkedCompanionSerials.remove(device.serialNumber)
        } else {
            linkedCompanionSerials.insert(device.serialNumber)
        }
    }

    var activeCompanionDevices: [AlexaDevice] {
        alexaClient.individualSpeakers.filter { linkedCompanionSerials.contains($0.serialNumber) }
    }

    /// Re-triggers the current song using the updated `sonosSyncOffsetSeconds` head-start so Sonos and Everywhere lock in sync
    func resyncMultiRoomOutput() async {
        guard let item = requestedItem ?? currentItem else { return }
        await play(item, inQueue: activeQueue)
    }

    /// Nudges the local / AirPlay 2 player forward or backward by `deltaSeconds` (e.g. +0.25s or -0.25s) for instant sub-second beat matching
    func nudgeLocalAirPlayTiming(by deltaSeconds: Double) {
        let player = ApplicationMusicPlayer.shared
        let currentPlaybackTime = player.playbackTime
        if currentPlaybackTime > 0 {
            player.playbackTime = max(0, currentPlaybackTime + deltaSeconds)
        }
        if let av = avPlayer, let currentItem = av.currentItem {
            let currentSec = CMTimeGetSeconds(currentItem.currentTime())
            let targetSec = max(0, currentSec + deltaSeconds)
            av.seek(to: CMTime(seconds: targetSec, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: - Persistent Speaker Selection

    func restoreSavedSpeakerIfNeeded() {
        if UserDefaults.standard.object(forKey: Self.linkedCompanionsKey) == nil {
            let sonosSerials = alexaClient.individualSpeakers
                .filter { $0.isSonosOrThirdPartySpeaker }
                .map { $0.serialNumber }
            if !sonosSerials.isEmpty {
                self.linkedCompanionSerials = Set(sonosSerials)
            }
        }

        guard case .localDevice = selectedTarget else { return }
        let savedSerial = UserDefaults.standard.string(forKey: Self.savedSpeakerSerialKey)

        if let serial = savedSerial,
           let matched = alexaClient.allDevices.first(where: { $0.serialNumber == serial }) {
            self.selectedTarget = .alexaDevice(matched)
            return
        }

        if let everywhere = alexaClient.speakerGroups.first(where: { $0.accountName.localizedCaseInsensitiveContains("everywhere") }) ?? alexaClient.speakerGroups.first {
            self.selectedTarget = .alexaDevice(everywhere)
            UserDefaults.standard.set(everywhere.serialNumber, forKey: Self.savedSpeakerSerialKey)
        } else if let firstEcho = alexaClient.individualSpeakers.first {
            self.selectedTarget = .alexaDevice(firstEcho)
            UserDefaults.standard.set(firstEcho.serialNumber, forKey: Self.savedSpeakerSerialKey)
        }
    }

    // MARK: - Per-Song Custom Alexa Search Phrase Override

    func customPhrase(for item: PlayableMediaItem) -> String? {
        customPhraseMap[item.id]
    }

    func setCustomPhrase(_ phrase: String, for item: PlayableMediaItem) async {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            customPhraseMap.removeValue(forKey: item.id)
        } else {
            customPhraseMap[item.id] = trimmed
        }
        UserDefaults.standard.set(customPhraseMap, forKey: Self.customPhraseMapKey)
        await play(item, inQueue: activeQueue)
    }

    // MARK: - Handle Voice / Text Request

    func handleVoiceRequest(_ rawText: String) async {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()

        let stopPhrases = ["stop", "stop playing", "stop music", "pause", "pause music", "shut up", "quiet", "off"]
        if stopPhrases.contains(lower) || lower.hasPrefix("stop ") || lower.hasPrefix("pause ") {
            await stopAllPlayback()
            return
        }

        if lower == "next" || lower == "next song" || lower == "skip" {
            await skipNext()
            return
        }

        if lower == "previous" || lower == "previous song" || lower == "back" {
            await skipPrevious()
            return
        }

        if lower == "resume" || lower == "play" || lower == "continue" {
            if !isPlaying {
                await togglePlayPause()
            }
            return
        }

        var cleanQuery = trimmed
        if cleanQuery.lowercased().hasPrefix("play ") {
            cleanQuery = String(cleanQuery.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let customItem = PlayableMediaItem(
            id: "custom-\(UUID().uuidString)",
            title: cleanQuery,
            subtitle: "Apple Music Custom Request",
            albumTitle: nil,
            artworkURL: nil,
            previewURL: nil,
            kind: .song,
            durationSeconds: 210
        )
        await play(customItem)
    }

    /// Immediately stops all playback on iPhone, active Alexa speaker/group, and all linked Sonos/companion speakers
    func stopAllPlayback() async {
        verificationTask?.cancel()
        lastManualCommandTime = Date()
        stopLocalPlayback()
        isPlaying = false
        elapsedSeconds = 0
        isSpeakerMismatch = false

        if case .alexaDevice(let device) = selectedTarget {
            statusBanner = "Stopping \(device.accountName)..."
            let companions = activeCompanionDevices.filter { $0.serialNumber != device.serialNumber }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    try? await self.alexaClient.sendTransportCommand(.pause, to: device)
                }
                for companion in companions {
                    group.addTask {
                        try? await self.alexaClient.sendTransportCommand(.pause, to: companion)
                    }
                }
            }
            statusBanner = "Stopped \(device.accountName)"
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.statusBanner == "Stopped \(device.accountName)" {
                    self.statusBanner = nil
                }
            }
        } else {
            statusBanner = nil
        }

        if let current = currentItem,
           current.title.lowercased().contains("stop") || current.subtitle == "Apple Music Custom Request" {
            currentItem = nil
        }
    }

    // MARK: - Play Media Item on Active Target (+ Synchronized Sonos Lead-Time Compensation)

    func play(_ item: PlayableMediaItem, inQueue queue: [PlayableMediaItem]? = nil) async {
        verificationTask?.cancel()
        lastManualCommandTime = Date()
        elapsedSeconds = 0
        isSpeakerMismatch = false

        let lowerTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["stop", "stop playing", "stop music", "pause", "pause music"].contains(lowerTitle) {
            await stopAllPlayback()
            return
        }

        restoreSavedSpeakerIfNeeded()

        if let queue, !queue.isEmpty {
            self.activeQueue = queue
        } else if activeQueue.isEmpty {
            let manager = AppleMusicManager.shared
            if !manager.searchResults.isEmpty && manager.searchResults.contains(where: { $0.id == item.id }) {
                self.activeQueue = manager.searchResults
            } else if !manager.activeCollectionTracks.isEmpty && manager.activeCollectionTracks.contains(where: { $0.id == item.id }) {
                self.activeQueue = manager.activeCollectionTracks
            } else {
                self.activeQueue = manager.recentSongs
            }
        }

        var resolvedItem = item
        if resolvedItem.artworkURL == nil || resolvedItem.previewURL == nil {
            if let match = await AppleMusicManager.shared.lookupITunesTrack(
                title: item.cleanTitle,
                artist: item.primaryArtist
            ) {
                if resolvedItem.artworkURL == nil {
                    resolvedItem.artworkURL = match.artworkURL
                }
                if resolvedItem.previewURL == nil {
                    resolvedItem.previewURL = match.previewURL
                }
            }
        }

        self.requestedItem = resolvedItem
        self.currentItem = resolvedItem
        self.errorMessage = nil

        switch selectedTarget {
        case .localDevice:
            await playLocally(resolvedItem)
        case .alexaDevice(let device):
            if !bridgeAirPlayWithAlexa {
                stopLocalPlayback()
            }
            await playOnAlexaSynchronized(resolvedItem, device: device)
        }
        updateLockScreenNowPlayingInfo()
    }

    func playWithPhrase(_ phrase: String, for item: PlayableMediaItem, provider: AlexaMusicProviderPreference? = nil) async {
        if let provider {
            self.providerPreference = provider
        }
        await setCustomPhrase(phrase, for: item)
    }

    // MARK: - Spotify Connect-Style Target Switching / Handoff

    func selectTarget(_ newTarget: PlaybackTarget) async {
        let previousTarget = selectedTarget
        guard previousTarget != newTarget else { return }

        lastManualCommandTime = Date()

        if newTarget.isAlexaTarget && !bridgeAirPlayWithAlexa {
            stopLocalPlayback()
        }

        self.selectedTarget = newTarget

        switch newTarget {
        case .alexaDevice(let device):
            UserDefaults.standard.set(device.serialNumber, forKey: Self.savedSpeakerSerialKey)
        case .localDevice:
            UserDefaults.standard.set("LOCAL_IPHONE", forKey: Self.savedSpeakerSerialKey)
        }

        if let activeItem = currentItem, isPlaying {
            // Pre-flight WHA Idle Release (inspired by alexa_media_player):
            // If switching from an individual Echo speaker to a Multi-Room group (or vice versa), pause the previous target first so it releases its stream lock.
            if case .alexaDevice(let oldAlexa) = previousTarget {
                try? await alexaClient.sendTransportCommand(.pause, to: oldAlexa)
                if newTarget.isAlexaTarget {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }

            switch newTarget {
            case .alexaDevice(let device):
                await playOnAlexaSynchronized(activeItem, device: device)
            case .localDevice:
                await playLocally(activeItem)
            }
        } else if case .alexaDevice(let device) = newTarget {
            await refreshAlexaNowPlaying(for: device, force: true)
        }
        updateLockScreenNowPlayingInfo()
    }

    // MARK: - Synchronized Alexa + Sonos Multi-Room Playback (With Configurable Head-Start Offset)

    private func playOnAlexaSynchronized(_ item: PlayableMediaItem, device: AlexaDevice) async {
        isTransferring = true
        let customOverride = customPhrase(for: item)
        let displayPhrase = customOverride ?? item.cleanTitle
        let companions = activeCompanionDevices.filter {
            $0.serialNumber != device.serialNumber && !device.clusterMembers.contains($0.serialNumber)
        }
        let offset = sonosSyncOffsetSeconds

        if companions.isEmpty && !bridgeAirPlayWithAlexa {
            statusBanner = "Starting \"\(displayPhrase)\" on \(device.accountName)..."
        } else {
            let formattedOffset = String(format: "%+.1fs", offset)
            statusBanner = "Syncing Sonos (\(formattedOffset) head-start) + \(device.accountName)..."
        }
        defer { isTransferring = false }

        do {
            // Case 1: Linked Sonos / Companion Alexa Speakers exist AND offset > 0 (Sonos is delayed, so give Sonos a head-start!)
            if !companions.isEmpty && offset > 0 {
                // 1. Fire all Sonos / Companion speakers FIRST in parallel
                for companion in companions {
                    Task {
                        try? await self.alexaClient.playMediaItem(
                            item,
                            customPhraseOverride: customOverride,
                            providerPreference: self.providerPreference,
                            on: companion
                        )
                    }
                }

                // 2. Wait the exact Sonos head-start offset (e.g. 1.8s) while Sonos buffers from Sonos Cloud
                let sleepNanos = UInt64(offset * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanos)

                // 3. Now fire the Echo Multi-Room Group (`Everywhere`) so both start audio together!
                try await alexaClient.playMediaItem(
                    item,
                    customPhraseOverride: customOverride,
                    providerPreference: providerPreference,
                    on: device
                )
            }
            // Case 2: Offset < 0 (Echo group is slower than Sonos or AirPlay 2, so start Echo group first, then Sonos/AirPlay)
            else if (!companions.isEmpty || bridgeAirPlayWithAlexa) && offset < 0 {
                let waitSeconds = abs(offset)

                // 1. Fire the Echo Multi-Room Group (`Everywhere`) FIRST
                try await alexaClient.playMediaItem(
                    item,
                    customPhraseOverride: customOverride,
                    providerPreference: providerPreference,
                    on: device
                )

                // 2. Wait for the Echo group to buffer
                let sleepNanos = UInt64(waitSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: sleepNanos)

                // 3. Fire Sonos companions and/or AirPlay 2
                for companion in companions {
                    Task {
                        try? await self.alexaClient.playMediaItem(
                            item,
                            customPhraseOverride: customOverride,
                            providerPreference: self.providerPreference,
                            on: companion
                        )
                    }
                }
                if bridgeAirPlayWithAlexa {
                    await playLocally(item)
                }
            }
            // Case 3: Offset == 0 or no companions
            else {
                await withTaskGroup(of: Void.self) { group in
                    for companion in companions {
                        group.addTask {
                            try? await self.alexaClient.playMediaItem(
                                item,
                                customPhraseOverride: customOverride,
                                providerPreference: self.providerPreference,
                                on: companion
                            )
                        }
                    }
                    group.addTask {
                        try? await self.alexaClient.playMediaItem(
                            item,
                            customPhraseOverride: customOverride,
                            providerPreference: self.providerPreference,
                            on: device
                        )
                    }
                }
            }

            // If AirPlay 2 Dual-Play is enabled and offset >= 0:
            // Note: AirPlay 2 starts faster locally (~0.5s) than Alexa Cloud (~2.0s), so if offset > 0 and no Alexa companions, delay AirPlay slightly
            if bridgeAirPlayWithAlexa && offset >= 0 {
                await playLocally(item)
            }

            self.isPlaying = true
            self.elapsedSeconds = 0
            self.lastManualCommandTime = Date()
            self.statusBanner = "Verifying playback on \(device.accountName)..."

            schedulePostPlayVerification(for: item, on: device)
        } catch {
            self.errorMessage = "Failed to start playback on \(device.accountName): \(error.localizedDescription)"
            self.statusBanner = nil
        }
    }

    private func schedulePostPlayVerification(for expectedItem: PlayableMediaItem, on device: AlexaDevice) {
        verificationTask?.cancel()
        verificationTask = Task {
            try? await Task.sleep(nanoseconds: 3_800_000_000)
            guard !Task.isCancelled else { return }

            await refreshAlexaNowPlaying(for: device, force: true)
            guard !Task.isCancelled else { return }

            if let report = liveSpeakerReport, !report.title.isEmpty {
                let matches = doesSpeakerTrackMatch(speakerTitle: report.title, speakerArtist: report.artist, expected: expectedItem)
                self.isSpeakerMismatch = !matches

                if matches {
                    self.statusBanner = "Verified: \"\(report.title)\" on \(report.reportingSpeakerName)"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if self.statusBanner?.hasPrefix("Verified:") == true {
                        self.statusBanner = nil
                    }
                } else if autoCorrectWrongSong && customPhrase(for: expectedItem) == nil {
                    let candidates = expectedItem.alexaCandidatePhrases
                    if candidates.count > 1 {
                        let alternate = candidates[1]
                        self.statusBanner = "Speaker played \"\(report.title)\" — retrying \"\(alternate)\"..."
                        try? await alexaClient.playAppleMusic(
                            searchPhrase: alternate,
                            fallbackPhrases: Array(candidates.dropFirst(2)),
                            providerPreference: .amazonMusic,
                            on: device
                        )
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        await refreshAlexaNowPlaying(for: device, force: true)
                    }
                } else {
                    self.statusBanner = "Speaker is playing: \"\(report.title)\""
                }
            } else {
                self.statusBanner = nil
            }
        }
    }

    func doesSpeakerTrackMatch(speakerTitle: String, speakerArtist: String, expected: PlayableMediaItem) -> Bool {
        if expected.subtitle == "Apple Music Custom Request" || expected.kind != .song {
            return true
        }

        let normSpeaker = normalizeForComparison(speakerTitle)
        let normExpected = normalizeForComparison(expected.cleanTitle)

        guard !normSpeaker.isEmpty, !normExpected.isEmpty else { return true }

        if normSpeaker.contains(normExpected) || normExpected.contains(normSpeaker) {
            return true
        }

        let speakerWords = Set(normSpeaker.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        let expectedWords = Set(normExpected.split(separator: " ").map(String.init).filter { $0.count >= 3 })

        if !speakerWords.isEmpty && !expectedWords.isEmpty {
            let intersection = speakerWords.intersection(expectedWords)
            if !intersection.isEmpty {
                return true
            }
        }

        if let movie = expected.extractedMovieName {
            let normMovie = normalizeForComparison(movie)
            if !normMovie.isEmpty && (normSpeaker.contains(normMovie) || normalizeForComparison(speakerArtist).contains(normMovie)) {
                return true
            }
        }

        return false
    }

    private func normalizeForComparison(_ text: String) -> String {
        let lower = text.lowercased()
        let allowed = lower.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : Character(" ") }
        return String(allowed)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Local iPhone / AirPlay 2 / Bluetooth Playback

    private func stopLocalPlayback() {
        ApplicationMusicPlayer.shared.pause()
        MPMusicPlayerController.applicationMusicPlayer.pause()
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
    }

    private func playLocally(_ item: PlayableMediaItem) async {
        configureAudioSession()
        isUsingAVPlayer = false

        if let song = item.musicKitSong {
            do {
                ApplicationMusicPlayer.shared.queue = [song]
                try await ApplicationMusicPlayer.shared.play()
                self.isPlaying = true
                return
            } catch {}
        } else if let playlist = item.musicKitPlaylist {
            do {
                ApplicationMusicPlayer.shared.queue = [playlist]
                try await ApplicationMusicPlayer.shared.play()
                self.isPlaying = true
                return
            } catch {}
        } else if let album = item.musicKitAlbum {
            do {
                ApplicationMusicPlayer.shared.queue = [album]
                try await ApplicationMusicPlayer.shared.play()
                self.isPlaying = true
                return
            } catch {}
        }

        var streamURL = item.previewURL
        if streamURL == nil {
            if let match = await AppleMusicManager.shared.lookupITunesTrack(title: item.cleanTitle, artist: item.primaryArtist) {
                streamURL = match.previewURL
                if self.currentItem?.artworkURL == nil, let art = match.artworkURL {
                    self.currentItem?.artworkURL = art
                }
            }
        }

        if let url = streamURL {
            isUsingAVPlayer = true
            let playerItem = AVPlayerItem(url: url)
            if let existingPlayer = avPlayer {
                existingPlayer.replaceCurrentItem(with: playerItem)
                existingPlayer.play()
            } else {
                let newPlayer = AVPlayer(playerItem: playerItem)
                self.avPlayer = newPlayer
                newPlayer.play()
            }
            self.avPlayer?.volume = Float(volumeLevel / 100.0)
            self.isPlaying = true
            return
        }

        self.isPlaying = true
    }

    // MARK: - Transport & Per-Room Volume Controls

    func togglePlayPause() async {
        lastManualCommandTime = Date()
        switch selectedTarget {
        case .localDevice:
            if isPlaying {
                stopLocalPlayback()
                isPlaying = false
            } else if let current = currentItem {
                await playLocally(current)
            }
        case .alexaDevice(let device):
            let nextState = !isPlaying
            isPlaying = nextState
            if !nextState && bridgeAirPlayWithAlexa {
                stopLocalPlayback()
            } else if nextState && bridgeAirPlayWithAlexa, let current = currentItem {
                Task { await playLocally(current) }
            }
            statusBanner = nextState ? "Resuming \(device.accountName)..." : "Stopping \(device.accountName)..."
            let companions = activeCompanionDevices.filter { $0.serialNumber != device.serialNumber }
            await withTaskGroup(of: Void.self) { group in
                for companion in companions {
                    group.addTask {
                        try? await self.alexaClient.sendTransportCommand(nextState ? .play : .pause, to: companion)
                    }
                }
                group.addTask {
                    try? await self.alexaClient.sendTransportCommand(nextState ? .play : .pause, to: device)
                }
            }
            statusBanner = nextState ? "Playing on \(device.accountName)" : "Paused \(device.accountName)"
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if self.statusBanner?.contains(device.accountName) == true {
                    self.statusBanner = nil
                }
            }
        }
    }

    func skipNext() async {
        lastManualCommandTime = Date()
        let queue = currentQueueList()

        if let current = requestedItem ?? currentItem,
           let idx = queue.firstIndex(where: { $0.id == current.id }),
           queue.count > 1 {
            let nextIndex: Int
            if isShuffleEnabled {
                nextIndex = Int.random(in: 0..<queue.count)
            } else {
                nextIndex = (idx + 1) % queue.count
            }
            let nextItem = queue[nextIndex]
            await play(nextItem, inQueue: queue)
            return
        }

        if case .alexaDevice(let device) = selectedTarget {
            isTransferring = true
            statusBanner = "Skipping to next track on \(device.accountName)..."
            defer { isTransferring = false }
            for companion in activeCompanionDevices where companion.serialNumber != device.serialNumber {
                Task { try? await self.alexaClient.sendTransportCommand(.next, to: companion) }
            }
            try? await alexaClient.sendTransportCommand(.next, to: device)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await refreshAlexaNowPlaying(for: device, force: true)
            statusBanner = nil
        } else if let first = queue.first {
            await play(first, inQueue: queue)
        }
    }

    func skipPrevious() async {
        lastManualCommandTime = Date()
        let queue = currentQueueList()

        if let current = requestedItem ?? currentItem,
           let idx = queue.firstIndex(where: { $0.id == current.id }),
           queue.count > 1 {
            let prevIndex = (idx - 1 + queue.count) % queue.count
            let prevItem = queue[prevIndex]
            await play(prevItem, inQueue: queue)
            return
        }

        if case .alexaDevice(let device) = selectedTarget {
            isTransferring = true
            statusBanner = "Returning to previous track on \(device.accountName)..."
            defer { isTransferring = false }
            for companion in activeCompanionDevices where companion.serialNumber != device.serialNumber {
                Task { try? await self.alexaClient.sendTransportCommand(.previous, to: companion) }
            }
            try? await alexaClient.sendTransportCommand(.previous, to: device)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await refreshAlexaNowPlaying(for: device, force: true)
            statusBanner = nil
        } else if let first = queue.first {
            await play(first, inQueue: queue)
        }
    }

    func upNextItems() -> [PlayableMediaItem] {
        let queue = currentQueueList()
        guard let current = requestedItem ?? currentItem,
              let idx = queue.firstIndex(where: { $0.id == current.id }) else {
            return Array(queue.prefix(20))
        }
        let after = Array(queue.dropFirst(idx + 1))
        let before = Array(queue.prefix(idx))
        return Array((after + before).prefix(25))
    }

    func currentQueueList() -> [PlayableMediaItem] {
        let manager = AppleMusicManager.shared
        if let current = requestedItem ?? currentItem {
            if !activeQueue.isEmpty && activeQueue.contains(where: { $0.id == current.id }) {
                return activeQueue
            }
            if !manager.searchResults.isEmpty && manager.searchResults.contains(where: { $0.id == current.id }) {
                return manager.searchResults
            }
            if !manager.activeCollectionTracks.isEmpty && manager.activeCollectionTracks.contains(where: { $0.id == current.id }) {
                return manager.activeCollectionTracks
            }
            if !manager.recentSongs.isEmpty && manager.recentSongs.contains(where: { $0.id == current.id }) {
                return manager.recentSongs
            }
        }
        return activeQueue.isEmpty ? manager.recentSongs : activeQueue
    }

    func setVolume(_ newVolume: Double) async {
        lastManualCommandTime = Date()
        let clamped = max(0, min(100, newVolume))
        self.volumeLevel = clamped
        switch selectedTarget {
        case .localDevice:
            avPlayer?.volume = Float(clamped / 100.0)
        case .alexaDevice(let device):
            try? await alexaClient.sendTransportCommand(.volume(Int(clamped)), to: device)
        }
    }

    func stepVolume(by delta: Double) async {
        await setVolume(volumeLevel + delta)
    }

    func setRoomVolume(_ newVolume: Double, for speaker: AlexaDevice) async {
        let clamped = max(0, min(100, newVolume))
        roomVolumes[speaker.serialNumber] = clamped
        await alexaClient.setDeviceVolume(Int(clamped), for: speaker)
    }

    func toggleShuffle() async {
        lastManualCommandTime = Date()
        self.isShuffleEnabled.toggle()
        if case .alexaDevice(let device) = selectedTarget {
            try? await alexaClient.sendTransportCommand(.shuffle(isShuffleEnabled), to: device)
        }
    }

    // MARK: - Music Assistant-Style First-Class Queue Mutations & Sleep Timer

    func playNext(_ item: PlayableMediaItem) {
        var queue = currentQueueList()
        queue.removeAll(where: { $0.id == item.id })
        if let current = requestedItem ?? currentItem,
           let idx = queue.firstIndex(where: { $0.id == current.id }) {
            queue.insert(item, at: min(queue.count, idx + 1))
        } else {
            queue.insert(item, at: 0)
        }
        self.activeQueue = queue
        self.statusBanner = "Playing next: \"\(item.cleanTitle)\""
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.statusBanner == "Playing next: \"\(item.cleanTitle)\"" {
                self.statusBanner = nil
            }
        }
    }

    func addToQueue(_ item: PlayableMediaItem) {
        var queue = currentQueueList()
        if !queue.contains(where: { $0.id == item.id }) {
            queue.append(item)
        }
        self.activeQueue = queue
        self.statusBanner = "Added \"\(item.cleanTitle)\" to queue"
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.statusBanner == "Added \"\(item.cleanTitle)\" to queue" {
                self.statusBanner = nil
            }
        }
    }

    func setSleepTimer(minutes: Int) {
        if minutes <= 0 {
            sleepTimerSecondsLeft = 0
            sleepTimerMinutesRemaining = 0
            statusBanner = "Sleep timer turned off"
        } else {
            sleepTimerSecondsLeft = minutes * 60
            sleepTimerMinutesRemaining = minutes
            statusBanner = "Sleep timer set for \(minutes) min"
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.statusBanner?.hasPrefix("Sleep timer") == true {
                self.statusBanner = nil
            }
        }
    }

    // MARK: - Auto-Advance Queue Engine & Progress Timer

    private func startProgressAndAutoAdvanceTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                // Universal Group Sleep Timer Countdown
                if sleepTimerSecondsLeft > 0 {
                    sleepTimerSecondsLeft -= 1
                    sleepTimerMinutesRemaining = Int(ceil(Double(sleepTimerSecondsLeft) / 60.0))
                    if sleepTimerSecondsLeft <= 0 {
                        sleepTimerMinutesRemaining = 0
                        await stopAllPlayback()
                        statusBanner = "Sleep timer ended playback"
                        continue
                    }
                }

                guard isPlaying, !isTransferring, let item = currentItem else { continue }
                elapsedSeconds += 1
                if Int(elapsedSeconds) % 5 == 0 {
                    updateLockScreenNowPlayingInfo()
                }

                let trackDuration = max(45, item.durationSeconds ?? 210)
                if isAutoAdvanceEnabled && elapsedSeconds >= trackDuration {
                    elapsedSeconds = 0
                    await skipNext()
                }
            }
        }
    }

    // MARK: - Live Polling of Actual Alexa Speaker State

    private func startPollingAlexaState() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if case .alexaDevice(let device) = selectedTarget, !isTransferring {
                    await refreshAlexaNowPlaying(for: device, force: false)
                }
            }
        }
    }

    func forceRefreshLiveSpeaker() async {
        if case .alexaDevice(let device) = selectedTarget {
            await refreshAlexaNowPlaying(for: device, force: true)
        }
    }

    func refreshAlexaNowPlaying(for device: AlexaDevice, force: Bool = false) async {
        if !force && Date().timeIntervalSince(lastManualCommandTime) < 3.5 {
            return
        }

        guard let report = await alexaClient.fetchLiveSpeakerReport(for: device) else { return }

        self.liveSpeakerReport = report
        self.isPlaying = (report.state == "PLAYING")

        if let vol = report.volume {
            self.volumeLevel = Double(vol)
        }
        if let progress = report.mediaProgress, progress > 0 {
            self.elapsedSeconds = progress
        }

        guard !report.title.isEmpty else { return }

        if let expected = self.requestedItem {
            let matched = doesSpeakerTrackMatch(
                speakerTitle: report.title,
                speakerArtist: report.artist,
                expected: expected
            )
            self.isSpeakerMismatch = !matched
        } else {
            self.isSpeakerMismatch = false
        }

        var artURL = report.artworkURL
        if artURL == nil {
            if let existing = self.requestedItem, !isSpeakerMismatch, existing.artworkURL != nil {
                artURL = existing.artworkURL
            } else if let match = await AppleMusicManager.shared.lookupITunesTrack(title: report.title, artist: report.artist) {
                artURL = match.artworkURL
            }
        }

        if let expected = self.requestedItem, !isSpeakerMismatch {
            var synced = expected
            if let artURL {
                synced.artworkURL = artURL
            }
            self.currentItem = synced
        } else {
            self.currentItem = PlayableMediaItem(
                id: "alexa-live-\(report.title)-\(report.artist)",
                title: report.title,
                subtitle: report.artist.isEmpty ? (report.providerName ?? "Alexa Live Stream") : report.artist,
                albumTitle: report.album,
                artworkURL: artURL,
                previewURL: nil,
                kind: .song,
                durationSeconds: report.mediaLength ?? 210
            )
        }
        updateLockScreenNowPlayingInfo()
    }
}
