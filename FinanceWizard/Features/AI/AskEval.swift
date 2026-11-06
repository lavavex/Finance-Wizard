//
//  AskEval.swift
//  Finance Wizard
//
//  Scores Ask against the on-device model using demo data, with answers computed from the rows.
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
    static func run() async throws -> (passed: Int, total: Int) {
        let container = try DemoMode.makeSeededContainer()
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
        let thisMonth = TransactionAnalytics.inPeriod(rows, period: .month)
        let previousStart = try required(Calendar.current.date(byAdding: .month, value: -1, to: Date()))
        let lastMonth = TransactionAnalytics.inPeriod(rows, period: .month, referenceDate: previousStart)
        let categories = TransactionAnalytics.categorySummaries(from: thisMonth)
        let biggest = try required(categories.first).category
        let card = try required(accounts.first(where: \.isCredit))
        let checking = try required(accounts.first { $0.subtype == "checking" })
        let plan = try required(context.fetch(FetchDescriptor<BudgetPlan>()).first)
        let budget = BudgetAnalytics.snapshot(plan: plan, transactions: rows)
        let recurring = SubscriptionAnalytics.detect(in: rows)
            .reduce(0) { $0 + $1.estimatedMonthly }

        func spent(_ merchant: String, in period: [Transaction]) -> Double {
            TransactionAnalytics.totalSpend(in: period.filter { $0.title == merchant })
        }
        func money(_ value: Double) -> [String] {
            let cents = String(format: "%.2f", value)
            let grouped = value.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
            return [cents, grouped]
        }

        return [
            Question(name: "total-this-month", prompt: "How much did I spend this month?",
                     expected: money(TransactionAnalytics.totalSpend(in: thisMonth))),
            Question(name: "biggest-category", prompt: "What's my biggest spending category this month?",
                     expected: [biggest]),
            Question(name: "category-amount", prompt: "How much did I spend on dining this month?",
                     expected: money(categories.first { $0.category == "Dining" }?.spent ?? 0)),
            Question(name: "merchant-this-month", prompt: "How much did I spend at Corner Market this month?",
                     expected: money(spent("Corner Market", in: thisMonth))),
            Question(name: "merchant-last-month", prompt: "How much did I spend at Corner Market last month?",
                     expected: money(spent("Corner Market", in: lastMonth))),
            Question(name: "follow-up", setup: ["How much did I spend at Corner Market this month?"],
                     prompt: "And last month?",
                     expected: money(spent("Corner Market", in: lastMonth))),
            Question(name: "checking-balance", prompt: "What's my checking balance?",
                     expected: money(checking.currentBalance) + money(checking.availableBalance ?? 0)),
            Question(name: "card-owed", prompt: "How much do I owe on my credit card?",
                     expected: money(card.currentBalance)),
            Question(name: "recurring-total", prompt: "How much do my recurring charges cost per month?",
                     expected: money(recurring)),
            Question(name: "budget-left", prompt: "How much of my budget do I have left this month?",
                     expected: money(budget.totalRemaining ?? 0)),
            Question(name: "next-payment", prompt: "What's the minimum payment due on my card?",
                     expected: money(card.minimumPaymentAmount ?? 0)),
            Question(name: "over-under", prompt: "Did I spend more than I earned this month?",
                     expected: money(abs(budget.income - budget.totalSpent))),
            Question(name: "no-data-no-guess", prompt: "How much did I spend at Example Nonexistent Store this month?",
                     expected: ["no ", "$0", "0.00", "didn't", "did not", "couldn't", "not find"])
        ]
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else { throw EvalError(message: "Demo data is missing a row the eval needs.") }
        return value
    }
}
#endif
