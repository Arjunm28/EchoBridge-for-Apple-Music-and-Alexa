# Changelog

All notable changes to **EchoBridge for Apple Music & Alexa** (`EchoBridge-for-Apple-Music-and-Alexa`) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed & Enhanced
- **Strict Apple Music Routing & Elimination of Silent Amazon Music Fallback**:
  - **Fixed Amazon Music Override on Echo Show / Echo Devices**: Resolved an issue where playback silently fell back to Amazon Music under the hood. 
  - **Default "Apple Music (Strict)" Mode**: Changed default `providerPreference` to `.appleMusic`, ensuring playback routes strictly through Apple Music and never degrades silently to Amazon Music.
  - **High-Fidelity TextCommand (`amzn1.ask.1p.tellalexa`)**: Routes voice commands formatted as `"play [song] from Apple Music [on Group]"` directly to Alexa's dialog manager. This invokes the linked Apple Music skill, displaying the Apple Music logo, album art, and native player on Echo Show screens.
  - **Dual Encoding for `Alexa.Music.PlaySearchPhrase`**: Supports both string-serialized Routine JSON payloads and dictionary objects for `musicProviderId: "APPLE_MUSIC"`.
  - **Fixed Post-Play Verification Provider Drift**: Fixed `PlaybackCoordinator.schedulePostPlayVerification` which previously forced `.amazonMusic` during track title mismatch retries, replacing it with the user's active `providerPreference`.
  - **Live Service Provider Badges**: Added live color-coded provider badges (Pink for Apple Music, Blue for Amazon Music) in [`NowPlayingBar.swift`](AlexaAppleMusic/Views/NowPlayingBar.swift) and [`NowPlayingDetailView.swift`](AlexaAppleMusic/Views/NowPlayingDetailView.swift) to provide full visibility into the active backend streaming provider.
  - **In-App Account Linking Guidance**: Added clear guidance and tip banners in [`SpeakerPickerSheet.swift`](AlexaAppleMusic/Views/SpeakerPickerSheet.swift) directing users to set Apple Music as their Default Music Service in the Alexa app (`More → Settings → Music & Podcasts → Default Services`).

### Added
- **Microphone Acoustic Auto-Sync ("TrueSync" Calibration)**:
  - Added [`AcousticSyncCalibrator.swift`](file:///Users/arjunmohankumar/Documents/Alexa-AppleMusic/AlexaAppleMusic/Services/AcousticSyncCalibrator.swift) using `AVAudioEngine` and transient cross-correlation.
  - Automatically measures the physical millisecond acoustic drift between Amazon Echo and Sonos speakers using the iPhone's microphone, computes the exact delay, and auto-calibrates `sonosSyncOffsetSeconds`.
  - Added **"Microphone Auto-Sync (TrueSync)"** interactive wizard card in `SpeakerPickerSheet.swift` with live progress, millisecond readout, and 1-tap auto-resync.
- **Direct Local Sonos UPnP Controller (`SonosLocalUPnPClient.swift`)**:
  - Implements SOAP control over local LAN on TCP port 1400 (`/MediaRenderer/RenderingControl/Control` & `/MediaRenderer/AVTransport/Control`).
  - Supports instant `<30ms` latency for volume scrubbing and transport actions on Sonos Era 100 without cloud hops.
- **Proportional Multi-Room Group Volume Scaling**:
  - Dragging master group volume dynamically scales individual room speakers relative to their existing balance ratio (inspired by Music Assistant and SoCo `GroupRenderingControl`).
- **"Don't Stop the Music" (Continuous Radio Engine)**:
  - Automatically fetches and queues Apple Music recommendations when reaching the end of the active queue so playback never stops.
- **Active Household Media Session Discovery**:
  - Queries `GET /api/np/list-media-sessions` in `AlexaAPIClient.swift` to identify currently playing Echo devices and clusters across the home.
- **Parallel Alexa Behavior Sequences (`ParallelNode`)**:
  - Dispatches multi-speaker behavior nodes in parallel in a single request payload, optimizing command delivery.
- **Apple Music URL & Clipboard Resolver (`music.apple.com/...`)**:
  - Added "Link" button in Home/Library toolbar to paste and resolve any Apple Music track/album link directly to playback targets.

### Changed
- **Streamlined 3-Tab Navigation & Decluttered Player UI**:
  - Updated [`ContentView.swift`](AlexaAppleMusic/Views/ContentView.swift) with dedicated **Home**, **Library**, and **Speakers** tabs and `.safeAreaInset(edge: .bottom)` mini-player docking.
  - Refactored [`LibraryAndSearchView.swift`](AlexaAppleMusic/Views/LibraryAndSearchView.swift) into focused `.home` and `.library` modes with segmented **Playlists**, **Albums**, **Songs**, and **Stations** views.
  - Simplified [`NowPlayingDetailView.swift`](AlexaAppleMusic/Views/NowPlayingDetailView.swift) with a compact Live Speaker Status pill, expandable Song Match drawer, and collapsible Up Next Queue drawer.
  - Organized [`SpeakerPickerSheet.swift`](AlexaAppleMusic/Views/SpeakerPickerSheet.swift) with an inline Stop button on the Active Output card and a collapsible disclosure section for advanced Sonos sync & catalog resolver settings.

### Added
- **Architectural Upgrades Inspired by Music Assistant & `alexapy`**:
  - **`Alexa.TextCommand` (`skillId: amzn1.ask.1p.tellalexa`)**: Added Amazon's first-party text-to-intent behavior node in `AlexaAPIClient.swift` for rock-solid Multi-Room (`WHA`) and regional song fallback.
  - **iOS Lock Screen, Control Center & Dynamic Island Integration**: Added `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` support in `PlaybackCoordinator.swift` so users can control Echo & Sonos Multi-Room playback directly from the iPhone Lock Screen.
  - **First-Class Queue Actions ("Play Next" & "Add to Queue")**: Long-press context menus on songs in `LibraryAndSearchView.swift` to insert tracks next or append to the active controller queue.
  - **Universal Group Sleep Timer**: Added a `15m / 30m / 45m / 60m` Sleep Timer in `NowPlayingDetailView.swift` that automatically stops all Echo Multi-Room and linked Sonos speakers when the timer expires.
  - **Pre-Flight `WHA` Idle Release**: Automatically releases single-speaker stream locks before transitioning to a Multi-Room (`WHA`) group.
- **Sonos + Echo Multi-Room Sync & Delay Compensation**:
  - **Multi-Room Companion Linking (`+` Link)**: Link any Alexa-enabled Sonos speaker (e.g., Sonos Era 100) to automatically play alongside Echo Multi-Room (`WHA`) groups like *Everywhere*.
  - **Sonos Head-Start Sync Offset (`-2.0s` to `+4.0s`)**: Staggered playback dispatch that triggers Sonos speakers first (`+1.8s` default head-start) to compensate for Sonos Cloud buffering lag before firing the Echo Multi-Room group.
  - **Hybrid AirPlay 2 + Alexa Dual-Play Bridge**: Simultaneous local AirPlay 2 (for Sonos) + Alexa Multi-Room playback with `-0.25s` / `+0.25s` real-time Fine Beat Nudge buttons.
  - **Per-Room Multi-Room Volume Sliders**: Independent volume sliders for every Echo and linked Sonos speaker inside the active group.
- Added live iOS Simulator app screenshots (`docs/screenshots/`) and embedded screenshot gallery in `README.md`.
- Added prominent **Sign In** card at the top of `SpeakerPickerSheet` when in Demo Mode or signed out so users can connect their real Amazon Alexa account with one tap.
- Prioritized **Speaker Groups (Multi-Room)** and **Individual Echo & Sonos Speakers** right below the Current Output card in `SpeakerPickerSheet`.

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
