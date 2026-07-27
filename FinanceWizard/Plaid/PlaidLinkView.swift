//
//  PlaidLinkView.swift
//  Finance Wizard
//
//  Opens Plaid Link in a WKWebView (no native LinkKit binary required).
//  On success, exchanges public_token and stores the Item.
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
                            onSuccess: { publicToken, metadata in
                                Task { await handleSuccess(publicToken: publicToken, metadata: metadata) }
                            },
                            onExit: { message in
                                if let message {
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
            let institution = (metadata["institution"] as? [String: Any])?["name"] as? String
                ?? "Linked bank"
            let accounts = (metadata["accounts"] as? [[String: Any]]) ?? []
            let accountNames: [String] = accounts.compactMap { acc in
                let name = acc["name"] as? String
                let mask = acc["mask"] as? String
                if let name, let mask, !mask.isEmpty {
                    return "\(name) ···\(mask)"
                }
                return name
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
}

// MARK: - WKWebView bridge

private struct PlaidLinkWebView: UIViewRepresentable {
    let linkToken: String
    var onSuccess: (_ publicToken: String, _ metadata: [String: Any]) -> Void
    var onExit: (_ message: String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSuccess: onSuccess, onExit: onExit)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "plaidBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        // Allow Plaid’s CDN scripts
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView

        let html = Self.htmlPage(linkToken: linkToken)
        webView.loadHTMLString(html, baseURL: URL(string: "https://cdn.plaid.com/")!)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Minimal hosted Link page that posts success/exit back to iOS.
    private static func htmlPage(linkToken: String) -> String {
        // Escape token for embedding in JS string
        let token = linkToken
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")

        return """
        <!DOCTYPE html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <script src="https://cdn.plaid.com/link/v2/stable/link-initialize.js"></script>
          <style>
            body { font-family: -apple-system, system-ui, sans-serif; margin: 0; padding: 24px;
                   background: #f2f2f7; color: #111; }
            #status { text-align: center; margin-top: 40px; color: #666; }
          </style>
        </head>
        <body>
          <div id="status">Opening Plaid Link…</div>
          <script>
            function post(msg) {
              try {
                window.webkit.messageHandlers.plaidBridge.postMessage(msg);
              } catch (e) {
                document.getElementById('status').innerText = 'Bridge error: ' + e;
              }
            }

            var handler = Plaid.create({
              token: '\(token)',
              onSuccess: function(public_token, metadata) {
                post({ type: 'success', public_token: public_token, metadata: metadata || {} });
              },
              onExit: function(err, metadata) {
                var message = null;
                if (err) {
                  message = err.display_message || err.error_message || err.error_code || 'Exited with error';
                }
                post({ type: 'exit', message: message, metadata: metadata || {} });
              },
              onEvent: function(eventName, metadata) {
                // no-op; available for debugging
              }
            });
            handler.open();
          </script>
        </body>
        </html>
        """
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onSuccess: (String, [String: Any]) -> Void
        var onExit: (String?) -> Void
        weak var webView: WKWebView?
        private var didFinish = false

        init(
            onSuccess: @escaping (String, [String: Any]) -> Void,
            onExit: @escaping (String?) -> Void
        ) {
            self.onSuccess = onSuccess
            self.onExit = onExit
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "plaidBridge",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            if didFinish { return }

            switch type {
            case "success":
                guard let publicToken = body["public_token"] as? String, !publicToken.isEmpty else {
                    didFinish = true
                    onExit("Missing public_token from Link.")
                    return
                }
                didFinish = true
                let metadata = body["metadata"] as? [String: Any] ?? [:]
                onSuccess(publicToken, metadata)
            case "exit":
                didFinish = true
                onExit(body["message"] as? String)
            default:
                break
            }
        }
    }
}
