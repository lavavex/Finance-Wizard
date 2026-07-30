//
//  PeriodSpendIndex.swift
//  Finance Wizard
//
//  One pass over transactions for a calendar period: spend totals +
//  payment-method indexes. Shared by Accounts, Benefits, and widgets.
//

import Foundation

/// Precomputed spend view of the store for a single period.
struct PeriodSpendIndex {
    let period: SnapshotPeriod
    let referenceDate: Date

    /// Every transaction in the period (any category).
    let periodTransactions: [Transaction]
    /// Period rows that count as spend (bill-pay categories excluded).
    let spendTransactions: [Transaction]
    /// Sum of abs(amount) on spend rows.
    let totalSpend: Double
    /// Signed sum on spend rows.
    let spendBalance: Double

    /// Spend dollars + count per payment method (period spend only).
    let spendByMethod: [String: MethodTotals]
    /// Period spend transactions grouped by payment method.
    let spendTxsByMethod: [String: [Transaction]]
    /// Payment methods seen anywhere in the store (for account matching).
    let allKnownMethods: Set<String>

    struct MethodTotals: Sendable, Equatable {
        var spend: Double
        var count: Int
    }

    // MARK: - Build

    /// Single pass: period filter → spend filter → method indexes.
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
            guard !TransactionAnalytics.isExcludedFromSpend(tx) else { continue }

            spendTxs.append(tx)
            let dollars = abs(tx.amount)
            totalSpend += dollars
            spendBalance += tx.amount

            var totals = spendByMethod[method] ?? MethodTotals(spend: 0, count: 0)
            totals.spend += dollars
            totals.count += 1
            spendByMethod[method] = totals
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

    func spendTransactions(for methods: Set<String>) -> [Transaction] {
        var out: [Transaction] = []
        for m in methods {
            if let chunk = spendTxsByMethod[m] {
                out.append(contentsOf: chunk)
            }
        }
        return out
    }
}

// MARK: - Account ↔ payment method pool

extension BankAccount {
    /// Payment methods in `pool` that belong to this account, plus the Plaid label.
    func matchingPaymentMethods(in pool: Set<String>) -> Set<String> {
        var methods = Set<String>()
        for method in pool where matchesPaymentMethod(method) {
            methods.insert(method)
        }
        methods.insert(plaidDisplayName)
        return methods
    }
}
