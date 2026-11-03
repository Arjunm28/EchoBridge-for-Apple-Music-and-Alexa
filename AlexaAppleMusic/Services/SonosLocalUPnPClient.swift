import Foundation

/// Fast local-network control for Sonos speakers (e.g. Sonos Era 100) on Port 1400 via UPnP SOAP.
/// Avoids cloud latency (<30ms local LAN execution) for volume and transport commands.
@MainActor
final class SonosLocalUPnPClient {
    static let shared = SonosLocalUPnPClient()

    private init() {}

    // MARK: - SOAP Call Helper

    private func sendSOAPRequest(
        ip: String,
        service: String,
        controlPath: String,
        action: String,
        bodyXML: String
    ) async throws -> String {
        let cleanIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIP.isEmpty, let url = URL(string: "http://\(cleanIP):1400\(controlPath)") else {
            throw URLError(.badURL)
        }

        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
            <s:Body>
                <u:\(action) xmlns:u="\(service)">
                    \(bodyXML)
                </u:\(action)>
            </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: url, timeoutInterval: 3.0)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = envelope.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - RenderingControl (Volume)

    func setVolume(_ volume: Int, ip: String) async throws {
        let clamped = max(0, min(100, volume))
        let body = """
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        <DesiredVolume>\(clamped)</DesiredVolume>
        """
        _ = try await sendSOAPRequest(
            ip: ip,
            service: "urn:schemas-upnp-org:service:RenderingControl:1",
            controlPath: "/MediaRenderer/RenderingControl/Control",
            action: "SetVolume",
            bodyXML: body
        )
    }

    func getVolume(ip: String) async throws -> Int? {
        let body = """
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        """
        let response = try await sendSOAPRequest(
            ip: ip,
            service: "urn:schemas-upnp-org:service:RenderingControl:1",
            controlPath: "/MediaRenderer/RenderingControl/Control",
            action: "GetVolume",
            bodyXML: body
        )
        if let match = response.range(of: "<CurrentVolume>")?.upperBound,
           let endMatch = response[match...].range(of: "</CurrentVolume>")?.lowerBound {
            let valString = String(response[match..<endMatch])
            return Int(valString)
        }
        return nil
    }

    // MARK: - AVTransport (Play, Pause, Next, Previous)

    func play(ip: String) async throws {
        let body = """
        <InstanceID>0</InstanceID>
        <Speed>1</Speed>
        """
        _ = try await sendSOAPRequest(
            ip: ip,
            service: "urn:schemas-upnp-org:service:AVTransport:1",
            controlPath: "/MediaRenderer/AVTransport/Control",
            action: "Play",
            bodyXML: body
        )
    }

    func pause(ip: String) async throws {
        let body = "<InstanceID>0</InstanceID>"
        _ = try await sendSOAPRequest(
            ip: ip,
            service: "urn:schemas-upnp-org:service:AVTransport:1",
            controlPath: "/MediaRenderer/AVTransport/Control",
            action: "Pause",
            bodyXML: body
        )
    }

    func next(ip: String) async throws {
        let body = "<InstanceID>0</InstanceID>"
        _ = try await sendSOAPRequest(
            ip: ip,
            service: "urn:schemas-upnp-org:service:AVTransport:1",
            controlPath: "/MediaRenderer/AVTransport/Control",
            action: "Next",
            bodyXML: body
        )
    }

    func previous(ip: String) async throws {
        let body = "<InstanceID>0</InstanceID>"
        _ = try await sendSOAPRequest(
            ip: ip,
            service: "urn:schemas-upnp-org:service:AVTransport:1",
            controlPath: "/MediaRenderer/AVTransport/Control",
            action: "Previous",
            bodyXML: body
        )
    }
}
