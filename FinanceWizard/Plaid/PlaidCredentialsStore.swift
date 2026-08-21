//
//  PlaidCredentialsStore.swift
//  Finance Wizard
//
//  User’s own Plaid developer credentials (client_id + secret + environment).
//  Secret is stored in Keychain; client id / env use UserDefaults.
//

import Foundation

/// Reads and writes the developer’s Plaid client_id, secret, environment, and OAuth URLs.
///
/// client_id and environment are non-secret prefs → UserDefaults.
/// The secret is sensitive → PlaidKeychain. Never log or print the secret.
enum PlaidCredentialsStore {
    // MARK: - Storage keys

    private static let clientIDKey = "plaid.clientID"
    private static let environmentKey = "plaid.environment"
    private static let redirectURIKey = "plaid.redirectURI"
    /// Keychain “account” name for the API secret (see PlaidKeychain).
    private static let secretAccount = "plaid.secret"

    // MARK: - Defaults (public constants)

    /// Default https OAuth redirect (Cloudflare Pages bounce). Must match Plaid Dashboard
    /// → Allowed redirect URIs exactly (including trailing slash if allowlisted that way).
    /// Settings can override (e.g. Universal Link later); leave blank to use this default.
    static let defaultRedirectURI = "https://budgetmagi.pages.dev/"

    /// Cloudflare Worker that receives Plaid webhooks (free tier).
    /// Passed as `webhook` on `/link/token/create` so new/relinked Items notify this URL.
    static let plaidWebhookURL = "https://plaid-webhooks.lavavex.workers.dev/plaid/webhook"

    // MARK: - Client ID (UserDefaults)

    /// Plaid dashboard client_id. Empty string means “not set yet.”
    static var clientID: String {
        get {
            UserDefaults.standard.string(forKey: clientIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        set {
            UserDefaults.standard.set(
                newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: clientIDKey
            )
        }
    }

    // MARK: - Secret (Keychain)

    /// Plaid API secret. Stored only in the Keychain, never in UserDefaults.
    static var secret: String {
        get { PlaidKeychain.get(account: secretAccount) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                PlaidKeychain.delete(account: secretAccount)
            } else {
                try? PlaidKeychain.set(trimmed, account: secretAccount)
            }
        }
    }

    // MARK: - Environment

    /// Which Plaid host to call (sandbox or production).
    static var environment: PlaidEnvironment {
        get {
            let raw = UserDefaults.standard.string(forKey: environmentKey)
            let env = PlaidEnvironment.fromStored(raw)
            // Retired Plaid “Development” host — persist Sandbox so the picker matches.
            if raw?.lowercased() == "development" {
                UserDefaults.standard.set(env.rawValue, forKey: environmentKey)
            }
            return env
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: environmentKey)
        }
    }

    // MARK: - OAuth redirect URI

    /// Effective **https** OAuth redirect for `/link/token/create`.
    /// Uses Settings override when set; otherwise `defaultRedirectURI`.
    /// Must be allowlisted under Team Settings → API → Allowed redirect URIs.
    /// Hosted Link still uses `financewizard://hosted-link-complete` as the
    /// mobile *completion* URI (that one may be a custom scheme).
    static var redirectURI: String {
        get {
            let stored = UserDefaults.standard.string(forKey: redirectURIKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultRedirectURI : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Clearing the field or re-entering the built-in default means “use default”
            // so later default-URL changes are not permanently overridden.
            if trimmed.isEmpty || trimmed == defaultRedirectURI {
                UserDefaults.standard.removeObject(forKey: redirectURIKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: redirectURIKey)
            }
        }
    }

    /// True when the user set a custom redirect (not the built-in Pages URL).
    static var hasCustomRedirectURI: Bool {
        let stored = UserDefaults.standard.string(forKey: redirectURIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !stored.isEmpty && stored != defaultRedirectURI
    }

    /// `redirect_uri` for `/link/token/create` — only an https URL, never a custom scheme.
    /// Returns nil if the configured value is not https (Plaid OAuth requires https).
    static var httpsRedirectURI: String? {
        let value = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("https://") else { return nil }
        return value
    }

    /// Removes old sample values like `https://localhost/plaid-oauth` left from early setup.
    /// Localhost is not a valid production OAuth redirect and confuses Plaid.
    static func clearLegacyLocalhostRedirectIfNeeded() {
        let stored = UserDefaults.standard.string(forKey: redirectURIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !stored.isEmpty else { return }
        if stored.contains("localhost") || stored.contains("127.0.0.1") {
            UserDefaults.standard.removeObject(forKey: redirectURIKey)
        }
    }

    // MARK: - Configuration checks

    /// True when both client id and secret are present.
    static var isConfigured: Bool {
        !clientID.isEmpty && !secret.isEmpty
    }

    /// Throws `PlaidAPIError.notConfigured` if credentials are missing.
    /// Call before any network request that needs client_id + secret.
    static func requireConfigured() throws {
        guard isConfigured else {
            throw PlaidAPIError.notConfigured
        }
    }
}
