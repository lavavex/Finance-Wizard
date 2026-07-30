//
//  PlaidCredentialsStore.swift
//  Finance Wizard
//
//  User’s own Plaid developer credentials (client_id + secret + environment).
//  Secret is stored in Keychain; client id / env use UserDefaults.
//

import Foundation

enum PlaidCredentialsStore {
    private static let clientIDKey = "plaid.clientID"
    private static let environmentKey = "plaid.environment"
    private static let redirectURIKey = "plaid.redirectURI"
    private static let secretAccount = "plaid.secret"

    /// Optional Universal Link / https OAuth redirect for app-to-app bank auth.
    /// Leave empty for Sandbox Hosted Link; set an allowlisted https URI in Production if needed.
    static let defaultRedirectURI = ""

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

    static var environment: PlaidEnvironment {
        get {
            let raw = UserDefaults.standard.string(forKey: environmentKey) ?? PlaidEnvironment.sandbox.rawValue
            return PlaidEnvironment(rawValue: raw) ?? .sandbox
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: environmentKey)
        }
    }

    /// Optional **https** OAuth redirect (Universal Link). Required by Plaid for many
    /// banks (Chase, etc.) and for update/relink when OAuth is involved.
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
            UserDefaults.standard.set(trimmed.isEmpty ? nil : trimmed, forKey: redirectURIKey)
        }
    }

    /// `redirect_uri` for `/link/token/create` — only an https URL, never a custom scheme.
    static var httpsRedirectURI: String? {
        let value = redirectURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("https://") else { return nil }
        return value
    }

    /// Removes old sample values like `https://localhost/plaid-oauth` left from early setup.
    /// Localhost is not a valid production OAuth redirect and confuses Plaid.
    static func clearLegacyLocalhostRedirectIfNeeded() {
        let value = redirectURI.lowercased()
        guard !value.isEmpty else { return }
        if value.contains("localhost") || value.contains("127.0.0.1") {
            redirectURI = ""
        }
    }

    /// True when both client id and secret are present.
    static var isConfigured: Bool {
        !clientID.isEmpty && !secret.isEmpty
    }

    static func requireConfigured() throws {
        guard isConfigured else {
            throw PlaidAPIError.notConfigured
        }
    }
}
