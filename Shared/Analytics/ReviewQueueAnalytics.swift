//
//  ReviewQueueAnalytics.swift
//  Finance Wizard
//
//  “Needs review” queue: unlocked defaults, ambiguous rails, bill-pay
//  candidates, and weak categories.
//
//  Learning notes:
//  - enum cases are fixed choices (like a multiple-choice list).
//  - CaseIterable auto-builds allCases so UI can loop every reason.
//  - RawValue enums (String) store a string behind each case for persistence/debug.
//  - inout parameters let a function update a value the caller still owns (profileCache).
//

import Foundation

/// Why a transaction landed in the review queue.
/// Identifiable + CaseIterable help SwiftUI pickers and ForEach.
enum ReviewQueueReason: String, CaseIterable, Identifiable, Sendable {
    case unlockedDefaultMultiplier
    case ambiguousRail
    case billPayCandidate
    case weakCategory

    /// Identifiable: use the raw string as the stable id.
    var id: String { rawValue }

    /// Short title shown in the UI.
    var title: String {
        // switch must handle every case (exhaustive) unless you add default
        switch self {
        case .unlockedDefaultMultiplier: return "Check rate"
        case .ambiguousRail: return "Debit or transfer?"
        case .billPayCandidate: return "Bill pay?"
        case .weakCategory: return "Category"
        }
    }

    /// SF Symbol name (Apple’s built-in icon set) for this reason.
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

/// One queue row: a transaction plus one or more reasons it needs attention.
struct ReviewQueueItem: Identifiable {
    var id: String { transaction.transactionId }
    var transaction: Transaction
    var reasons: [ReviewQueueReason]
}

/// Static helpers that scan transactions and flag rows needing a human pass.
enum ReviewQueueAnalytics {
    /// Spend-like rows that need a human pass (newest first).
    /// Default `accounts: []` lets callers omit accounts when rail checks are not needed.
    static func items(
        in transactions: [Transaction],
        accounts: [BankAccount] = []
    ) -> [ReviewQueueItem] {
        let spend = TransactionAnalytics.spendOnly(transactions)
        // Cap work: only recent spend for the queue (full history is too heavy for the UI).
        let cal = Calendar.current
        // date(byAdding:) walks backward 120 days; ?? uses distantPast if that fails
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
            // &profileCache: pass the dictionary as inout so the helper can fill the cache
            if looksUnlockedDefault(tx, accounts: accounts, profileCache: &profileCache) {
                reasons.append(.unlockedDefaultMultiplier)
            }

            if !reasons.isEmpty {
                rows.append(ReviewQueueItem(transaction: tx, reasons: reasons))
            }
        }

        // Newest transactions first (descending date)
        return rows.sorted { $0.transaction.date > $1.transaction.date }
    }

    /// Count of queue items (thin wrapper when the UI only needs a badge number).
    static func count(in transactions: [Transaction], accounts: [BankAccount] = []) -> Int {
        items(in: transactions, accounts: accounts).count
    }

    // MARK: - Heuristics
    // private static = only this file can call them; keeps the public API small.

    /// Empty or generic labels that usually need a real category.
    private static func looksWeakCategory(_ category: String) -> Bool {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if c.isEmpty { return true }
        return [
            "miscellaneous", "misc", "other", "uncategorized", "general",
            "transfer", "transfers", "unknown"
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
        // contains { } is true if any needle appears inside the title
        return needles.contains { t.contains($0) }
    }

    /// Debit vs ACH unclear on a rewards checking account where the two rates differ.
    private static func looksAmbiguousRail(_ tx: Transaction, accounts: [BankAccount]) -> Bool {
        // guard with comma: all conditions must succeed or we return false
        guard let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts),
              account.isDepository else {
            return false
        }
        // Only matter when debit/ACH rates differ (or X Money–style product)
        let debit = account.debitRewardMultiplier
        let ach = account.achRewardMultiplier
        // Nested closure assigned to a local Bool for readability
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
        // Load profile once per key; store it so the next transaction reuses it
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
        // Stored rate far from profile → needs review
        if abs(stored - expected) > 0.05 { return true }
        // Points card stuck at 1x when the profile default is higher
        if profile.rewardKind == .points, abs(stored - 1) < 0.001, abs(profile.defaultMultiplier - 1) > 0.05 {
            return true
        }
        return false
    }
}
