import Foundation

// MARK: - Amazon Region Configuration

enum AmazonRegion: String, CaseIterable, Identifiable, Codable {
    case us = "amazon.com"
    case uk = "amazon.co.uk"
    case de = "amazon.de"
    case ca = "amazon.ca"
    case au = "amazon.com.au"
    case jp = "amazon.co.jp"
    case `in` = "amazon.in"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .us: return "United States (amazon.com)"
        case .uk: return "United Kingdom (amazon.co.uk)"
        case .de: return "Germany (amazon.de)"
        case .ca: return "Canada (amazon.ca)"
        case .au: return "Australia (amazon.com.au)"
        case .jp: return "Japan (amazon.co.jp)"
        case .in: return "India (amazon.in)"
        }
    }

    var alexaBaseURL: URL {
        switch self {
        case .us:
            return URL(string: "https://pitangui.amazon.com")!
        case .uk, .de, .in:
            return URL(string: "https://layla.amazon.\(rawValue.replacingOccurrences(of: "amazon.", with: ""))")!
        case .ca, .au, .jp:
            return URL(string: "https://alexa.\(rawValue)")!
        }
    }

    var webHost: String {
        "alexa.\(rawValue)"
    }

    var loginURL: URL {
        var components = URLComponents(string: "https://www.\(rawValue)/ap/signin")!
        components.queryItems = [
            URLQueryItem(name: "openid.pape.max_auth_age", value: "0"),
            URLQueryItem(name: "openid.return_to", value: "https://alexa.\(rawValue)/api/devices-v2/device?cached=true"),
            URLQueryItem(name: "openid.identity", value: "http://specs.openid.net/auth/2.0/identifier_select"),
            URLQueryItem(name: "openid.assoc_handle", value: assocHandle),
            URLQueryItem(name: "openid.mode", value: "checkid_setup"),
            URLQueryItem(name: "openid.claimed_id", value: "http://specs.openid.net/auth/2.0/identifier_select"),
            URLQueryItem(name: "openid.ns", value: "http://specs.openid.net/auth/2.0")
        ]
        return components.url!
    }

    private var assocHandle: String {
        switch self {
        case .us: return "amzn_dp_project_dee_ios"
        case .uk: return "amzn_dp_project_dee_ios_uk"
        case .de: return "amzn_dp_project_dee_ios_de"
        case .ca: return "amzn_dp_project_dee_ios_ca"
        case .au: return "amzn_dp_project_dee_ios_au"
        case .jp: return "amzn_dp_project_dee_ios_jp"
        case .in: return "amzn_dp_project_dee_ios_in"
        }
    }

    var defaultLocale: String {
        switch self {
        case .us: return "en-US"
        case .uk: return "en-GB"
        case .de: return "de-DE"
        case .ca: return "en-CA"
        case .au: return "en-AU"
        case .jp: return "ja-JP"
        case .in: return "en-IN"
        }
    }
}

// MARK: - Alexa Device Models

struct AlexaDevicesResponse: Codable {
    let devices: [AlexaDevice]
}

struct AlexaDevice: Codable, Identifiable, Hashable {
    let accountName: String
    let serialNumber: String
    let deviceType: String
    let deviceFamily: String
    let deviceOwnerCustomerId: String
    let online: Bool
    let capabilities: [String]
    let clusterMembers: [String]
    let parentClusters: [String]?

    var id: String { serialNumber }

    /// True when this device represents a Multi-Room Music (Whole Home Audio) speaker group
    var isSpeakerGroup: Bool {
        deviceFamily == "WHA" || !clusterMembers.isEmpty
    }

    /// True when this speaker is a Sonos speaker (e.g. Sonos Era 100, Beam, Arc, One) or third-party Alexa-enabled speaker
    var isSonosOrThirdPartySpeaker: Bool {
        if isSpeakerGroup { return false }
        let lowerName = accountName.lowercased()
        if lowerName.contains("sonos") || lowerName.contains("era") || lowerName.contains("beam") || lowerName.contains("roam") || lowerName.contains("move") {
            return true
        }
        return deviceFamily == "THIRD_PARTY_AVS_SONOS_BOOTLEG"
            || deviceFamily == "THIRD_PARTY_AVS_MEDIA_DISPLAY"
            || deviceFamily.hasPrefix("THIRD_PARTY_AVS")
    }

    /// True when this device is an individual Echo / Sonos / Alexa speaker capable of audio playback
    var isPlayableSpeaker: Bool {
        if isSpeakerGroup { return true }
        // Exclude phone apps (VOX), Fire TV sticks, and tablets unless they explicitly support audio player
        let strictlyExcludedFamilies: Set<String> = ["VOX", "FIRE_TV", "TABLET"]
        if strictlyExcludedFamilies.contains(deviceFamily) && !capabilities.contains("APPLE_MUSIC") {
            return false
        }
        let audioCapabilities: Set<String> = [
            "AUDIO_PLAYER",
            "APPLE_MUSIC",
            "MUSIC_SKILL",
            "TUNE_IN",
            "SALMON",
            "VOLUME_SETTING",
            "MICROPHONE"
        ]
        return !capabilities.filter { audioCapabilities.contains($0) }.isEmpty
            || deviceFamily == "ECHO"
            || deviceFamily == "KNIGHT"
            || deviceFamily == "ROOK"
            || deviceFamily.hasPrefix("THIRD_PARTY_AVS")
    }

    var sfSymbolName: String {
        if isSpeakerGroup {
            return "hifispeaker.2.fill"
        }
        if isSonosOrThirdPartySpeaker {
            return "hifispeaker.and.homepodmini.fill"
        }
        switch deviceFamily {
        case "KNIGHT":
            return "tv.and.mediabox"
        case "ROOK":
            return "clock.fill"
        case "ECHO":
            return "homepodmini.fill"
        default:
            return "hifispeaker.fill"
        }
    }
}

// MARK: - Playback Target Selection

enum PlaybackTarget: Identifiable, Hashable {
    case localDevice
    case alexaDevice(AlexaDevice)

    var id: String {
        switch self {
        case .localDevice:
            return "local_iphone"
        case .alexaDevice(let device):
            return device.serialNumber
        }
    }

    var displayName: String {
        switch self {
        case .localDevice:
            return "iPhone / AirPlay 2"
        case .alexaDevice(let device):
            return device.accountName
        }
    }

    var iconName: String {
        switch self {
        case .localDevice:
            return "airplayaudio"
        case .alexaDevice(let device):
            return device.sfSymbolName
        }
    }

    var isAlexaTarget: Bool {
        if case .alexaDevice = self { return true }
        return false
    }
}

// MARK: - Alexa Live Speaker Track Report

struct AlexaLiveTrackReport: Equatable {
    let title: String
    let artist: String
    let album: String?
    let providerName: String?
    let state: String // "PLAYING", "PAUSED", "IDLE"
    let artworkURL: URL?
    let mediaProgress: Double?
    let mediaLength: Double?
    let volume: Int?
    let reportingSpeakerName: String
}

// MARK: - Alexa Now Playing Response

struct AlexaPlayerInfoResponse: Codable {
    let playerInfo: AlexaPlayerInfo?
}

struct AlexaPlayerInfo: Codable {
    let state: String? // "PLAYING", "PAUSED", "IDLE"
    let infoText: AlexaInfoText?
    let mainArt: AlexaArt?
    let progress: AlexaProgress?
    let volume: AlexaVolume?
    let provider: AlexaProvider?
}

struct AlexaInfoText: Codable {
    let title: String?
    let subText1: String? // Artist
    let subText2: String? // Album
}

struct AlexaArt: Codable {
    let url: String?
}

struct AlexaProgress: Codable {
    let mediaLength: Double?
    let mediaProgress: Double?
}

struct AlexaVolume: Codable {
    let volume: Int?
    let muted: Bool?
}

struct AlexaProvider: Codable {
    let providerName: String?
}
