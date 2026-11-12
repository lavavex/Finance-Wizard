//
//  AskPlan.swift
//  Finance Wizard
//
//  A budget and a card payoff order, worked out by the app. The on-device model only has to pick
//  one and introduce it, and the sections go into the chat exactly as written here.
//

import Foundation

enum AskPlan {
    static let budgetTitle = "Starting budget"
    static let payoffTitle = "Pay in this order"

    private static func dollars(_ value: Double) -> String { AskLedger.money(value) }

    /// Spending a budget shouldn't squeeze. Everything else is what gets cut to fit.
    private static let needs: Set<String> = Set([
        KnownCategory.housing, .utilities, .homeInternet, .carInsurance, .insurance, .groceries,
        .gas, .transit, .health, .education, .pets,
    ].map(\.rawValue))

    /// The answer as it appears in the chat: the headline, then the sections.
    static func chatText(_ plan: MoneyInsight) -> String {
        let sections = plan.sections.map { section in
            ([section.title] + section.lines.map { "- \($0)" }).joined(separator: "\n")
        }
        return ([plan.headline] + sections).joined(separator: "\n\n")
    }

    // MARK: - Budget

    /// The income source a question names, like "what I bring in from Example Market".
    static func incomeSource(namedIn question: String, among income: [Income]) -> String {
        let key = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let asked = key(question)
        return Set(income.map(\.source))
            .filter { key($0).count >= 4 && asked.contains(key($0)) }
            .max { key($0).count < key($1).count } ?? ""
    }

    /// Income against bills and card minimums, then a budget for what's left, sized from the last
    /// three full months so a month in progress doesn't skew it.
    /// - Parameter incomeSource: An employer the user named, to budget on that income alone.
    static func budget(
        _ all: [Transaction],
        income: [Income],
        accounts: [BankAccount],
        plans: [PayoffPlan],
        incomeSource: String = "",
        now: Date = .now,
        calendar: Calendar = .current
    ) -> MoneyInsight {
        var sections: [MoneyInsight.Section] = []
        let thisMonth = TransactionAnalytics.monthStart(for: now)
        let earliest = calendar.date(byAdding: .month, value: -3, to: thisMonth) ?? thisMonth
        let spend = TransactionAnalytics.spendOnly(all)
        let recentSpend = spend.filter { $0.date >= earliest && $0.date < thisMonth }
        let earned = income.filter {
            $0.date >= earliest && $0.date < thisMonth && !IncomeAnalytics.nonEarningsCategories.contains($0.category)
        }
        // A newly linked bank may not have three months yet, and dividing by three would shrink it.
        let months = Double(max(1, Set((recentSpend.map(\.date) + earned.map(\.date)).map {
            TransactionAnalytics.monthStart(for: $0)
        }).count))

        let key = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = key(incomeSource)
        let fromSource = wanted.isEmpty ? [] : earned.filter { key($0.source).contains(wanted) }
        // A one-time deposit, like a loan payout or a cash deposit, isn't income to budget on.
        let bySource = Dictionary(grouping: earned, by: \.source)
        let repeating = bySource.filter { _, rows in
            months < 2 || Set(rows.map { TransactionAnalytics.monthStart(for: $0.date) }).count >= 2
        }
        let steady = repeating.isEmpty ? earned : repeating.values.flatMap { $0 }
        let oneTime = repeating.isEmpty ? [] : earned.filter { repeating[$0.source] == nil }
        let counted = fromSource.isEmpty ? steady : fromSource
        let monthlyIncome = counted.reduce(0) { $0 + $1.amount } / months
        guard monthlyIncome > 0 else {
            return MoneyInsight(
                headline: "I don't see any income in the last three months, so I can't build a budget yet.",
                sections: []
            )
        }
        var incomeLines = Dictionary(grouping: counted, by: \.source)
            .mapValues { $0.reduce(0) { $0 + $1.amount } / months }
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key): about \(dollars($0.value)) a month" }
        sections.append(.init(title: "Income", lines: incomeLines))

        let detected = SubscriptionAnalytics.detect(in: all, now: now)
        let bills = detected.filter { !SubscriptionAnalytics.isOverdue($0, now: now) }
            .sorted { $0.estimatedMonthly > $1.estimatedMonthly }
        let billTotal = bills.reduce(0) { $0 + $1.estimatedMonthly }
        let minimums = accounts.filter(\.isCredit).compactMap { card -> (name: String, amount: Double)? in
            guard let minimum = card.minimumPaymentAmount, minimum > 0 else { return nil }
            return (card.displayName, minimum)
        }
        let minimumTotal = minimums.reduce(0) { $0 + $1.amount }
        // A plan on the card's statement is already inside that card's minimum.
        let extra = plans.filter { $0.isActive && !$0.kind.followsCardStatement }
        let extraTotal = extra.reduce(0) { $0 + $1.monthlyPayment }
        var fixedLines = bills.prefix(8).map { "\($0.displayVendor): \(dollars($0.estimatedMonthly))" }
        if bills.count > 8 {
            fixedLines.append("\(bills.count - 8) smaller ones: \(dollars(bills.dropFirst(8).reduce(0) { $0 + $1.estimatedMonthly }))")
        }
        fixedLines += minimums.map { "\($0.name) minimum: \(dollars($0.amount))" }
        fixedLines += extra.map { "\($0.name): \(dollars($0.monthlyPayment))" }
        let fixed = billTotal + minimumTotal + extraTotal
        if !fixedLines.isEmpty {
            sections.append(.init(title: "Bills and card minimums, \(dollars(fixed)) a month", lines: fixedLines))
        }

        let known = Set(detected.flatMap(\.sampleTransactionIds))
        let other = Dictionary(grouping: recentSpend.filter { !known.contains($0.transactionId) }, by: \.category)
            .mapValues { $0.reduce(0) { $0 + abs($1.amount) } / months }
            .sorted { $0.value > $1.value }
        let otherTotal = other.reduce(0) { $0 + $1.value }
        let left = monthlyIncome - fixed

        var headline = "You bring in about \(dollars(monthlyIncome)) a month"
        if !fromSource.isEmpty { headline += " from \(fromSource[0].source)" }
        if left <= 0 {
            headline += ", and bills and card minimums take \(dollars(fixed)), which is \(dollars(-left)) more than that."
            sections.append(.init(title: budgetTitle, lines: [
                "Nothing is left after bills and minimums, so the first step is cutting a bill or adding income",
            ]))
        } else {
            headline += ". Bills and card minimums take \(dollars(fixed)), leaving \(dollars(left))."
            // Needs keep their usual amount, and everything else shares what remains.
            let needsTotal = other.filter { needs.contains($0.key) }.reduce(0) { $0 + $1.value }
            let wantsTotal = otherTotal - needsTotal
            let forWants = max(0, left - needsTotal)
            let scale = wantsTotal > forWants ? forWants / wantsTotal : 1
            let budgeted = { (category: String, average: Double) in
                (needs.contains(category) ? average : average * scale).rounded()
            }
            // Needs first, then the rest, each largest first.
            let ordered = other.filter { needs.contains($0.key) } + other.filter { !needs.contains($0.key) }
            let shown = Set((other.filter { needs.contains($0.key) }.prefix(4) + other.filter { !needs.contains($0.key) }.prefix(5)).map(\.key))
            var lines = ordered.filter { shown.contains($0.key) }.map { category, average -> String in
                let amount = budgeted(category, average)
                return amount < average.rounded()
                    ? "\(category): \(dollars(amount)), down from \(dollars(average))"
                    : "\(category): \(dollars(amount)), your usual"
            }
            let rest = other.filter { !shown.contains($0.key) }
            if !rest.isEmpty {
                lines.append("Everything else: \(dollars(rest.reduce(0) { $0 + budgeted($1.key, $1.value) }))")
            }
            if needsTotal > left {
                lines.append("Needs alone come to \(dollars(needsTotal)), which is more than what's left")
            }
            if otherTotal > left {
                headline += " Your other spending averages \(dollars(otherTotal)), so it has to come down by \(dollars(otherTotal - left)) to fit."
            } else {
                let free = left - otherTotal
                headline += " Your other spending averages \(dollars(otherTotal)), so about \(dollars(free)) is free for debt or savings."
                lines.append("Extra card payments or savings: \(dollars(free))")
            }
            sections.append(.init(title: budgetTitle, lines: lines))
        }

        if fromSource.isEmpty, !oneTime.isEmpty {
            sections.append(.init(
                title: "One-time deposits, not counted as monthly income",
                lines: oneTime.sorted { $0.amount > $1.amount }.prefix(4).map {
                    "\($0.source): \(dollars($0.amount)) on \(MoneyInsights.shortDay($0.date))"
                }
            ))
        }
        let lapsed = detected.filter { SubscriptionAnalytics.isOverdue($0, now: now) }
        if !lapsed.isEmpty {
            sections.append(.init(
                title: "Not counted, because they haven't charged lately",
                lines: lapsed.map { "\($0.displayVendor): \(dollars($0.estimatedMonthly)), last charged \(MoneyInsights.shortDay($0.lastDate))" }
            ))
        }
        let vagueSince = calendar.date(byAdding: .day, value: -60, to: now) ?? now
        let vague = spend
            .filter { $0.date >= vagueSince && !known.contains($0.transactionId) && MoneyInsights.looksLikeVaguePayment($0.title) }
            .sorted { $0.date > $1.date }
            .prefix(6)
            .map { "\($0.title): \(dollars(abs($0.amount))) on \(MoneyInsights.shortDay($0.date))" }
        if !vague.isEmpty {
            sections.append(.init(
                title: "Payments the bank didn't name. Give them a category so they count as the right thing",
                lines: Array(vague)
            ))
        }
        return MoneyInsight(headline: headline, sections: sections)
    }

    // MARK: - Card payoff

    /// Highest interest rate first, which costs the least. Minimums everywhere else.
    static func payoff(accounts: [BankAccount], plans: [PayoffPlan], now: Date = .now) -> MoneyInsight {
        let cards = accounts.filter { $0.isCredit && $0.currentBalance > 0 }
        guard !cards.isEmpty else {
            return MoneyInsight(headline: "None of your linked cards has a balance to pay off.", sections: [])
        }
        let ordered = cards.sorted { first, second in
            // A 0% card and one with no rate shown both wait behind every card that charges interest.
            let (a, b) = (max(first.purchaseApr ?? 0, 0), max(second.purchaseApr ?? 0, 0))
            return a == b ? first.currentBalance < second.currentBalance : a > b
        }
        let percent = { (apr: Double) in "\(apr.formatted(.number.precision(.fractionLength(0...2))))%" }
        let interest = { (card: BankAccount) in card.currentBalance * (card.purchaseApr ?? 0) / 1200 }
        let owed = cards.reduce(0) { $0 + $1.currentBalance }
        let minimumTotal = cards.reduce(0) { $0 + ($1.minimumPaymentAmount ?? 0) }
        let interestTotal = cards.reduce(0) { $0 + interest($1) }

        var sections: [MoneyInsight.Section] = []
        sections.append(.init(title: payoffTitle, lines: ordered.enumerated().map { index, card in
            var line = "\(index + 1). \(card.displayName): owes \(dollars(card.currentBalance))"
            if let apr = card.purchaseApr {
                line += " at \(percent(apr)) APR"
                if apr > 0 { line += ", about \(dollars(interest(card))) a month in interest" }
            } else {
                line += ", rate unknown"
            }
            return line
        }))

        let day = { (date: Date) in MoneyInsights.shortDay(date) }
        let today = Calendar.current.startOfDay(for: now)
        let due = cards
            .filter { ($0.nextPaymentDueDate ?? .distantPast) >= today }
            .sorted { ($0.nextPaymentDueDate ?? now) < ($1.nextPaymentDueDate ?? now) }
            .map { card -> String in
                let minimum = card.minimumPaymentAmount.map { "minimum \(dollars($0))" } ?? "minimum not shown"
                return "\(card.displayName): \(minimum), due \(day(card.nextPaymentDueDate ?? now))"
            }
        if !due.isEmpty { sections.append(.init(title: "Minimums coming due", lines: due)) }
        let passed = cards
            .filter { card in card.nextPaymentDueDate.map { $0 < today } ?? false }
            .map { "\($0.displayName): its due date of \(day($0.nextPaymentDueDate ?? now)) has passed, so check that it was paid" }
        if !passed.isEmpty { sections.append(.init(title: "Check these", lines: passed)) }

        let activePlans = plans.filter(\.isActive)
        if !activePlans.isEmpty {
            sections.append(.init(title: "Payoff plans already running", lines: activePlans.map {
                "\($0.name) on \($0.paymentMethod): \(dollars($0.monthlyPayment)) a month, \(dollars($0.remainingAmount)) left"
            }))
        }
        let cash = accounts.filter { !$0.isCredit }.reduce(0) { $0 + ($1.availableBalance ?? $1.currentBalance) }
        sections.append(.init(title: "Cash on hand", lines: ["\(dollars(cash)) across checking and savings"]))

        var headline = "Your cards owe \(dollars(owed))"
        if interestTotal > 0 { headline += " and cost about \(dollars(interestTotal)) a month in interest" }
        headline += ". Pay every minimum"
        if minimumTotal > 0 { headline += ", \(dollars(minimumTotal)) in total" }
        if let first = ordered.first, let apr = first.purchaseApr, apr > 0 {
            headline += ", then put anything extra on \(first.displayName), which has the highest rate at \(percent(apr))."
        } else {
            headline += ", then put anything extra on \(ordered[0].displayName), the smallest balance, since none of these cards shows an interest rate."
        }
        return MoneyInsight(headline: headline, sections: sections)
    }
}
