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
            var toolActivity: [String] = []
            do {
                let conversation = AskConversation(modelContext: context)
                var history: [AskChatTurn] = []
                for turn in question.setup {
                    let reply = try await conversation.send(turn, history: history) { _ in }
                    history += [AskChatTurn(isUser: true, text: turn), AskChatTurn(isUser: false, text: reply.text)]
                }
                let reply = try await conversation.send(question.prompt, history: history) { _ in }
                answer = reply.text
                if reply.warning != nil { answer += " [WARNED]" }
                if let transcript = conversation.transcript { toolActivity = toolActivityLines(in: transcript) }
                if isCorrect(answer, expected: question.expected) {
                    outcome = "PASS"
                    passed += 1
                }
            } catch {
                outcome = "ERROR"
                answer = String(describing: error)
            }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            let flat = answer.replacingOccurrences(of: "\n", with: " ")
            for line in toolActivity { print("ASKEVAL|  \(line)") }
            print("ASKEVAL|\(outcome)|\(question.name)|\(seconds)s|want \(question.expected)|\(flat.prefix(300))")
        }
        print("ASKEVAL|SCORE|\(passed)/\(questions.count)")
        await runLongChat(questions, context: context)
        return (passed, questions.count)
    }

    /// Every question in one chat, which is what fills the context window and rotates the session.
    private static func runLongChat(_ questions: [Question], context: ModelContext) async {
        let conversation = AskConversation(modelContext: context)
        var history: [AskChatTurn] = []
        var passed = 0
        for question in questions where question.setup.isEmpty {
            do {
                let reply = try await conversation.send(question.prompt, history: history) { _ in }
                history += [AskChatTurn(isUser: true, text: question.prompt), AskChatTurn(isUser: false, text: reply.text)]
                let correct = isCorrect(reply.text, expected: question.expected)
                if !correct, let transcript = conversation.transcript {
                    for line in toolActivityLines(in: transcript).suffix(4) { print("ASKEVAL|  \(line)") }
                }
                if correct { passed += 1 }
                let flat = reply.text.replacingOccurrences(of: "\n", with: " ")
                print("ASKEVAL|CHAT|\(correct ? "PASS" : "FAIL")|\(question.name)|\(reply.warning == nil ? "" : "WARNED ")\(flat.prefix(200))")
            } catch {
                print("ASKEVAL|CHAT|ERROR|\(question.name)|\(AskConversation.message(for: error))")
            }
        }
        print("ASKEVAL|CHATSCORE|\(passed)/\(questions.filter { $0.setup.isEmpty }.count)")
    }

    /// A number matches by value, so "$40" and "92.7 USD" count as 40.00 and 92.70.
    private static func isCorrect(_ answer: String, expected: [String]) -> Bool {
        let answer = answer.replacingOccurrences(of: "\u{2019}", with: "'")
        let stated = AskAnswerCheck.numbers(in: answer)
        return expected.contains { want in
            if let amount = Double(want.replacingOccurrences(of: ",", with: "")) {
                return stated.contains { abs($0 - amount) < 0.005 }
            }
            return answer.localizedCaseInsensitiveContains(want)
        }
    }

    /// What the model asked the tools and what they returned, for reading a wrong answer.
    private static func toolActivityLines(in transcript: Transcript) -> [String] {
        transcript.flatMap { entry -> [String] in
            switch entry {
            case .toolCalls(let calls):
                return calls.map { "call \($0.toolName) \($0.arguments.jsonString)" }
            case .toolOutput(let output):
                return output.segments.compactMap { segment in
                    if case .structure(let structure) = segment {
                        return "gave \(structure.content.jsonString.prefix(200))"
                    }
                    return nil
                }
            default:
                return []
            }
        }
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
        let recurring = SubscriptionAnalytics.detect(in: rows).filter { !SubscriptionAnalytics.isOverdue($0) }
            .reduce(0) { $0 + $1.estimatedMonthly }
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
        let twoMonthsDate = try required(Calendar.current.date(byAdding: .month, value: -2, to: now))
        let twoMonthsAgo = TransactionAnalytics.inPeriod(rows, period: .month, referenceDate: twoMonthsDate)
        let lastMonthName = lastMonthDate.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "en_US")))
        let thisMonthName = now.formatted(.dateTime.month(.wide).locale(Locale(identifier: "en_US")))
        questions.append(Question(name: "range-of-months",
                                  prompt: "What did I spend in total from \(olderName) through \(lastMonthName)?",
                                  expected: money(TransactionAnalytics.totalSpend(in: olderMonth + twoMonthsAgo + lastMonth))))
        questions.append(Question(name: "reworded-total",
                                  prompt: "what's my spending looking like so far in \(thisMonthName)",
                                  expected: money(TransactionAnalytics.totalSpend(in: thisMonth))))
        if let category = categories.dropFirst().first {
            questions.append(Question(name: "reworded-category",
                                      prompt: "\(category.category.lowercased()) total this month?",
                                      expected: money(category.spent)))
        }
        if let merchant = busiestMerchant(in: twoMonthsAgo) {
            let monthName = twoMonthsDate.formatted(.dateTime.month(.wide).locale(Locale(identifier: "en_US")))
            questions.append(Question(name: "reworded-merchant",
                                      prompt: "what did \(merchant) cost me in \(monthName)",
                                      expected: money(spent(merchant, in: twoMonthsAgo))))
        }
        if let largest = TransactionAnalytics.spendOnly(lastMonth).map({ abs($0.amount) }).max() {
            questions.append(Question(name: "largest-charge", prompt: "What was my largest charge last month?",
                                      expected: money(largest)))
        }
        let cards = accounts.filter(\.isCredit)
        if cards.count > 1 {
            questions.append(Question(name: "total-owed", prompt: "How much do I owe across all my credit cards?",
                                      expected: money(cards.reduce(0) { $0 + $1.currentBalance })))
        }
        questions.append(Question(name: "make-budget", prompt: "Can you help me make a budget?",
                                  expected: [AskPlan.budgetTitle, "can't build a budget"]))
        questions.append(Question(name: "pay-off-cards", prompt: "How should I pay off my credit cards?",
                                  expected: [AskPlan.payoffTitle, "None of your linked cards"]))
        questions.append(Question(name: "afford", prompt: "Where can I cut back on spending?",
                                  expected: [AskPlan.budgetTitle, "can't build a budget"]))
        questions.append(Question(name: "cant-do-that", prompt: "Move $100 into my savings account.",
                                  expected: ["can't", "cannot", "unable", "not able", "don't have"]))
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
