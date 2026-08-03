//
//  PlaidEnvironment.swift
//  Finance Wizard
//
//  Which Plaid API host to call (sandbox / development / production).
//
//  SWIFT TERMS IN THIS FILE:
//  - enum: A type that holds a fixed set of cases (here: three environments).
//  - RawRepresentable (via ": String"): Each case stores an underlying String (rawValue).
//  - CaseIterable: Adds .allCases so you can loop every environment (e.g. in a picker).
//  - Identifiable: Requires an `id` so SwiftUI ForEach can track each case.
//  - Codable: Can encode/decode to JSON (or other formats) automatically.
//  - Sendable: Safe to pass across concurrency boundaries (actors, async tasks).
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

    /// Identifiable requirement: unique id for each case (here, the raw string).
    var id: String { rawValue }

    /// Human-readable label for Settings pickers and UI.
    var displayName: String {
        // switch: pick one branch based on which case `self` is.
        switch self {
        case .sandbox: return "Sandbox (test banks)"
        case .development: return "Development"
        case .production: return "Production"
        }
    }

    /// Base URL for REST calls (no trailing slash).
    ///
    /// URL is Foundation’s type for web addresses. The trailing `!` is a force-unwrap:
    /// we assert these hard-coded strings are always valid URLs (they are constants).
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
