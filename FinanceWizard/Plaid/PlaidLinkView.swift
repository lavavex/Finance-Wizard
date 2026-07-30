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

/// New Link vs update mode (re-auth / add accounts for an existing Item).
enum PlaidLinkMode: Equatable {
    case new
    case update(PlaidLinkedItem)

    var navigationTitle: String {
        switch self {
        case .new: return "Link bank"
        case .update: return "Relink bank"
        }
    }

    var existingItem: PlaidLinkedItem? {
        if case .update(let item) = self { return item }
        return nil
    }
}

/// Sheet: create Hosted Link token → open secure browser session → poll for public_token → save Item.
struct PlaidLinkSheet: View {
    var mode: PlaidLinkMode = .new
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
                    ProgressView(
                        mode.existingItem == nil
                        ? "Preparing Plaid Link…"
                        : "Preparing relink…"
                    )
                case .waitingForUser:
                    VStack(spacing: 16) {
                        ProgressView()
                        Text(
                            mode.existingItem == nil
                            ? "Complete bank login in the browser window."
                            : "Re-authenticate \(mode.existingItem?.institutionName ?? "your bank") in the browser. You can also select more accounts."
                        )
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
                    ProgressView(
                        mode.existingItem == nil
                        ? "Saving linked bank…"
                        : "Updating linked bank…"
                    )
                case .failed:
                    ContentUnavailableView(
                        mode.existingItem == nil ? "Link failed" : "Relink failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage ?? "Unknown error")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(mode.navigationTitle)
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
            let session = try await PlaidAPIClient.createHostedLinkSession(
                accessToken: mode.existingItem?.accessToken
            )
            phase = .waitingForUser

            let controller = HostedLinkSessionController()
            sessionController = controller

            // Race browser callback against token polling. When no https OAuth
            // redirect is configured, Hosted Link may not bounce via
            // financewizard:// — success is still visible on /link/token/get.
            enum RaceEvent {
                case browserClosed(callback: URL?)
                case linkReady(PlaidAPIClient.LinkSuccessPayload)
            }

            let success = try await withThrowingTaskGroup(of: RaceEvent.self) { group in
                group.addTask { @MainActor in
                    let url = try await controller.start(
                        url: session.hostedLinkURL,
                        callbackScheme: PlaidHostedLink.callbackScheme
                    )
                    return .browserClosed(callback: url)
                }
                group.addTask {
                    let payload = try await PlaidAPIClient.waitForLinkSuccess(
                        linkToken: session.linkToken,
                        maxAttempts: 60,
                        delayNanoseconds: 500_000_000
                    )
                    return .linkReady(payload)
                }

                var ready: PlaidAPIClient.LinkSuccessPayload?
                for try await event in group {
                    switch event {
                    case .linkReady(let payload):
                        ready = payload
                        group.cancelAll()
                        await MainActor.run { controller.cancel() }
                    case .browserClosed(let callback):
                        if callback != nil {
                            // Custom-scheme completion fired — wait briefly for token
                            group.cancelAll()
                            ready = try await PlaidAPIClient.waitForLinkSuccess(
                                linkToken: session.linkToken,
                                maxAttempts: 12,
                                delayNanoseconds: 400_000_000
                            )
                        } else {
                            // User dismissed browser; stop polling
                            group.cancelAll()
                        }
                    }
                    break
                }
                return ready
            }

            guard let success else {
                dismiss()
                return
            }

            phase = .finishing
            await completeWithSuccess(success)
        } catch is CancellationError {
            dismiss()
        } catch {
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
            if let existing = mode.existingItem {
                // Update mode: keep the same Item access token + sync cursor.
                // Plaid does not require exchanging the public_token after a successful update.
                let name = success.institutionName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let item = PlaidLinkedItem(
                    id: existing.id,
                    accessToken: existing.accessToken,
                    institutionName: (name?.isEmpty == false ? name! : existing.institutionName),
                    accountNames: success.accountNames.isEmpty
                        ? existing.accountNames
                        : success.accountNames,
                    transactionsCursor: existing.transactionsCursor,
                    linkedAt: existing.linkedAt
                )
                PlaidItemStore.upsert(item)
                onFinished(.success(item))
                dismiss()
                return
            }

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
