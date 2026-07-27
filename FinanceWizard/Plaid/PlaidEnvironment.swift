//
//  PlaidEnvironment.swift
//  Finance Wizard
//
//  Which Plaid API host to call (sandbox / development / production).
//

import Foundation

/// Plaid API environment. Secrets are environment-specific in the dashboard.
enum PlaidEnvironment: String, CaseIterable, Identifiable, Codable, Sendable {
    case sandbox
    case development
    case production

    var id: String { rawValue }

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
