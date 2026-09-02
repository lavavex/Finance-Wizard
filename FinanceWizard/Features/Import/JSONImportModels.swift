//
//  JSONImportModels.swift
//  Finance Wizard
//
//  Decode shapes for the offline JSON import (legacy finance-sync export format).
//  Split out of ContentView.swift, which held them only because the importer lives there.
//

import Foundation

/// One expense row as it appears in a JSON export file (snake_case keys from the server era).
struct ImportedTransaction: Decodable {
    let transaction_id: String
    let date: String
    let vendor: String
    let category: String
    let amount: Double
    let payment_method: String
    // Present after classify / lock on finance-sync (optional for older exports).
    let category_locked: Bool?
    let override_source: String?
}

/// Top-level JSON object: { "transactions": [ ... ] }.
struct ExportFile: Decodable {
    let transactions: [ImportedTransaction]
}

// Optional income array for offline JSON imports (legacy finance-sync shape still accepted)
/// One income row from a JSON export (amounts are positive “earned” money).
struct ImportedIncome: Decodable {
    let transaction_id: String
    let date: String
    let month_name: String?
    let year: Int?
    let source: String
    let category: String
    let amount: Double
    let account_name: String?
    let account_mask: String?
    let source_institution: String?
    let raw_name: String?
    let pfc: String?
    let pending: Bool?
    let kind: String?
    let updated_at: String?
}

/// Wrapper around an income export file; several top-level keys are optional for flexibility.
struct IncomeExportFile: Decodable {
    let ok: Bool?
    let kind: String?
    let count: Int?
    let total: Double?
    let categories: [String]?
    let income: [ImportedIncome]?

    var rows: [ImportedIncome] { income ?? [] }
}
