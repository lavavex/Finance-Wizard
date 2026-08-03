//
//  Income.swift
//  Finance Wizard
//
//  Income rows from finance-sync GET /api/income.
//  Separate stream from expenses — never included in Total Spend or category charts.
//  Field names match the IncomeRow contract in grokinstruct.txt.
//
//  Swift note: keeping Income as its own @Model type (not a flag on Transaction)
//  makes filters and analytics simpler — you never mix paychecks into “spend.”
//

import Foundation
import SwiftData

// MARK: - SwiftData model
// @Model + final class = a database-backed object. Stored vars persist; computed
// vars (accountDisplay, iconKey) are derived when read and are not saved as columns.

/// Money-in row saved on disk in the App Group store.
@Model
final class Income {
    // Stable Plaid/import id from API `transaction_id` (primary key on the portal).
    // @Attribute(.unique) enforces one row per id when syncing.
    @Attribute(.unique) var transactionId: String

    /// Display name: employer / payer / short label (API `source`)
    var source: String
    /// Always positive — money received
    var amount: Double
    var date: Date
    /// Canonical: Payroll, Direct Deposit, Interest, Refund, Other Income
    var category: String
    // Optional strings (String?) may be nil when the API omitted that field.
    /// e.g. "CHASE COLLEGE" (API `account_name`)
    var accountName: String?
    /// Last4, e.g. "2667" (API `account_mask`)
    var accountMask: String?
    /// e.g. "Chase", "X Money" (API `source_institution`)
    var sourceInstitution: String?
    /// Original bank description (API `raw_name`)
    var rawName: String?
    /// Plaid personal_finance_category detailed (API `pfc`)
    var pfc: String?
    var pending: Bool
    /// Discriminator — always "income" from the API
    var kind: String
    /// ISO timestamp from server when present
    var updatedAt: String?

    // MARK: - Computed display helpers
    // These build UI strings from stored fields. No disk storage of their own.

    /// Account line for lists: "CHASE COLLEGE ···2667" or institution fallback.
    /// if let name, !name.isEmpty is Swift’s way to unwrap an optional and check emptiness.
    var accountDisplay: String {
        var parts: [String] = []
        if let accountName, !accountName.isEmpty {
            parts.append(accountName)
        } else if let sourceInstitution, !sourceInstitution.isEmpty {
            parts.append(sourceInstitution)
        }
        if let accountMask, !accountMask.isEmpty {
            parts.append("···\(accountMask)")
        }
        // Ternary: condition ? valueIfTrue : valueIfFalse
        return parts.isEmpty ? "Account" : parts.joined(separator: " ")
    }

    /// Value passed to BankIconView (institution preferred, then account name)
    var iconKey: String {
        if let sourceInstitution, !sourceInstitution.isEmpty { return sourceInstitution }
        if let accountName, !accountName.isEmpty { return accountName }
        return source
    }

    // Default parameter values (= nil, = false, etc.) let callers skip arguments
    // they do not care about when creating a new Income.
    init(
        transactionId: String,
        source: String,
        amount: Double,
        date: Date,
        category: String,
        accountName: String? = nil,
        accountMask: String? = nil,
        sourceInstitution: String? = nil,
        rawName: String? = nil,
        pfc: String? = nil,
        pending: Bool = false,
        kind: String = "income",
        updatedAt: String? = nil
    ) {
        self.transactionId = transactionId
        self.source = source
        self.amount = amount
        self.date = date
        self.category = category
        self.accountName = accountName
        self.accountMask = accountMask
        self.sourceInstitution = sourceInstitution
        self.rawName = rawName
        self.pfc = pfc
        self.pending = pending
        self.kind = kind
        self.updatedAt = updatedAt
    }
}

// MARK: - Period helpers (same windows as expenses; never mixed into spend)
//
// enum here is used as a namespace for static helper functions — you never create
// an “instance” of IncomeAnalytics. Call them like IncomeAnalytics.totalEarned(in: rows).
//
// static means the function belongs to the type itself, not to one Income object.

/// Pure helpers that filter, sum, and sort income arrays (no SwiftData writes).
enum IncomeAnalytics {
    /// Canonical categories from finance-sync (also on GET /api/categories → incomeCategories)
    static let knownCategories = [
        "Payroll",
        "Direct Deposit",
        "Interest",
        "Refund",
        "Other Income"
    ]

    /// Rows inside the selected week / month, or all rows for `.all`.
    /// guard let interval = … else { return rows } means: if dateInterval is nil
    /// (all-time period), keep every row; otherwise filter by start/end.
    static func inPeriod(
        _ rows: [Income],
        period: SnapshotPeriod,
        referenceDate: Date = Date()
    ) -> [Income] {
        guard let interval = TransactionAnalytics.dateInterval(
            for: period,
            referenceDate: referenceDate
        ) else {
            return rows
        }
        // filter keeps only elements where the closure returns true.
        return rows.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    /// Sum of income amounts (API amounts are always positive).
    /// reduce starts at 0 and adds each amount; max(0, …) ignores negative noise.
    static func totalEarned(in rows: [Income]) -> Double {
        rows.reduce(0) { $0 + max(0, $1.amount) }
    }

    /// Sort without changing which rows are present — only order changes.
    static func sorted(_ rows: [Income], by sort: TransactionSort) -> [Income] {
        switch sort {
        case .dateNewest:
            return rows.sorted { $0.date > $1.date }
        case .dateOldest:
            return rows.sorted { $0.date < $1.date }
        case .amountLargest:
            return rows.sorted { $0.amount > $1.amount }
        case .amountSmallest:
            return rows.sorted { $0.amount < $1.amount }
        case .titleAZ:
            return rows.sorted {
                $0.source.localizedCaseInsensitiveCompare($1.source) == .orderedAscending
            }
        }
    }

    /// Convenience: filter to a period, then sort — one call for list screens.
    static func filter(
        _ rows: [Income],
        period: SnapshotPeriod,
        referenceDate: Date = Date(),
        sort: TransactionSort = .dateNewest
    ) -> [Income] {
        sorted(inPeriod(rows, period: period, referenceDate: referenceDate), by: sort)
    }
}
