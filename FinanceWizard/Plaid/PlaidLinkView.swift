//
//  PlaidLinkView.swift
//  Finance Wizard
//
//  Plaid Hosted Link in ASWebAuthenticationSession (webview Link is deprecated).
//  See https://plaid.com/docs/link/hosted-link/
//

import SwiftUI
import AuthenticationServices

/// Custom URL scheme for Hosted Link completion (not a Universal Link; not in Plaid Dashboard).
enum PlaidHostedLink {
    static let callbackScheme = "financewizard"
    static let completionRedirectURI = "financewizard://hosted-link-complete"
}

/// Sheet: create Hosted Link token → open secure browser session → poll for public_token → save Item.
struct PlaidLinkSheet: View {
    var onFinished: (Result<PlaidLinkedItem, Error>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .starting
    @State private var errorMessage: String?
    @State private var sessionController: HostedLinkSessionController?

    private enum Phase {
        case starting
        case waitingForUser
        case finishing
        case failed
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .starting:
                    ProgressView("Preparing Plaid Link…")
                case .waitingForUser:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Complete bank login in the browser window.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Text("If nothing appeared, check that pop-ups aren’t blocked, then try again.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                case .finishing:
                    ProgressView("Saving linked bank…")
                case .failed:
                    ContentUnavailableView(
                        "Link failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage ?? "Unknown error")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Link bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        sessionController?.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                await startHostedLink()
            }
        }
    }

    private func startHostedLink() async {
        phase = .starting
        do {
            let session = try await PlaidAPIClient.createHostedLinkSession()
            phase = .waitingForUser

            let controller = HostedLinkSessionController()
            sessionController = controller

            let callbackURL = try await controller.start(
                url: session.hostedLinkURL,
                callbackScheme: PlaidHostedLink.callbackScheme
            )

            // User cancelled the system browser sheet
            if callbackURL == nil {
                dismiss()
                return
            }

            phase = .finishing
            let success = try await PlaidAPIClient.waitForLinkSuccess(linkToken: session.linkToken)
            await completeWithSuccess(success)
        } catch {
            // ASWebAuthenticationSession cancel is reported as error
            if let authError = error as? ASWebAuthenticationSessionError,
               authError.code == .canceledLogin {
                dismiss()
                return
            }
            errorMessage = error.localizedDescription
            phase = .failed
            onFinished(.failure(error))
        }
    }

    private func completeWithSuccess(_ success: PlaidAPIClient.LinkSuccessPayload) async {
        do {
            let exchanged = try await PlaidAPIClient.exchangePublicToken(success.publicToken)
            let item = PlaidLinkedItem(
                id: exchanged.itemID,
                accessToken: exchanged.accessToken,
                institutionName: success.institutionName ?? "Linked bank",
                accountNames: success.accountNames,
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

// MARK: - ASWebAuthenticationSession bridge

@MainActor
final class HostedLinkSessionController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL?, Error>?

    /// Starts Hosted Link. Returns the callback URL, or `nil` if the user cancelled without error.
    func start(url: URL, callbackScheme: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL?, Error>) in
            self.continuation = cont

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                guard let self else { return }
                let cont = self.continuation
                self.continuation = nil
                self.session = nil

                if let error {
                    // Map cancel to nil URL for cleaner UI
                    if let auth = error as? ASWebAuthenticationSessionError,
                       auth.code == .canceledLogin {
                        cont?.resume(returning: nil)
                    } else {
                        cont?.resume(throwing: error)
                    }
                    return
                }
                cont?.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            if !session.start() {
                self.continuation = nil
                cont.resume(
                    throwing: PlaidAPIError.http(
                        status: 0,
                        code: nil,
                        message: "Could not start the secure browser session for Plaid Link."
                    )
                )
            }
        }
    }

    func cancel() {
        session?.cancel()
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: nil)
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Prefer the key window of the active scene
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        if let window = scenes.flatMap(\.windows).first {
            return window
        }
        return ASPresentationAnchor()
    }
}
