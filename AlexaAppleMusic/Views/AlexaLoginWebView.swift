import SwiftUI
import WebKit

struct AlexaLoginSheetView: View {
    @ObservedObject var authManager = AlexaAuthManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Text("Amazon Region:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Region", selection: $authManager.region) {
                        ForEach(AmazonRegion.allCases) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))

                Divider()

                AlexaWebViewRepresentable(
                    url: authManager.region.loginURL,
                    onLoginDetected: {
                        Task {
                            await AlexaAPIClient.shared.fetchDevices()
                            dismiss()
                        }
                    }
                )
            }
            .navigationTitle("Sign in to Amazon Alexa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Demo Mode") {
                        authManager.enableDemoMode()
                        Task {
                            await AlexaAPIClient.shared.fetchDevices()
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

struct AlexaWebViewRepresentable: UIViewRepresentable {
    let url: URL
    let onLoginDetected: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginDetected: onLoginDetected)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        context.coordinator.lastLoadedHost = url.host
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedHost != url.host {
            context.coordinator.lastLoadedHost = url.host
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onLoginDetected: () -> Void
        var lastLoadedHost: String?
        private var hasCompletedLogin = false

        init(onLoginDetected: @escaping () -> Void) {
            self.onLoginDetected = onLoginDetected
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !hasCompletedLogin else { return }
            guard let currentURL = webView.url else { return }

            let host = currentURL.host?.lowercased() ?? ""
            let path = currentURL.path.lowercased()

            // Stay open while on any Amazon /ap/* authentication, MFA, CVF, or captcha page
            let isAuthFlowPath = path.contains("/ap/") ||
                path.contains("signin") ||
                path.contains("mfa") ||
                path.contains("cvf") ||
                path.contains("forgotpassword") ||
                path.contains("register")

            guard !isAuthFlowPath else { return }

            // Only attempt cookie capture once redirected to the Alexa host or post-login return URL
            let isPostLoginDestination = host.hasPrefix("alexa.") ||
                host.hasPrefix("pitangui.") ||
                host.hasPrefix("layla.") ||
                path.contains("/api/devices-v2/device") ||
                path.contains("/spa/")

            guard isPostLoginDestination else { return }

            Task { @MainActor in
                let captured = await AlexaAuthManager.shared.captureCookies(
                    from: webView.configuration.websiteDataStore.httpCookieStore
                )
                if captured && !self.hasCompletedLogin {
                    self.hasCompletedLogin = true
                    self.onLoginDetected()
                }
            }
        }
    }
}
