# Alexa Apple Music Connect 🎵🔊

> **Spotify Connect for Apple Music + Amazon Echo.**
> Browse Apple Music, pick any individual Echo speaker or Multi-Room speaker group, and cast music directly from your iPhone—no voice commands required.

![Platform](https://img.shields.io/badge/Platform-iOS%2017%2B-pink)
![Language](https://img.shields.io/badge/Swift-5.10%2B-orange)
![License](https://img.shields.io/badge/License-MIT-green)
![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)

---

## 💡 The Story: Why Does This Project Exist?

If you use **Spotify** and own **Amazon Echo** speakers, life is easy: you open the Spotify app, tap the speaker icon, and every Echo device and Multi-Room speaker group in your home appears right there via **Spotify Connect**.

If you switch to **Apple Music**, you hit a wall:
1. **Apple Music only speaks AirPlay 2** in its native speaker picker.
2. **Amazon Echo speakers don't support AirPlay.**
3. Even though Amazon has an official **Apple Music skill for Alexa**, the only ways to use it are shouting voice commands across the room (*"Alexa, play my Chill Mix playlist on the Downstairs group!"*—and hoping she understands the song title) or digging through the clunky Alexa app media menus.
4. Worse, if you try to build a custom Alexa Skill using Amazon's `AudioPlayer` directive or an AirPlay bridge, **Amazon blocks custom skills from playing on Multi-Room Music (WHA) speaker groups**.

### How We're Tackling It

Instead of trying to force raw AirPlay audio over a local network bridge (which breaks Multi-Room sync), **Alexa Apple Music Connect** acts as a **native cloud-to-cloud controller** that bridges **Apple's `MusicKit`** with **Amazon's internal Alexa Behavior & Whole-Home Audio APIs** directly on-device:

```
┌────────────────────────────────────────────────────────────────────┐
│                   Alexa Apple Music Connect (iOS)                  │
│                                                                    │
│  ┌──────────────────────────┐        ┌──────────────────────────┐  │
│  │     Apple MusicKit       │        │   SystemMusicPlayer      │  │
│  │  • Personal Library      │        │  • Detects song playing  │  │
│  │  • Playlists & Albums    │        │    in iOS Music app for  │  │
│  │  • Full Catalog Search   │        │    1-tap Alexa Handoff   │  │
│  └────────────┬─────────────┘        └────────────┬─────────────┘  │
│               └─────────────────┬─────────────────┘                │
│                                 ▼                                  │
│                  ┌─────────────────────────────┐                   │
│                  │     PlaybackCoordinator     │                   │
│                  │  Spotify Connect-style UI   │                   │
│                  └──────────────┬──────────────┘                   │
└─────────────────────────────────┼──────────────────────────────────┘
                                  │
         Direct HTTPS (Session Cookies + CSRF negotiated on-device)
                                  │
                                  ▼
┌────────────────────────────────────────────────────────────────────┐
│                    Amazon Alexa Cloud APIs                         │
│                                                                    │
│  1. Discovery: GET /api/devices-v2/device                          │
│     • Individual Echo Speakers (ECHO, KNIGHT, ROOK)                │
│     • Multi-Room Speaker Groups (deviceFamily == "WHA")            │
│                                                                    │
│  2. Playback:  POST /api/behaviors/preview                         │
│     • Operation: Alexa.Music.PlaySearchPhrase                      │
│     • Provider:  APPLE_MUSIC                                       │
│                                                                    │
│  3. Control:   POST /api/np/command & GET /api/np/player           │
│     • Play / Pause / Next / Prev / Shuffle / Volume / Live State   │
└────────────────────────────────────────────────────────────────────┘
```

1. **Discover Every Speaker & Multi-Room Group**: Queries `/api/devices-v2/device` to list both individual Echo speakers and `WHA` (Whole Home Audio) Multi-Room speaker groups—complete with the member speakers inside each group.
2. **Trigger Native Apple Music Streams on Alexa**: Dispatches `Alexa.Music.PlaySearchPhrase` payloads with `musicProviderId: "APPLE_MUSIC"` to `/api/behaviors/preview`. Because this invokes Amazon's first-party Apple Music integration on the cloud side, **lossless/high-quality streams and Multi-Room speaker groups work natively**.
3. **1-Tap Handoff from the iOS Apple Music App**: Reads `MPMusicPlayerController.systemMusicPlayer.nowPlayingItem` so if you're already listening to a song in the default iPhone Music app, you can hand it off to your Echo speakers with one tap.
4. **100% Standalone iOS App**: No Raspberry Pi, Node.js bridge, or home server required.

> *Built in the open and vibe-coded with **Gemini 4 Argon** in Antigravity—turning a daily smart-home frustration into an open-source community project.*

---

## ✨ Current Features

- **Spotify Connect-Style Speaker Picker (`SpeakerPickerSheet`)**:
  - View all **Speaker Groups (Multi-Room)** with their member Echo devices listed underneath.
  - View all **Individual Echo Speakers** with online/offline status and device-specific icons.
  - Switch speakers mid-song to immediately transfer playback to the new target.
- **Native Apple Music Browse & Search (`AppleMusicManager`)**:
  - Browse your personal Apple Music playlists and recently added tracks via `MusicKit`.
  - Search songs, albums, and playlists across the Apple Music catalog (with an automatic fallback to the public iTunes Search API so the app works immediately in the Simulator even before provisioning a paid MusicKit token).
- **1-Tap Native Music App Handoff**:
  - Detects what's currently playing in the iPhone's native Apple Music app and offers a one-tap **"Cast to Alexa"** banner.
- **Real-Time Transport & Volume Control**:
  - Play, pause, skip next/previous, toggle shuffle, and adjust speaker/group volume from the mini-player bar or full-screen Now Playing sheet.
- **Instant Demo Mode**:
  - Preview the full Spotify Connect UI with simulated Echo speakers and Multi-Room groups (*Everywhere*, *Downstairs*, *Upstairs*) before signing into Amazon.

---

## 🚀 Getting Started

### Prerequisites
- Xcode 16+ / iOS 17.0+
- An Amazon account with Echo devices and the **Apple Music skill** linked in the Alexa app (`Settings -> Music & Podcasts -> Apple Music`).
- *(Optional for personal library playlists)* An Apple Developer account with the **MusicKit** capability enabled on your App ID.

### Build & Run
1. Clone the repository:
   ```bash
   git clone https://github.com/Arjunm28/Alexa-Apple-Music-Bridge.git
   cd Alexa-Apple-Music-Bridge
   open AlexaAppleMusic.xcodeproj
   ```
2. In Xcode, select the **AlexaAppleMusic** project -> **Signing & Capabilities**:
   - Select your **Team** and set a unique **Bundle Identifier**.
   - *(Optional)* Click **+ Capability** and add **MusicKit**.
3. Press `Cmd + R` to run on your iPhone or Simulator.
4. Tap **Connect Alexa** -> **Sign in with Amazon** (or tap **Try Demo Speakers** to explore the UI first).

---

## 🗺️ Open-Source Roadmap (Help Wanted!)

We're actively looking for contributors! Here are the top areas where you can jump in:

- [ ] **Queue Management & Up Next**: Queue multiple Apple Music tracks sequentially and auto-advance or sync queue state with Alexa.
- [ ] **iOS Lock Screen & Control Center (`MPNowPlayingInfoCenter`)**: Expose active Alexa speaker playback to the iPhone Lock Screen, Dynamic Island, and hardware volume buttons when casting.
- [ ] **Share Sheet Extension ("Share from Apple Music -> Play on Alexa")**: An iOS Share Extension so users can tap `Share` inside the native Apple Music app and pick an Echo speaker or group directly without even switching apps.
- [ ] **macOS Menu Bar App Target**: Bring the same SwiftUI codebase to macOS as a lightweight menu bar speaker picker.
- [ ] **Amazon OAuth / Token Refresh Hardening**: Improve long-lived token refresh (`at-main` / FRC / device registration) so cookies never expire.
- [ ] **Dynamic Multi-Room Group Builder**: Create or modify speaker groups on the fly from inside the app.

Check out [CONTRIBUTING.md](CONTRIBUTING.md) to get started!

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
