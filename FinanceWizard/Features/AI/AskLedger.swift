//
//  AskLedger.swift
//  Finance Wizard
//
//  The arithmetic behind Ask. The on-device model is unreliable at math and has little context,
//  so the app computes every total and hands the model a short result to phrase.
//

import Foundation
import SwiftData

enum AskLedger {
    /// Cents precision, so tool results don't carry floating-point noise into the model.
    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    // MARK: - Date ranges

    struct MonthRange: Equatable {
        var start: Date
        var end: Date
        var label: String
    }

    /// Whole months from `from` through `to`. Takes "2026-03" or a month name. A blank or unknown
    /// value means this month. A month name means its most recent occurrence.
    static func monthRange(
        from: String,
        to: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MonthRange {
        let first = monthStart(from, now: now, calendar: calendar)
            ?? monthStart(to, now: now, calendar: calendar)
            ?? thisMonth(now: now, calendar: calendar)
        let last = monthStart(to, now: now, calendar: calendar) ?? first
        let start = min(first, last)
        let lastStart = max(first, last)
        let end = calendar.date(byAdding: .month, value: 1, to: lastStart) ?? lastStart
        let startLabel = monthLabel(start)
        let label = start == lastStart ? startLabel : "\(startLabel) through \(monthLabel(lastStart))"
        return MonthRange(start: start, end: end, label: label)
    }

    private static func thisMonth(now: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
    }

    private static func monthStart(_ raw: String, now: Date, calendar: Calendar) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let numeric = text.split(separator: "-").compactMap { Int($0) }
        if numeric.count >= 2, numeric[0] >= 2000, (1...12).contains(numeric[1]) {
            return calendar.date(from: DateComponents(year: numeric[0], month: numeric[1], day: 1))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let names = formatter.monthSymbols ?? []
        let lower = text.lowercased()
        guard let index = names.firstIndex(where: { lower.hasPrefix($0.lowercased().prefix(3)) }) else {
            return nil
        }
        let current = thisMonth(now: now, calendar: calendar)
        var year = calendar.component(.year, from: current)
        if index + 1 > calendar.component(.month, from: current) { year -= 1 }
        return calendar.date(from: DateComponents(year: year, month: index + 1, day: 1))
    }

    private static func monthLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))
    }

    // MARK: - Spending

    struct Charge: Equatable {
        var title: String
        var amount: Double
        var date: Date
    }

    struct MerchantTotal: Equatable {
        var name: String
        var amount: Double
    }

    struct Spending: Equatable {
        var headline: String
        var total: Double
        var refunds: Double
        var chargeCount: Int
        var largest: [Charge]
        var topMerchants: [MerchantTotal]
    }

    /// Spend after refunds, optionally narrowed to a merchant or a category.
    static func spending(
        merchant: String,
        category: String,
        range: MonthRange,
        in context: ModelContext
    ) -> Spending {
        let start = range.start
        let end = range.end
        let rows = (try? context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.date >= start && $0.date < end }
        ))) ?? []
        let filters = spendingFilters(merchant: merchant, category: category, categoriesInUse: rows.map(\.category))
        let merchantKey = searchKey(filters.merchant)
        let wantedCategory = filters.category

        let matching = rows.filter { row in
            if !merchantKey.isEmpty, !matchesMerchant(row, key: merchantKey) { return false }
            return true
        }
        let spend = TransactionAnalytics.spendOnly(matching).filter {
            wantedCategory.isEmpty || $0.category.caseInsensitiveCompare(wantedCategory) == .orderedSame
        }
        // A refund row doesn't record the purchase's category, so a category total stays gross.
        let refunds = wantedCategory.isEmpty ? TransactionAnalytics.refundTotal(in: matching) : 0
        let gross = spend.reduce(0) { $0 + abs($1.amount) }
        let total = max(0, gross - refunds)

        var byMerchant: [String: Double] = [:]
        for row in spend { byMerchant[row.title, default: 0] += abs(row.amount) }

        let subject: String = {
            var parts: [String] = []
            if !wantedCategory.isEmpty { parts.append("on \(wantedCategory)") }
            if !merchantKey.isEmpty { parts.append("at \(filters.merchant)") }
            return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        }()
        let headline: String
        if spend.isEmpty && refunds < 0.005 {
            headline = "No charges\(subject) in \(range.label)."
        } else {
            let plural = spend.count == 1 ? "charge" : "charges"
            let refundNote = refunds >= 0.005 ? ", after \(money(refunds)) in refunds" : ""
            headline = "You spent \(money(total))\(subject) in \(range.label) across \(spend.count) \(plural)\(refundNote)."
        }

        return Spending(
            headline: headline,
            total: rounded(total),
            refunds: rounded(refunds),
            chargeCount: spend.count,
            largest: spend.sorted { abs($0.amount) > abs($1.amount) }.prefix(3).map {
                Charge(title: $0.title, amount: rounded(abs($0.amount)), date: $0.displayDate)
            },
            topMerchants: merchantKey.isEmpty
                ? byMerchant.sorted { $0.value > $1.value }.prefix(3).map {
                    MerchantTotal(name: $0.key, amount: rounded($0.value))
                }
                : []
        )
    }

    /// The model sometimes fills an unused field with "all" or the field's own name, or puts a
    /// category in the merchant field. Left alone, those filters match nothing and read as $0.
    static func spendingFilters(
        merchant: String,
        category: String,
        categoriesInUse: [String] = []
    ) -> (merchant: String, category: String) {
        func cleaned(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return fillerWords.contains(trimmed.lowercased()) ? "" : trimmed
        }
        func categoryName(_ text: String) -> String? {
            KnownCategory.canonicalName(for: text)
                ?? categoriesInUse.first { $0.caseInsensitiveCompare(text) == .orderedSame }
        }
        var merchantName = cleaned(merchant)
        let categoryText = cleaned(category)
        var resolved = categoryText.isEmpty ? nil : categoryName(categoryText)

        if resolved == nil, !merchantName.isEmpty, let named = categoryName(merchantName) {
            resolved = named
            merchantName = ""
        } else if let resolved, merchantName.caseInsensitiveCompare(resolved) == .orderedSame {
            merchantName = ""
        }
        // A real name in the category field that isn't a category is most likely a merchant.
        if resolved == nil, merchantName.isEmpty { merchantName = categoryText }
        return (merchantName, resolved ?? "")
    }

    private static let fillerWords: Set<String> = [
        "all", "any", "none", "n/a", "na", "null", "nil", "empty", "unknown", "everything",
        "merchant", "merchants", "category", "categories", "all merchants", "all categories"
    ]

    /// Letters and digits only, so "Corner-Market" and "corner market" match.
    static func searchKey(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func matchesMerchant(_ row: Transaction, key: String) -> Bool {
        searchKey(row.title).contains(key) || searchKey(row.merchantName ?? "").contains(key)
    }

    // MARK: - Budget

    struct BudgetStatus: Equatable {
        struct Category: Equatable {
            var name: String
            var spent: Double
            var limit: Double
        }

        var headline: String
        var spent: Double
        var limit: Double?
        var remaining: Double?
        var overLimit: [Category]
        var closestToLimit: [Category]
    }

    static func budgetStatus(now: Date = .now, in context: ModelContext) -> BudgetStatus {
        let rows = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let plans = (try? context.fetch(FetchDescriptor<BudgetPlan>())) ?? []
        guard let plan = plans.first(where: { $0.planId == BudgetStore.defaultPlanId }) ?? plans.first else {
            let spent = rounded(TransactionAnalytics.totalSpend(
                in: TransactionAnalytics.inPeriod(rows, period: .month, referenceDate: now)
            ))
            return BudgetStatus(
                headline: "No budget is set. You've spent \(money(spent)) this month.",
                spent: spent,
                limit: nil,
                remaining: nil,
                overLimit: [],
                closestToLimit: []
            )
        }

        let snapshot = BudgetAnalytics.snapshot(plan: plan, transactions: rows, referenceDate: now)
        let limited: [BudgetStatus.Category] = snapshot.categories.compactMap { item in
            guard let limit = item.limit else { return nil }
            return .init(name: item.category, spent: rounded(item.spent), limit: rounded(limit))
        }
        let headline: String
        if let remaining = snapshot.totalRemaining, let limit = snapshot.monthlyLimit {
            let status = remaining >= 0
                ? "\(money(remaining)) left"
                : "\(money(abs(remaining))) over"
            headline = "You've spent \(money(snapshot.totalSpent)) of your \(money(limit)) monthly budget, \(status)."
        } else {
            headline = "You've spent \(money(snapshot.totalSpent)) this month. No total monthly limit is set."
        }
        return BudgetStatus(
            headline: headline,
            spent: rounded(snapshot.totalSpent),
            limit: snapshot.monthlyLimit.map { rounded($0) },
            remaining: snapshot.totalRemaining.map { rounded($0) },
            overLimit: limited.filter { $0.spent > $0.limit + 0.005 },
            closestToLimit: limited
                .filter { $0.spent <= $0.limit + 0.005 }
                .sorted { $0.spent / max($0.limit, 1) > $1.spent / max($1.limit, 1) }
                .prefix(3)
                .map { $0 }
        )
    }

    // MARK: - Upcoming card payments

    struct CardPayment: Equatable {
        var name: String
        var balance: Double
        var minimumDue: Double?
        var dueDate: Date
        var isOverdue: Bool
    }

    struct UpcomingPayments: Equatable {
        var headline: String
        var totalMinimum: Double
        var cards: [CardPayment]
    }

    static func upcomingPayments(now: Date = .now, in context: ModelContext) -> UpcomingPayments {
        let accounts = (try? context.fetch(FetchDescriptor<BankAccount>())) ?? []
        let today = Calendar.current.startOfDay(for: now)
        let cards: [CardPayment] = accounts.filter(\.isCredit).compactMap { account in
            guard let due = account.nextPaymentDueDate else { return nil }
            let overdue = account.isOverdue == true
            guard overdue || due >= today else { return nil }
            return CardPayment(
                name: account.displayName,
                balance: rounded(account.currentBalance),
                minimumDue: account.minimumPaymentAmount.map { rounded($0) },
                dueDate: due,
                isOverdue: overdue
            )
        }
        .sorted { $0.dueDate < $1.dueDate }
        let total = rounded(cards.compactMap(\.minimumDue).reduce(0, +))
        guard let next = cards.first else {
            return UpcomingPayments(
                headline: "No card payment due dates are known. Sync may need to finish.",
                totalMinimum: 0,
                cards: []
            )
        }
        let day = next.dueDate.formatted(.dateTime.month(.wide).day().locale(Locale(identifier: "en_US")))
        return UpcomingPayments(
            headline: "Next due: \(next.name) on \(day). Minimums total \(money(total)).",
            totalMinimum: total,
            cards: Array(cards.prefix(6))
        )
    }
}
