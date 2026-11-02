# Changelog

All notable changes to **Alexa Apple Music Connect** (`Alexa-Apple-Music-Bridge`) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Planned
- iOS Share Sheet Extension (`Share -> Play on Alexa` from the native Apple Music app).
- iOS Lock Screen & Dynamic Island integration (`MPNowPlayingInfoCenter` & `MPRemoteCommandCenter`).
- Queue management & Up Next synchronization.
- macOS Menu Bar app target.
- Automated Amazon OAuth token refresh.

---

## [0.1.0] - 2026-11-02

### Added
- **Standalone SwiftUI iOS App (`AlexaAppleMusic.xcodeproj`)**:
  - Zero-server architecture running 100% natively on iOS 17.0+.
- **Amazon Alexa On-Device Auth (`AlexaAuthManager` & `AlexaLoginSheetView`)**:
  - In-app `WKWebView` login supporting US, UK, DE, CA, AU, JP, and IN Amazon regions.
  - Automatic session cookie & `csrf` token capture and persistence.
  - Built-in **Demo Speakers Mode** for instant Simulator and UI testing without an Amazon login.
- **Speaker & Multi-Room Group Discovery (`AlexaAPIClient` & `SpeakerPickerSheet`)**:
  - Fetches all Echo devices via `/api/devices-v2/device`.
  - Automatically separates **Multi-Room Speaker Groups** (`WHA`) from **Individual Echo Speakers** (`ECHO`, `KNIGHT`, `ROOK`) and resolves group `clusterMembers` to display member speaker names.
- **Cloud-to-Cloud Apple Music Playback & Transport Control (`PlaybackCoordinator`)**:
  - Triggers native Apple Music streams on individual Echo speakers and Multi-Room speaker groups via `/api/behaviors/automations/validate` and `/api/behaviors/preview` (`Alexa.Music.PlaySearchPhrase` with `musicProviderId: "APPLE_MUSIC"`).
  - Supports Play, Pause, Skip Next, Skip Previous, Shuffle, and Volume control via `/api/np/command`.
  - Live polling of active speaker state via `/api/np/player`.
  - Seamless target handoff when switching speakers mid-song.
- **Apple MusicKit & Native Music App Handoff (`AppleMusicManager` & `LibraryAndSearchView`)**:
  - Personal playlist & library browsing via `MusicKit`.
  - Full catalog search (Songs, Albums, Playlists) with automatic fallback to the public iTunes Search API.
  - 1-Tap Handoff banner detecting the currently playing track in the iPhone's built-in Apple Music app (`MPMusicPlayerController.systemMusicPlayer`).
- **Open-Source Documentation**:
  - Added `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, and MIT `LICENSE`.
