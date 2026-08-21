//
//  PlaidEnvironment.swift
//  Finance Wizard
//
//  Which Plaid API host to call (sandbox / development / production).
//

import Foundation

/// Which Plaid backend this app talks to.
///
/// Plaid issues separate API secrets per environment in their dashboard.
/// Sandbox is for fake test banks; production is real user bank data.
enum PlaidEnvironment: String, CaseIterable, Identifiable, Codable, Sendable {
    case sandbox
    case development
    case production

    var id: String { rawValue }

    /// Human-readable label for Settings pickers and UI.
    var displayName: String {
        switch self {
        case .sandbox: return "Sandbox (test banks)"
        case .development: return "Development"
        case .production: return "Production"
        }
    }

    /// Base URL for REST calls (no trailing slash).
    var baseURL: URL {
        switch self {
        case .sandbox:
            return URL(string: "https://sandbox.plaid.com")!
        case .development:
            return URL(string: "https://development.plaid.com")!
        case .production:
            return URL(string: "https://production.plaid.com")!
        }
    }
}
