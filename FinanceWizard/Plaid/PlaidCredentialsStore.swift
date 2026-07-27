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
    private static let secretAccount = "plaid.secret"

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
