import SwiftUI

struct ContentView: View {
    @ObservedObject var authManager = AlexaAuthManager.shared
    @ObservedObject var alexaClient = AlexaAPIClient.shared
    @ObservedObject var coordinator = PlaybackCoordinator.shared

    @State private var showSpeakerPickerSheet = false
    @State private var showNowPlayingDetail = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryAndSearchView(
                mode: .home,
                onOpenSpeakers: { showSpeakerPickerSheet = true },
                onOpenNowPlaying: { showNowPlayingDetail = true }
            )
            .safeAreaInset(edge: .bottom) {
                miniPlayerOverlay
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(0)

            LibraryAndSearchView(
                mode: .library,
                onOpenSpeakers: { showSpeakerPickerSheet = true },
                onOpenNowPlaying: { showNowPlayingDetail = true }
            )
            .safeAreaInset(edge: .bottom) {
                miniPlayerOverlay
            }
            .tabItem {
                Label("Library", systemImage: "music.note.list")
            }
            .tag(1)

            SpeakerPickerSheet(isEmbeddedInTab: true)
                .safeAreaInset(edge: .bottom) {
                    if coordinator.currentItem != nil {
                        NowPlayingBar(
                            onTapBar: { showNowPlayingDetail = true },
                            onTapSpeakers: { showSpeakerPickerSheet = true }
                        )
                        .padding(.bottom, 6)
                    }
                }
                .tabItem {
                    Label("Speakers", systemImage: "hifispeaker.2.fill")
                }
                .tag(2)
        }
        .tint(.pink)
        .sheet(isPresented: $showSpeakerPickerSheet) {
            SpeakerPickerSheet(isEmbeddedInTab: false)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showNowPlayingDetail) {
            NowPlayingDetailView()
        }
        .task {
            let env = ProcessInfo.processInfo.environment["SCREENSHOT_MODE"]
            if env == "SPEAKERS" {
                authManager.enableDemoMode()
                await alexaClient.fetchDevices()
                if let group = alexaClient.speakerGroups.first {
                    await coordinator.selectTarget(.alexaDevice(group))
                }
                showSpeakerPickerSheet = true
            } else if env == "SPEAKERS_TAB" {
                authManager.enableDemoMode()
                await alexaClient.fetchDevices()
                if let group = alexaClient.speakerGroups.first {
                    await coordinator.selectTarget(.alexaDevice(group))
                }
                selectedTab = 2
            } else if env == "NOW_PLAYING" {
                authManager.enableDemoMode()
                await alexaClient.fetchDevices()
                if let speaker = alexaClient.individualSpeakers.first {
                    await coordinator.selectTarget(.alexaDevice(speaker))
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let firstSong = AppleMusicManager.shared.recentSongs.first {
                    await coordinator.play(firstSong)
                }
                showNowPlayingDetail = true
            } else if env == "HOME_CONNECTED" {
                authManager.enableDemoMode()
                await alexaClient.fetchDevices()
                if let group = alexaClient.speakerGroups.first {
                    await coordinator.selectTarget(.alexaDevice(group))
                }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if let firstSong = AppleMusicManager.shared.recentSongs.first {
                    await coordinator.play(firstSong)
                }
            } else if authManager.isAuthenticated {
                await alexaClient.fetchDevices()
            }
        }
    }

    @ViewBuilder
    private var miniPlayerOverlay: some View {
        if coordinator.currentItem != nil || coordinator.selectedTarget.isAlexaTarget {
            NowPlayingBar(
                onTapBar: { showNowPlayingDetail = true },
                onTapSpeakers: { showSpeakerPickerSheet = true }
            )
            .padding(.bottom, 6)
        }
    }
}
