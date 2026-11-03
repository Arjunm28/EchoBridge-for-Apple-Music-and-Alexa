import Foundation

enum AlexaMusicProviderPreference: String, CaseIterable, Identifiable {
    case appleMusic = "Apple Music"
    case auto = "Smart Auto"
    case amazonMusic = "Amazon Music"

    var id: String { rawValue }

    var providerIds: [String] {
        switch self {
        case .appleMusic:
            return ["APPLE_MUSIC"]
        case .auto:
            return ["APPLE_MUSIC", "AMAZON_MUSIC"]
        case .amazonMusic:
            return ["AMAZON_MUSIC"]
        }
    }

    var defaultVoiceSuffix: String {
        switch self {
        case .appleMusic, .auto:
            return "from Apple Music"
        case .amazonMusic:
            return "on Amazon Music"
        }
    }

    func naturalVoiceSuffix(for phrase: String) -> String {
        switch self {
        case .appleMusic, .auto:
            if phrase.lowercased().contains(" from ") {
                return "on Apple Music"
            }
            return "from Apple Music"
        case .amazonMusic:
            return "on Amazon Music"
        }
    }

    var detailDescription: String {
        switch self {
        case .appleMusic:
            return "Strict Apple Music playback via linked Apple Music skill. Never falls back to Amazon Music."
        case .auto:
            return "Prioritizes Apple Music; uses Amazon Music only if Apple Music is unreachable."
        case .amazonMusic:
            return "Streams directly using your Amazon Music library or subscription."
        }
    }
}

enum AlexaTransportCommand {
    case play
    case pause
    case next
    case previous
    case volume(Int) // 0...100
    case shuffle(Bool)

    var payloadJSON: [String: Any] {
        switch self {
        case .play:
            return ["type": "PlayCommand"]
        case .pause:
            return ["type": "PauseCommand"]
        case .next:
            return ["type": "NextCommand"]
        case .previous:
            return ["type": "PreviousCommand"]
        case .volume(let level):
            return ["type": "VolumeLevelCommand", "volumeLevel": max(0, min(100, level))]
        case .shuffle(let enabled):
            return ["type": "ShuffleCommand", "shuffle": enabled ? "true" : "false"]
        }
    }
}

struct AlexaAPIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AlexaAPIClient: ObservableObject {
    static let shared = AlexaAPIClient()

    @Published var allDevices: [AlexaDevice] = []
    @Published var individualSpeakers: [AlexaDevice] = []
    @Published var speakerGroups: [AlexaDevice] = []
    @Published var isLoadingDevices: Bool = false
    @Published var lastErrorMessage: String?
    @Published var accountCustomerId: String?

    private let authManager = AlexaAuthManager.shared

    private init() {}

    // MARK: - Device Discovery

    func fetchDevices() async {
        isLoadingDevices = true
        lastErrorMessage = nil
        defer { isLoadingDevices = false }

        if authManager.isDemoMode {
            loadDemoDevices()
            return
        }

        await authManager.fetchCSRFTokenIfNeeded()
        await fetchBootstrapCustomerIdIfNeeded()

        let region = authManager.region
        let candidateURLs: [URL] = [
            URL(string: "https://\(region.webHost)/api/devices-v2/device?cached=true")!,
            region.alexaBaseURL.appendingPathComponent("api/devices-v2/device")
        ]

        for url in candidateURLs {
            do {
                let request = try buildAuthenticatedRequest(url: url, method: "GET")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }
                let decoded = try JSONDecoder().decode(AlexaDevicesResponse.self, from: data)
                applyLoadedDevices(decoded.devices)
                return
            } catch {
                lastErrorMessage = "Could not load Alexa devices: \(error.localizedDescription)"
            }
        }
    }

    private func fetchBootstrapCustomerIdIfNeeded() async {
        guard accountCustomerId == nil else { return }
        let region = authManager.region
        let urls: [URL] = [
            URL(string: "https://\(region.webHost)/api/bootstrap?version=0")!,
            region.alexaBaseURL.appendingPathComponent("api/bootstrap")
        ]
        for url in urls {
            guard let request = try? buildAuthenticatedRequest(url: url, method: "GET"),
                  let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let auth = json["authentication"] as? [String: Any],
                  let customerId = auth["customerId"] as? String,
                  !customerId.isEmpty else {
                continue
            }
            self.accountCustomerId = customerId
            return
        }
    }

    private func applyLoadedDevices(_ devices: [AlexaDevice]) {
        self.allDevices = devices
        if self.accountCustomerId == nil {
            self.accountCustomerId = devices.first(where: { !$0.isSpeakerGroup })?.deviceOwnerCustomerId
                ?? devices.first?.deviceOwnerCustomerId
        }
        self.speakerGroups = devices
            .filter { $0.isSpeakerGroup }
            .sorted { $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending }

        self.individualSpeakers = devices
            .filter { !$0.isSpeakerGroup && $0.isPlayableSpeaker }
            .sorted { $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending }

        PlaybackCoordinator.shared.restoreSavedSpeakerIfNeeded()
    }

    /// Returns human-readable names of the individual Echo speakers inside a Multi-Room speaker group
    func memberNames(for group: AlexaDevice) -> [String] {
        guard !group.clusterMembers.isEmpty else { return [] }
        let bySerial = Dictionary(uniqueKeysWithValues: allDevices.map { ($0.serialNumber, $0.accountName) })
        return group.clusterMembers.compactMap { bySerial[$0] }
    }

    /// Discovers active media playback sessions across the household via `/api/np/list-media-sessions`.
    /// Returns devices that are currently streaming or active.
    func fetchActiveHouseholdSessions() async -> [AlexaDevice] {
        if authManager.isDemoMode {
            return speakerGroups.filter { $0.accountName.localizedCaseInsensitiveContains("downstairs") }
        }

        await authManager.fetchCSRFTokenIfNeeded()
        let region = authManager.region
        let url = URL(string: "https://\(region.webHost)/api/np/list-media-sessions")!

        guard let request = try? buildAuthenticatedRequest(url: url, method: "GET"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = json["mediaSessionList"] as? [[String: Any]] else {
            return []
        }

        var activeSerials: Set<String> = []
        for session in sessions {
            if let dsn = session["deviceSerialNumber"] as? String {
                activeSerials.insert(dsn)
            }
            if let clusterMembers = session["clusterMembers"] as? [String] {
                activeSerials.formUnion(clusterMembers)
            }
        }

        return allDevices.filter { activeSerials.contains($0.serialNumber) }
    }

    /// Returns the actual `AlexaDevice` member objects inside a Multi-Room speaker group
    func memberDevices(for group: AlexaDevice) -> [AlexaDevice] {
        guard group.isSpeakerGroup else { return [group] }
        let matches = allDevices.filter { group.clusterMembers.contains($0.serialNumber) }
        return matches.isEmpty ? individualSpeakers : matches
    }

    // MARK: - Direct Apple Music / Amazon Music Playback on Echo or Speaker Group

    func playMediaItem(
        _ item: PlayableMediaItem,
        customPhraseOverride: String? = nil,
        providerPreference: AlexaMusicProviderPreference = .appleMusic,
        on targetDevice: AlexaDevice
    ) async throws {
        if let override = customPhraseOverride, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await playAppleMusic(
                searchPhrase: override,
                fallbackPhrases: item.alexaCandidatePhrases,
                providerPreference: providerPreference,
                on: targetDevice
            )
        } else {
            let candidates = item.alexaCandidatePhrases
            try await playAppleMusic(
                searchPhrase: candidates.first ?? item.title,
                fallbackPhrases: Array(candidates.dropFirst()),
                providerPreference: providerPreference,
                on: targetDevice
            )
        }
    }

    /// Sends a raw text/voice command string (e.g., "stop", "pause", "volume 30", "play Anirudh songs") directly to Alexa
    /// Uses `Alexa.TextCommand` (`skillId: amzn1.ask.1p.tellalexa`, same as alexapy / alexa_media_player) with fallback to `Alexa.VoiceCommand`.
    func sendRawVoiceCommand(_ commandText: String, to targetDevice: AlexaDevice) async throws {
        if authManager.isDemoMode { return }
        await authManager.fetchCSRFTokenIfNeeded()
        await fetchBootstrapCustomerIdIfNeeded()

        let region = authManager.region
        let locale = region.defaultLocale
        let physicalDevice = resolvePhysicalSpeaker(for: targetDevice)
        let customerId = accountCustomerId ?? physicalDevice.deviceOwnerCustomerId

        let effectiveText: String
        if targetDevice.isSpeakerGroup && !commandText.localizedCaseInsensitiveContains(targetDevice.accountName) {
            effectiveText = "\(commandText) on \(targetDevice.accountName)"
        } else {
            effectiveText = commandText
        }

        let textPayload: [String: Any] = [
            "deviceType": physicalDevice.deviceType,
            "deviceSerialNumber": physicalDevice.serialNumber,
            "customerId": customerId,
            "locale": locale,
            "text": effectiveText
        ]

        let textCommandNode = try await executeBehaviorNode(
            nodeType: "Alexa.TextCommand",
            skillId: "amzn1.ask.1p.tellalexa",
            operationPayload: textPayload,
            encodePayloadAsString: false
        )
        if textCommandNode.succeeded {
            return
        }

        _ = try await executeBehaviorNode(
            nodeType: "Alexa.VoiceCommand",
            operationPayload: textPayload,
            encodePayloadAsString: false
        )
    }

    func setDeviceVolume(_ level: Int, for speaker: AlexaDevice) async {
        if authManager.isDemoMode { return }
        await authManager.fetchCSRFTokenIfNeeded()
        await fetchBootstrapCustomerIdIfNeeded()

        let clamped = max(0, min(100, level))
        let region = authManager.region
        let locale = region.defaultLocale
        let customerId = accountCustomerId ?? speaker.deviceOwnerCustomerId

        let volPayload: [String: Any] = [
            "deviceType": speaker.deviceType,
            "deviceSerialNumber": speaker.serialNumber,
            "customerId": customerId,
            "locale": locale,
            "value": String(clamped)
        ]
        _ = try? await executeBehaviorNode(
            nodeType: "Alexa.DeviceControls.Volume",
            operationPayload: volPayload,
            encodePayloadAsString: false
        )
    }

    func playAppleMusic(
        searchPhrase: String,
        fallbackPhrases: [String] = [],
        providerPreference: AlexaMusicProviderPreference = .appleMusic,
        on targetDevice: AlexaDevice
    ) async throws {
        if authManager.isDemoMode {
            throw AlexaAPIError(
                message: "Demo Mode is active (\(targetDevice.accountName) is a simulated speaker). Open Speakers → Disconnect / Exit Demo Mode → Sign in with Amazon."
            )
        }

        await authManager.fetchCSRFTokenIfNeeded()
        await fetchBootstrapCustomerIdIfNeeded()

        let region = authManager.region
        let locale = region.defaultLocale

        let allPhrases = ([searchPhrase] + fallbackPhrases)
            .map { $0.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let primaryPhrase = allPhrases.first ?? searchPhrase
        let (executionDevice, effectivePrimaryPhrase) = resolveExecutionTarget(for: targetDevice, basePhrase: primaryPhrase)
        let customerId = accountCustomerId ?? executionDevice.deviceOwnerCustomerId

        var lastStatus: Int = 0
        var lastBodySnippet: String = ""

        // =========================================================================
        // PHASE 1: Direct Apple Music Execution (for .appleMusic and .auto)
        // =========================================================================
        if providerPreference != .amazonMusic {
            let appleSuffix = providerPreference.naturalVoiceSuffix(for: primaryPhrase)

            // Strategy 1: Alexa.TextCommand ("play <phrase> from Apple Music [on GroupName]")
            // Routed through amzn1.ask.1p.tellalexa — forces Alexa's cloud to query the official Apple Music skill
            // rather than defaulting to Amazon Music, and renders Apple Music branding on Echo Show.
            let appleCommandText: String
            if targetDevice.isSpeakerGroup {
                appleCommandText = "play \(primaryPhrase) \(appleSuffix) on \(targetDevice.accountName)"
            } else {
                appleCommandText = "play \(primaryPhrase) \(appleSuffix)"
            }

            let appleTextPayload: [String: Any] = [
                "deviceType": executionDevice.deviceType,
                "deviceSerialNumber": executionDevice.serialNumber,
                "customerId": customerId,
                "locale": locale,
                "text": appleCommandText
            ]

            let textCmdRes = try await executeBehaviorNode(
                nodeType: "Alexa.TextCommand",
                skillId: "amzn1.ask.1p.tellalexa",
                operationPayload: appleTextPayload,
                encodePayloadAsString: false
            )
            if textCmdRes.succeeded {
                return
            }
            lastStatus = textCmdRes.statusCode
            lastBodySnippet = textCmdRes.responseSnippet

            // Strategy 2: Alexa.Music.PlaySearchPhrase with "APPLE_MUSIC"
            let appleMusicPayload = await validateOrBuildMusicPayload(
                phrase: effectivePrimaryPhrase,
                providerId: "APPLE_MUSIC",
                device: executionDevice,
                customerId: customerId,
                locale: locale
            )

            // Try standard routine String encoding
            if let strRes = try? await executeBehaviorNode(
                nodeType: "Alexa.Music.PlaySearchPhrase",
                operationPayload: appleMusicPayload,
                encodePayloadAsString: true
            ), strRes.succeeded {
                return
            }

            // Try JSON object encoding
            if let objRes = try? await executeBehaviorNode(
                nodeType: "Alexa.Music.PlaySearchPhrase",
                operationPayload: appleMusicPayload,
                encodePayloadAsString: false
            ), objRes.succeeded {
                return
            }

            // Strategy 3: Alexa.VoiceCommand with Apple Music clause
            if let voiceRes = try? await executeBehaviorNode(
                nodeType: "Alexa.VoiceCommand",
                operationPayload: appleTextPayload,
                encodePayloadAsString: false
            ), voiceRes.succeeded {
                return
            }

            // Strategy 4: Try candidate fallback phrases (e.g. without soundtrack tag, or clean title by artist)
            for altPhrase in allPhrases.dropFirst() {
                let altSuffix = providerPreference.naturalVoiceSuffix(for: altPhrase)
                let altCmdText: String
                if targetDevice.isSpeakerGroup {
                    altCmdText = "play \(altPhrase) \(altSuffix) on \(targetDevice.accountName)"
                } else {
                    altCmdText = "play \(altPhrase) \(altSuffix)"
                }
                var altPayload = appleTextPayload
                altPayload["text"] = altCmdText
                if let altRes = try? await executeBehaviorNode(
                    nodeType: "Alexa.TextCommand",
                    skillId: "amzn1.ask.1p.tellalexa",
                    operationPayload: altPayload,
                    encodePayloadAsString: false
                ), altRes.succeeded {
                    return
                }
            }
        }

        // =========================================================================
        // PHASE 2: Amazon Music (ONLY if user selected .amazonMusic OR (.auto AND Apple Music failed))
        // =========================================================================
        if providerPreference == .amazonMusic || providerPreference == .auto {
            let amazonMusicPayload = await validateOrBuildMusicPayload(
                phrase: effectivePrimaryPhrase,
                providerId: "AMAZON_MUSIC",
                device: executionDevice,
                customerId: customerId,
                locale: locale
            )

            if let amzRes = try? await executeBehaviorNode(
                nodeType: "Alexa.Music.PlaySearchPhrase",
                operationPayload: amazonMusicPayload,
                encodePayloadAsString: false
            ), amzRes.succeeded {
                return
            }

            let amzCmdText: String
            if targetDevice.isSpeakerGroup {
                amzCmdText = "play \(primaryPhrase) on Amazon Music on \(targetDevice.accountName)"
            } else {
                amzCmdText = "play \(primaryPhrase) on Amazon Music"
            }
            let amzPayload: [String: Any] = [
                "deviceType": executionDevice.deviceType,
                "deviceSerialNumber": executionDevice.serialNumber,
                "customerId": customerId,
                "locale": locale,
                "text": amzCmdText
            ]
            if let amzTextRes = try? await executeBehaviorNode(
                nodeType: "Alexa.TextCommand",
                skillId: "amzn1.ask.1p.tellalexa",
                operationPayload: amzPayload,
                encodePayloadAsString: false
            ), amzTextRes.succeeded {
                return
            }
        }

        let detail = lastBodySnippet.isEmpty
            ? "HTTP \(lastStatus)"
            : "HTTP \(lastStatus): \(lastBodySnippet.prefix(120))"
        let helpTip = providerPreference == .appleMusic
            ? "\n\nTip: To stream Apple Music, ensure the Apple Music skill is enabled and linked to your Apple ID in the Amazon Alexa app (More → Settings → Music & Podcasts → Apple Music, and set as Default Service)."
            : ""
        throw AlexaAPIError(
            message: "Alexa could not start playback on \(targetDevice.accountName) (\(detail)).\(helpTip)"
        )
    }

    private func executeBehaviorNode(
        nodeType: String,
        skillId: String? = nil,
        operationPayload: [String: Any],
        encodePayloadAsString: Bool
    ) async throws -> (succeeded: Bool, statusCode: Int, responseSnippet: String) {
        let payloadValue: Any
        if encodePayloadAsString,
           let data = try? JSONSerialization.data(withJSONObject: operationPayload),
           let str = String(data: data, encoding: .utf8) {
            payloadValue = str
        } else {
            payloadValue = operationPayload
        }

        var startNode: [String: Any] = [
            "@type": "com.amazon.alexa.behaviors.model.OpaquePayloadOperationNode",
            "type": nodeType,
            "operationPayload": payloadValue
        ]
        if let skillId {
            startNode["skillId"] = skillId
        }

        let sequenceDict: [String: Any] = [
            "@type": "com.amazon.alexa.behaviors.model.Sequence",
            "startNode": startNode
        ]

        guard let sequenceData = try? JSONSerialization.data(withJSONObject: sequenceDict),
              let sequenceJsonString = String(data: sequenceData, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }

        let previewBody: [String: Any] = [
            "behaviorId": "PREVIEW",
            "sequenceJson": sequenceJsonString,
            "status": "ENABLED"
        ]

        let region = authManager.region
        let candidatePreviewURLs: [URL] = [
            URL(string: "https://\(region.webHost)/api/behaviors/preview")!,
            region.alexaBaseURL.appendingPathComponent("api/behaviors/preview")
        ]

        var lastCode = 0
        var lastSnippet = ""

        for previewURL in candidatePreviewURLs {
            var request = try buildAuthenticatedRequest(url: previewURL, method: "POST")
            request.httpBody = try JSONSerialization.data(withJSONObject: previewBody)

            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse {
                lastCode = http.statusCode
                lastSnippet = String(data: data, encoding: .utf8) ?? ""
                if (200...299).contains(http.statusCode) {
                    return (true, http.statusCode, "")
                }
            }
        }

        return (false, lastCode, lastSnippet)
    }

    /// Executes multiple behavior nodes in parallel using `com.amazon.alexa.behaviors.model.ParallelNode`
    func executeParallelBehaviorNodes(nodes: [[String: Any]]) async throws -> Bool {
        if authManager.isDemoMode { return true }
        let parallelDict: [String: Any] = [
            "@type": "com.amazon.alexa.behaviors.model.Sequence",
            "startNode": [
                "@type": "com.amazon.alexa.behaviors.model.ParallelNode",
                "nodes": nodes
            ]
        ]

        guard let sequenceData = try? JSONSerialization.data(withJSONObject: parallelDict),
              let sequenceJsonString = String(data: sequenceData, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }

        let previewBody: [String: Any] = [
            "behaviorId": "PREVIEW",
            "sequenceJson": sequenceJsonString,
            "status": "ENABLED"
        ]

        let region = authManager.region
        let previewURL = URL(string: "https://\(region.webHost)/api/behaviors/preview")!
        var request = try buildAuthenticatedRequest(url: previewURL, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: previewBody)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            return true
        }
        return false
    }

    private func resolveExecutionTarget(for device: AlexaDevice, basePhrase: String) -> (AlexaDevice, String) {
        guard device.isSpeakerGroup else {
            return (device, basePhrase)
        }

        if let memberSerial = device.clusterMembers.first,
           let memberDevice = allDevices.first(where: { $0.serialNumber == memberSerial && $0.online }) {
            return (memberDevice, "\(basePhrase) on \(device.accountName)")
        }

        if let anyOnlineSpeaker = individualSpeakers.first(where: { $0.online }) {
            return (anyOnlineSpeaker, "\(basePhrase) on \(device.accountName)")
        }

        return (device, basePhrase)
    }

    /// Resolves a physical Echo speaker that can execute Behavior / Transport commands on behalf of `device`
    private func resolvePhysicalSpeaker(for device: AlexaDevice) -> AlexaDevice {
        guard device.isSpeakerGroup else { return device }
        if let memberSerial = device.clusterMembers.first,
           let memberDevice = allDevices.first(where: { $0.serialNumber == memberSerial && $0.online }) {
            return memberDevice
        }
        if let anyOnlineSpeaker = individualSpeakers.first(where: { $0.online }) {
            return anyOnlineSpeaker
        }
        return device
    }

    /// Resolves all physical member speakers inside a Multi-Room speaker group
    private func resolveGroupMemberDevices(for device: AlexaDevice) -> [AlexaDevice] {
        guard device.isSpeakerGroup else { return [device] }
        let members = allDevices.filter { device.clusterMembers.contains($0.serialNumber) && $0.online }
        if !members.isEmpty {
            return members
        }
        return [resolvePhysicalSpeaker(for: device)]
    }

    private func validateOrBuildMusicPayload(
        phrase: String,
        providerId: String,
        device: AlexaDevice,
        customerId: String,
        locale: String
    ) async -> [String: Any] {
        let basePayload: [String: Any] = [
            "deviceType": device.deviceType,
            "deviceSerialNumber": device.serialNumber,
            "customerId": customerId,
            "locale": locale,
            "musicProviderId": providerId,
            "searchPhrase": phrase,
            "sanitizedSearchPhrase": phrase.lowercased()
        ]

        let region = authManager.region
        let candidateValidateURLs: [URL] = [
            URL(string: "https://\(region.webHost)/api/behaviors/automations/validate")!,
            region.alexaBaseURL.appendingPathComponent("api/behaviors/automations/validate")
        ]

        guard let innerPayloadData = try? JSONSerialization.data(withJSONObject: basePayload),
              let innerPayloadString = String(data: innerPayloadData, encoding: .utf8) else {
            return basePayload
        }

        let validateBody: [String: Any] = [
            "type": "Alexa.Music.PlaySearchPhrase",
            "operationPayload": innerPayloadString
        ]

        for validateURL in candidateValidateURLs {
            do {
                var request = try buildAuthenticatedRequest(url: validateURL, method: "POST")
                request.httpBody = try JSONSerialization.data(withJSONObject: validateBody)
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let validPayloadDict = json["operationPayload"] as? [String: Any] {
                        var merged = validPayloadDict
                        merged["deviceType"] = device.deviceType
                        merged["deviceSerialNumber"] = device.serialNumber
                        merged["customerId"] = customerId
                        merged["locale"] = locale
                        return merged
                    } else if let validPayloadString = json["operationPayload"] as? String,
                              let strData = validPayloadString.data(using: .utf8),
                              let parsedDict = try? JSONSerialization.jsonObject(with: strData) as? [String: Any] {
                        var merged = parsedDict
                        merged["deviceType"] = device.deviceType
                        merged["deviceSerialNumber"] = device.serialNumber
                        merged["customerId"] = customerId
                        merged["locale"] = locale
                        return merged
                    }
                }
            } catch {
                continue
            }
        }

        return basePayload
    }

    // MARK: - Transport & Volume Control

    func sendTransportCommand(_ command: AlexaTransportCommand, to device: AlexaDevice) async throws {
        if authManager.isDemoMode {
            return
        }

        await authManager.fetchCSRFTokenIfNeeded()
        await fetchBootstrapCustomerIdIfNeeded()

        let region = authManager.region
        let locale = region.defaultLocale
        let physicalDevice = resolvePhysicalSpeaker(for: device)
        let memberDevices = resolveGroupMemberDevices(for: device)
        let customerId = accountCustomerId ?? physicalDevice.deviceOwnerCustomerId

        let npTargets: [AlexaDevice] = device.isSpeakerGroup ? ([device] + memberDevices) : [device]
        let baseHosts = [region.webHost, region.alexaBaseURL.host ?? region.webHost]
        var anySucceeded = false

        for target in npTargets {
            for host in baseHosts {
                var components = URLComponents(string: "https://\(host)/api/np/command")!
                components.queryItems = [
                    URLQueryItem(name: "deviceSerialNumber", value: target.serialNumber),
                    URLQueryItem(name: "deviceType", value: target.deviceType)
                ]

                guard let url = components.url,
                      var request = try? buildAuthenticatedRequest(url: url, method: "POST"),
                      let body = try? JSONSerialization.data(withJSONObject: command.payloadJSON) else {
                    continue
                }
                request.httpBody = body

                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse,
                   (200...299).contains(http.statusCode) {
                    anySucceeded = true
                    break
                }
            }
        }

        switch command {
        case .volume(let level):
            let clamped = max(0, min(100, level))
            for member in memberDevices {
                let volPayload: [String: Any] = [
                    "deviceType": member.deviceType,
                    "deviceSerialNumber": member.serialNumber,
                    "customerId": customerId,
                    "locale": locale,
                    "value": String(clamped)
                ]
                if let res = try? await executeBehaviorNode(
                    nodeType: "Alexa.DeviceControls.Volume",
                    operationPayload: volPayload,
                    encodePayloadAsString: false
                ), res.succeeded {
                    anySucceeded = true
                }
            }

        case .pause:
            let text = device.isSpeakerGroup ? "stop playing on \(device.accountName)" : "pause"
            let pausePayload: [String: Any] = [
                "deviceType": physicalDevice.deviceType,
                "deviceSerialNumber": physicalDevice.serialNumber,
                "customerId": customerId,
                "locale": locale,
                "text": text
            ]
            let res = try await executeBehaviorNode(
                nodeType: "Alexa.VoiceCommand",
                operationPayload: pausePayload,
                encodePayloadAsString: false
            )
            if res.succeeded { anySucceeded = true }

        case .play:
            let text = device.isSpeakerGroup ? "resume on \(device.accountName)" : "resume"
            let resumePayload: [String: Any] = [
                "deviceType": physicalDevice.deviceType,
                "deviceSerialNumber": physicalDevice.serialNumber,
                "customerId": customerId,
                "locale": locale,
                "text": text
            ]
            let res = try await executeBehaviorNode(
                nodeType: "Alexa.VoiceCommand",
                operationPayload: resumePayload,
                encodePayloadAsString: false
            )
            if res.succeeded { anySucceeded = true }

        case .next:
            let nextPayload: [String: Any] = [
                "deviceType": physicalDevice.deviceType,
                "deviceSerialNumber": physicalDevice.serialNumber,
                "customerId": customerId,
                "locale": locale,
                "text": "next song"
            ]
            let res = try await executeBehaviorNode(
                nodeType: "Alexa.VoiceCommand",
                operationPayload: nextPayload,
                encodePayloadAsString: false
            )
            if res.succeeded { anySucceeded = true }

        case .previous:
            let prevPayload: [String: Any] = [
                "deviceType": physicalDevice.deviceType,
                "deviceSerialNumber": physicalDevice.serialNumber,
                "customerId": customerId,
                "locale": locale,
                "text": "previous song"
            ]
            let res = try await executeBehaviorNode(
                nodeType: "Alexa.VoiceCommand",
                operationPayload: prevPayload,
                encodePayloadAsString: false
            )
            if res.succeeded { anySucceeded = true }

        case .shuffle(let enabled):
            let shufflePayload: [String: Any] = [
                "deviceType": physicalDevice.deviceType,
                "deviceSerialNumber": physicalDevice.serialNumber,
                "customerId": customerId,
                "locale": locale,
                "text": enabled ? "shuffle on" : "shuffle off"
            ]
            let res = try await executeBehaviorNode(
                nodeType: "Alexa.VoiceCommand",
                operationPayload: shufflePayload,
                encodePayloadAsString: false
            )
            if res.succeeded { anySucceeded = true }
        }

        if !anySucceeded {
            throw AlexaAPIError(message: "Could not send transport command to \(device.accountName).")
        }
    }

    // MARK: - Deep Live Now Playing Inspection (/api/np/player + /api/media/state across Group & All Member Speakers)

    func fetchLiveSpeakerReport(for device: AlexaDevice) async -> AlexaLiveTrackReport? {
        if authManager.isDemoMode {
            return nil
        }

        let region = authManager.region
        let memberDevices = resolveGroupMemberDevices(for: device)
        // Check the group device first, then every physical member speaker, then any online Echo speaker
        var candidateDevices: [AlexaDevice] = [device]
        for member in memberDevices where !candidateDevices.contains(where: { $0.serialNumber == member.serialNumber }) {
            candidateDevices.append(member)
        }
        for speaker in individualSpeakers where speaker.online && !candidateDevices.contains(where: { $0.serialNumber == speaker.serialNumber }) {
            candidateDevices.append(speaker)
        }

        let baseHosts = [region.webHost, region.alexaBaseURL.host ?? region.webHost]
        var fallbackReport: AlexaLiveTrackReport?

        for target in candidateDevices {
            for host in baseHosts {
                // 1. Query /api/np/player
                if let report = await queryNPPlayerEndpoint(host: host, target: target) {
                    if report.state == "PLAYING" && !report.title.isEmpty {
                        return report
                    }
                    if fallbackReport == nil && !report.title.isEmpty {
                        fallbackReport = report
                    }
                }

                // 2. Query /api/media/state (often populated on individual Echo speakers when WHA group is playing)
                if let mediaReport = await queryMediaStateEndpoint(host: host, target: target) {
                    if mediaReport.state == "PLAYING" && !mediaReport.title.isEmpty {
                        return mediaReport
                    }
                    if fallbackReport == nil && !mediaReport.title.isEmpty {
                        fallbackReport = mediaReport
                    }
                }
            }
        }

        return fallbackReport
    }

    private func queryNPPlayerEndpoint(host: String, target: AlexaDevice) async -> AlexaLiveTrackReport? {
        var components = URLComponents(string: "https://\(host)/api/np/player")!
        components.queryItems = [
            URLQueryItem(name: "deviceSerialNumber", value: target.serialNumber),
            URLQueryItem(name: "deviceType", value: target.deviceType),
            URLQueryItem(name: "screenWidth", value: "1392")
        ]

        guard let url = components.url,
              let request = try? buildAuthenticatedRequest(url: url, method: "GET"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let playerInfo = json["playerInfo"] as? [String: Any] else {
            return nil
        }

        let state = (playerInfo["state"] as? String) ?? "IDLE"
        let infoText = playerInfo["infoText"] as? [String: Any]
        let title = (infoText?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let artist = (infoText?["subText1"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let album = (infoText?["subText2"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let providerDict = playerInfo["provider"] as? [String: Any]
        let providerName = providerDict?["providerName"] as? String

        let mainArt = playerInfo["mainArt"] as? [String: Any]
        let artURLString = (mainArt?["url"] as? String)?.replacingOccurrences(of: "http://", with: "https://")
        let artURL = artURLString.flatMap { URL(string: $0) }

        let progressDict = playerInfo["progress"] as? [String: Any]
        let mediaProgress = progressDict?["mediaProgress"] as? Double
        let mediaLength = progressDict?["mediaLength"] as? Double

        let volumeDict = playerInfo["volume"] as? [String: Any]
        let volume = volumeDict?["volume"] as? Int

        guard !title.isEmpty || state == "PLAYING" else { return nil }

        return AlexaLiveTrackReport(
            title: title,
            artist: artist,
            album: album,
            providerName: providerName,
            state: state,
            artworkURL: artURL,
            mediaProgress: mediaProgress,
            mediaLength: mediaLength,
            volume: volume,
            reportingSpeakerName: target.accountName
        )
    }

    private func queryMediaStateEndpoint(host: String, target: AlexaDevice) async -> AlexaLiveTrackReport? {
        var components = URLComponents(string: "https://\(host)/api/media/state")!
        components.queryItems = [
            URLQueryItem(name: "deviceSerialNumber", value: target.serialNumber),
            URLQueryItem(name: "deviceType", value: target.deviceType)
        ]

        guard let url = components.url,
              let request = try? buildAuthenticatedRequest(url: url, method: "GET"),
              let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let currentState = (json["currentState"] as? String) ?? "IDLE"
        let queue = json["queue"] as? [[String: Any]]
        let firstItem = queue?.first

        let title = (firstItem?["title"] as? String)
            ?? (json["title"] as? String)
            ?? ""
        let artist = (firstItem?["artist"] as? String)
            ?? (json["artist"] as? String)
            ?? ""
        let album = (firstItem?["album"] as? String)
            ?? (json["album"] as? String)
        let providerName = (json["providerId"] as? String)
            ?? (firstItem?["providerName"] as? String)
        let artURLString = ((firstItem?["imageURL"] as? String) ?? (json["imageURL"] as? String))?
            .replacingOccurrences(of: "http://", with: "https://")
        let artURL = artURLString.flatMap { URL(string: $0) }
        let volume = json["volume"] as? Int
        let progressSeconds = (json["progressSeconds"] as? Double)

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        return AlexaLiveTrackReport(
            title: trimmedTitle,
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: album,
            providerName: providerName,
            state: currentState == "PLAYING" ? "PLAYING" : "PAUSED",
            artworkURL: artURL,
            mediaProgress: progressSeconds,
            mediaLength: nil,
            volume: volume,
            reportingSpeakerName: target.accountName
        )
    }

    // MARK: - Request Builder

    private func buildAuthenticatedRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let region = authManager.region

        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://\(region.webHost)/spa/index.html", forHTTPHeaderField: "Referer")
        request.setValue("https://\(region.webHost)", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
            forHTTPHeaderField: "User-Agent"
        )

        let cookieHeader = authManager.cookieHeaderString()
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let csrf = authManager.csrfToken
            ?? HTTPCookieStorage.shared.cookies?.first(where: { $0.name == "csrf" })?.value
            ?? ""
        request.setValue(csrf, forHTTPHeaderField: "csrf")

        return request
    }

    // MARK: - Demo Speakers for Instant Testing

    private func loadDemoDevices() {
        let demoSpeakers: [AlexaDevice] = [
            AlexaDevice(
                accountName: "Living Room Echo Studio",
                serialNumber: "DEMO_ECHO_LIVING_ROOM",
                deviceType: "A3RBAYBE7VM004",
                deviceFamily: "ECHO",
                deviceOwnerCustomerId: "DEMO_CUSTOMER",
                online: true,
                capabilities: ["AUDIO_PLAYER", "APPLE_MUSIC", "VOLUME_SETTING"],
                clusterMembers: [],
                parentClusters: ["DEMO_WHA_EVERYWHERE", "DEMO_WHA_DOWNSTAIRS"]
            ),
            AlexaDevice(
                accountName: "Kitchen Echo Show",
                serialNumber: "DEMO_ECHO_KITCHEN",
                deviceType: "A1NL4BVLQ4L3N3",
                deviceFamily: "KNIGHT",
                deviceOwnerCustomerId: "DEMO_CUSTOMER",
                online: true,
                capabilities: ["AUDIO_PLAYER", "APPLE_MUSIC", "VOLUME_SETTING"],
                clusterMembers: [],
                parentClusters: ["DEMO_WHA_EVERYWHERE", "DEMO_WHA_DOWNSTAIRS"]
            ),
            AlexaDevice(
                accountName: "Bedroom Echo Dot",
                serialNumber: "DEMO_ECHO_BEDROOM",
                deviceType: "A32DOYMUN6DTXA",
                deviceFamily: "ECHO",
                deviceOwnerCustomerId: "DEMO_CUSTOMER",
                online: true,
                capabilities: ["AUDIO_PLAYER", "APPLE_MUSIC", "VOLUME_SETTING"],
                clusterMembers: [],
                parentClusters: ["DEMO_WHA_EVERYWHERE", "DEMO_WHA_UPSTAIRS"]
            ),
            AlexaDevice(
                accountName: "Office Echo Pop",
                serialNumber: "DEMO_ECHO_OFFICE",
                deviceType: "A2H4LV5GIZ1JFT",
                deviceFamily: "ECHO",
                deviceOwnerCustomerId: "DEMO_CUSTOMER",
                online: true,
                capabilities: ["AUDIO_PLAYER", "APPLE_MUSIC"],
                clusterMembers: [],
                parentClusters: ["DEMO_WHA_EVERYWHERE", "DEMO_WHA_UPSTAIRS"]
            ),
            AlexaDevice(
                accountName: "Everywhere",
                serialNumber: "DEMO_WHA_EVERYWHERE",
                deviceType: "A3C9PE6TNYLTCH",
                deviceFamily: "WHA",
                deviceOwnerCustomerId: "DEMO_CUSTOMER",
                online: true,
                capabilities: ["AUDIO_PLAYER", "APPLE_MUSIC"],
                clusterMembers: [
                    "DEMO_ECHO_LIVING_ROOM",
                    "DEMO_ECHO_KITCHEN",
                    "DEMO_ECHO_BEDROOM",
                    "DEMO_ECHO_OFFICE"
                ],
                parentClusters: nil
            ),
            AlexaDevice(
                accountName: "Downstairs",
                serialNumber: "DEMO_WHA_DOWNSTAIRS",
                deviceType: "A3C9PE6TNYLTCH",
                deviceFamily: "WHA",
                deviceOwnerCustomerId: "DEMO_CUSTOMER",
                online: true,
                capabilities: ["AUDIO_PLAYER", "APPLE_MUSIC"],
                clusterMembers: [
                    "DEMO_ECHO_LIVING_ROOM",
                    "DEMO_ECHO_KITCHEN"
                ],
                parentClusters: nil
            ),
            AlexaDevice(
                accountName: "Upstairs",
                serialNumber: "DEMO_WHA_UPSTAIRS",
                deviceType: "A3C9PE6TNYLTCH",
                deviceFamily: "WHA",
                deviceOwnerCustomerId: "DEMO_CUSTOMER",
                online: true,
                capabilities: ["AUDIO_PLAYER", "APPLE_MUSIC"],
                clusterMembers: [
                    "DEMO_ECHO_BEDROOM",
                    "DEMO_ECHO_OFFICE"
                ],
                parentClusters: nil
            )
        ]

        applyLoadedDevices(demoSpeakers)
    }
}
