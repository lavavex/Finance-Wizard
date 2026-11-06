//
//  MoneyInsights.swift
//  Finance Wizard
//
//  Explanations computed from the user's rows. The app finds what changed, so these work without
//  a model, and a model only ever rewords the facts.
//

import Foundation

struct MoneyInsight: Equatable {
    struct Section: Equatable {
        var title: String
        var lines: [String]
    }

    var headline: String
    var sections: [Section]

    /// Everything a model may use to write a summary.
    var facts: [String] {
        [headline] + sections.flatMap { section in section.lines.map { "\(section.title): \($0)" } }
    }
}

enum MoneyInsights {
    private static func money(_ value: Double) -> String { AskLedger.money(value) }

    private static func monthLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))
    }

    private static func previousMonth(_ month: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .month, value: -1, to: month) ?? month
    }

    private static func rows(_ all: [Transaction], in month: Date) -> [Transaction] {
        TransactionAnalytics.inPeriod(all, period: .month, referenceDate: month)
    }

    private static func gross(_ rows: [Transaction]) -> Double {
        rows.reduce(0) { $0 + abs($1.amount) }
    }

    /// Largest moves first, in either direction. Small changes aren't worth explaining.
    private static func changes(
        now: [Transaction],
        before: [Transaction],
        by key: (Transaction) -> String,
        limit: Int
    ) -> [String] {
        struct Change {
            var name: String
            var new: Double
            var old: Double
            var size: Double { abs(new - old) }
        }
        let current = Dictionary(grouping: now, by: key).mapValues { gross($0) }
        let previous = Dictionary(grouping: before, by: key).mapValues { gross($0) }
        let all = Set(current.keys).union(previous.keys).map { name in
            Change(name: name, new: current[name] ?? 0, old: previous[name] ?? 0)
        }
        let sorted = all.filter { $0.size >= 1 }.sorted { first, second in
            first.size == second.size ? first.name < second.name : first.size > second.size
        }
        return sorted.prefix(limit).map { change in
            let word = change.new > change.old ? "up" : "down"
            return "\(change.name) \(word) \(money(abs(change.new - change.old))), \(money(change.old)) to \(money(change.new))"
        }
    }

    private static func largest(_ rows: [Transaction], limit: Int) -> [String] {
        rows.sorted { abs($0.amount) > abs($1.amount) }.prefix(limit).map {
            "\($0.title), \(money(abs($0.amount)))"
        }
    }

    // MARK: - Why is this number what it is?

    /// A month's spending against the month before, optionally for one category.
    static func spending(
        _ all: [Transaction],
        month: Date,
        category: String? = nil,
        calendar: Calendar = .current
    ) -> MoneyInsight {
        let earlier = previousMonth(month, calendar: calendar)
        let matches = { (row: Transaction) in
            category == nil || row.category.caseInsensitiveCompare(category ?? "") == .orderedSame
        }
        let nowRows = TransactionAnalytics.spendOnly(rows(all, in: month)).filter(matches)
        let beforeRows = TransactionAnalytics.spendOnly(rows(all, in: earlier)).filter(matches)
        let total = category == nil ? TransactionAnalytics.totalSpend(in: rows(all, in: month)) : gross(nowRows)
        let before = category == nil ? TransactionAnalytics.totalSpend(in: rows(all, in: earlier)) : gross(beforeRows)
        let subject = category.map { "on \($0) " } ?? ""

        let direction: String
        if abs(total - before) < 0.005 {
            direction = "the same as"
        } else {
            direction = "\(money(abs(total - before))) \(total > before ? "more than" : "less than")"
        }
        var sections: [MoneyInsight.Section] = []
        if category == nil {
            let moves = changes(now: nowRows, before: beforeRows, by: \.category, limit: 4)
            if !moves.isEmpty { sections.append(.init(title: "Biggest category changes", lines: moves)) }
        }
        let merchants = changes(now: nowRows, before: beforeRows, by: \.title, limit: 4)
        if !merchants.isEmpty { sections.append(.init(title: "Biggest merchant changes", lines: merchants)) }
        let top = largest(nowRows, limit: 3)
        if !top.isEmpty { sections.append(.init(title: "Largest charges", lines: top)) }

        return MoneyInsight(
            headline: "You spent \(money(total)) \(subject)in \(monthLabel(month)), \(direction) \(monthLabel(earlier)) (\(money(before))).",
            sections: sections
        )
    }

    /// How one charge compares with earlier charges at the same merchant.
    static func charge(_ row: Transaction, among all: [Transaction]) -> MoneyInsight {
        let amount = abs(row.amount)
        let earlier = TransactionAnalytics.spendOnly(all)
            .filter { $0.title == row.title && $0.transactionId != row.transactionId && $0.date < row.date }
            .sorted { $0.date > $1.date }
        guard let last = earlier.first else {
            return MoneyInsight(
                headline: "This is your first charge from \(row.title), at \(money(amount)).",
                sections: []
            )
        }
        let average = gross(earlier) / Double(earlier.count)
        let difference = amount - average
        let comparison: String
        if abs(difference) < 0.5 {
            comparison = "about your usual amount"
        } else {
            comparison = "\(money(abs(difference))) \(difference > 0 ? "above" : "below") your average of \(money(average))"
        }
        let day = last.date.formatted(.dateTime.month(.wide).day().year().locale(Locale(identifier: "en_US")))
        return MoneyInsight(
            headline: "This \(money(amount)) charge from \(row.title) is \(comparison).",
            sections: [
                .init(title: "History", lines: [
                    "\(earlier.count + 1) charges in total, \(money(gross(earlier) + amount)) overall",
                    "Previous charge: \(money(abs(last.amount))) on \(day)",
                ]),
            ]
        )
    }

    // MARK: - Monthly recap

    static func monthlyRecap(
        _ all: [Transaction],
        income: [Income],
        budget: BudgetSnapshot? = nil,
        month: Date,
        calendar: Calendar = .current
    ) -> MoneyInsight {
        let earlier = previousMonth(month, calendar: calendar)
        let nowRows = TransactionAnalytics.spendOnly(rows(all, in: month))
        let beforeRows = TransactionAnalytics.spendOnly(rows(all, in: earlier))
        let spent = TransactionAnalytics.totalSpend(in: rows(all, in: month))
        let spentBefore = TransactionAnalytics.totalSpend(in: rows(all, in: earlier))
        let interval = calendar.dateInterval(of: .month, for: month)
        let earned = income
            .filter { interval?.contains($0.date) == true && !IncomeAnalytics.nonEarningsCategories.contains($0.category) }
            .reduce(0) { $0 + $1.amount }

        let change = spent - spentBefore
        let net = earned - spent
        var sections: [MoneyInsight.Section] = [
            .init(title: "Overview", lines: [
                "Income: \(money(earned))",
                "Spending: \(money(spent)), \(money(abs(change))) \(change >= 0 ? "more" : "less") than \(monthLabel(earlier))",
                "\(net >= 0 ? "Left over" : "Overspent"): \(money(abs(net)))",
            ]),
        ]
        let moves = changes(now: nowRows, before: beforeRows, by: \.category, limit: 4)
        if !moves.isEmpty { sections.append(.init(title: "Biggest category changes", lines: moves)) }
        let prices = priceChanges(all, month: month, calendar: calendar)
        if !prices.isEmpty { sections.append(.init(title: "Price changes", lines: prices)) }
        let merchants = newMerchants(all, nowRows: nowRows, month: month, calendar: calendar)
        if !merchants.isEmpty { sections.append(.init(title: "New this month", lines: merchants)) }
        let top = largest(nowRows, limit: 3)
        if !top.isEmpty { sections.append(.init(title: "Largest charges", lines: top)) }
        if let budget {
            let over = budget.categories.compactMap { item -> String? in
                guard let limit = item.limit, item.spent > limit + 0.005 else { return nil }
                return "\(item.category): \(money(item.spent)) of \(money(limit))"
            }
            if !over.isEmpty { sections.append(.init(title: "Over budget", lines: over)) }
        }

        return MoneyInsight(
            headline: "In \(monthLabel(month)) you earned \(money(earned)) and spent \(money(spent)).",
            sections: sections
        )
    }

    /// A merchant that charged one steady amount for at least three months and then changed it.
    static func priceChanges(_ all: [Transaction], month: Date, calendar: Calendar = .current) -> [String] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start else { return [] }
        let spend = TransactionAnalytics.spendOnly(all)
        return Dictionary(grouping: spend, by: \.title).compactMap { title, rows -> (String, Double)? in
            let earlier = rows.filter { $0.date < start }.sorted { $0.date > $1.date }
            let current = rows.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }
            guard current.count == 1, let new = current.first.map({ abs($0.amount) }) else { return nil }
            let recent = earlier.prefix(3).map { abs($0.amount) }
            guard recent.count == 3, let old = recent.first,
                  recent.allSatisfy({ abs($0 - old) < 0.01 }),
                  abs(new - old) >= 0.5 else { return nil }
            return ("\(title): \(money(old)) to \(money(new))", abs(new - old))
        }
        .sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        .prefix(5)
        .map(\.0)
    }

    private static func newMerchants(
        _ all: [Transaction],
        nowRows: [Transaction],
        month: Date,
        calendar: Calendar
    ) -> [String] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start else { return [] }
        let seen = Set(all.filter { $0.date < start }.map(\.title))
        // With no earlier history, everything is new, which says nothing.
        guard !seen.isEmpty else { return [] }
        let fresh = nowRows.filter { !seen.contains($0.title) }
        return Dictionary(grouping: fresh, by: \.title)
            .mapValues { gross($0) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3)
            .map { "\($0.key), \(money($0.value))" }
    }
}

// MARK: - Money plan

extension MoneyInsights {
    /// Everything a cloud model needs to plan: cash, debts, income, bills, and where the rest goes.
    static func moneyPlan(
        _ all: [Transaction],
        income: [Income],
        accounts: [BankAccount],
        plans: [PayoffPlan],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MoneyInsight {
        let dollars = { (value: Double) in AskLedger.money(value) }
        var sections: [MoneyInsight.Section] = []

        let cash = accounts.filter { !$0.isCredit }
        if !cash.isEmpty {
            sections.append(.init(
                title: "Cash accounts",
                lines: cash.map { "\($0.displayName): \(dollars($0.availableBalance ?? $0.currentBalance))" }
            ))
        }
        let cards = accounts.filter(\.isCredit).sorted { $0.currentBalance > $1.currentBalance }
        if !cards.isEmpty {
            sections.append(.init(title: "Credit cards", lines: cards.map { card in
                var line = "\(card.displayName): owes \(dollars(card.currentBalance))"
                if let minimum = card.minimumPaymentAmount { line += ", minimum \(dollars(minimum))" }
                if let due = card.nextPaymentDueDate {
                    line += ", due \(due.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US"))))"
                }
                if let apr = card.purchaseApr { line += ", \(apr.formatted(.number.precision(.fractionLength(0...2))))% APR" }
                return line
            }))
        }
        let activePlans = plans.filter(\.isActive)
        if !activePlans.isEmpty {
            sections.append(.init(title: "Payoff plans", lines: activePlans.map { plan in
                var line = "\(plan.name) on \(plan.paymentMethod): \(dollars(plan.monthlyPayment)) a month, \(dollars(plan.remainingAmount)) left"
                if let apr = plan.aprPercent { line += ", \(apr.formatted(.number.precision(.fractionLength(0...2))))% APR" }
                return line
            }))
        }

        // The last three full months, so a month in progress doesn't skew the averages.
        let thisMonth = TransactionAnalytics.monthStart(for: now)
        let earliest = calendar.date(byAdding: .month, value: -3, to: thisMonth) ?? thisMonth
        let paid = income.filter {
            $0.date >= earliest && $0.date < thisMonth && !IncomeAnalytics.nonEarningsCategories.contains($0.category)
        }
        if !paid.isEmpty {
            let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            let earned = income.filter { $0.date >= yearAgo && !IncomeAnalytics.nonEarningsCategories.contains($0.category) }
            // By source, so a question about one employer has an answer. A bank can rename the
            // same paycheck partway through, so these can overlap.
            let sources = Dictionary(grouping: earned, by: \.source)
                .map { source, rows -> (date: Date, line: String) in
                    let last = rows.map(\.date).max() ?? now
                    let average = rows.reduce(0) { $0 + $1.amount } / Double(rows.count)
                    let category = rows.last?.category ?? "Income"
                    return (last, "\(source) (\(category)): \(rows.count) deposits, about \(dollars(average)) each, last \(shortDay(last))")
                }
                .sorted { $0.date > $1.date }
                .prefix(8)
                .map(\.line)
            sections.append(.init(
                title: "Income",
                lines: ["Average \(dollars(paid.reduce(0) { $0 + $1.amount } / 3)) a month"] + sources
            ))
        }

        let spend = TransactionAnalytics.spendOnly(all)
        let recurring = SubscriptionAnalytics.detect(in: all, now: now)
        let categoryOf = Dictionary(spend.map { ($0.transactionId, $0.category) }, uniquingKeysWith: { first, _ in first })
        let isSubscription = { (item: SubscriptionCandidate) -> Bool in
            let category = item.sampleTransactionIds.last.flatMap { categoryOf[$0] } ?? ""
            return ["entertainment", "subscriptions", "shopping"].contains(category.lowercased())
        }
        let describe = { (item: SubscriptionCandidate) in
            "\(item.displayVendor): \(dollars(item.estimatedMonthly)) a month, last charged \(shortDay(item.lastDate))"
        }
        let bills = recurring.filter { !isSubscription($0) }.map(describe)
        if !bills.isEmpty { sections.append(.init(title: "Recurring bills", lines: bills)) }
        let subscriptions = recurring.filter(isSubscription).map(describe)
        if !subscriptions.isEmpty { sections.append(.init(title: "Subscriptions", lines: subscriptions)) }

        let known = Set(recurring.flatMap(\.sampleTransactionIds))
        let vagueSince = calendar.date(byAdding: .day, value: -60, to: now) ?? now
        let vague = spend
            .filter { $0.date >= vagueSince && !known.contains($0.transactionId) && looksLikeVaguePayment($0.title) }
            .sorted { $0.date > $1.date }
            .prefix(8)
            .map { "\($0.title): \(dollars(abs($0.amount))) on \(shortDay($0.date))" }
        if !vague.isEmpty { sections.append(.init(title: "Unidentified bank payments", lines: Array(vague))) }

        let window = spend.filter { $0.date >= earliest && $0.date < thisMonth && !known.contains($0.transactionId) }
        let byCategory = Dictionary(grouping: window, by: \.category)
            .mapValues { $0.reduce(0) { $0 + abs($1.amount) } / 3 }
            .sorted { $0.value > $1.value }
            .prefix(6)
        if !byCategory.isEmpty {
            sections.append(.init(
                title: "Other spending, monthly average",
                lines: byCategory.map { "\($0.key): \(dollars($0.value))" }
            ))
        }
        let byMerchant = Dictionary(grouping: window, by: \.title)
            .mapValues { $0.reduce(0) { $0 + abs($1.amount) } / 3 }
            .sorted { $0.value > $1.value }
            .prefix(8)
        if !byMerchant.isEmpty {
            sections.append(.init(
                title: "Top merchants, monthly average",
                lines: byMerchant.map { "\($0.key): \(dollars($0.value))" }
            ))
        }

        let owed = cards.reduce(0) { $0 + $1.currentBalance }
        return MoneyInsight(
            headline: "Cards owe \(dollars(owed)) in total, with \(dollars(cash.reduce(0) { $0 + ($1.availableBalance ?? $1.currentBalance) })) in cash accounts.",
            sections: sections
        )
    }

    private static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(Locale(identifier: "en_US")))
    }

    /// Bank lines that hide who was paid, so a model should ask rather than assume.
    static func looksLikeVaguePayment(_ title: String) -> Bool {
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["payment", "web pmts", "web pmt", "ach pmt", "ach payment", "bill pay", "billpay", "autopay", "online payment", "check"]
            .contains(lower)
    }
}

// MARK: - Search

/// What a plain-English transaction search asked for, once read by the model.
struct TransactionSearchFilter: Equatable {
    var merchant = ""
    var category = ""
    var minAmount: Double?
    var maxAmount: Double?
    var fromMonth = ""
    var toMonth = ""

    /// The model invents filters, such as adding Shopping to a search for Amazon, and each one
    /// silently hides rows. Keep only what the user's own words support.
    func supported(by query: String) -> TransactionSearchFilter {
        let lower = query.lowercased()
        let words = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var result = self

        let merchantWords = merchant.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !Self.genericWords.contains($0) }
        result.merchant = merchantWords.allSatisfy(words.contains) ? merchantWords.joined(separator: " ") : ""

        let categoryWords = category.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !Self.genericWords.contains($0) }
        result.category = categoryWords.contains(where: words.contains) ? categoryWords.joined(separator: " ") : ""
        if result.category.isEmpty {
            result.category = words.compactMap { KnownCategory.canonicalName(for: $0) }.first ?? ""
        }
        // A word that named the category shouldn't also search merchants.
        if KnownCategory.canonicalName(for: result.merchant) != nil { result.merchant = "" }

        let hasNumber = words.contains { $0.contains(where: \.isNumber) }
        if !hasNumber || (minAmount ?? 1) <= 0 { result.minAmount = nil }
        if !hasNumber || (maxAmount ?? 1) <= 0 { result.maxAmount = nil }
        if !words.contains(where: { Self.timeWords.contains($0) || $0.count == 4 && Int($0) != nil }) {
            result.fromMonth = ""
            result.toMonth = ""
        }
        return result
    }

    private static let genericWords: Set<String> = [
        "charge", "charges", "purchase", "purchases", "transaction", "transactions", "payment", "payments",
        "spending", "stuff", "all", "my", "any"
    ]

    private static let timeWords: Set<String> = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let months = (formatter.monthSymbols ?? []) + (formatter.shortMonthSymbols ?? [])
        return Set(months.map { $0.lowercased() } + ["last", "this", "month", "year", "since", "ago", "yesterday", "today"])
    }()

    private var range: AskLedger.MonthRange? {
        guard !fromMonth.isEmpty || !toMonth.isEmpty else { return nil }
        return AskLedger.monthRange(from: fromMonth, to: toMonth)
    }

    func matches(in rows: [Transaction]) -> [Transaction] {
        let filters = AskLedger.spendingFilters(merchant: merchant, category: category, categoriesInUse: rows.map(\.category))
        let merchantKey = AskLedger.searchKey(filters.merchant)
        let range = range
        return rows.filter { row in
            let amount = abs(row.amount)
            if let minAmount, amount < minAmount { return false }
            if let maxAmount, amount > maxAmount { return false }
            if let range, row.date < range.start || row.date >= range.end { return false }
            if !filters.category.isEmpty, row.category.caseInsensitiveCompare(filters.category) != .orderedSame { return false }
            if !merchantKey.isEmpty, !AskLedger.matchesMerchant(row, key: merchantKey) { return false }
            return true
        }
        .sorted { $0.date > $1.date }
    }

    /// Shown above results, so a misread search is obvious.
    var summary: String {
        let filters = AskLedger.spendingFilters(merchant: merchant, category: category)
        var parts: [String] = []
        if !filters.merchant.isEmpty { parts.append(filters.merchant) }
        if !filters.category.isEmpty { parts.append(filters.category) }
        if let minAmount { parts.append("over \(AskLedger.money(minAmount))") }
        if let maxAmount { parts.append("under \(AskLedger.money(maxAmount))") }
        if let range { parts.append(range.label) }
        return parts.isEmpty ? "All transactions" : parts.joined(separator: " · ")
    }
}
