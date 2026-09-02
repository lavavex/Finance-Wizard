//
//  BudgetAnalytics.swift
//  Finance Wizard
//
//  Compare spend to the monthly budget plan for a period.
//

import Foundation

/// Progress for one budget category in a period (spent vs optional limit).
struct BudgetCategoryProgress: Identifiable {
    var id: String { category }
    let category: String
    let spent: Double
    /// `nil` means the user set no cap for this category.
    let limit: Double?
    let transactionCount: Int

    /// Dollars left under the limit. `nil` when there is no limit.
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

/// Frozen budget health for a period (totals, income, per-category rows).
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
}

/// Pure analytics helpers for budgets (no UI). Call `snapshot` to build a `BudgetSnapshot`.
enum BudgetAnalytics {
    /// Builds a full budget picture: period spend, category progress, income vs plan.
    static func snapshot(
        plan: BudgetPlan,
        transactions: [Transaction],
        incomeRows: [Income] = [],
        period: SnapshotPeriod = .month,
        referenceDate: Date = Date()
    ) -> BudgetSnapshot {
        let spendIndex = PeriodSpendIndex.build(
            transactions: transactions,
            period: period,
            referenceDate: referenceDate
        )
        let categorySpend = TransactionAnalytics.categorySummaries(
            from: spendIndex.spendTransactions,
            categoryLimit: nil
        )
        let spentByCategory = Dictionary(
            uniqueKeysWithValues: categorySpend.map { ($0.category, $0) }
        )

        var keys = Set(spentByCategory.keys)
        for (cat, limit) in plan.categoryLimits where limit > 0 {
            keys.insert(KnownCategory.canonicalName(for: cat) ?? cat)
        }
        let knownOrder = KnownCategory.budgetPickerNames
        let ordered = knownOrder.filter { keys.contains($0) }
            + keys.subtracting(Set(knownOrder)).sorted()

        var categories: [BudgetCategoryProgress] = []
        var budgetedSpend = 0.0
        for cat in ordered {
            let summary = spentByCategory[cat]
            let spent = summary?.spent ?? 0
            let limit = plan.limit(forCategory: cat)
            if limit != nil { budgetedSpend += spent }
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

        categories.sort { a, b in
            let aHas = a.limit != nil
            let bHas = b.limit != nil
            if aHas != bHas { return aHas && !bHas }
            if a.isOver != b.isOver { return a.isOver && !b.isOver }
            return a.spent > b.spent
        }

        let totalSpent = spendIndex.totalSpend
        let unbudgeted = max(0, totalSpent - budgetedSpend)
        let income = IncomeAnalytics.totalEarned(
            in: IncomeAnalytics.inPeriod(incomeRows, period: period, referenceDate: referenceDate)
        )

        let streams = plan.expectedIncomeStreams
        let expectedInPeriod = streams.reduce(0.0) {
            $0 + $1.expectedAmount(in: period, referenceDate: referenceDate)
        }
        let expectedMonthly = plan.expectedMonthlyIncome
        let nextPayday = streams
            .compactMap { $0.nextDate(from: Date()) }
            .min()

        return BudgetSnapshot(
            period: period,
            referenceDate: referenceDate,
            periodLabel: period.filterLabel(referenceDate: referenceDate),
            totalSpent: totalSpent,
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
