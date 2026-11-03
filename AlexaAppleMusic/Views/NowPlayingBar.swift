import SwiftUI

struct NowPlayingBar: View {
    @ObservedObject var coordinator = PlaybackCoordinator.shared
    var onTapBar: () -> Void
    var onTapSpeakers: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Mismatch Banner if the Echo speaker started a different song than requested
            if coordinator.isSpeakerMismatch,
               let requested = coordinator.requestedItem,
               let live = coordinator.liveSpeakerReport {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Speaker playing \"\(live.title)\" instead of \"\(requested.cleanTitle)\"")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer()
                    Button("Fix") {
                        onTapBar()
                    }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.pink)
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }

            HStack(spacing: 12) {
                // Tappable Artwork + Title area that opens full-screen Now Playing Detail
                Button(action: onTapBar) {
                    HStack(spacing: 12) {
                        ArtworkThumbnailView(url: coordinator.currentItem?.artworkURL, size: 46)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                if let live = coordinator.liveSpeakerReport, live.state == "PLAYING" {
                                    Circle()
                                        .fill(coordinator.isSpeakerMismatch ? Color.orange : Color.green)
                                        .frame(width: 7, height: 7)
                                }
                                Text(coordinator.liveSpeakerReport?.title ?? coordinator.currentItem?.cleanTitle ?? "Select a Song")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 4) {
                                if coordinator.selectedTarget.isAlexaTarget {
                                    Image(systemName: coordinator.selectedTarget.iconName)
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                    Text(coordinator.liveSpeakerReport?.reportingSpeakerName ?? coordinator.selectedTarget.displayName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                        .lineLimit(1)

                                    let artistText = coordinator.liveSpeakerReport?.artist ?? coordinator.currentItem?.primaryArtist ?? ""
                                    if !artistText.isEmpty {
                                        Text("• \(artistText)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    if let provider = coordinator.liveSpeakerReport?.providerName, !provider.isEmpty {
                                        let isApple = provider.localizedCaseInsensitiveContains("apple")
                                        Text("• \(isApple ? "Apple Music" : provider)")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(isApple ? .pink : .secondary)
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text(coordinator.currentItem?.primaryArtist ?? "Playing on iPhone")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Speaker Picker Button
                Button(action: onTapSpeakers) {
                    Image(systemName: coordinator.selectedTarget.isAlexaTarget ? coordinator.selectedTarget.iconName : "airplayaudio")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .primary)
                        .frame(width: 34, height: 34)
                        .background(
                            Circle()
                                .fill(coordinator.selectedTarget.isAlexaTarget ? Color.green.opacity(0.18) : Color(.tertiarySystemFill))
                        )
                }
                .buttonStyle(.plain)

                // Play / Pause + Next Buttons
                if coordinator.currentItem != nil || coordinator.liveSpeakerReport != nil {
                    Button {
                        Task {
                            await coordinator.togglePlayPause()
                        }
                    } label: {
                        if coordinator.isTransferring {
                            ProgressView()
                                .frame(width: 34, height: 34)
                        } else {
                            Image(systemName: coordinator.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3)
                                .foregroundStyle(.primary)
                                .frame(width: 34, height: 34)
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task {
                            await coordinator.skipNext()
                        }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 34)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(coordinator.isSpeakerMismatch ? Color.orange.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: coordinator.isSpeakerMismatch ? 1.2 : 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 12)
    }
}

struct ArtworkThumbnailView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                ZStack {
                    LinearGradient(
                        colors: [.pink, .purple, .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .id(url?.absoluteString ?? "placeholder")
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
    }
}
