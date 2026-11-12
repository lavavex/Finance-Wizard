//
//  AskEdit.swift
//  Finance Wizard
//
//  Category changes made from Ask. The model reads what the user wants, the app finds the
//  charges and words the change, and nothing is written until the user taps Apply.
//

import Foundation
import SwiftData
import WidgetKit

/// A change waiting for the user's Apply.
struct AskEditProposal: Equatable {
    var transactionIds: [String]
    /// The bank lines being changed, as the app shows them.
    var titles: [String]
    var category: String
    /// Set when the change covers one exact amount of a line that hides several payees.
    var amount: Double?
    /// What Ask says before the buttons.
    var summary: String
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
            transactionIds: changing.map(\.transactionId),
            titles: titles,
            category: category,
            amount: ruleAmount,
            summary: summary
        )
    }

    // MARK: - Applying

    /// Writes the change the same way the transaction screen does. Returns what to say.
    @discardableResult
    static func apply(_ proposal: AskEditProposal, modelContext: ModelContext) -> String {
        let ids = Set(proposal.transactionIds)
        let rows = ((try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []).filter { ids.contains($0.transactionId) }
        let payments = (try? modelContext.fetch(FetchDescriptor<CreditCardPayment>())) ?? []
        let isPayment = TransactionAnalytics.isCreditCardPaymentCategory(proposal.category)
        for row in rows {
            row.category = proposal.category
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
        if !DemoMode.isActive, !TransactionAnalytics.isExcludedFromSpendCategory(proposal.category) {
            for title in proposal.titles {
                if !MoneyInsights.looksLikeVaguePayment(title) {
                    VendorRulesStore.upsert(vendor: title, paymentMethod: nil, category: proposal.category)
                } else if let amount = proposal.amount {
                    VendorRulesStore.upsert(vendor: title, paymentMethod: nil, category: proposal.category, amount: amount)
                }
            }
        }
        do {
            try modelContext.save()
        } catch {
            return "That didn't save: \(error.localizedDescription)"
        }
        WidgetCenter.shared.reloadAllTimelines()
        return "Done. \(rows.count == 1 ? "1 charge is" : "\(rows.count) charges are") now under \(proposal.category)."
    }
}
