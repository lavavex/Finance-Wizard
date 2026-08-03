//
//  BudgetAnalytics.swift
//  Finance Wizard
//
//  Compare spend to the monthly budget plan for a period.
//
//  Learning notes:
//  - struct = a value type that groups related data (copied when passed around).
//  - enum with only static methods = a namespace for helpers (no instances needed).
//  - Computed properties (var with a body, no stored value) recalculate each time you read them.
//  - Optional types (Double?) mean “maybe a number, maybe nil (missing).”
//

import Foundation

/// Progress for one budget category in a period (spent vs optional limit).
/// Identifiable: SwiftUI lists need a stable `id` so rows can animate and update correctly.
struct BudgetCategoryProgress: Identifiable {
    /// Protocol requirement: unique key for this row (here, the category name).
    var id: String { category }
    let category: String
    let spent: Double
    /// `nil` means the user set no cap for this category.
    let limit: Double?
    let transactionCount: Int

    /// Dollars left under the limit. `nil` when there is no limit.
    /// `guard let` unwraps an optional and early-returns if it is missing.
    var remaining: Double? {
        guard let limit else { return nil }
        return limit - spent
    }

    /// How full the budget bar is: 0…1 normally; can exceed 1 when over budget.
    var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return spent / limit
    }

    /// True when spent is meaningfully past the limit (tiny epsilon avoids float noise).
    var isOver: Bool {
        guard let limit else { return false }
        return spent > limit + 0.005
    }
}

/// One frozen “picture” of budget health for a period (totals, income, per-category rows).
/// Built by `BudgetAnalytics.snapshot` so UI does not re-run heavy math in every view body.
struct BudgetSnapshot {
    let period: SnapshotPeriod
    let referenceDate: Date
    let periodLabel: String
    let totalSpent: Double
    let monthlyLimit: Double?
    /// Actual income deposited in the period (from synced Income rows).
    let income: Double
    /// Planned income for the period from expected streams.
    let expectedIncome: Double
    /// Sum of stream monthly estimates (always monthly cadence).
    let expectedMonthlyIncome: Double
    /// Soonest next payday across streams (if any).
    let nextPayday: Date?
    let categories: [BudgetCategoryProgress]
    let unbudgetedSpend: Double
    let transactionCount: Int

    /// Total budget remaining (monthly plan minus all spend).
    var totalRemaining: Double? {
        guard let monthlyLimit, monthlyLimit > 0 else { return nil }
        return monthlyLimit - totalSpent
    }

    /// Overall fill fraction for the monthly limit.
    var totalFraction: Double? {
        guard let monthlyLimit, monthlyLimit > 0 else { return nil }
        return totalSpent / monthlyLimit
    }

    var isOverTotal: Bool {
        guard let monthlyLimit else { return false }
        return totalSpent > monthlyLimit + 0.005
    }

    /// Actual − expected for the period (positive = more income than planned).
    var incomeVsExpected: Double? {
        guard expectedIncome > 0.005 || !expectedMonthlyIncome.isZero else { return nil }
        return income - expectedIncome
    }

    /// Spend headroom if using expected monthly income as the soft ceiling.
    var expectedIncomeRemaining: Double? {
        guard expectedMonthlyIncome > 0.005 else { return nil }
        return expectedMonthlyIncome - totalSpent
    }

    /// Sum of category limits (for display).
    /// compactMap(\.limit) keeps only non-nil limits; reduce(0, +) adds them starting at 0.
    /// The `\.limit` syntax is a key path: “read the `limit` property of each element.”
    var sumOfCategoryLimits: Double {
        categories.compactMap(\.limit).reduce(0, +)
    }
}

/// Pure analytics helpers for budgets (no UI). Call `snapshot` to build a `BudgetSnapshot`.
enum BudgetAnalytics {
    /// Builds a full budget picture: period spend, category progress, income vs plan.
    /// Default parameter values (`period:`, `referenceDate:`) apply when callers omit them.
    static func snapshot(
        plan: BudgetPlan,
        transactions: [Transaction],
        incomeRows: [Income] = [],
        period: SnapshotPeriod = .month,
        referenceDate: Date = Date()
    ) -> BudgetSnapshot {
        // One shared pass over transactions for totals + spend rows (see PeriodSpendIndex).
        let spendIndex = PeriodSpendIndex.build(
            transactions: transactions,
            period: period,
            referenceDate: referenceDate
        )
        // Group spend by category name into summary rows.
        let categorySpend = TransactionAnalytics.categorySummaries(
            from: spendIndex.spendTransactions,
            categoryLimit: nil
        )
        // Dictionary maps category name → summary for O(1) lookups later.
        // map transforms each summary into a (key, value) pair for the dictionary.
        let spentByCategory = Dictionary(
            uniqueKeysWithValues: categorySpend.map { ($0.category, $0) }
        )

        // Rows for every category that has a limit and/or spend this period
        var keys = Set(spentByCategory.keys)
        // where limit > 0: only real caps count toward “budgeted” categories
        for (cat, limit) in plan.categoryLimits where limit > 0 {
            keys.insert(KnownCategory.canonicalName(for: cat) ?? cat)
        }
        // Prefer Budget picker order, then any free-form leftovers A–Z
        let knownOrder = KnownCategory.budgetPickerNames
        // filter keeps names that are in keys; + concatenates two arrays
        let ordered = knownOrder.filter { keys.contains($0) }
            + keys.subtracting(Set(knownOrder)).sorted()

        var categories: [BudgetCategoryProgress] = []
        var budgetedSpend = 0.0
        for cat in ordered {
            // Optional chaining: summary?.spent is nil if the category is missing
            let summary = spentByCategory[cat]
            let spent = summary?.spent ?? 0
            let limit = plan.limit(forCategory: cat)
            if limit != nil { budgetedSpend += spent }
            // Skip zero-spend categories with no limit
            if spent < 0.005, limit == nil { continue }
            categories.append(
                BudgetCategoryProgress(
                    category: cat,
                    spent: spent,
                    limit: limit,
                    transactionCount: summary?.transactionCount ?? 0
                )
            )
        }

        // Categories with limits first (over budget on top), then unbudgeted by spend
        // Trailing closure: sort { a, b in … } is the comparison function.
        categories.sort { a, b in
            let aHas = a.limit != nil
            let bHas = b.limit != nil
            if aHas != bHas { return aHas && !bHas }
            if a.isOver != b.isOver { return a.isOver && !b.isOver }
            return a.spent > b.spent
        }

        let totalSpent = spendIndex.totalSpend
        // max(0, …) clamps so we never show negative unbudgeted spend
        let unbudgeted = max(0, totalSpent - budgetedSpend)
        let income = IncomeAnalytics.totalEarned(
            in: IncomeAnalytics.inPeriod(incomeRows, period: period, referenceDate: referenceDate)
        )

        let streams = plan.expectedIncomeStreams
        // reduce walks the array, accumulating a running total ($0 is so far, $1 is next item)
        let expectedInPeriod = streams.reduce(0.0) {
            $0 + $1.expectedAmount(in: period, referenceDate: referenceDate)
        }
        let expectedMonthly = plan.expectedMonthlyIncome
        // compactMap drops nil next-dates; min() picks the earliest Date among remaining
        let nextPayday = streams
            .compactMap { $0.nextDate(from: Date()) }
            .min()

        return BudgetSnapshot(
            period: period,
            referenceDate: referenceDate,
            periodLabel: period.filterLabel(referenceDate: referenceDate),
            totalSpent: totalSpent,
            // Immediately-invoked closure: run a small block to produce monthlyLimit
            monthlyLimit: {
                guard let m = plan.monthlyLimit, m > 0 else { return nil }
                return m
            }(),
            income: income,
            expectedIncome: expectedInPeriod,
            expectedMonthlyIncome: expectedMonthly,
            nextPayday: nextPayday,
            categories: categories,
            unbudgetedSpend: unbudgeted,
            transactionCount: spendIndex.spendTransactions.count
        )
    }
}
