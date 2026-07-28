//
//  ReviewQueueAnalytics.swift
//  Finance Wizard
//
//  “Needs review” queue: unlocked defaults, ambiguous rails, bill-pay
//  candidates, and weak categories.
//

import Foundation

enum ReviewQueueReason: String, CaseIterable, Identifiable, Sendable {
    case unlockedDefaultMultiplier
    case ambiguousRail
    case billPayCandidate
    case weakCategory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unlockedDefaultMultiplier: return "Check rate"
        case .ambiguousRail: return "Debit or transfer?"
        case .billPayCandidate: return "Bill pay?"
        case .weakCategory: return "Category"
        }
    }

    var systemImage: String {
        switch self {
        case .unlockedDefaultMultiplier: return "number.circle"
        case .ambiguousRail: return "arrow.left.arrow.right.circle"
        case .billPayCandidate: return "creditcard.circle"
        case .weakCategory: return "questionmark.circle"
        }
    }

    /// Longer explanation for docs / code — not shown as primary UI copy.
    var shortHint: String {
        switch self {
        case .unlockedDefaultMultiplier:
            return "Rewards rate not locked; Sync may overwrite"
        case .ambiguousRail:
            return "Debit vs ACH unclear (matters for debit cashback)"
        case .billPayCandidate:
            return "Looks like a card payment but isn’t bill pay"
        case .weakCategory:
            return "Misc / empty / uncategorized"
        }
    }
}

struct ReviewQueueItem: Identifiable {
    var id: String { transaction.transactionId }
    var transaction: Transaction
    var reasons: [ReviewQueueReason]
}

enum ReviewQueueAnalytics {
    /// Spend-like rows that need a human pass (newest first).
    static func items(
        in transactions: [Transaction],
        accounts: [BankAccount] = []
    ) -> [ReviewQueueItem] {
        let spend = TransactionAnalytics.spendOnly(transactions)
        var rows: [ReviewQueueItem] = []

        for tx in spend {
            var reasons: [ReviewQueueReason] = []

            if looksWeakCategory(tx.category) {
                reasons.append(.weakCategory)
            }
            if looksBillPayCandidate(tx) {
                reasons.append(.billPayCandidate)
            }
            if looksAmbiguousRail(tx, accounts: accounts) {
                reasons.append(.ambiguousRail)
            }
            if looksUnlockedDefault(tx, accounts: accounts) {
                reasons.append(.unlockedDefaultMultiplier)
            }

            if !reasons.isEmpty {
                rows.append(ReviewQueueItem(transaction: tx, reasons: reasons))
            }
        }

        return rows.sorted { $0.transaction.date > $1.transaction.date }
    }

    static func count(in transactions: [Transaction], accounts: [BankAccount] = []) -> Int {
        items(in: transactions, accounts: accounts).count
    }

    // MARK: - Heuristics

    private static func looksWeakCategory(_ category: String) -> Bool {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if c.isEmpty { return true }
        return [
            "miscellaneous", "misc", "other", "uncategorized", "general",
            "transfer", "transfers", "unknown"
        ].contains(c)
    }

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

    private static func looksAmbiguousRail(_ tx: Transaction, accounts: [BankAccount]) -> Bool {
        guard let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts),
              account.isDepository else {
            return false
        }
        // Only matter when debit/ACH rates differ (or X Money–style product)
        let debit = account.debitRewardMultiplier
        let ach = account.achRewardMultiplier
        let railsDiffer: Bool = {
            if let debit, let ach, abs(debit - ach) > 0.0001 { return true }
            return CardBenefitsStore.hasDebitRewards(account)
        }()
        guard railsDiffer else { return false }
        if tx.isPaymentRailLocked { return false }
        return tx.effectivePaymentRail == .other
    }

    private static func looksUnlockedDefault(_ tx: Transaction, accounts: [BankAccount]) -> Bool {
        if tx.isMultiplierLocked { return false }
        if TransactionAnalytics.isExcludedFromSpendCategory(tx.category) { return false }

        let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts)
        guard CardBenefitsStore.isRewardsEligible(account: account, paymentMethod: tx.paymentMethod) else {
            return false
        }

        let profile = CardBenefitsStore.profile(
            accountId: account?.accountId,
            paymentMethod: tx.paymentMethod,
            accounts: accounts
        )
        // Flag when stored mult matches base rate while a boost might apply, or still at 1 on a points card
        let expected = profile.rate(
            forTransactionCategory: tx.category,
            title: tx.title,
            on: tx.date
        )
        let stored = tx.multiplier
        // Unlocked and either at flat 1 while profile default/boost differs, or diverges from profile
        if abs(stored - expected) > 0.05 { return true }
        if abs(stored - profile.defaultMultiplier) < 0.05,
           profile.customCategoryRates().contains(where: { $0.rate > profile.defaultMultiplier + 0.05 }) {
            // Still at base while card has boosts — worth a glance if category might map wrong
            let reward = tx.effectiveRewardCategory
            let boost = profile.rate(forCategory: reward.rawValue, on: tx.date)
            if abs(boost - profile.defaultMultiplier) > 0.05, abs(stored - boost) > 0.05 {
                return true
            }
        }
        if profile.rewardKind == .points, abs(stored - 1) < 0.001, abs(profile.defaultMultiplier - 1) > 0.05 {
            return true
        }
        return false
    }
}
