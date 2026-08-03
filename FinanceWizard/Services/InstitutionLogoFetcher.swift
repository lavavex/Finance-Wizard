//
//  InstitutionLogoFetcher.swift
//  Finance Wizard
//
//  Listens for logo cache misses and loads bank branding (logo + color) from Plaid.
//  Lives in the app target because Shared cannot import the Plaid client.
//

import Foundation

// enum used as a namespace for static helpers (no instances needed).
enum InstitutionLogoFetcher {
    // Tracks whether we already registered the notification observer (start only once).
    private static var started = false

    /// Call once at app launch so logo-miss notifications begin loading images.
    static func start() {
        // guard: if already started, return early (idempotent setup).
        guard !started else { return }
        started = true
        // NotificationCenter is a publish/subscribe bus inside the process.
        // addObserver: when .institutionLogoNeedsFetch posts, run this closure.
        // A closure is a block of code you can pass around like a value (here: { note in ... }).
        NotificationCenter.default.addObserver(
            forName: .institutionLogoNeedsFetch,
            object: nil,
            queue: .main
        ) { note in
            // userInfo is an optional dictionary of extra data on the notification.
            // as? is a conditional cast: returns the value if it is that type, else nil.
            // ?? provides a default when the left side is nil (nil-coalescing).
            let id = note.userInfo?["institutionID"] as? String ?? ""
            let name = note.userInfo?["name"] as? String
            guard !id.isEmpty else { return }
            // Task { } starts unstructured async work from a non-async context.
            Task { await fetch(institutionID: id, name: name) }
        }
    }

    // @MainActor: this function always runs on the main (UI) thread.
    // private: only code inside this enum can call fetch.
    // async: can use await for network and other asynchronous work.
    // String? means optional String — either a String or nil (name may be unknown).
    @MainActor
    private static func fetch(institutionID: String, name: String?) async {
        // defer: run this block when the function exits (success or early return or error).
        // Ensures the cache always knows the in-flight fetch finished.
        defer { InstitutionLogoCache.markFetchFinished(institutionID: institutionID) }
        guard PlaidCredentialsStore.isConfigured else { return }
        // Another concurrent fetch may have already filled the cache (race).
        if InstitutionLogoCache.logoImage(institutionID: institutionID) != nil { return }
        do {
            // try await: wait for the async throwing network call; throw on failure.
            let branding = try await PlaidAPIClient.institutionBranding(institutionID: institutionID)
            InstitutionLogoCache.store(
                institutionID: branding.institutionID,
                // Prefer Plaid’s name; fall back to the name from the notification.
                name: branding.name ?? name,
                logoBase64: branding.logoBase64,
                primaryColorHex: branding.primaryColorHex
            )
            // if let name: unwrap the optional; only enter the block when name is non-nil.
            // Also store under the caller’s name if it differs (lookup by display name).
            if let name, !name.isEmpty, branding.name?.caseInsensitiveCompare(name) != .orderedSame {
                InstitutionLogoCache.store(
                    institutionID: branding.institutionID,
                    name: name,
                    logoBase64: branding.logoBase64,
                    primaryColorHex: branding.primaryColorHex
                )
            }
            // No console logging — missing logos are normal and spam lags DEBUG sessions.
        } catch {
            // Silent: monogram + brand color cover the UI when fetch fails.
            // catch without binding still swallows the error (we choose not to surface it).
        }
    }
}
