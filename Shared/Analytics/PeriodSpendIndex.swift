//
//  PeriodSpendIndex.swift
//  Finance Wizard
//
//  One pass over transactions for a calendar period: spend totals +
//  payment-method indexes. Shared by Accounts, Benefits, and widgets.
//
//  Learning notes:
//  - Building indexes once avoids looping the same array many times in the UI.
//  - Set = unordered unique collection; Dictionary = key → value lookup.
//  - static func on a struct is a factory that returns a new value without needing `self`.
//  - extension adds methods to an existing type (here BankAccount) without editing its original file.
//

import Foundation

/// Precomputed spend view of the store for a single period.
/// Holds both raw lists and dictionary indexes so later lookups stay O(1) per method.
struct PeriodSpendIndex {
    let period: SnapshotPeriod
    let referenceDate: Date

    /// Every transaction in the period (any category).
    let periodTransactions: [Transaction]
    /// Period rows that count as spend (bill-pay categories excluded).
    let spendTransactions: [Transaction]
    /// Sum of abs(amount) on spend rows (always positive dollars spent).
    let totalSpend: Double
    /// Signed sum on spend rows (keeps refunds negative if present).
    let spendBalance: Double

    /// Spend dollars + count per payment method (period spend only).
    let spendByMethod: [String: MethodTotals]
    /// Period spend transactions grouped by payment method.
    let spendTxsByMethod: [String: [Transaction]]
    /// Payment methods seen anywhere in the store (for account matching).
    let allKnownMethods: Set<String>

    /// Nested struct: lives inside PeriodSpendIndex for organization.
    /// Sendable means safe to pass across concurrency boundaries; Equatable enables ==.
    struct MethodTotals: Sendable, Equatable {
        var spend: Double
        var count: Int
    }

    // MARK: - Build
    // MARK comments create jump-to sections in Xcode’s minimap and jump bar.

    /// Single pass: period filter → spend filter → method indexes.
    /// `static` = call as PeriodSpendIndex.build(...) without an existing instance.
    static func build(
        transactions: [Transaction],
        period: SnapshotPeriod,
        referenceDate: Date = Date()
    ) -> PeriodSpendIndex {
        let periodTxs = TransactionAnalytics.inPeriod(
            transactions,
            period: period,
            referenceDate: referenceDate
        )

        var spendTxs: [Transaction] = []
        // reserveCapacity hints the array how big it may grow (fewer reallocations).
        spendTxs.reserveCapacity(periodTxs.count)
        var spendByMethod: [String: MethodTotals] = [:]
        var spendTxsByMethod: [String: [Transaction]] = [:]
        var allKnown = Set<String>()
        var totalSpend = 0.0
        var spendBalance = 0.0

        // Methods from full history (orphans / matching even if no spend this period)
        for tx in transactions {
            allKnown.insert(TransactionAnalytics.cardName(for: tx))
        }

        for tx in periodTxs {
            let method = TransactionAnalytics.cardName(for: tx)
            allKnown.insert(method)
            // guard else { continue } skips non-spend rows (e.g. card payments)
            guard !TransactionAnalytics.isExcludedFromSpend(tx) else { continue }

            spendTxs.append(tx)
            let dollars = abs(tx.amount)
            totalSpend += dollars
            spendBalance += tx.amount

            // ?? provides a default when the dictionary has no entry for this method yet
            var totals = spendByMethod[method] ?? MethodTotals(spend: 0, count: 0)
            totals.spend += dollars
            totals.count += 1
            spendByMethod[method] = totals
            // default: [] creates an empty array for the key if missing, then appends
            spendTxsByMethod[method, default: []].append(tx)
        }

        return PeriodSpendIndex(
            period: period,
            referenceDate: referenceDate,
            periodTransactions: periodTxs,
            spendTransactions: spendTxs,
            totalSpend: totalSpend,
            spendBalance: spendBalance,
            spendByMethod: spendByMethod,
            spendTxsByMethod: spendTxsByMethod,
            allKnownMethods: allKnown
        )
    }

    // MARK: - Lookups

    /// Sum spend and counts across several payment-method names (one account may have many).
    func totals(for methods: Set<String>) -> MethodTotals {
        var spend = 0.0
        var count = 0
        for m in methods {
            if let t = spendByMethod[m] {
                spend += t.spend
                count += t.count
            }
        }
        return MethodTotals(spend: spend, count: count)
    }

    /// Flatten spend transactions for the given methods into one array.
    func spendTransactions(for methods: Set<String>) -> [Transaction] {
        var out: [Transaction] = []
        for m in methods {
            if let chunk = spendTxsByMethod[m] {
                // append(contentsOf:) adds every element of another sequence
                out.append(contentsOf: chunk)
            }
        }
        return out
    }
}

// MARK: - Account ↔ payment method pool

extension BankAccount {
    /// Payment methods in `pool` that belong to this account, plus the Plaid label.
    /// `where matchesPaymentMethod` filters the for-in loop to matching names only.
    func matchingPaymentMethods(in pool: Set<String>) -> Set<String> {
        var methods = Set<String>()
        for method in pool where matchesPaymentMethod(method) {
            methods.insert(method)
        }
        methods.insert(plaidDisplayName)
        return methods
    }
}
