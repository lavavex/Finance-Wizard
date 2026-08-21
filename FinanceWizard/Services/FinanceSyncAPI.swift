//
//  FinanceSyncAPI.swift
//  Finance Wizard
//
//  Local helpers left after removing the remote finance-sync server.
//  Categories come from built-in lists; classify runs on-device only.
//

import Foundation

/// Built-in category helpers (no remote portal).
/// Named “API” historically; today these are just local static functions.
enum FinanceSyncAPI {
    /// Expense category names for the transaction editor.
    /// Kept `async` so former network call sites can still `await` without a rewrite.
    static func fetchCategories() async -> [String] {
        KnownCategory.defaultNames
    }
}
