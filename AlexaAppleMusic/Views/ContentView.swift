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
                onOpenSpeakers: { showSpeakerPickerSheet = true },
                onOpenNowPlaying: { showNowPlayingDetail = true }
            )
            .safeAreaInset(edge: .bottom) {
                if coordinator.currentItem != nil || coordinator.selectedTarget.isAlexaTarget {
                    NowPlayingBar(
                        onTapBar: { showNowPlayingDetail = true },
                        onTapSpeakers: { showSpeakerPickerSheet = true }
                    )
                    .padding(.bottom, 6)
                }
            }
            .tabItem {
                Label("Music", systemImage: "music.note.house.fill")
            }
            .tag(0)

            SpeakerPickerSheet()
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
                .tag(1)
        }
        .tint(.pink)
        .sheet(isPresented: $showSpeakerPickerSheet) {
            SpeakerPickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showNowPlayingDetail) {
            NowPlayingDetailView()
        }
        .task {
            if authManager.isAuthenticated {
                await alexaClient.fetchDevices()
            }
        }
    }
}
