import SwiftUI

struct NowPlayingDetailView: View {
    @ObservedObject var coordinator = PlaybackCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSpeakerSheet = false
    @State private var showCustomPhraseEditor = false
    @State private var customPhraseInput = ""
    @State private var showMatchDrawer = false
    @State private var showQueueDrawer = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.pink.opacity(0.24),
                        Color.indigo.opacity(0.18),
                        Color(.systemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        // Compact Live Speaker Status Pill (Auto-expands on mismatch or when tapped)
                        if coordinator.selectedTarget.isAlexaTarget {
                            compactLiveSpeakerStatus
                                .padding(.horizontal, 24)
                                .padding(.top, 4)
                        }

                        // Large Album Artwork
                        ArtworkThumbnailView(url: coordinator.currentItem?.artworkURL, size: 256)
                            .shadow(color: .black.opacity(0.32), radius: 22, x: 0, y: 12)
                            .scaleEffect(coordinator.isPlaying ? 1.0 : 0.94)
                            .animation(.spring(response: 0.4, dampingFraction: 0.72), value: coordinator.isPlaying)
                            .padding(.top, 4)

                        // Track Title, Artist & Subtle Status
                        VStack(spacing: 5) {
                            Text(coordinator.liveSpeakerReport?.title ?? coordinator.currentItem?.cleanTitle ?? "No Track Selected")
                                .font(.title2.weight(.bold))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)

                            Text(coordinator.liveSpeakerReport?.artist ?? coordinator.currentItem?.subtitle ?? "Apple Music")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if let movie = (coordinator.requestedItem ?? coordinator.currentItem)?.extractedMovieName {
                                Text("Soundtrack: \(movie)")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.pink)
                            } else if let album = coordinator.liveSpeakerReport?.album ?? coordinator.currentItem?.albumTitle, !album.isEmpty {
                                Text(album)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }

                            if let status = coordinator.statusBanner {
                                Text(status)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.top, 2)
                            }
                        }
                        .padding(.horizontal, 24)

                        // Progress Bar
                        if let item = coordinator.currentItem {
                            let total = max(45, coordinator.liveSpeakerReport?.mediaLength ?? item.durationSeconds ?? 210)
                            VStack(spacing: 5) {
                                ProgressView(value: min(coordinator.elapsedSeconds, total), total: total)
                                    .tint(.pink)
                                HStack {
                                    Text(formatTime(coordinator.elapsedSeconds))
                                    Spacer()
                                    Text(formatTime(total))
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 28)
                        }

                        // Clean Transport Controls (Shuffle, Previous, Play/Pause, Next, Auto-Next)
                        HStack(spacing: 34) {
                            Button {
                                Task { await coordinator.toggleShuffle() }
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.title3)
                                    .foregroundStyle(coordinator.isShuffleEnabled ? .pink : .secondary)
                            }

                            Button {
                                Task { await coordinator.skipPrevious() }
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 27))
                                    .foregroundStyle(.primary)
                            }

                            Button {
                                Task { await coordinator.togglePlayPause() }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.primary)
                                        .frame(width: 70, height: 70)

                                    if coordinator.isTransferring {
                                        ProgressView()
                                            .tint(Color(.systemBackground))
                                    } else {
                                        Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 28, weight: .bold))
                                            .foregroundStyle(Color(.systemBackground))
                                    }
                                }
                            }

                            Button {
                                Task { await coordinator.skipNext() }
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 27))
                                    .foregroundStyle(.primary)
                            }

                            Button {
                                coordinator.isAutoAdvanceEnabled.toggle()
                            } label: {
                                Image(systemName: "infinity")
                                    .font(.title3)
                                    .foregroundStyle(coordinator.isAutoAdvanceEnabled ? .pink : .secondary)
                            }
                        }

                        // Master Volume Slider
                        HStack(spacing: 12) {
                            Button {
                                Task { await coordinator.stepVolume(by: -10) }
                            } label: {
                                Image(systemName: "speaker.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { coordinator.volumeLevel },
                                    set: { coordinator.volumeLevel = $0 }
                                ),
                                in: 0...100,
                                step: 1
                            ) { editing in
                                if !editing {
                                    Task {
                                        await coordinator.setVolume(coordinator.volumeLevel)
                                    }
                                }
                            }
                            .tint(.pink)

                            Button {
                                Task { await coordinator.stepVolume(by: 10) }
                            } label: {
                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text("\(Int(coordinator.volumeLevel))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, 28)

                        // Apple Music-Style Bottom Action Bar (Speakers, Fix Song Match, Up Next Queue)
                        HStack(spacing: 10) {
                            Button {
                                showSpeakerSheet = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: coordinator.selectedTarget.iconName)
                                        .font(.caption.weight(.semibold))
                                    Text(coordinator.selectedTarget.displayName)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Capsule()
                                        .fill(coordinator.selectedTarget.isAlexaTarget ? Color.green.opacity(0.18) : Color(.secondarySystemBackground))
                                )
                                .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .primary)
                            }
                            .buttonStyle(.plain)

                            if coordinator.selectedTarget.isAlexaTarget {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showMatchDrawer.toggle()
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "wand.and.stars")
                                            .font(.caption.weight(.semibold))
                                        Text("Fix Match")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 10)
                                    .background(
                                        Capsule()
                                            .fill(showMatchDrawer || coordinator.isSpeakerMismatch ? Color.orange.opacity(0.22) : Color(.secondarySystemBackground))
                                    )
                                    .foregroundStyle(showMatchDrawer || coordinator.isSpeakerMismatch ? .orange : .primary)
                                }
                                .buttonStyle(.plain)
                            }

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showQueueDrawer.toggle()
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "list.bullet")
                                        .font(.caption.weight(.semibold))
                                    Text("Up Next")
                                        .font(.caption.weight(.semibold))
                                }
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .background(
                                    Capsule()
                                        .fill(showQueueDrawer ? Color.pink.opacity(0.22) : Color(.secondarySystemBackground))
                                )
                                .foregroundStyle(showQueueDrawer ? .pink : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)

                        // Expandable Drawer 1: Song Match & Custom Phrase Override (Shown when tapped or on mismatch)
                        if (showMatchDrawer || coordinator.isSpeakerMismatch),
                           let targetSong = coordinator.requestedItem ?? coordinator.currentItem,
                           coordinator.selectedTarget.isAlexaTarget {
                            songMatchDrawerView(for: targetSong)
                                .padding(.horizontal, 24)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // Expandable Drawer 2: Up Next Queue (Shown when user taps "Up Next")
                        if showQueueDrawer {
                            upNextQueueDrawerView
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(coordinator.selectedTarget.displayName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section("Speaker Controls") {
                            Button(role: .destructive) {
                                Task { await coordinator.stopAllPlayback() }
                            } label: {
                                Label("Stop All Speakers", systemImage: "stop.circle.fill")
                            }

                            Button {
                                Task { await coordinator.forceRefreshLiveSpeaker() }
                            } label: {
                                Label("Refresh Live Speaker Track", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }

                        Section("Sleep Timer (\(coordinator.sleepTimerMinutesRemaining > 0 ? "\(coordinator.sleepTimerMinutesRemaining)m left" : "Off"))") {
                            Button("Turn Off Sleep Timer") { coordinator.setSleepTimer(minutes: 0) }
                            Button("15 Minutes") { coordinator.setSleepTimer(minutes: 15) }
                            Button("30 Minutes") { coordinator.setSleepTimer(minutes: 30) }
                            Button("45 Minutes") { coordinator.setSleepTimer(minutes: 45) }
                            Button("60 Minutes") { coordinator.setSleepTimer(minutes: 60) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if coordinator.sleepTimerMinutesRemaining > 0 {
                                Image(systemName: "moon.zzz.fill")
                                    .font(.caption)
                                    .foregroundStyle(.pink)
                                Text("\(coordinator.sleepTimerMinutesRemaining)m")
                                    .font(.caption2.monospacedDigit().weight(.bold))
                                    .foregroundStyle(.pink)
                            } else {
                                Image(systemName: "ellipsis.circle")
                                    .font(.headline)
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSpeakerSheet) {
                SpeakerPickerSheet(isEmbeddedInTab: false)
            }
            .alert("Custom Alexa Song Phrase", isPresented: $showCustomPhraseEditor) {
                TextField("e.g. Aeroplane from Scene", text: $customPhraseInput)
                Button("Save & Play") {
                    if let target = coordinator.requestedItem ?? coordinator.currentItem {
                        Task {
                            await coordinator.setCustomPhrase(customPhraseInput, for: target)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Override the exact voice phrase sent to Alexa for this song. Your custom phrase will be remembered automatically.")
            }
            .task {
                await coordinator.forceRefreshLiveSpeaker()
            }
        }
    }

    // MARK: - Compact Live Speaker Status Pill (Progressive Disclosure)

    @ViewBuilder
    private var compactLiveSpeakerStatus: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showMatchDrawer.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: coordinator.isSpeakerMismatch ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(coordinator.isSpeakerMismatch ? .orange : .green)

                if let report = coordinator.liveSpeakerReport, !report.title.isEmpty {
                    if coordinator.isSpeakerMismatch, let requested = coordinator.requestedItem {
                        Text("Speaker playing \"\(report.title)\" instead of \"\(requested.cleanTitle)\" • Tap to Fix")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else {
                        Text("Live on \(report.reportingSpeakerName): \(report.title)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("Connected to \(coordinator.selectedTarget.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: showMatchDrawer ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(coordinator.isSpeakerMismatch ? Color.orange.opacity(0.16) : Color(.secondarySystemBackground).opacity(0.85))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expandable Song Match Drawer

    @ViewBuilder
    private func songMatchDrawerView(for targetSong: PlayableMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Try Alternate Voice Phrase", systemImage: "wand.and.stars")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Custom Phrase...") {
                    customPhraseInput = coordinator.customPhrase(for: targetSong) ?? targetSong.cleanTitle
                    showCustomPhraseEditor = true
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.pink)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(targetSong.alexaCandidatePhrases, id: \.self) { phrase in
                        Button {
                            Task {
                                await coordinator.playWithPhrase(phrase, for: targetSong)
                            }
                        } label: {
                            Text("Play \"\(phrase)\"")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        Task {
                            await coordinator.playWithPhrase(
                                targetSong.cleanTitle,
                                for: targetSong,
                                provider: .amazonMusic
                            )
                        }
                    } label: {
                        Label("Try Amazon Music", systemImage: "music.quarternote.3")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.18))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    // MARK: - Expandable Up Next Queue Drawer

    @ViewBuilder
    private var upNextQueueDrawerView: some View {
        let upcoming = coordinator.upNextItems()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Up Next in Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if coordinator.isDontStopTheMusicEnabled {
                    Text("Auto-Radio On")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.pink.opacity(0.18))
                        .foregroundStyle(.pink)
                        .clipShape(Capsule())
                }
                Toggle("Auto-Next", isOn: $coordinator.isAutoAdvanceEnabled)
                    .labelsHidden()
                    .tint(.pink)
            }
            .padding(.horizontal, 24)

            if upcoming.isEmpty {
                Text("Queue is empty. Play a playlist or tap '•••' on any song to add it to your queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(upcoming.prefix(15)) { nextItem in
                        Button {
                            Task {
                                await coordinator.play(nextItem, inQueue: coordinator.currentQueueList())
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ArtworkThumbnailView(url: nextItem.artworkURL, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(nextItem.cleanTitle)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(nextItem.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "play.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
