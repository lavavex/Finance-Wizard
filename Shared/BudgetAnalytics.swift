//
//  BudgetAnalytics.swift
//  Finance Wizard
//
//  Compare spend to the monthly budget plan for a period.
//

import Foundation

struct BudgetCategoryProgress: Identifiable {
    var id: String { category }
    let category: String
    let spent: Double
    let limit: Double?
    let transactionCount: Int

    var remaining: Double? {
        guard let limit else { return nil }
        return limit - spent
    }

    /// 0…1+ (can exceed 1 when over budget).
    var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return spent / limit
    }

    var isOver: Bool {
        guard let limit else { return false }
        return spent > limit + 0.005
    }
}

struct BudgetSnapshot {
    let period: SnapshotPeriod
    let referenceDate: Date
    let periodLabel: String
    let totalSpent: Double
    let monthlyLimit: Double?
    let income: Double
    let categories: [BudgetCategoryProgress]
    let unbudgetedSpend: Double
    let transactionCount: Int

    var totalRemaining: Double? {
        guard let monthlyLimit, monthlyLimit > 0 else { return nil }
        return monthlyLimit - totalSpent
    }

    var totalFraction: Double? {
        guard let monthlyLimit, monthlyLimit > 0 else { return nil }
        return totalSpent / monthlyLimit
    }

    var isOverTotal: Bool {
        guard let monthlyLimit else { return false }
        return totalSpent > monthlyLimit + 0.005
    }

    /// Sum of category limits (for display).
    var sumOfCategoryLimits: Double {
        categories.compactMap(\.limit).reduce(0, +)
    }
}

enum BudgetAnalytics {
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

        // Rows for every category that has a limit and/or spend this period
        var keys = Set(spentByCategory.keys)
        for (cat, limit) in plan.categoryLimits where limit > 0 {
            keys.insert(KnownCategory.canonicalName(for: cat) ?? cat)
        }
        // Prefer a stable order: KnownCategory order, then extras A–Z
        let knownOrder = KnownCategory.spendNames
        let ordered = knownOrder.filter { keys.contains($0) }
            + keys.subtracting(knownOrder).sorted()

        var categories: [BudgetCategoryProgress] = []
        var budgetedSpend = 0.0
        for cat in ordered {
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
            categories: categories,
            unbudgetedSpend: unbudgeted,
            transactionCount: spendIndex.spendTransactions.count
        )
    }
}
