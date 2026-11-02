# Contributing to EchoBridge for Apple Music & Alexa

First off, thank you for considering contributing to **EchoBridge for Apple Music & Alexa**! 🎉
Our goal is to make playing Apple Music on Amazon Echo speakers and Multi-Room speaker groups as seamless as Spotify Connect.

---

## 🛠️ How the Codebase is Organized

```
AlexaAppleMusic/
├── AlexaAppleMusicApp.swift          # App entry point
├── Models/
│   ├── AlexaModels.swift             # Amazon regions, AlexaDevice, WHA group & player models
│   └── MusicItemModels.swift         # Unified PlayableMediaItem (MusicKit + iTunes Search)
├── Services/
│   ├── AlexaAuthManager.swift        # On-device WKWebView login, cookie & CSRF persistence
│   ├── AlexaAPIClient.swift          # Alexa device discovery, PlaySearchPhrase, /api/np/* control
│   ├── AppleMusicManager.swift       # MusicKit library/catalog requests & system player handoff
│   └── PlaybackCoordinator.swift     # Target switching, handoff & live polling coordinator
└── Views/
    ├── ContentView.swift             # TabView + floating mini-player container
    ├── LibraryAndSearchView.swift    # Browse, search, quick speaker strip & handoff banner
    ├── SpeakerPickerSheet.swift      # Spotify Connect-style speaker & Multi-Room group sheet
    ├── NowPlayingBar.swift           # Floating mini-player with active speaker bar
    ├── NowPlayingDetailView.swift    # Fullscreen player view
    └── AlexaLoginWebView.swift       # Amazon login sheet with region selector
```

---

## 🚀 Getting Started as a Contributor

1. **Fork & Clone** the repo.
2. Open `AlexaAppleMusic.xcodeproj` in Xcode 16+.
3. You can develop and test the UI immediately in the **iOS Simulator** without logging into Amazon or having a paid Apple Developer account:
   - Tap **Try Demo Speakers** in the Speaker Picker to populate simulated Echo speakers and Multi-Room groups (*Everywhere*, *Downstairs*, *Upstairs*).
   - Search works out-of-the-box via the automatic iTunes Catalog Search fallback in `AppleMusicManager.swift`.

---

## 💡 High-Impact Features to Work On

1. **iOS Share Extension**: Allow users inside the native iOS Apple Music app to tap `Share -> Play on Alexa` and select a speaker or Multi-Room group directly from the share sheet.
2. **Lock Screen / Dynamic Island Integration (`MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`)**: Mirror the active Echo speaker's Now Playing metadata to the iOS Lock Screen and Dynamic Island.
3. **macOS Catalyst / Native macOS Menu Bar Target**: Add a macOS menu bar target so Mac users can cast Apple Music to Echo speakers.
4. **Amazon Auth Token Refresh**: Implement automated token refresh using Amazon's `/auth/register` mobile OAuth flow so sessions stay alive indefinitely.
5. **Better Multi-Room Group Handling**: Support edge cases across different Amazon regional endpoints (`pitangui`, `layla`, `alexa.amazon.*`).

---

## 📬 Submitting a Pull Request

1. Create a feature branch (`git checkout -b feat/your-feature-name`).
2. Make sure the project compiles cleanly without warnings.
3. Open a Pull Request describing what you changed and how you tested it (Simulator Demo Mode and/or physical Echo hardware).
