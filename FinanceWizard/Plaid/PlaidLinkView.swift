//
//  PlaidLinkView.swift
//  Finance Wizard
//
//  Plaid Hosted Link in ASWebAuthenticationSession (webview Link is deprecated).
//  See https://plaid.com/docs/link/hosted-link/
//
//  Flow:
//  1. Create a Hosted Link session (link_token + hosted URL) via Plaid API.
//  2. Open that URL in a secure system browser (ASWebAuthenticationSession).
//  3. User logs into their bank; we either get a custom-scheme callback OR
//     poll /link/token/get until a public_token is ready.
//  4. Exchange public_token → access_token (new link) or refresh accounts (relink).
//  5. Save PlaidLinkedItem via PlaidItemStore.
//

import SwiftUI
import AuthenticationServices

// MARK: - Hosted Link URL scheme

/// Custom URL scheme for Hosted Link completion (not a Universal Link; not in Plaid Dashboard).
/// When the browser finishes, iOS may open financewizard://… and hand us the callback URL.
enum PlaidHostedLink {
    /// URL scheme registered by the app (must match Info.plist URL types).
    static let callbackScheme = "financewizard"
    /// Full completion redirect used when configuring Hosted Link.
    static let completionRedirectURI = "financewizard://hosted-link-complete"
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a new Link replaces an older Item for the same institution.
    /// Other parts of the app (e.g. account lists) listen and clean up orphans.
    static let plaidItemsReplaced = Notification.Name("PlaidLink.plaidItemsReplaced")
}

// MARK: - Link mode

/// New Link vs update mode (re-auth / add accounts for an existing Item).
enum PlaidLinkMode: Equatable {
    /// Brand-new bank connection (will create a new Plaid Item).
    case new
    /// Re-authenticate or change accounts for an existing Item.
    case update(PlaidLinkedItem)

    var navigationTitle: String {
        switch self {
        case .new: return "Link bank"
        case .update: return "Relink bank"
        }
    }

    /// The existing item when in update mode; nil for .new.
    var existingItem: PlaidLinkedItem? {
        if case .update(let item) = self { return item }
        return nil
    }

    /// True only for update mode with a non-empty access token.
    var isUpdateMode: Bool {
        guard let item = existingItem else { return false }
        return !item.accessToken.isEmpty
    }
}

// MARK: - Link sheet UI

/// Sheet: create Hosted Link token → open secure browser session → poll for public_token → save Item.
struct PlaidLinkSheet: View {
    var mode: PlaidLinkMode = .new
    var onFinished: (Result<PlaidLinkedItem, Error>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .starting
    @State private var errorMessage: String?
    /// Strong reference so the browser session isn’t deallocated mid-flow.
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

    // MARK: - Hosted Link orchestration

    /// Create session → open browser → race browser-close vs token-poll → save Item.
    private func startHostedLink() async {
        phase = .starting
        do {
            // Only pass access_token when truly updating — never open a “new Item” flow for Relink.
            let accessTokenForUpdate = mode.isUpdateMode ? mode.existingItem?.accessToken : nil
            let session = try await PlaidAPIClient.createHostedLinkSession(
                accessToken: accessTokenForUpdate
            )
            phase = .waitingForUser

            let controller = HostedLinkSessionController()
            sessionController = controller

            // Keep polling while the bank sheet is open. A 30s cap used to fire
            // while the user was still typing Sandbox credentials.
            enum RaceEvent {
                case browserClosed(callback: URL?)
                case linkReady(PlaidAPIClient.LinkSuccessPayload)
                case graceExpired
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
                        maxAttempts: 1200,
                        delayNanoseconds: 500_000_000
                    )
                    return .linkReady(payload)
                }

                var ready: PlaidAPIClient.LinkSuccessPayload?
                var userDismissedBrowser = false
                for try await event in group {
                    switch event {
                    case .linkReady(let payload):
                        ready = payload
                        group.cancelAll()
                        await MainActor.run { controller.cancel() }
                    case .browserClosed(let callback):
                        userDismissedBrowser = (callback == nil)
                        // Plaid may take a few seconds after the bounce to
                        // publish public_token on /link/token/get.
                        group.addTask {
                            try await Task.sleep(for: .seconds(15))
                            return .graceExpired
                        }
                    case .graceExpired:
                        group.cancelAll()
                    }
                    if ready != nil { break }
                    if case .graceExpired = event { break }
                }
                if ready == nil, !userDismissedBrowser {
                    throw PlaidAPIError.http(
                        status: 0,
                        code: nil,
                        message: "Link closed without linking a bank (or the session timed out). Try Link again."
                    )
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

    /// After we have a public_token (or update success), persist the Item.
    private func completeWithSuccess(_ success: PlaidAPIClient.LinkSuccessPayload) async {
        do {
            if let existing = mode.existingItem {
                // Update mode: keep the same Item access token + sync cursor.
                // Plaid does not require exchanging the public_token after a successful update.
                // Refresh account names from /accounts/get so deselected accounts drop out.
                let liveNames = (try? await PlaidAPIClient.accountsGet(accessToken: existing.accessToken))
                    .map { details in
                        details.map { detail -> String in
                            let name = detail.name ?? detail.official_name ?? existing.institutionName
                            if let mask = detail.mask, !mask.isEmpty {
                                return "\(name) ···\(mask)"
                            }
                            return name
                        }
                    } ?? success.accountNames

                let name = success.institutionName?.trimmingCharacters(in: .whitespacesAndNewlines)
                let item = PlaidLinkedItem(
                    id: existing.id,
                    accessToken: existing.accessToken,
                    institutionName: (name?.isEmpty == false ? name! : existing.institutionName),
                    accountNames: liveNames.isEmpty ? success.accountNames : liveNames,
                    transactionsCursor: existing.transactionsCursor,
                    linkedAt: existing.linkedAt
                )
                PlaidItemStore.upsert(item)
                onFinished(.success(item))
                dismiss()
                return
            }

            // New link: exchange short-lived public_token for long-lived access_token.
            let exchanged = try await PlaidAPIClient.exchangePublicToken(success.publicToken)
            let institutionName = success.institutionName ?? "Linked bank"

            // If the user linked the same bank again as a *new* Item (instead of Relink),
            // replace the previous Item so Settings doesn't stack duplicate connections.
            let priorDuplicates = PlaidItemStore.loadItems().filter { old in
                old.id != exchanged.itemID
                    && old.institutionName.caseInsensitiveCompare(institutionName) == .orderedSame
            }
            let replacedItemIds = priorDuplicates.map(\.id)
            for old in priorDuplicates {
                try? await PlaidAPIClient.removeItem(accessToken: old.accessToken)
                PlaidItemStore.remove(itemID: old.id)
            }
            if !replacedItemIds.isEmpty {
                NotificationCenter.default.post(
                    name: .plaidItemsReplaced,
                    object: nil,
                    userInfo: ["itemIds": replacedItemIds]
                )
            }

            let item = PlaidLinkedItem(
                id: exchanged.itemID,
                accessToken: exchanged.accessToken,
                institutionName: institutionName,
                accountNames: success.accountNames,
                // Empty cursor = next sync pulls full history.
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

/// Bridges Apple’s callback-based `ASWebAuthenticationSession` into async/await.
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
            // Shared cookies help bank SSO; ephemeral would be a fully private session.
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

    /// Cancel the browser and resume any waiter with nil (user-dismissed).
    func cancel() {
        session?.cancel()
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: nil)
        }
    }

    /// Required by ASWebAuthenticationPresentationContextProviding: which window hosts the sheet?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        if let window = scenes.flatMap(\.windows).first {
            return window
        }
        // iOS 26+: UIWindow() is deprecated — always create with a windowScene.
        if let scene = scenes.first {
            return UIWindow(windowScene: scene)
        }
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return UIWindow(windowScene: scene)
        }
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first {
            return window
        }
        preconditionFailure("ASWebAuthenticationSession needs a window scene for presentationAnchor")
    }
}
