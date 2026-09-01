//
//  ReviewQueueAnalytics.swift
//  Finance Wizard
//
//  “Needs review” queue: unlocked defaults, ambiguous rails, bill-pay
//  candidates, and weak categories.
//

import Foundation

/// Why a transaction landed in the review queue.
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
        let spend = TransactionAnalytics.spendOnly(transactions)
        let cal = Calendar.current
        let cutoff = cal.date(byAdding: .day, value: -120, to: Date()) ?? .distantPast
        let recent = spend.filter { $0.date >= cutoff }

        // Cache profiles so we do not rebuild the same card benefits for every row.
        var profileCache: [String: CardBenefitsProfile] = [:]
        var rows: [ReviewQueueItem] = []

        for tx in recent {
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
            if looksUnlockedDefault(tx, accounts: accounts, profileCache: &profileCache) {
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

    /// Debit vs ACH unclear on a rewards checking account where the two rates differ.
    private static func looksAmbiguousRail(_ tx: Transaction, accounts: [BankAccount]) -> Bool {
        guard let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts),
              account.isDepository else {
            return false
        }
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

    /// Multiplier looks like a stale default (not locked, and does not match the profile).
    private static func looksUnlockedDefault(
        _ tx: Transaction,
        accounts: [BankAccount],
        profileCache: inout [String: CardBenefitsProfile]
    ) -> Bool {
        if tx.isMultiplierLocked { return false }
        if TransactionAnalytics.isExcludedFromSpendCategory(tx.category) { return false }

        let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts)
        guard CardBenefitsStore.isRewardsEligible(account: account, paymentMethod: tx.paymentMethod) else {
            return false
        }

        let cacheKey = account?.accountId ?? tx.paymentMethod
        let profile: CardBenefitsProfile = {
            if let cached = profileCache[cacheKey] { return cached }
            let p = CardBenefitsStore.profile(
                accountId: account?.accountId,
                paymentMethod: tx.paymentMethod,
                accounts: accounts
            )
            profileCache[cacheKey] = p
            return p
        }()

        let expected = profile.rate(
            forTransactionCategory: tx.category,
            title: tx.title,
            on: tx.date
        )
        let stored = tx.multiplier
        if abs(stored - expected) > 0.05 { return true }
        if profile.rewardKind == .points, abs(stored - 1) < 0.001, abs(profile.defaultMultiplier - 1) > 0.05 {
            return true
        }
        return false
    }
}
