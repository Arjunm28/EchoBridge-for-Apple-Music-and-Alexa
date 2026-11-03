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
    var isEmbeddedInTab: Bool = false

    @ObservedObject var authManager = AlexaAuthManager.shared
    @ObservedObject var alexaClient = AlexaAPIClient.shared
    @ObservedObject var coordinator = PlaybackCoordinator.shared

    @Environment(\.dismiss) private var dismiss
    @State private var showLoginSheet = false
    @State private var showAdvancedSyncSettings = false

    var body: some View {
        NavigationStack {
            List {
                // 1. Active Output + Master & Per-Room Volumes
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(coordinator.selectedTarget.isAlexaTarget ? Color.green.opacity(0.2) : Color.pink.opacity(0.2))
                                .frame(width: 46, height: 46)
                            Image(systemName: coordinator.selectedTarget.iconName)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(coordinator.selectedTarget.isAlexaTarget ? .green : .pink)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Active Output")
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
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Local iPhone / AirPlay 2 Output")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if coordinator.isTransferring {
                            ProgressView()
                        } else if coordinator.isPlaying {
                            Button(role: .destructive) {
                                Task { await coordinator.stopAllPlayback() }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .font(.caption.weight(.bold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.red.opacity(0.15))
                                    .foregroundStyle(.red)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)

                    // Master Volume + Per-Room Individual Volume Sliders
                    if coordinator.selectedTarget.isAlexaTarget {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                Image(systemName: "speaker.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

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
                                .tint(.green)

                                Image(systemName: "speaker.wave.3.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text("\(Int(coordinator.volumeLevel))%")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 38, alignment: .trailing)
                            }

                            if case .alexaDevice(let group) = coordinator.selectedTarget {
                                let baseMembers = group.isSpeakerGroup ? alexaClient.memberDevices(for: group) : [group]
                                let linkedExtras = coordinator.activeCompanionDevices.filter { extra in
                                    !baseMembers.contains(where: { $0.serialNumber == extra.serialNumber })
                                }
                                let allRoomSpeakers = baseMembers + linkedExtras

                                if allRoomSpeakers.count > 1 {
                                    Divider()
                                    Text("Room Volumes")
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

                // 2. Sign-In Card when not authenticated or in Demo Mode
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
                                Text("Sign in to load your Echo speakers & Multi-Room groups")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Sign In") {
                                showLoginSheet = true
                            }
                            .font(.caption.weight(.bold))
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                        }
                    }
                }

                if authManager.isAuthenticated {
                    // 3. Multi-Room Speaker Groups
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
                        Text("Multi-Room Speaker Groups")
                    }

                    // 4. Individual Echo & Sonos Speakers
                    Section {
                        if alexaClient.isLoadingDevices {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Discovering Echo & Sonos speakers...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else if alexaClient.individualSpeakers.isEmpty {
                            Text("No speakers found. Pull to refresh.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(alexaClient.individualSpeakers) { speaker in
                                individualSpeakerWithLinkRow(speaker)
                            }
                        }

                        speakerRow(
                            target: .localDevice,
                            title: "This iPhone / AirPlay 2",
                            subtitle: "Direct local or AirPlay 2 audio output",
                            icon: "airplayaudio",
                            isOnline: true
                        )
                    } header: {
                        Text("Individual Speakers")
                    } footer: {
                        Text("Tap '+' on a Sonos or extra room speaker to link it so it plays automatically with 'Everywhere'.")
                    }
                }

                // 5. Progressive Disclosure: Collapsible Advanced Sync & Audio Settings
                Section {
                    DisclosureGroup(isExpanded: $showAdvancedSyncSettings) {
                        // A. Sonos Head-Start Sync Offset
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label("Sonos Head-Start Offset", systemImage: "timer")
                                    .font(.subheadline.weight(.medium))
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
                                    Label("Resync", systemImage: "arrow.triangle.2.circlepath")
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

                        // B. Alexa Catalog Resolver Preference
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Music Catalog Resolver")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Picker("Alexa Catalog Resolver", selection: $coordinator.providerPreference) {
                                ForEach(AlexaMusicProviderPreference.allCases) { pref in
                                    Text(pref.rawValue).tag(pref)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(.vertical, 2)

                        // C. AirPlay 2 Dual-Play Bridge
                        Toggle(isOn: $coordinator.bridgeAirPlayWithAlexa) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Dual-Play: AirPlay 2 + Alexa Group")
                                    .font(.subheadline)
                                Text("Stream locally via AirPlay 2 alongside Alexa")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tint(.pink)

                        if coordinator.bridgeAirPlayWithAlexa {
                            HStack {
                                Text("AirPlay Route & Beat Nudge")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                SystemAirPlayRouteButton()
                                    .frame(width: 34, height: 34)
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
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(.pink)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sonos Sync & Advanced Audio")
                                    .font(.subheadline.weight(.medium))
                                Text("Sonos head-start (\(String(format: "%+.1fs", coordinator.sonosSyncOffsetSeconds))), \(coordinator.providerPreference.rawValue) resolver")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // 6. Account Management Footer
                if authManager.isAuthenticated {
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
            .navigationTitle("Speakers")
            .navigationBarTitleDisplayMode(isEmbeddedInTab ? .large : .inline)
            .refreshable {
                await alexaClient.fetchDevices()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if authManager.isAuthenticated && !isEmbeddedInTab {
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
                    if isEmbeddedInTab {
                        if authManager.isAuthenticated {
                            Button {
                                Task {
                                    await alexaClient.fetchDevices()
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    } else {
                        Button("Done") {
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
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
                        .frame(width: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.accountName)
                            .font(.body.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .green : (speaker.online ? .primary : .secondary))

                        Text(
                            isLinkedCompanion
                                ? "Linked with Everywhere (\(String(format: "%+.1fs", coordinator.sonosSyncOffsetSeconds)))"
                                : (speaker.online ? "Online" : "Offline")
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
                Image(systemName: isLinkedCompanion ? "link.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(isLinkedCompanion ? .pink : .secondary)
                    .padding(4)
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
                if !isEmbeddedInTab {
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .green : (isOnline ? .primary : .secondary))
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .green : (isOnline ? .primary : .secondary))

                    Text(isOnline ? subtitle : "Offline")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title3)
                }
            }
            .contentShape(Rectangle())
        }
        .disabled(!isOnline)
    }
}
