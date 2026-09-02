//
//  ReviewQueueAnalytics.swift
//  Finance Wizard
//
//  “Needs review” queue: bill-pay candidates and weak categories.
//  The rewards-driven reasons (unlocked rate, ambiguous debit/ACH rail) were
//  removed with the rewards feature — nothing depends on the rail rate now.
//

import Foundation

/// Why a transaction landed in the review queue.
enum ReviewQueueReason: String, CaseIterable, Identifiable, Sendable {
    case billPayCandidate
    case weakCategory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .billPayCandidate: return "Bill pay?"
        case .weakCategory: return "Category"
        }
    }

    var systemImage: String {
        switch self {
        case .billPayCandidate: return "creditcard.circle"
        case .weakCategory: return "questionmark.circle"
        }
    }

    var shortHint: String {
        switch self {
        case .billPayCandidate:
            return "Looks like a card payment but isn’t bill pay"
        case .weakCategory:
            return "Misc / empty / uncategorized"
        }
    }
}

/// One queue row: a transaction plus one or more reasons it needs attention.
struct ReviewQueueItem: Identifiable {
    var id: String { transaction.transactionId }
    var transaction: Transaction
    var reasons: [ReviewQueueReason]
}

/// Static helpers that scan transactions and flag rows needing a human pass.
enum ReviewQueueAnalytics {
    /// Spend-like rows that need a human pass (newest first).
    static func items(
        in transactions: [Transaction],
        accounts: [BankAccount] = []
    ) -> [ReviewQueueItem] {
        let recent = recentSpend(in: transactions)
        var rows: [ReviewQueueItem] = []

        for tx in recent {
            var reasons: [ReviewQueueReason] = []

            if looksWeakCategory(tx.category) {
                reasons.append(.weakCategory)
            }
            if looksBillPayCandidate(tx) {
                reasons.append(.billPayCandidate)
            }

            if !reasons.isEmpty {
                rows.append(ReviewQueueItem(transaction: tx, reasons: reasons))
            }
        }

        return rows.sorted { $0.transaction.date > $1.transaction.date }
    }

    /// PERF: was `items(...).count`, which allocated a ReviewQueueItem per hit and then sorted
    /// the whole array before throwing it away. This runs on every Transactions-tab rebuild.
    /// Count the same rows without building or ordering them.
    static func count(in transactions: [Transaction], accounts: [BankAccount] = []) -> Int {
        recentSpend(in: transactions).reduce(into: 0) { total, tx in
            if needsReview(tx, accounts: accounts) { total += 1 }
        }
    }

    /// Spend rows recent enough to be worth reviewing (shared by items and count).
    private static func recentSpend(in transactions: [Transaction]) -> [Transaction] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? .distantPast
        return TransactionAnalytics.spendOnly(transactions).filter { $0.date >= cutoff }
    }

    private static func needsReview(_ tx: Transaction, accounts: [BankAccount]) -> Bool {
        looksWeakCategory(tx.category) || looksBillPayCandidate(tx)
    }

    // MARK: - Heuristics

    /// Empty or generic labels that usually need a real category.
    private static func looksWeakCategory(_ category: String) -> Bool {
        if TransactionAnalytics.isExcludedFromSpendCategory(category) { return false }
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if c.isEmpty { return true }
        return [
            "miscellaneous", "misc", "other", "uncategorized", "general",
            "transfer", "transfers", "unknown", "debit"
        ].contains(c)
    }

    /// Title text that often means “paying the credit card,” not true spend.
    private static func looksBillPayCandidate(_ tx: Transaction) -> Bool {
        if TransactionAnalytics.isExcludedFromSpendCategory(tx.category) { return false }
        let t = tx.title.lowercased()
        let needles = [
            "payment thank you", "payment thankyou", "autopay", "auto pay",
            "bill pay", "billpay", "credit card payment", "online payment",
            "payment to chase", "payment to amex", "payment to american",
            "payment to citi", "payment to capital", "payment to discover",
            "epay", "e-pay", "epmt", "ach payment"
        ]
        return needles.contains { t.contains($0) }
    }
}
