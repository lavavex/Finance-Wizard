//
//  PlaidEnvironment.swift
//  Finance Wizard
//
//  Which Plaid API host to call (sandbox or production).
//  Plaid retired the old “Development” host; stored values map to Sandbox.
//

import Foundation

/// Which Plaid backend this app talks to.
///
/// Plaid issues a separate API secret per environment in the dashboard.
/// Sandbox is fake test banks; Production is real bank data (needs Plaid Production access).
enum PlaidEnvironment: String, CaseIterable, Identifiable, Codable, Sendable {
    case sandbox
    case production

    var id: String { rawValue }

    /// Human-readable label for Settings pickers and UI.
    var displayName: String {
        switch self {
        case .sandbox: return "Sandbox (test banks)"
        case .production: return "Production"
        }
    }

    /// Base URL for REST calls (no trailing slash).
    var baseURL: URL {
        switch self {
        case .sandbox:
            return URL(string: "https://sandbox.plaid.com")!
        case .production:
            return URL(string: "https://production.plaid.com")!
        }
    }

    /// Decode Settings / backup strings. Unknown or retired `development` → Sandbox.
    static func fromStored(_ raw: String?) -> PlaidEnvironment {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "production" { return .production }
        return .sandbox
    }
}
