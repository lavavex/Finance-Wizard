//
//  InstitutionLogoFetcher.swift
//  Finance Wizard
//
//  Listens for logo cache misses and loads bank branding (logo + color) from Plaid.
//  Lives in the app target because Shared cannot import the Plaid client.
//

import Foundation

enum InstitutionLogoFetcher {
    /// Tracks whether we already registered the notification observer (start only once).
    private static var started = false

    /// Call once at app launch so logo-miss notifications begin loading images.
    static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: .institutionLogoNeedsFetch,
            object: nil,
            queue: .main
        ) { note in
            let id = note.userInfo?["institutionID"] as? String ?? ""
            let name = note.userInfo?["name"] as? String
            guard !id.isEmpty else { return }
            Task { await fetch(institutionID: id, name: name) }
        }
    }

    @MainActor
    private static func fetch(institutionID: String, name: String?) async {
        defer { InstitutionLogoCache.markFetchFinished(institutionID: institutionID) }
        guard PlaidCredentialsStore.isConfigured else { return }
        // Another concurrent fetch may have already filled the cache.
        if InstitutionLogoCache.logoImage(institutionID: institutionID) != nil { return }
        do {
            let branding = try await PlaidAPIClient.institutionBranding(institutionID: institutionID)
            InstitutionLogoCache.store(
                institutionID: branding.institutionID,
                name: branding.name ?? name,
                logoBase64: branding.logoBase64,
                primaryColorHex: branding.primaryColorHex
            )
            // Also store under the caller’s display name when it differs from Plaid’s.
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
        }
    }
}
