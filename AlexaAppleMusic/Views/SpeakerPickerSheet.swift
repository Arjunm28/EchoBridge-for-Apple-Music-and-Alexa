import SwiftUI
import AVKit

struct SystemAirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.activeTintColor = UIColor.systemPink
        picker.tintColor = UIColor.label
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct SpeakerPickerSheet: View {
    @ObservedObject var authManager = AlexaAuthManager.shared
    @ObservedObject var alexaClient = AlexaAPIClient.shared
    @ObservedObject var coordinator = PlaybackCoordinator.shared

    @Environment(\.dismiss) private var dismiss
    @State private var showLoginSheet = false

    var body: some View {
        NavigationStack {
            List {
                // Active Target Header Card + Live Echo Remote Controls
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(coordinator.selectedTarget.isAlexaTarget ? Color.green.opacity(0.2) : Color.pink.opacity(0.2))
                                .frame(width: 48, height: 48)
                            Image(systemName: coordinator.selectedTarget.iconName)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .pink)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Current Output")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(coordinator.selectedTarget.displayName)
                                    .font(.headline)
                                if !coordinator.activeCompanionDevices.isEmpty {
                                    Text("+ \(coordinator.activeCompanionDevices.count) Linked")
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.pink.opacity(0.2))
                                        .foregroundStyle(.pink)
                                        .clipShape(Capsule())
                                }
                            }
                            if let status = coordinator.statusBanner {
                                Text(status)
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else if coordinator.selectedTarget.isAlexaTarget {
                                Text("Alexa Cloud Connect • \(coordinator.providerPreference.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            } else {
                                Text("Local iPhone / AirPlay 2 Output")
                                    .font(.caption2)
                                    .foregroundStyle(.pink)
                            }
                        }

                        Spacer()

                        if coordinator.isTransferring {
                            ProgressView()
                        } else if coordinator.isPlaying {
                            Image(systemName: "waveform")
                                .symbolEffect(.variableColor.iterative, isActive: coordinator.isPlaying)
                                .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .pink)
                        }
                    }
                    .padding(.vertical, 4)

                    // Quick Hardware-Style Echo Remote Strip
                    HStack(spacing: 10) {
                        Button(role: .destructive) {
                            Task { await coordinator.stopAllPlayback() }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.15))
                                .foregroundStyle(.red)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await coordinator.togglePlayPause() }
                        } label: {
                            Label(coordinator.isPlaying ? "Pause" : "Resume", systemImage: coordinator.isPlaying ? "pause.fill" : "play.fill")
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)

                        Button {
                            Task { await coordinator.skipNext() }
                        } label: {
                            Label("Next", systemImage: "forward.fill")
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)

                    // Master Volume Control
                    if coordinator.selectedTarget.isAlexaTarget {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Button {
                                    Task { await coordinator.stepVolume(by: -10) }
                                } label: {
                                    Image(systemName: "speaker.minus.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)

                                Slider(
                                    value: Binding(
                                        get: { coordinator.volumeLevel },
                                        set: { newVal in
                                            coordinator.volumeLevel = newVal
                                        }
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
                                .tint(.green)

                                Button {
                                    Task { await coordinator.stepVolume(by: 10) }
                                } label: {
                                    Image(systemName: "speaker.plus.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)

                                Text("\(Int(coordinator.volumeLevel))%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }

                            // Per-Room Individual Volume Sliders (Group Members + Linked Sonos Speakers)
                            if case .alexaDevice(let group) = coordinator.selectedTarget {
                                let baseMembers = group.isSpeakerGroup ? alexaClient.memberDevices(for: group) : [group]
                                let linkedExtras = coordinator.activeCompanionDevices.filter { extra in
                                    !baseMembers.contains(where: { $0.serialNumber == extra.serialNumber })
                                }
                                let allRoomSpeakers = baseMembers + linkedExtras

                                if allRoomSpeakers.count > 1 {
                                    Divider()
                                    Text("Individual Speaker Volumes (Multi-Room + Linked Sonos)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    ForEach(allRoomSpeakers) { roomSpeaker in
                                        HStack(spacing: 10) {
                                            Image(systemName: roomSpeaker.sfSymbolName)
                                                .font(.caption)
                                                .foregroundStyle(roomSpeaker.isSonosOrThirdPartySpeaker ? .pink : .green)
                                                .frame(width: 18)
                                            Text(roomSpeaker.accountName)
                                                .font(.caption.weight(.medium))
                                                .frame(width: 96, alignment: .leading)
                                                .lineLimit(1)

                                            Slider(
                                                value: Binding(
                                                    get: { coordinator.roomVolumes[roomSpeaker.serialNumber] ?? coordinator.volumeLevel },
                                                    set: { coordinator.roomVolumes[roomSpeaker.serialNumber] = $0 }
                                                ),
                                                in: 0...100,
                                                step: 1
                                            ) { editing in
                                                if !editing {
                                                    let val = coordinator.roomVolumes[roomSpeaker.serialNumber] ?? coordinator.volumeLevel
                                                    Task {
                                                        await coordinator.setRoomVolume(val, for: roomSpeaker)
                                                    }
                                                }
                                            }
                                            .tint(roomSpeaker.isSonosOrThirdPartySpeaker ? .pink : .green.opacity(0.8))

                                            Text("\(Int(coordinator.roomVolumes[roomSpeaker.serialNumber] ?? coordinator.volumeLevel))%")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .frame(width: 34, alignment: .trailing)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Prominent Sign-In Card when not authenticated or in Demo Mode
                if !authManager.isAuthenticated || authManager.isDemoMode {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "person.badge.key.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 36, height: 36)
                                .background(Color.blue.opacity(0.15))
                                .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text(authManager.isDemoMode ? "Demo Speakers Active" : "Connect Amazon Alexa")
                                    .font(.subheadline.weight(.semibold))
                                Text("Sign in to load your real Echo speakers & Multi-Room groups")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                showLoginSheet = true
                            } label: {
                                Text("Sign In")
                                    .font(.caption.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                    }
                }

                if authManager.isAuthenticated {
                    // Multi-Room Speaker Groups Section
                    Section {
                        if alexaClient.speakerGroups.isEmpty && !alexaClient.isLoadingDevices {
                            Text("No Multi-Room speaker groups found in your Alexa account.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(alexaClient.speakerGroups) { group in
                                let members = alexaClient.memberNames(for: group)
                                let linkedNames = coordinator.activeCompanionDevices.map(\.accountName)
                                let combined = members + linkedNames
                                let subtitle = combined.isEmpty
                                    ? "Multi-Room Music Group"
                                    : combined.joined(separator: " • ")
                                speakerRow(
                                    target: .alexaDevice(group),
                                    title: group.accountName,
                                    subtitle: subtitle,
                                    icon: "hifispeaker.2.fill",
                                    isOnline: group.online
                                )
                            }
                        }
                    } header: {
                        HStack {
                            Label("Speaker Groups (Multi-Room)", systemImage: "speaker.wave.2.bubble.left.fill")
                            Spacer()
                            if authManager.isDemoMode {
                                Text("DEMO")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .foregroundStyle(.orange)
                                    .clipShape(Capsule())
                            }
                        }
                    }

                    // Individual Echo & Sonos Speakers Section (with Multi-Room Companion Link button!)
                    Section {
                        if alexaClient.isLoadingDevices {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Discovering Echo & Sonos speakers...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else if alexaClient.individualSpeakers.isEmpty {
                            Text("No Echo or Sonos speakers found. Pull to refresh or verify your Amazon region.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(alexaClient.individualSpeakers) { speaker in
                                individualSpeakerWithLinkRow(speaker)
                            }
                        }
                    } header: {
                        Text("Individual Echo & Sonos Speakers")
                    } footer: {
                        Text("Tap '+' on any speaker (such as Sonos Era 100) to link it as a Multi-Room Companion so it automatically starts playing whenever you play on 'Everywhere'.")
                    }
                }

                // Sonos Era 100 & Hybrid Multi-Room Sync Calibration Section
                Section {
                    // 1. Sonos Head-Start / Latency Compensation Slider
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Sonos Head-Start Sync Offset", systemImage: "timer")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(String(format: "%+.1f sec", coordinator.sonosSyncOffsetSeconds))
                                .font(.caption.monospacedDigit().weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.pink.opacity(0.18))
                                .foregroundStyle(.pink)
                                .clipShape(Capsule())
                        }

                        Slider(
                            value: $coordinator.sonosSyncOffsetSeconds,
                            in: -2.0...4.0,
                            step: 0.1
                        )
                        .tint(.pink)

                        HStack {
                            Text("Delay Sonos (-2s)")
                            Spacer()
                            Text("0.0s")
                            Spacer()
                            Text("Start Sonos Earlier (+4s)")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach([1.0, 1.5, 1.8, 2.2, 2.8], id: \.self) { preset in
                                Button {
                                    coordinator.sonosSyncOffsetSeconds = preset
                                } label: {
                                    Text(String(format: "+%.1fs", preset))
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(
                                             abs(coordinator.sonosSyncOffsetSeconds - preset) < 0.05
                                                ? Color.pink
                                                : Color(.tertiarySystemFill)
                                        )
                                        .foregroundStyle(abs(coordinator.sonosSyncOffsetSeconds - preset) < 0.05 ? .white : .primary)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                            Button {
                                Task { await coordinator.resyncMultiRoomOutput() }
                            } label: {
                                Label("Apply & Resync", systemImage: "arrow.triangle.2.circlepath")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.green.opacity(0.2))
                                    .foregroundStyle(.green)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    // 2. AirPlay 2 Option + Micro Beat Nudge Buttons
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Select Sonos Era 100 via AirPlay 2", systemImage: "airplayaudio")
                                .font(.subheadline.weight(.semibold))
                            Text("Or use AirPlay 2 with instant ±0.2s beat alignment")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        SystemAirPlayRouteButton()
                            .frame(width: 38, height: 38)
                    }

                    Toggle(isOn: $coordinator.bridgeAirPlayWithAlexa) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Dual-Play: AirPlay 2 (Sonos) + Alexa Group")
                                .font(.subheadline.weight(.medium))
                            Text("Streams to Sonos via AirPlay 2 simultaneously with Everywhere")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.pink)

                    if coordinator.bridgeAirPlayWithAlexa {
                        HStack(spacing: 10) {
                            Text("Fine Beat Nudge (AirPlay):")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("-0.25s") {
                                coordinator.nudgeLocalAirPlayTiming(by: -0.25)
                            }
                            .font(.caption2.weight(.bold))
                            .buttonStyle(.bordered)

                            Button("+0.25s") {
                                coordinator.nudgeLocalAirPlayTiming(by: 0.25)
                            }
                            .font(.caption2.weight(.bold))
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Label("Sonos Era 100 Delay Compensation & Bridge", systemImage: "hifispeaker.and.homepodmini.fill")
                } footer: {
                    Text("Because Sonos Era 100 buffers through Sonos Cloud after receiving Alexa's command, giving Sonos a +1.5s to +2.2s Head-Start triggers Sonos FIRST, waits for it to buffer, and then triggers 'Everywhere' so they start on the same beat.")
                }

                // Music Catalog Resolver Preference
                Section {
                    Picker("Alexa Catalog Resolver", selection: $coordinator.providerPreference) {
                        ForEach(AlexaMusicProviderPreference.allCases) { pref in
                            Text(pref.rawValue).tag(pref)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Auto-Advance Playlist Queue", isOn: $coordinator.isAutoAdvanceEnabled)
                        .font(.subheadline)
                } header: {
                    Text("Playback Engine & Regional Song Matching")
                }

                // Direct iPhone / AirPlay 2 Standalone Mode
                Section("Standalone iPhone / AirPlay 2 Mode") {
                    speakerRow(
                        target: .localDevice,
                        title: "iPhone / AirPlay 2 (Sonos Era 100)",
                        subtitle: "Streams lossless Apple Music directly from your iPhone",
                        icon: "airplayaudio",
                        isOnline: true
                    )
                }

                if !authManager.isAuthenticated {
                    Section("Amazon Alexa Account") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Connect your Amazon account to discover all your Echo speakers, Sonos Alexa speakers, and Multi-Room speaker groups.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 12) {
                                Button {
                                    showLoginSheet = true
                                } label: {
                                    Label("Sign in with Amazon", systemImage: "person.badge.key.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)

                                Button {
                                    authManager.enableDemoMode()
                                    Task {
                                        await alexaClient.fetchDevices()
                                    }
                                } label: {
                                    Text("Try Demo Speakers")
                                        .font(.subheadline.weight(.medium))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    // Account Management Footer
                    Section {
                        if authManager.isDemoMode {
                            Button {
                                showLoginSheet = true
                            } label: {
                                Label("Sign in to Real Amazon Account", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        }
                        Button(role: .destructive) {
                            Task {
                                await coordinator.selectTarget(.localDevice)
                                authManager.signOut()
                            }
                        } label: {
                            Label(authManager.isDemoMode ? "Exit Demo Mode" : "Disconnect Amazon Account", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
            .navigationTitle("Speakers & Sonos Sync")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await alexaClient.fetchDevices()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if authManager.isAuthenticated {
                        Button {
                            Task {
                                await alexaClient.fetchDevices()
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showLoginSheet) {
                AlexaLoginSheetView()
            }
            .task {
                if authManager.isAuthenticated && alexaClient.allDevices.isEmpty {
                    await alexaClient.fetchDevices()
                }
            }
        }
    }

    @ViewBuilder
    private func individualSpeakerWithLinkRow(_ speaker: AlexaDevice) -> some View {
        let target: PlaybackTarget = .alexaDevice(speaker)
        let isSelected = (coordinator.selectedTarget == target)
        let isLinkedCompanion = coordinator.isCompanionLinked(speaker)

        HStack(spacing: 12) {
            Button {
                Task {
                    await coordinator.selectTarget(target)
                }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: speaker.sfSymbolName)
                        .font(.title3)
                        .foregroundStyle(isSelected ? .green : (speaker.isSonosOrThirdPartySpeaker ? .pink : (speaker.online ? .primary : .secondary)))
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(speaker.accountName)
                                .font(.body.weight(isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? .green : (speaker.online ? .primary : .secondary))

                            if speaker.isSonosOrThirdPartySpeaker {
                                Text("SONOS / AVS")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.pink.opacity(0.18))
                                    .foregroundStyle(.pink)
                                    .clipShape(Capsule())
                            }
                        }

                        Text(
                            isLinkedCompanion
                                ? "Linked (\(String(format: "%+.1fs", coordinator.sonosSyncOffsetSeconds)) head-start) • Plays with Everywhere"
                                : (speaker.online ? "Online • Tap '+' to link with Multi-Room" : "Offline")
                        )
                        .font(.caption)
                        .foregroundStyle(isLinkedCompanion ? .pink : .secondary)
                        .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!speaker.online)

            // Multi-Room Companion Link Toggle Button
            Button {
                coordinator.toggleCompanionSpeaker(speaker)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isLinkedCompanion ? "link.circle.fill" : "plus.circle")
                        .font(.title3)
                    if isLinkedCompanion {
                        Text("Linked")
                            .font(.caption2.weight(.bold))
                    }
                }
                .foregroundStyle(isLinkedCompanion ? .pink : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isLinkedCompanion ? Color.pink.opacity(0.15) : Color(.tertiarySystemFill))
                )
            }
            .buttonStyle(.plain)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            }
        }
    }

    @ViewBuilder
    private func speakerRow(
        target: PlaybackTarget,
        title: String,
        subtitle: String,
        icon: String,
        isOnline: Bool
    ) -> some View {
        let isSelected = (coordinator.selectedTarget == target)

        Button {
            Task {
                await coordinator.selectTarget(target)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .green : (isOnline ? .primary : .secondary))
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .green : (isOnline ? .primary : .secondary))

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                } else if !isOnline {
                    Text("Offline")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOnline && target != .localDevice)
    }
}
