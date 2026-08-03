//
//  PlaidLinkView.swift
//  Finance Wizard
//
//  Plaid Hosted Link in ASWebAuthenticationSession (webview Link is deprecated).
//  See https://plaid.com/docs/link/hosted-link/
//
//  Flow overview:
//  1. Create a Hosted Link session (link_token + hosted URL) via Plaid API.
//  2. Open that URL in a secure system browser (ASWebAuthenticationSession).
//  3. User logs into their bank; we either get a custom-scheme callback OR
//     poll /link/token/get until a public_token is ready.
//  4. Exchange public_token → access_token (new link) or refresh accounts (relink).
//  5. Save PlaidLinkedItem via PlaidItemStore.
//
//  SWIFT TERMS IN THIS FILE:
//  - SwiftUI View: Declarative UI; body rebuilds when @State changes.
//  - @State: View-local mutable state; changing it triggers a re-render.
//  - @Environment(\.dismiss): Read the environment value used to close a sheet.
//  - async/await: Suspend until network/browser work finishes without blocking the UI thread.
//  - Task / .task: Start async work tied to the view’s lifetime.
//  - Result<Success, Failure>: Enum holding either .success(value) or .failure(error).
//  - withThrowingTaskGroup: Run multiple async child tasks; first useful result wins.
//  - withCheckedThrowingContinuation: Bridge callback-based APIs into async/await.
//  - @MainActor: Ensure UI work runs on the main thread.
//  - [weak self]: Avoid retain cycles in closures that outlive the object briefly.
//

import SwiftUI
// AuthenticationServices: Apple’s secure browser session for OAuth-style logins.
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
/// Equatable lets SwiftUI and tests compare modes with ==.
enum PlaidLinkMode: Equatable {
    /// Brand-new bank connection (will create a new Plaid Item).
    case new
    /// Re-authenticate or change accounts for an existing Item (associated value holds it).
    case update(PlaidLinkedItem)

    var navigationTitle: String {
        switch self {
        case .new: return "Link bank"
        case .update: return "Relink bank"
        }
    }

    /// The existing item when in update mode; nil for .new.
    /// `if case` pattern-matches the associated value out of the enum.
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
///
/// `onFinished` is a closure (function type) the parent provides to learn success/failure.
/// `Result<PlaidLinkedItem, Error>` is either the new/updated item or an error.
struct PlaidLinkSheet: View {
    var mode: PlaidLinkMode = .new
    var onFinished: (Result<PlaidLinkedItem, Error>) -> Void

    /// Dismiss the sheet (injected by SwiftUI’s environment).
    @Environment(\.dismiss) private var dismiss
    /// Current step of the link flow; drives which ProgressView / error UI we show.
    @State private var phase: Phase = .starting
    @State private var errorMessage: String?
    /// Strong reference so the browser session isn’t deallocated mid-flow.
    @State private var sessionController: HostedLinkSessionController?

    /// Private nested enum: only this view needs these phases.
    private enum Phase {
        case starting
        case waitingForUser
        case finishing
        case failed
    }

    var body: some View {
        NavigationStack {
            Group {
                // switch on phase to show one UI branch at a time.
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
            // .task runs this async function when the view appears; cancels if the view goes away.
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
            // try await: wait for the network call; throw if it fails.
            let session = try await PlaidAPIClient.createHostedLinkSession(
                accessToken: accessTokenForUpdate
            )
            phase = .waitingForUser

            let controller = HostedLinkSessionController()
            sessionController = controller

            // Race browser callback against token polling. When no https OAuth
            // redirect is configured, Hosted Link may not bounce via
            // financewizard:// — success is still visible on /link/token/get.
            // Local enum for the two possible “who finished first” events.
            enum RaceEvent {
                case browserClosed(callback: URL?)
                case linkReady(PlaidAPIClient.LinkSuccessPayload)
            }

            // withThrowingTaskGroup: spawn concurrent child tasks; collect results as they finish.
            let success = try await withThrowingTaskGroup(of: RaceEvent.self) { group in
                // Child 1: open browser and wait for callback or cancel.
                // @MainActor: ASWebAuthenticationSession must be driven from the main actor.
                group.addTask { @MainActor in
                    let url = try await controller.start(
                        url: session.hostedLinkURL,
                        callbackScheme: PlaidHostedLink.callbackScheme
                    )
                    return .browserClosed(callback: url)
                }
                // Child 2: poll Plaid until public_token is ready.
                group.addTask {
                    let payload = try await PlaidAPIClient.waitForLinkSuccess(
                        linkToken: session.linkToken,
                        maxAttempts: 60,
                        delayNanoseconds: 500_000_000
                    )
                    return .linkReady(payload)
                }

                var ready: PlaidAPIClient.LinkSuccessPayload?
                // for try await: iterate results as each child completes (throws if a child throws).
                for try await event in group {
                    switch event {
                    case .linkReady(let payload):
                        ready = payload
                        // Stop the other child; cancel browser if still open.
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
                    // We only need the first decisive event.
                    break
                }
                return ready
            }

            // Optional binding: if polling never got a payload, just close.
            guard let success else {
                dismiss()
                return
            }

            phase = .finishing
            await completeWithSuccess(success)
        } catch is CancellationError {
            // Task was cancelled (view dismissed) — quiet exit.
            dismiss()
        } catch {
            // Type cast: check if this is the specific “user cancelled login” error.
            if let authError = error as? ASWebAuthenticationSessionError,
               authError.code == .canceledLogin {
                dismiss()
                return
            }
            errorMessage = error.localizedDescription
            phase = .failed
            // Result.failure wraps the error for the parent callback.
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
                // try? await: optional success — fall back to Link metadata names if API fails.
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
            // Notify host to drop orphaned local BankAccount rows for replaced Items
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
///
/// `@MainActor` means all methods run on the main thread (required for UI presentation).
/// `final class` cannot be subclassed; `NSObject` subclassing is required for the
/// `ASWebAuthenticationPresentationContextProviding` protocol.
@MainActor
final class HostedLinkSessionController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    /// Holds the suspended async function until the browser callback fires.
    /// CheckedContinuation is the “resume handle” from withCheckedThrowingContinuation.
    private var continuation: CheckedContinuation<URL?, Error>?

    /// Starts Hosted Link. Returns the callback URL, or `nil` if the user cancelled without error.
    func start(url: URL, callbackScheme: String) async throws -> URL? {
        // withCheckedThrowingContinuation: wrap a completion-handler API as async throws.
        // When the browser finishes, we call cont.resume(...) to wake the awaiter.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL?, Error>) in
            self.continuation = cont

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                // [weak self]: if the controller is gone, don’t retain it; just return.
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

            // Who presents the browser sheet? This controller (see presentationAnchor).
            session.presentationContextProvider = self
            // false = allow shared cookies (helps bank SSO); true would be fully private.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            // start() returns false if the session could not begin.
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
        // Prefer the key window of the active scene
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        if let window = scenes.flatMap(\.windows).first {
            return window
        }
        // Fallback empty anchor (should be rare).
        return ASPresentationAnchor()
    }
}
