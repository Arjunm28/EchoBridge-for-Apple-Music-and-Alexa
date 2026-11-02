import SwiftUI

struct NowPlayingDetailView: View {
    @ObservedObject var coordinator = PlaybackCoordinator.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showSpeakerSheet = false
    @State private var showCustomPhraseEditor = false
    @State private var customPhraseInput = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color.pink.opacity(0.28),
                        Color.indigo.opacity(0.22),
                        Color(.systemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Live Speaker Telemetry Verification Card (Requested vs Actually Playing on Speaker)
                        if coordinator.selectedTarget.isAlexaTarget {
                            liveSpeakerVerificationCard
                                .padding(.horizontal, 20)
                                .padding(.top, 6)
                        }

                        // Large Album Artwork
                        ArtworkThumbnailView(url: coordinator.currentItem?.artworkURL, size: 225)
                            .shadow(color: .black.opacity(0.32), radius: 20, x: 0, y: 10)
                            .scaleEffect(coordinator.isPlaying ? 1.0 : 0.94)
                            .animation(.spring(response: 0.4, dampingFraction: 0.72), value: coordinator.isPlaying)

                        // Track Metadata + Status
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
                                Text("Movie / Soundtrack: \(movie)")
                                    .font(.caption.weight(.semibold))
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

                        // Progress Bar + Auto-Advance Indicator
                        if let item = coordinator.currentItem {
                            let total = max(45, coordinator.liveSpeakerReport?.mediaLength ?? item.durationSeconds ?? 210)
                            VStack(spacing: 4) {
                                ProgressView(value: min(coordinator.elapsedSeconds, total), total: total)
                                    .tint(coordinator.selectedTarget.isAlexaTarget ? .green : .pink)
                                HStack {
                                    Text(formatTime(coordinator.elapsedSeconds))
                                    Spacer()
                                    if coordinator.isAutoAdvanceEnabled {
                                        Label("Auto-Next Queue On", systemImage: "repeat.1")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(formatTime(total))
                                }
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 28)
                        }

                        // Primary Transport Controls (Shuffle, Previous, Play/Pause, Stop, Next)
                        HStack(spacing: 30) {
                            Button {
                                Task { await coordinator.toggleShuffle() }
                            } label: {
                                Image(systemName: "shuffle")
                                    .font(.title3)
                                    .foregroundStyle(coordinator.isShuffleEnabled ? .green : .secondary)
                            }

                            Button {
                                Task { await coordinator.skipPrevious() }
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.primary)
                            }

                            Button {
                                Task { await coordinator.togglePlayPause() }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.primary)
                                        .frame(width: 68, height: 68)

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
                                    .font(.system(size: 26))
                                    .foregroundStyle(.primary)
                            }

                            Button {
                                Task { await coordinator.stopAllPlayback() }
                            } label: {
                                Image(systemName: "stop.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.red)
                            }
                        }

                        // Smart Song Match / Provider Switcher Strip (Uses `requestedItem` so you never lose the song you tapped!)
                        if let targetSong = coordinator.requestedItem ?? coordinator.currentItem,
                           coordinator.selectedTarget.isAlexaTarget {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label("Force Exact Song Match", systemImage: "wand.and.stars")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Edit Custom Phrase") {
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
                                                    .background(Color(.secondarySystemBackground))
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
                                            Label("Try on Amazon Music", systemImage: "music.quarternote.3")
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
                            .padding(.horizontal, 24)
                        }

                        // Volume Slider
                        HStack(spacing: 12) {
                            Button {
                                Task { await coordinator.stepVolume(by: -10) }
                            } label: {
                                Image(systemName: "speaker.minus.fill")
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
                            .tint(coordinator.selectedTarget.isAlexaTarget ? .green : .pink)

                            Button {
                                Task { await coordinator.stepVolume(by: 10) }
                            } label: {
                                Image(systemName: "speaker.plus.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text("\(Int(coordinator.volumeLevel))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, 24)

                        // Speaker Target Selector Pill
                        Button {
                            showSpeakerSheet = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: coordinator.selectedTarget.iconName)
                                    .font(.subheadline.weight(.semibold))
                                Text(
                                    coordinator.selectedTarget.isAlexaTarget
                                        ? "Playing on \(coordinator.selectedTarget.displayName) (Tap for Room Volumes)"
                                        : "Connect to an Alexa Speaker or Group"
                                )
                                .font(.caption.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.up")
                                    .font(.caption.weight(.bold))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(coordinator.selectedTarget.isAlexaTarget ? Color.green.opacity(0.2) : Color(.secondarySystemBackground))
                            )
                            .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .primary)
                        }
                        .padding(.horizontal, 24)

                        // Interactive "Up Next" Queue Section
                        let upcoming = coordinator.upNextItems()
                        if !upcoming.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Label("Up Next in Queue", systemImage: "text.line.first.and.arrowtriangle.forward")
                                        .font(.headline)
                                    Spacer()
                                    Toggle("Auto-Next", isOn: $coordinator.isAutoAdvanceEnabled)
                                        .labelsHidden()
                                        .tint(.green)
                                }
                                .padding(.horizontal, 24)

                                LazyVStack(spacing: 4) {
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
                                                Image(systemName: "play.circle")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .padding(.horizontal, 24)
                                            .padding(.vertical, 4)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.top, 6)
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
                    VStack(spacing: 1) {
                        Text(coordinator.providerPreference.rawValue.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(coordinator.selectedTarget.displayName)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .primary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await coordinator.forceRefreshLiveSpeaker() }
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                    }
                }
            }
            .sheet(isPresented: $showSpeakerSheet) {
                SpeakerPickerSheet()
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

    // MARK: - Live Speaker Telemetry vs Requested Track Comparison Card

    @ViewBuilder
    private var liveSpeakerVerificationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: coordinator.isSpeakerMismatch ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .foregroundStyle(coordinator.isSpeakerMismatch ? .orange : .green)
                Text(coordinator.isSpeakerMismatch ? "Speaker Track Mismatch Detected" : "Live Speaker Now Playing")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(coordinator.isSpeakerMismatch ? .orange : .green)
                Spacer()
                if let report = coordinator.liveSpeakerReport {
                    Text("\(report.reportingSpeakerName) • \(report.state)")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(Capsule())
                }
            }

            if let report = coordinator.liveSpeakerReport, !report.title.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ACTUALLY ON SPEAKER")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(report.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if !report.artist.isEmpty {
                            Text(report.artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if let requested = coordinator.requestedItem {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("YOU REQUESTED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(requested.cleanTitle)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(requested.primaryArtist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            } else {
                Text("Polling live track state from \(coordinator.selectedTarget.displayName)...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(coordinator.isSpeakerMismatch ? Color.orange.opacity(0.15) : Color(.secondarySystemBackground).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(coordinator.isSpeakerMismatch ? Color.orange.opacity(0.5) : Color.clear, lineWidth: 1)
        )
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
