//
//  AskEval.swift
//  Finance Wizard
//
//  Scores Ask against the on-device model, with answers computed from the rows. Merchants and
//  categories come from the data itself, so it works on demo data or a copy of a real store.
//  Debug only. The model varies between runs, so this reports a score, not a pass or fail.
//

#if DEBUG
import Foundation
import SwiftData
import FoundationModels

@MainActor
enum AskEval {
    struct Question {
        let name: String
        /// Earlier turns in the same chat.
        var setup: [String] = []
        let prompt: String
        /// The answer must contain at least one of these.
        let expected: [String]
    }

    struct EvalError: Error {
        let message: String
    }

    /// Prints one ASKEVAL line per question. Returns the number that passed and the total.
    @discardableResult
    static func run(container: ModelContainer? = nil) async throws -> (passed: Int, total: Int) {
        let container = try container ?? DemoMode.makeSeededContainer()
        let context = ModelContext(container)
        let questions = try makeQuestions(context: context)
        var passed = 0

        for question in questions {
            let started = Date()
            var outcome = "FAIL"
            var answer = ""
            do {
                let session = try OnDeviceAI.makeAskSession(modelContext: context)
                for turn in question.setup {
                    _ = try await session.respond(to: turn)
                }
                answer = try await session.respond(to: question.prompt).content
                if question.expected.contains(where: { answer.localizedCaseInsensitiveContains($0) }) {
                    outcome = "PASS"
                    passed += 1
                }
            } catch {
                outcome = "ERROR"
                answer = String(describing: error)
            }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            let flat = answer.replacingOccurrences(of: "\n", with: " ")
            print("ASKEVAL|\(outcome)|\(question.name)|\(seconds)s|want \(question.expected)|\(flat.prefix(300))")
        }
        print("ASKEVAL|SCORE|\(passed)/\(questions.count)")
        return (passed, questions.count)
    }

    private static func makeQuestions(context: ModelContext) throws -> [Question] {
        let rows = try context.fetch(FetchDescriptor<Transaction>())
        let accounts = try context.fetch(FetchDescriptor<BankAccount>())
        let income = try context.fetch(FetchDescriptor<Income>())
        let now = Date()
        let thisMonth = TransactionAnalytics.inPeriod(rows, period: .month, referenceDate: now)
        let lastMonthDate = try required(Calendar.current.date(byAdding: .month, value: -1, to: now))
        let lastMonth = TransactionAnalytics.inPeriod(rows, period: .month, referenceDate: lastMonthDate)
        let threeMonthsDate = try required(Calendar.current.date(byAdding: .month, value: -3, to: now))
        let olderMonth = TransactionAnalytics.inPeriod(rows, period: .month, referenceDate: threeMonthsDate)
        let olderName = threeMonthsDate.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))
        let categories = TransactionAnalytics.categorySummaries(from: thisMonth)
        let recentCategories = TransactionAnalytics.categorySummaries(from: lastMonth)

        func spent(_ merchant: String, in period: [Transaction]) -> Double {
            TransactionAnalytics.totalSpend(in: period.filter { sameMerchant($0.title, merchant) })
        }
        /// The merchant with the most charges, ignoring card payments and other non-spend rows.
        func busiestMerchant(in period: [Transaction]) -> String? {
            Dictionary(grouping: TransactionAnalytics.spendOnly(period), by: \.title)
                .max { $0.value.count < $1.value.count }?.key
        }
        func money(_ value: Double) -> [String] {
            let cents = String(format: "%.2f", value)
            let grouped = value.formatted(
                .number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US"))
            )
            return [cents, grouped]
        }

        var questions: [Question] = [
            Question(name: "total-this-month", prompt: "How much did I spend this month?",
                     expected: money(TransactionAnalytics.totalSpend(in: thisMonth))),
            Question(name: "total-last-month", prompt: "How much did I spend last month?",
                     expected: money(TransactionAnalytics.totalSpend(in: lastMonth))),
            Question(name: "total-named-month", prompt: "How much did I spend in \(olderName)?",
                     expected: money(TransactionAnalytics.totalSpend(in: olderMonth))),
            Question(name: "no-data-no-guess", prompt: "How much did I spend at Example Nonexistent Store this month?",
                     expected: ["no ", "$0", "0.00", "didn't", "did not", "couldn't", "not find"])
        ]

        if let biggest = categories.first {
            questions.append(Question(name: "biggest-category", prompt: "What's my biggest spending category this month?",
                                      expected: [biggest.category]))
        }
        if let category = recentCategories.dropFirst().first {
            questions.append(Question(name: "category-amount",
                                      prompt: "How much did I spend on \(category.category) last month?",
                                      expected: money(category.spent)))
        }
        if let merchant = busiestMerchant(in: lastMonth) {
            questions.append(Question(name: "merchant-last-month",
                                      prompt: "How much did I spend at \(merchant) last month?",
                                      expected: money(spent(merchant, in: lastMonth))))
            questions.append(Question(name: "follow-up",
                                      setup: ["How much did I spend at \(merchant) this month?"],
                                      prompt: "And last month?",
                                      expected: money(spent(merchant, in: lastMonth))))
        }
        if let merchant = busiestMerchant(in: olderMonth) {
            questions.append(Question(name: "merchant-named-month",
                                      prompt: "How much did I spend at \(merchant) in \(olderName)?",
                                      expected: money(spent(merchant, in: olderMonth))))
        }
        if let checking = accounts.first(where: { $0.subtype == "checking" }) {
            questions.append(Question(name: "checking-balance", prompt: "What's the balance in \(checking.displayName)?",
                                      expected: money(checking.currentBalance) + money(checking.availableBalance ?? checking.currentBalance)))
        }
        if let card = accounts.filter(\.isCredit).max(by: { $0.currentBalance < $1.currentBalance }) {
            questions.append(Question(name: "card-owed", prompt: "How much do I owe on \(card.displayName)?",
                                      expected: money(card.currentBalance)))
        }
        let dueCards = accounts.filter { $0.isCredit && $0.minimumPaymentAmount != nil && ($0.nextPaymentDueDate ?? .distantPast) >= now }
        if let next = dueCards.min(by: { ($0.nextPaymentDueDate ?? now) < ($1.nextPaymentDueDate ?? now) }) {
            questions.append(Question(name: "next-payment", prompt: "What's the minimum payment due on \(next.displayName)?",
                                      expected: money(next.minimumPaymentAmount ?? 0)))
        }
        let recurring = SubscriptionAnalytics.detect(in: rows).reduce(0) { $0 + $1.estimatedMonthly }
        if recurring > 0 {
            questions.append(Question(name: "recurring-total", prompt: "How much do my recurring charges cost per month?",
                                      expected: money(recurring)))
        }
        if let plan = try context.fetch(FetchDescriptor<BudgetPlan>()).first {
            let budget = BudgetAnalytics.snapshot(plan: plan, transactions: rows, incomeRows: income)
            if let remaining = budget.totalRemaining {
                questions.append(Question(name: "budget-left", prompt: "How much of my budget do I have left this month?",
                                          expected: money(abs(remaining))))
            }
            questions.append(Question(name: "over-under", prompt: "How much more did I spend than I earned this month?",
                                      expected: money(abs(budget.income - budget.totalSpent))))
        }
        return questions
    }

    /// Same matching the spending tool uses, so an expected total covers the same rows.
    private static func sameMerchant(_ title: String, _ merchant: String) -> Bool {
        let key = { (text: String) in text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return key(title).contains(key(merchant))
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw EvalError(message: "Demo data is missing a row the eval needs.") }
        return value
    }
}
#endif
