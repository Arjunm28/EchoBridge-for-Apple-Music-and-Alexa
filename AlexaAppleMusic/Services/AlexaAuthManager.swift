import Foundation
import WebKit
import Combine
import Security

@MainActor
final class AlexaAuthManager: ObservableObject {
    static let shared = AlexaAuthManager()

    @Published var isAuthenticated: Bool = false
    @Published var isDemoMode: Bool = false
    @Published var region: AmazonRegion {
        didSet {
            UserDefaults.standard.set(region.rawValue, forKey: Self.regionKey)
        }
    }
    @Published var csrfToken: String?

    private static let legacySavedCookiesKey = "alexa_saved_cookies_v1"
    private static let keychainService = "com.alexaapplemusic.auth"
    private static let keychainAccount = "alexa_session_cookies_v1"
    private static let regionKey = "alexa_selected_region_v1"

    private init() {
        let savedRegionRaw = UserDefaults.standard.string(forKey: Self.regionKey) ?? AmazonRegion.us.rawValue
        self.region = AmazonRegion(rawValue: savedRegionRaw) ?? .us
        restoreCookiesFromStorage()
    }

    // MARK: - Cookie Persistence

    func captureCookies(from cookieStore: WKHTTPCookieStore) async -> Bool {
        let allCookies = await cookieStore.allCookies()
        let domainSuffix = region.rawValue
        let amazonCookies = allCookies.filter { $0.domain.contains(domainSuffix) }

        // Only authenticated Amazon sessions issue x-main or at-main (or acb regional equivalents).
        let regionalSuffix = domainSuffix.replacingOccurrences(of: "amazon.", with: "")
        let hasAuthCookie = amazonCookies.contains { cookie in
            let name = cookie.name
            return (name == "x-main" ||
                    name == "at-main" ||
                    name == "x-acb\(regionalSuffix)" ||
                    name == "at-acb\(regionalSuffix)" ||
                    name == "sess-at-main" ||
                    name == "sess-at-acb\(regionalSuffix)") && !cookie.value.isEmpty
        }

        guard hasAuthCookie else { return false }

        for cookie in amazonCookies {
            HTTPCookieStorage.shared.setCookie(cookie)
            if cookie.name == "csrf" {
                self.csrfToken = cookie.value
            }
        }

        saveCookiesToStorage(amazonCookies)

        // Ensure we have a valid CSRF token by calling /api/language or /api/bootstrap
        if self.csrfToken == nil || self.csrfToken?.isEmpty == true {
            await fetchCSRFTokenIfNeeded()
        }

        self.isAuthenticated = true
        self.isDemoMode = false
        return true
    }

    func fetchCSRFTokenIfNeeded() async {
        // First check if csrf cookie is already in HTTPCookieStorage
        if let existingCSRF = HTTPCookieStorage.shared.cookies?.first(where: { $0.name == "csrf" && !$0.value.isEmpty }) {
            self.csrfToken = existingCSRF.value
            return
        }

        // Also check WKWebView's cookie store in case it was set there during login
        let wkCookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in wkCookies where cookie.domain.contains(region.rawValue) {
            HTTPCookieStorage.shared.setCookie(cookie)
            if cookie.name == "csrf" && !cookie.value.isEmpty {
                self.csrfToken = cookie.value
            }
        }
        if let token = self.csrfToken, !token.isEmpty {
            return
        }

        let candidateCSRFURLs: [URL] = [
            URL(string: "https://\(region.webHost)/api/language")!,
            URL(string: "https://\(region.webHost)/api/bootstrap?version=0")!,
            URL(string: "https://\(region.webHost)/api/users/me?platform=ios&version=2.2.556530.0")!,
            region.alexaBaseURL.appendingPathComponent("api/language"),
            region.alexaBaseURL.appendingPathComponent("api/bootstrap")
        ]

        let cookieHeader = cookieHeaderString()

        for url in candidateCSRFURLs {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("https://\(region.webHost)/spa/index.html", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
            if !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   let url = response.url {
                    var headerFields: [String: String] = [:]
                    for (k, v) in httpResponse.allHeaderFields {
                        headerFields[String(describing: k)] = String(describing: v)
                    }
                    let newCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
                    for cookie in newCookies {
                        HTTPCookieStorage.shared.setCookie(cookie)
                        if cookie.name == "csrf" && !cookie.value.isEmpty {
                            self.csrfToken = cookie.value
                        }
                    }
                }
                if self.csrfToken == nil,
                   let existingCSRF = HTTPCookieStorage.shared.cookies?.first(where: { $0.name == "csrf" && !$0.value.isEmpty }) {
                    self.csrfToken = existingCSRF.value
                }
                if let token = self.csrfToken, !token.isEmpty {
                    if let allCookies = HTTPCookieStorage.shared.cookies?.filter({ $0.domain.contains(region.rawValue) }) {
                        saveCookiesToStorage(allCookies)
                    }
                    return
                }
            } catch {
                continue
            }
        }

        // If Amazon still did not emit a csrf cookie, synthesize one and register it in HTTPCookieStorage
        // so that the Cookie header ("csrf=<val>") and HTTP header ("csrf: <val>") match, which satisfies Amazon's double-submit CSRF check.
        let fallbackCSRF = String(Int.random(in: 100_000_000...999_999_999))
        if let csrfCookie = HTTPCookie(properties: [
            .domain: ".\(region.rawValue)",
            .path: "/",
            .name: "csrf",
            .value: fallbackCSRF,
            .secure: "TRUE"
        ]) {
            HTTPCookieStorage.shared.setCookie(csrfCookie)
        }
        self.csrfToken = fallbackCSRF
    }

    private func saveCookiesToStorage(_ cookies: [HTTPCookie]) {
        let serializable: [[String: Any]] = cookies.compactMap { cookie in
            guard let props = cookie.properties else { return nil }
            var dict: [String: Any] = [:]
            for (key, value) in props {
                if let strVal = value as? String {
                    dict[key.rawValue] = strVal
                } else if let urlVal = value as? URL {
                    dict[key.rawValue] = urlVal.absoluteString
                } else if let dateVal = value as? Date {
                    dict[key.rawValue] = dateVal.timeIntervalSince1970
                } else if let numVal = value as? NSNumber {
                    dict[key.rawValue] = numVal
                }
            }
            return dict
        }

        if let data = try? JSONSerialization.data(withJSONObject: serializable, options: []) {
            saveKeychainData(data)
            UserDefaults.standard.removeObject(forKey: Self.legacySavedCookiesKey)
        }
    }

    private func restoreCookiesFromStorage() {
        var saved: [[String: Any]]?

        if let data = loadKeychainData(),
           let decoded = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
            saved = decoded
        } else if let legacySaved = UserDefaults.standard.array(forKey: Self.legacySavedCookiesKey) as? [[String: Any]],
                  !legacySaved.isEmpty {
            // Migrate existing plaintext UserDefaults cookies into the Keychain
            saved = legacySaved
            if let data = try? JSONSerialization.data(withJSONObject: legacySaved, options: []) {
                saveKeychainData(data)
            }
            UserDefaults.standard.removeObject(forKey: Self.legacySavedCookiesKey)
        }

        guard let cookieDicts = saved, !cookieDicts.isEmpty else {
            return
        }

        var restoredCookies: [HTTPCookie] = []
        for dict in cookieDicts {
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (k, v) in dict {
                let key = HTTPCookiePropertyKey(rawValue: k)
                if key == .expires, let timestamp = v as? TimeInterval {
                    props[key] = Date(timeIntervalSince1970: timestamp)
                } else {
                    props[key] = v
                }
            }
            if let cookie = HTTPCookie(properties: props) {
                restoredCookies.append(cookie)
            }
        }

        let regionalSuffix = region.rawValue.replacingOccurrences(of: "amazon.", with: "")
        let hasValidAuthCookie = restoredCookies.contains { cookie in
            let name = cookie.name
            return (name == "x-main" ||
                    name == "at-main" ||
                    name == "x-acb\(regionalSuffix)" ||
                    name == "at-acb\(regionalSuffix)" ||
                    name == "sess-at-main" ||
                    name == "sess-at-acb\(regionalSuffix)") && !cookie.value.isEmpty
        }

        guard hasValidAuthCookie else {
            deleteKeychainData()
            UserDefaults.standard.removeObject(forKey: Self.legacySavedCookiesKey)
            self.isAuthenticated = false
            return
        }

        for cookie in restoredCookies {
            HTTPCookieStorage.shared.setCookie(cookie)
            if cookie.name == "csrf" && !cookie.value.isEmpty {
                self.csrfToken = cookie.value
            }
        }

        self.isAuthenticated = true
    }

    // MARK: - Keychain Helpers

    private func saveKeychainData(_ data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadKeychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func deleteKeychainData() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    func cookieHeaderString() -> String {
        let domainSuffix = region.rawValue
        var cookies = (HTTPCookieStorage.shared.cookies ?? []).filter {
            $0.domain.contains(domainSuffix)
        }
        if let csrf = csrfToken, !csrf.isEmpty, !cookies.contains(where: { $0.name == "csrf" }) {
            if let csrfCookie = HTTPCookie(properties: [
                .domain: ".\(domainSuffix)",
                .path: "/",
                .name: "csrf",
                .value: csrf
            ]) {
                cookies.append(csrfCookie)
            }
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func enableDemoMode() {
        self.isDemoMode = true
        self.isAuthenticated = true
    }

    func signOut() {
        deleteKeychainData()
        UserDefaults.standard.removeObject(forKey: Self.legacySavedCookiesKey)
        if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies {
                HTTPCookieStorage.shared.deleteCookie(cookie)
            }
        }
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) {}
        self.csrfToken = nil
        self.isAuthenticated = false
        self.isDemoMode = false
    }
}
