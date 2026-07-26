//
//  Income.swift
//  FinanceWidget
//
//  Income rows from finance-sync GET /api/income.
//  Separate stream from expenses — never included in Total Spend or category charts.
//  Field names match the IncomeRow contract in grokinstruct.txt.
//

import Foundation
import SwiftData

// Money-in row saved on disk in the App Group store
@Model
final class Income {
    // Stable Plaid/import id from API `transaction_id` (primary key on the portal)
    @Attribute(.unique) var transactionId: String

    /// Display name: employer / payer / short label (API `source`)
    var source: String
    /// Always positive — money received
    var amount: Double
    var date: Date
    /// Canonical: Payroll, Direct Deposit, Interest, Refund, Other Income
    var category: String
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

    /// Account line for lists: "CHASE COLLEGE ·••2667" or institution fallback
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
        return parts.isEmpty ? "Account" : parts.joined(separator: " ")
    }

    /// Value passed to BankIconView (institution preferred, then account name)
    var iconKey: String {
        if let sourceInstitution, !sourceInstitution.isEmpty { return sourceInstitution }
        if let accountName, !accountName.isEmpty { return accountName }
        return source
    }

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
        return rows.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    /// Sum of income amounts (API amounts are always positive).
    static func totalEarned(in rows: [Income]) -> Double {
        rows.reduce(0) { $0 + max(0, $1.amount) }
    }

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

    static func filter(
        _ rows: [Income],
        period: SnapshotPeriod,
        referenceDate: Date = Date(),
        sort: TransactionSort = .dateNewest
    ) -> [Income] {
        sorted(inPeriod(rows, period: period, referenceDate: referenceDate), by: sort)
    }
}
