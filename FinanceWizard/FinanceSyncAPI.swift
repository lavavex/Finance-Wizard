//
//  FinanceSyncAPI.swift
//  Finance Wizard
//
//  Local helpers after removing the finance-sync server.
//  Categories come from built-in lists; classify is device-only.
//

import Foundation

/// Built-in category helpers (no remote portal).
enum FinanceSyncAPI {
    /// Expense category names for the transaction editor.
    static func fetchCategories() async -> [String] {
        KnownCategory.defaultNames
    }
}
