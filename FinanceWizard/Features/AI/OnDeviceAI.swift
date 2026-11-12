//
//  OnDeviceAI.swift
//  Finance Wizard
//
//  Apple Foundation Models. Availability is live; session and suggestCategory are stubs.
//

import Foundation
import FoundationModels
import SwiftData

// MARK: - Status

/// Whether the system on-device language model can be used right now.
enum OnDeviceAIAvailability: Equatable {
    /// Model is ready — safe to call session / respond.
    case available
    /// Hardware or OS can’t run Apple Intelligence / Foundation Models.
    case unavailable(reason: String)
    /// Supported device, but Intelligence is off, or the model is still downloading.
    case notEnabled(reason: String)
}

// MARK: - Service

enum OnDeviceAI {

    static func availabilityStatus() -> OnDeviceAIAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(reason: "This Device is not supported by Apple Intelligence.")
            case .appleIntelligenceNotEnabled:
                return .notEnabled(reason: "You haven’t enabled Apple Intelligence on this Device.")
            case .modelNotReady:
                return .notEnabled(reason: "The model is not ready yet.")
            @unknown default:
                return .unavailable(reason: "On-device AI is unavailable.")
            }
        }
    }

    /// Short on purpose: instructions count against the small on-device context window.
    static func askInstructions(today: Date = .now) -> String {
        let date = today.formatted(.dateTime.month(.wide).day().year().locale(Locale(identifier: "en_US")))
        let month = today.formatted(.iso8601.year().month())
        let previous = (Calendar.current.date(byAdding: .month, value: -1, to: today) ?? today)
            .formatted(.iso8601.year().month())
        return """
            You are Budget Magi's assistant. Today is \(date). This month is \(month). Last month is \(previous).
            Every money fact must come from a tool, in this conversation. Never estimate or do math yourself.
            Tools:
            getSpending: how much was spent, by merchant, category, or month. For one month, set only fromMonth.
            getMoneySnapshot: income vs spending for a month, or why money feels tight.
            getBudgetStatus: budget left, and categories over limit.
            getUpcomingPayments: card due dates and minimum payments.
            getAccountBalances: cash, account balances, or what is owed on a card.
            getRecurringCharges: subscriptions, repeating bills, and payoff plans.
            searchTransactions: to list individual charges.
            When a headline answers the question, use it, then add at most one short sentence. If the question is about one item, give that item's number.
            Use names exactly as tools give them. Write money like $12.50. Credit card payments aren't spending.
            You look up numbers. If asked to make a budget or plan, say you can't do that here.
            If no tool covers the question, say so briefly.
            """
    }

    static func makeSession() throws -> LanguageModelSession {
        switch availabilityStatus() {
        case .available:
            return LanguageModelSession()
        case .unavailable(let reason), .notEnabled(let reason):
            throw OnDeviceAIError.modelUnavailable(reason)
        }
    }

    static func askTools(modelContext: ModelContext, asked: AskQuestionBox? = nil) -> [any Tool] {
        [
            SpendingQueryTool(modelContext: modelContext, asked: asked),
            MoneySnapshotTool(modelContext: modelContext),
            BudgetStatusTool(modelContext: modelContext),
            UpcomingPaymentsTool(modelContext: modelContext),
            AccountBalancesTool(modelContext: modelContext),
            RecurringChargesTool(modelContext: modelContext),
            SearchTransactionsTool(modelContext: modelContext),
        ]
    }

    /// Chat session: developer instructions + ledger tools (Apple's tool-calling path).
    /// - Parameter earlierChat: Recap of the conversation so far, for a new session.
    /// - Parameter asked: Kept up to date with the question, for tools that check arguments against it.
    static func makeAskSession(
        modelContext: ModelContext,
        earlierChat: String? = nil,
        asked: AskQuestionBox? = nil
    ) throws -> LanguageModelSession {
        switch availabilityStatus() {
        case .available:
            var instructions = askInstructions()
            if let earlierChat, !earlierChat.isEmpty {
                instructions += "\nEarlier questions in this chat. A follow-up keeps the same merchant or category:\n\(earlierChat)"
            }
            return LanguageModelSession(
                tools: askTools(modelContext: modelContext, asked: asked),
                instructions: instructions
            )
        case .unavailable(let reason), .notEnabled(let reason):
            throw OnDeviceAIError.modelUnavailable(reason)
        }
    }

    /// What kind of answer a question wants. The app writes budgets and payoff plans itself,
    /// so the model only has to recognize a request for one.
    enum AskIntent: String {
        case lookup
        case budget
        case payoff
        case recategorize
    }

    /// A change to how charges are filed, read from the user's words.
    @Generable
    struct EditRequest {
        @Guide(description: "The store, business, or bank line whose charges should change, exactly as the user wrote it")
        var merchant: String
        @Guide(description: "The dollar amount of the charge, only if the user gave one")
        var amount: Double?
        @Guide(description: "The category that fits what the user said it is")
        var category: String
    }

    private static func categoryList() async -> String {
        await MainActor.run { AskEdit.categories.joined(separator: ", ") }
    }

    /// Which charges to move and where. Nil if the model can't say or isn't available.
    static func editRequest(for question: String) async -> EditRequest? {
        guard case .available = availabilityStatus() else { return nil }
        let session = LanguageModelSession(instructions: """
            The user wants charges from a merchant filed under a different category. Read out the merchant, the amount if they gave one, and the category.
            The category must be exactly one of: \(await categoryList()).
            Phone and internet bills are Home Internet. Rent and mortgage are Housing. Electric, gas, and water bills are Utilities. A payment to a credit card is Credit Card Payment.
            """)
        let options = GenerationOptions(sampling: .greedy)
        return try? await session.respond(to: question, generating: EditRequest.self, options: options).content
    }

    @Generable
    struct PaymentAnswer {
        @Guide(description: "The category that fits what the user said the payment was for")
        var category: String
    }

    /// The category for a payment the user just explained, such as "that's my rent".
    static func category(forPaymentExplainedAs answer: String) async -> String? {
        guard case .available = availabilityStatus() else { return nil }
        let session = LanguageModelSession(instructions: """
            The user is saying what a bank payment was for. Pick the category that fits.
            The category must be exactly one of: \(await categoryList()).
            Phone and internet bills are Home Internet. Rent and mortgage are Housing. Electric, gas, and water bills are Utilities. A payment to a credit card is Credit Card Payment.
            """)
        let options = GenerationOptions(sampling: .greedy)
        return try? await session.respond(to: answer, generating: PaymentAnswer.self, options: options).content.category
    }

    @Generable
    enum AskRequestKind: String {
        case lookup
        case budget
        case payoff
    }

    @Generable
    enum AskMessageKind: String {
        case question
        case correction
    }

    /// Sorting happens in short sessions of its own, in two steps. Offering the plans as tools
    /// in the chat session made the model pick worse tools for lookups, and one four-way choice
    /// sorted worse than a two-way choice followed by a three-way one.
    static func askIntent(for question: String) async -> AskIntent {
        guard case .available = availabilityStatus() else { return .lookup }
        // Greedy, so the same question always gets the same kind of answer.
        let options = GenerationOptions(sampling: .greedy)
        let corrections = LanguageModelSession(instructions: """
            The user keeps a list of charges, each filed under a category such as Dining, Housing, or Entertainment.
            Decide whether their message is a correction or a question.
            correction: it says a merchant or payment belongs under a different category, or says what a payment was for.
            "Corner Cafe is dining, not shopping" is a correction.
            "That 50.00 payment was my water bill" is a correction.
            "Put Example Gym under health" is a correction.
            question: anything else.
            "How much did I spend at Corner Cafe?" is a question.
            "What is my water bill?" is a question.
            "Move 50 dollars to savings" is a question.
            """)
        if let kind = try? await corrections.respond(to: question, generating: AskMessageKind.self, options: options).content,
           kind == .correction {
            return .recategorize
        }
        let requests = LanguageModelSession(instructions: """
            Sort a question about the user's own money into one kind.
            budget: they want a budget made for them, ask what they can afford, or ask where to cut back or save.
            payoff: they want to pay off or pay down credit cards or debt, or ask which card to pay first.
            lookup: everything else, such as how much they spent, a balance, what is due, how much they owe, or how their budget is doing.
            """)
        let kind = try? await requests.respond(to: question, generating: AskRequestKind.self, options: options).content
        switch kind {
        case .budget: return .budget
        case .payoff: return .payoff
        default: return .lookup
        }
    }

    /// Rewords computed facts. Returns nil if the model added an amount of its own, since the
    /// facts stand on their own without it.
    static func summarize(_ insight: MoneyInsight) async throws -> String? {
        let session = try makeSession()
        let facts = insight.facts.joined(separator: "\n")
        let prompt = """
            In one or two short sentences, tell the user what matters most in these facts.
            Use only these facts and their exact amounts. Don't give advice.
            \(facts)
            """
        let text = try await session.respond(to: prompt).content
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, AskAnswerCheck.unverifiedAmounts(in: text, facts: [facts]).isEmpty else { return nil }
        return text
    }

    @Generable
    struct SearchRequest {
        @Guide(description: "Store or business the user named")
        var merchant: String?
        @Guide(description: "Spending category the user named")
        var category: String?
        @Guide(description: "Only charges of at least this many dollars")
        var minAmount: Double?
        @Guide(description: "Only charges of at most this many dollars")
        var maxAmount: Double?
        @Guide(description: "First month as YYYY-MM, if the user named a time")
        var fromMonth: String?
        @Guide(description: "Last month of a range as YYYY-MM")
        var toMonth: String?
    }

    /// Reads a plain-English search into filters. The results come from the rows, not the model.
    static func searchFilter(for query: String, today: Date = .now) async throws -> TransactionSearchFilter {
        guard case .available = availabilityStatus() else {
            throw OnDeviceAIError.modelUnavailable("Apple Intelligence isn't available for AI search.")
        }
        let month = today.formatted(.iso8601.year().month())
        let previous = (Calendar.current.date(byAdding: .month, value: -1, to: today) ?? today)
            .formatted(.iso8601.year().month())
        let session = LanguageModelSession(instructions: """
            Turn a search of the user's bank transactions into filters. Fill in only what they asked for.
            This month is \(month). Last month is \(previous).
            """)
        let request = try await session.respond(to: query, generating: SearchRequest.self).content
        return TransactionSearchFilter(
            merchant: request.merchant ?? "",
            category: request.category ?? "",
            minAmount: request.minAmount,
            maxAmount: request.maxAmount,
            fromMonth: request.fromMonth ?? "",
            toMonth: request.toMonth ?? ""
        )
        .supported(by: query)
    }

    /// Spend category from merchant title; `allowedCategories` keeps the model on-rails.
    static func suggestCategory(
        title: String,
        amount: Double?,
        allowedCategories: [String]
    ) async throws -> String {
        let session = try makeSession()
        let list = allowedCategories.joined(separator: ", ")
        let amountPart = amount.map { String(format: "%.2f", abs($0)) } ?? "unknown"
        let prompt = """
            Pick exactly one category from this list: \(list).
            Merchant: \(title)
            Amount USD: \(amountPart)
            Reply with only the category name, nothing else.
            """
        let response = try await session.respond(to: prompt)
        let raw = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'."))
        if let exact = allowedCategories.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return exact
        }
        if let fuzzy = allowedCategories.first(where: { raw.localizedCaseInsensitiveContains($0) }) {
            return fuzzy
        }
        throw OnDeviceAIError.emptyResponse
    }
}

// MARK: - Errors

enum OnDeviceAIError: LocalizedError {
    case notImplemented(String)
    case modelUnavailable(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notImplemented(let name):
            return "AI function not implemented yet: \(name)"
        case .modelUnavailable(let reason):
            return "On-device AI unavailable: \(reason)"
        case .emptyResponse:
            return "The model returned an empty response."
        }
    }
}
