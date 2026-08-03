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
    /// async means this function can be awaited; kept async so call sites that
    /// once hit the network can still use the same await style without a big rewrite.
    /// [String] is an array (ordered list) of String values.
    static func fetchCategories() async -> [String] {
        // KnownCategory.defaultNames is a compiled-in list of category title strings.
        KnownCategory.defaultNames
    }
}
