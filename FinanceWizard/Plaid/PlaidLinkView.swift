//
//  PlaidLinkView.swift
//  Finance Wizard
//
//  Official Plaid Link *webview* flow (isWebview=true + plaidlink:// redirects).
//  Supports OAuth “Continue to Login” by keeping bank auth in-app and re-initializing
//  Link after the redirect_uri returns.
//

import SwiftUI
import WebKit

/// Full-screen sheet: create link_token → open Link → exchange → save Item.
struct PlaidLinkSheet: View {
    var onFinished: (Result<PlaidLinkedItem, Error>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var linkToken: String?
    @State private var errorMessage: String?

    private enum Phase {
        case loading
        case ready
        case exchanging
        case failed
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    ProgressView("Preparing Plaid Link…")
                case .ready:
                    if let linkToken {
                        PlaidLinkWebView(
                            linkToken: linkToken,
                            redirectURI: PlaidCredentialsStore.redirectURI,
                            onSuccess: { publicToken, metadata in
                                Task { await handleSuccess(publicToken: publicToken, metadata: metadata) }
                            },
                            onExit: { message in
                                if let message, !message.isEmpty {
                                    errorMessage = message
                                    phase = .failed
                                } else {
                                    dismiss()
                                }
                            }
                        )
                    }
                case .exchanging:
                    ProgressView("Saving linked bank…")
                case .failed:
                    ContentUnavailableView(
                        "Link failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage ?? "Unknown error")
                    )
                }
            }
            .navigationTitle("Link bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await prepareLink()
            }
        }
    }

    private func prepareLink() async {
        phase = .loading
        do {
            let token = try await PlaidAPIClient.createLinkToken()
            linkToken = token
            phase = .ready
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    private func handleSuccess(publicToken: String, metadata: [String: Any]) async {
        phase = .exchanging
        do {
            let exchanged = try await PlaidAPIClient.exchangePublicToken(publicToken)
            let institution = (metadata["institution_name"] as? String)
                ?? (metadata["institution"] as? [String: Any])?["name"] as? String
                ?? "Linked bank"

            // Webview “connected” may pass accounts as a JSON string
            var accountNames: [String] = []
            if let accounts = metadata["accounts"] as? [[String: Any]] {
                accountNames = accounts.compactMap { Self.accountLabel(from: $0) }
            } else if let accountsJSON = metadata["accounts"] as? String,
                      let data = accountsJSON.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                accountNames = parsed.compactMap { Self.accountLabel(from: $0) }
            }

            let item = PlaidLinkedItem(
                id: exchanged.itemID,
                accessToken: exchanged.accessToken,
                institutionName: institution,
                accountNames: accountNames,
                transactionsCursor: "",
                linkedAt: Date()
            )
            PlaidItemStore.upsert(item)
            onFinished(.success(item))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
            onFinished(.failure(error))
        }
    }

    private static func accountLabel(from acc: [String: Any]) -> String? {
        // Webview schema: meta.name / meta.number  OR name / mask
        let name = (acc["meta"] as? [String: Any])?["name"] as? String
            ?? acc["name"] as? String
        let mask = (acc["meta"] as? [String: Any])?["number"] as? String
            ?? acc["mask"] as? String
        if let name, let mask, !mask.isEmpty {
            return "\(name) ···\(mask)"
        }
        return name
    }
}

// MARK: - Official Link webview

/// Loads `cdn.plaid.com/link/v2/stable/link.html?isWebview=true&token=…`
/// and intercepts `plaidlink://` + OAuth redirect_uri navigations.
private struct PlaidLinkWebView: UIViewRepresentable {
    let linkToken: String
    let redirectURI: String
    var onSuccess: (_ publicToken: String, _ metadata: [String: Any]) -> Void
    var onExit: (_ message: String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            linkToken: linkToken,
            redirectURI: redirectURI,
            onSuccess: onSuccess,
            onExit: onExit
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Share cookies / session across OAuth hops in the same process
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        // Safari-like UA avoids some banks rejecting embedded “unsupported browser”
        webView.customUserAgent = Self.mobileSafariUserAgent

        context.coordinator.webView = webView
        webView.load(URLRequest(url: context.coordinator.initializationURL()))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    private static var mobileSafariUserAgent: String {
        // Realistic iOS Safari UA; empty/custom UAs cause OAuth “unsupported browser” on some banks
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let linkToken: String
        let redirectURI: String
        var onSuccess: (String, [String: Any]) -> Void
        var onExit: (String?) -> Void
        weak var webView: WKWebView?
        private var didFinish = false

        init(
            linkToken: String,
            redirectURI: String,
            onSuccess: @escaping (String, [String: Any]) -> Void,
            onExit: @escaping (String?) -> Void
        ) {
            self.linkToken = linkToken
            self.redirectURI = redirectURI
            self.onSuccess = onSuccess
            self.onExit = onExit
        }

        func initializationURL(receivedRedirectURI: String? = nil) -> URL {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "cdn.plaid.com"
            components.path = "/link/v2/stable/link.html"
            var items: [URLQueryItem] = [
                URLQueryItem(name: "isWebview", value: "true"),
                URLQueryItem(name: "isMobile", value: "true"),
                URLQueryItem(name: "token", value: linkToken)
            ]
            if let receivedRedirectURI {
                // Must be the full URL including oauth_state_id (Plaid docs)
                items.append(URLQueryItem(name: "receivedRedirectUri", value: receivedRedirectURI))
            }
            components.queryItems = items
            return components.url!
        }

        // MARK: WKUIDelegate — bank OAuth often uses window.open / target=_blank

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // Keep OAuth inside this webview so “Continue to Login” actually navigates
            // (returning nil without loading drops the click entirely).
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        // MARK: WKNavigationDelegate

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // 1) Link → app callbacks (plaidlink://connected|exit|event)
            if url.scheme?.lowercased() == "plaidlink" {
                handlePlaidLinkURL(url)
                decisionHandler(.cancel)
                return
            }

            // 2) OAuth return to our redirect_uri → re-init Link with receivedRedirectUri
            if matchesRedirectURI(url) {
                let reinit = initializationURL(receivedRedirectURI: url.absoluteString)
                webView.load(URLRequest(url: reinit))
                decisionHandler(.cancel)
                return
            }

            // 3) Explicit link taps for http(s) that leave the bank flow (e.g. “forgot password”)
            //    keep in-webview; only open Safari for non-http schemes we don't handle
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                decisionHandler(.allow)
                return
            }

            // Bank app deep links / tel / mailto — hand to the system
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func matchesRedirectURI(_ url: URL) -> Bool {
            guard let redirect = URL(string: redirectURI) else { return false }
            // Compare scheme + host + path (ignore query — oauth_state_id is appended)
            let urlPath = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
            let redirectPath = redirect.path.hasSuffix("/") ? String(redirect.path.dropLast()) : redirect.path
            let pathMatches = (urlPath == redirectPath)
                || (urlPath.isEmpty && redirectPath.isEmpty)
                || (urlPath == "/" && redirectPath.isEmpty)
                || (urlPath.isEmpty && redirectPath == "/")
            return url.scheme?.lowercased() == redirect.scheme?.lowercased()
                && url.host?.lowercased() == redirect.host?.lowercased()
                && pathMatches
        }

        private func handlePlaidLinkURL(_ url: URL) {
            if didFinish { return }
            let action = (url.host ?? "").lowercased()
            let params = queryParams(url)

            switch action {
            case "connected":
                didFinish = true
                guard let publicToken = params["public_token"], !publicToken.isEmpty else {
                    onExit("Link succeeded but no public_token was returned.")
                    return
                }
                // Flatten query params as metadata (institution_name, accounts, …)
                var metadata: [String: Any] = params
                onSuccess(publicToken, metadata)

            case "exit":
                didFinish = true
                let message = params["error_display_message"]
                    ?? params["error_message"]
                    ?? params["display_message"]
                // User cancelled without an error → silent dismiss
                if message == nil || message?.isEmpty == true {
                    onExit(nil)
                } else {
                    onExit(message)
                }

            case "event":
                // Optional: could surface OPEN_OAUTH etc. for debugging
                break

            default:
                break
            }
        }

        private func queryParams(_ url: URL) -> [String: String] {
            guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
                return [:]
            }
            var dict: [String: String] = [:]
            for item in items {
                dict[item.name] = item.value ?? ""
            }
            return dict
        }
    }
}
