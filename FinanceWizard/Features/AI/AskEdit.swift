//
//  AskEdit.swift
//  Finance Wizard
//
//  Changes made from Ask: categories, budget limits, and what counts as a recurring bill. The
//  model reads what the user wants, the app finds what it affects and words the change, and
//  nothing is written until the user taps Apply.
//

import Foundation
import SwiftData
import WidgetKit

/// A change waiting for the user's Apply.
struct AskEditProposal: Equatable {
    /// What Ask says before the buttons.
    var summary: String
    var action: Action

    enum Action: Equatable {
        /// `titles` are the bank lines as the app shows them. `amount` is set when the change
        /// covers one exact amount of a line that hides several payees.
        case category(transactionIds: [String], titles: [String], category: String, amount: Double?)
        /// Replaces every category limit and the overall monthly limit.
        case budget(limits: [String: Double], monthly: Double)
        case limit(category: String, amount: Double)
        /// `marker` is what the Recurring tab stores: a cadence, "cancelled", or "none".
        case recurring(transactionIds: [String], vendor: String, marker: String)
    }

    /// The charges a category change touches, which a cancelled change shouldn't be asked about again.
    var transactionIds: [String] {
        if case .category(let ids, _, _, _) = action { return ids }
        return []
    }
}

@MainActor
enum AskEdit {
    /// What the chat sends for the "label my unnamed payments" chip.
    static let labelPrompt = "Help me label my unnamed payments"

    /// Categories a charge can be moved to from Ask.
    static var categories: [String] {
        KnownCategory.defaultNames.filter {
            !TransactionAnalytics.isExcludedFromSpendCategory($0) || TransactionAnalytics.isCreditCardPaymentCategory($0)
        }
    }

    private static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func cents(_ amount: Double) -> Int { Int((abs(amount) * 100).rounded()) }

    // MARK: - Finding charges

    /// Recent spending whose bank line names nobody and that still has no real category.
    static func unnamedPayments(in rows: [Transaction], now: Date = .now) -> [Transaction] {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        return TransactionAnalytics.spendOnly(rows)
            .filter {
                $0.date >= since && !$0.isCategoryLocked
                    && MoneyInsights.looksLikeVaguePayment($0.title)
                    && ReviewQueueAnalytics.looksWeakCategory($0.category)
            }
            .sorted { $0.date > $1.date }
    }

    static func question(about row: Transaction) -> String {
        "What was \(row.title), \(AskLedger.money(abs(row.amount))) on \(MoneyInsights.shortDay(row.date)) from \(row.paymentMethod)? Tell me what it paid for, like rent or a phone bill, or say skip."
    }

    /// Charges a request means. An exact name beats a partial one, so "Amazon" doesn't sweep in
    /// "Amazon Kindle". An amount narrows it to charges of exactly that much.
    static func charges(named merchant: String, amount: Double?, in rows: [Transaction]) -> [Transaction] {
        let wanted = key(merchant)
        guard wanted.count >= 3 else { return [] }
        let exact = rows.filter { key($0.title) == wanted }
        let named = exact.isEmpty ? rows.filter { key($0.title).contains(wanted) } : exact
        guard let amount else { return named }
        return named.filter { cents($0.amount) == cents(amount) }
    }

    /// The charges a request is about, checked against the user's own words, since the model
    /// can name the payee instead of the bank line or invent an amount.
    /// - Returns: The charges, and the amount if the user really gave one.
    static func charges(
        asked question: String,
        merchant: String,
        amount: Double?,
        in rows: [Transaction]
    ) -> (rows: [Transaction], amount: Double?) {
        let stated = AskAnswerCheck.numbers(in: question).map(cents)
        let amounts = Set(rows.map { cents($0.amount) })
        // An amount counts only if the user typed it and a charge has it.
        let given = ([amount].compactMap { $0 }.map(cents) + stated).first { stated.contains($0) && amounts.contains($0) }
        let amount = given.map { Double($0) / 100 }
        let named = charges(named: merchant, amount: amount, in: rows)
        if !named.isEmpty { return (named, amount) }
        if let given {
            // "The $177.09 payment is my phone bill" names the payee, not the bank line. Only
            // for lines that name nobody, or any charge of that amount would be swept in.
            return (rows.filter { cents($0.amount) == given && MoneyInsights.looksLikeVaguePayment($0.title) }, amount)
        }
        // A merchant the user wrote that the model reworded.
        let asked = key(question)
        let written = Set(rows.map(\.title))
            .filter { key($0).count >= 4 && asked.contains(key($0)) }
            .max { key($0).count < key($1).count }
        return (written.map { charges(named: $0, amount: nil, in: rows) } ?? [], nil)
    }

    /// A category the user named outright, which outranks the model's own idea of where a
    /// merchant belongs. "Entertainment, not pets" names two, and the one the charges already
    /// have, or that follows "not", isn't the one they want.
    static func categoryNamed(in question: String, current: Set<String>) -> String? {
        let lower = " " + question.lowercased() + " "
        let named = categories.filter { category in
            let word = category.lowercased()
            guard let range = lower.range(of: word) else { return false }
            let before = lower[..<range.lowerBound]
            let after = lower[range.upperBound...]
            // Whole words only, so "health" doesn't match "healthy".
            guard !(before.last?.isLetter ?? false), !(after.first?.isLetter ?? false) else { return false }
            return !before.hasSuffix("not ") && !before.hasSuffix("isn't ") && !before.hasSuffix("isn’t ")
        }
        let wanted = named.filter { name in !current.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
        return wanted.count == 1 ? wanted[0] : nil
    }

    // MARK: - Proposing

    /// Nil when nothing would change.
    static func proposal(for rows: [Transaction], category: String, amount: Double? = nil) -> AskEditProposal? {
        guard let category = categories.first(where: { $0.caseInsensitiveCompare(category) == .orderedSame }) else {
            return nil
        }
        let changing = rows.filter { $0.category.caseInsensitiveCompare(category) != .orderedSame }
        guard !changing.isEmpty else { return nil }
        var seen = Set<String>()
        let titles = changing.map(\.title).filter { seen.insert($0.lowercased()).inserted }
        let from = Set(changing.map(\.category)).sorted().joined(separator: " and ")
        let total = AskLedger.money(changing.reduce(0) { $0 + abs($1.amount) })
        let names = titles.prefix(3).joined(separator: ", ")
        let what = changing.count == 1
            ? "1 \(names) charge (\(total))"
            : "\(changing.count) \(names) charges (\(total) in all)"
        var summary = "File \(what) under \(category) instead of \(from)?"
        let allVague = titles.allSatisfy(MoneyInsights.looksLikeVaguePayment)
        // One amount of a vague line can be remembered. The whole line can't, since it hides several payees.
        let ruleAmount = allVague ? (amount ?? (Set(changing.map { cents($0.amount) }).count == 1 ? abs(changing[0].amount) : nil)) : nil
        if TransactionAnalytics.isExcludedFromSpendCategory(category) {
            summary += " That takes them out of your spending totals."
        } else if !allVague {
            summary += " Later charges from \(titles.count == 1 ? "it" : "them") will go there too."
        } else if let ruleAmount {
            summary += " Later \(titles[0]) charges of exactly \(AskLedger.money(ruleAmount)) will go there too."
        }
        return AskEditProposal(
            summary: summary,
            action: .category(transactionIds: changing.map(\.transactionId), titles: titles, category: category, amount: ruleAmount)
        )
    }

    // MARK: - Budget limits

    /// What the chat sends for the "use this budget" chip.
    static let useBudgetPrompt = "Use this budget"

    /// Turns the budget Ask built into the Budget tab's limits.
    static func budgetProposal(limits: [String: Double], current: BudgetPlan?) -> AskEditProposal? {
        guard !limits.isEmpty else { return nil }
        let monthly = limits.values.reduce(0, +)
        let had = current?.categoryLimits.filter { $0.value > 0 }.count ?? 0
        let count = limits.count == 1 ? "1 category limit" : "\(limits.count) category limits"
        var summary = "Set \(count) on the Budget tab, \(AskLedger.money(monthly)) a month in all?"
        summary += had > 0 ? " This replaces the \(had) you have now." : " You can change any of them there."
        return AskEditProposal(summary: summary, action: .budget(limits: limits, monthly: monthly))
    }

    /// "Set my dining budget to $200". The amount has to be one the user typed.
    static func limitProposal(asked question: String, category: String, amount: Double?, current: BudgetPlan?) -> AskEditProposal? {
        let stated = AskAnswerCheck.numbers(in: question).filter { $0 > 0 }
        guard let category = KnownCategory.budgetPickerOrder.map(\.rawValue)
            .first(where: { $0.caseInsensitiveCompare(category) == .orderedSame }),
            let amount = stated.first(where: { typed in amount.map { abs($0 - typed) < 0.005 } ?? true }) ?? stated.first
        else { return nil }
        let was = current?.limit(forCategory: category)
        if let was, abs(was - amount) < 0.005 { return nil }
        let summary = was.map { "Change your \(category) limit from \(AskLedger.money($0)) to \(AskLedger.money(amount)) a month?" }
            ?? "Set a \(category) limit of \(AskLedger.money(amount)) a month?"
        return AskEditProposal(summary: summary, action: .limit(category: category, amount: amount))
    }

    /// A message that sets a budget limit: it names a budget or limit, gives an amount, and isn't a question.
    static func looksLikeLimitRequest(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        guard !looksLikeQuestion(text), !AskAnswerCheck.numbers(in: text).isEmpty else { return false }
        return [" budget ", " limit ", " cap "].contains(where: lower.contains)
    }

    // MARK: - Recurring bills

    /// A statement about whether something is a bill: cancelled, on a schedule, or not recurring.
    static func looksLikeRecurringRequest(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        guard !looksLikeQuestion(text) else { return false }
        if lower.contains("cancel") { return true }
        // A schedule word alone could be a lookup, like "Example Stream monthly cost".
        let schedule = [
            " monthly ", " yearly ", " annual", " weekly ", " recurring ", " subscription ",
            " every month", " every year", " every week", " each month", " each year",
        ]
        let states = [" is ", " isn't ", " isn’t ", " not a ", " bills me ", " charges me ", " treat ", " mark "]
        return schedule.contains(where: lower.contains) && states.contains(where: lower.contains)
    }

    static func looksLikeQuestion(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix("?") { return true }
        return ["how ", "what", "which ", "when ", "why ", "where ", "who ", "show ", "list ", "do ", "does ", "did ", "is ", "are ", "can ", "compare"]
            .contains(where: lower.hasPrefix)
    }

    /// Every charge from the same vendor as the ones named, as the Recurring tab groups them.
    static func recurringProposal(named merchant: String, asked question: String, marker: String, in rows: [Transaction]) -> AskEditProposal? {
        let found = charges(asked: question, merchant: merchant, amount: nil, in: rows).rows
        guard let title = found.first?.title else { return nil }
        let vendor = SubscriptionAnalytics.normalizeVendor(title)
        let all = rows.filter { SubscriptionAnalytics.normalizeVendor($0.title) == vendor }
        let changing = all.filter { ($0.subscriptionCadenceOverride ?? "").lowercased() != marker }
        guard !changing.isEmpty else { return nil }
        let summary: String
        switch marker {
        case "cancelled":
            summary = "Mark \(title) as cancelled? It moves to Ended on the Recurring tab and stops counting as a bill. This only updates the app, and doesn't cancel anything with \(title)."
        case "none":
            summary = "Stop treating \(title) as a recurring charge? It comes off the Recurring tab."
        default:
            summary = "Treat \(title) as a \(marker) bill? It shows on the Recurring tab even when the amount changes."
        }
        return AskEditProposal(
            summary: summary,
            action: .recurring(transactionIds: changing.map(\.transactionId), vendor: title, marker: marker)
        )
    }

    // MARK: - Applying

    /// Writes the change the same way the app's own screens do. Returns what to say.
    @discardableResult
    static func apply(_ proposal: AskEditProposal, modelContext: ModelContext) -> String {
        let done: String
        switch proposal.action {
        case .category(let ids, let titles, let category, let amount):
            done = applyCategory(ids: ids, titles: titles, category: category, amount: amount, modelContext: modelContext)
        case .budget(let limits, let monthly):
            let plan = budgetPlan(in: modelContext)
            plan.categoryLimits = [:]
            for (category, amount) in limits { plan.setLimit(amount, forCategory: category) }
            plan.monthlyLimit = monthly
            done = "Done. Your Budget tab now has \(limits.count) category limits, \(AskLedger.money(monthly)) a month in all."
        case .limit(let category, let amount):
            budgetPlan(in: modelContext).setLimit(amount, forCategory: category)
            done = "Done. Your \(category) limit is \(AskLedger.money(amount)) a month."
        case .recurring(let ids, let vendor, let marker):
            let wanted = Set(ids)
            for row in ((try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []) where wanted.contains(row.transactionId) {
                row.subscriptionCadenceOverride = marker
            }
            switch marker {
            case "cancelled": done = "Done. \(vendor) is marked cancelled."
            case "none": done = "Done. \(vendor) is no longer treated as recurring."
            default: done = "Done. \(vendor) is a \(marker) bill."
            }
        }
        do {
            try modelContext.save()
        } catch {
            return "That didn't save: \(error.localizedDescription)"
        }
        WidgetCenter.shared.reloadAllTimelines()
        return done
    }

    static func budgetPlan(in modelContext: ModelContext) -> BudgetPlan {
        if let plan = try? modelContext.fetch(FetchDescriptor<BudgetPlan>()).first { return plan }
        let plan = BudgetPlan()
        modelContext.insert(plan)
        return plan
    }

    private static func applyCategory(ids: [String], titles: [String], category: String, amount: Double?, modelContext: ModelContext) -> String {
        let ids = Set(ids)
        let rows = ((try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []).filter { ids.contains($0.transactionId) }
        let payments = (try? modelContext.fetch(FetchDescriptor<CreditCardPayment>())) ?? []
        let isPayment = TransactionAnalytics.isCreditCardPaymentCategory(category)
        for row in rows {
            row.category = category
            row.categoryLocked = true
            row.overrideSource = "user"
            // Total paid follows the category, as it does when the row is edited by hand.
            let mirrored = payments.first { $0.transactionId == row.transactionId }
            if isPayment, mirrored == nil {
                modelContext.insert(CreditCardPayment(
                    transactionId: row.transactionId,
                    amount: abs(row.amount),
                    date: row.date,
                    cardName: row.paymentMethod,
                    sourceAccount: row.paymentMethod,
                    title: row.title
                ))
            } else if !isPayment, let mirrored {
                modelContext.delete(mirrored)
            }
        }
        if !DemoMode.isActive, !TransactionAnalytics.isExcludedFromSpendCategory(category) {
            for title in titles {
                if !MoneyInsights.looksLikeVaguePayment(title) {
                    VendorRulesStore.upsert(vendor: title, paymentMethod: nil, category: category)
                } else if let amount {
                    VendorRulesStore.upsert(vendor: title, paymentMethod: nil, category: category, amount: amount)
                }
            }
        }
        return "Done. \(rows.count == 1 ? "1 charge is" : "\(rows.count) charges are") now under \(category)."
    }
}
