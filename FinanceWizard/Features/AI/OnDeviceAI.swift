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

    static func askTools(modelContext: ModelContext) -> [any Tool] {
        [
            SpendingQueryTool(modelContext: modelContext),
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
    static func makeAskSession(modelContext: ModelContext, earlierChat: String? = nil) throws -> LanguageModelSession {
        switch availabilityStatus() {
        case .available:
            var instructions = askInstructions()
            if let earlierChat, !earlierChat.isEmpty {
                instructions += "\nEarlier questions in this chat. A follow-up keeps the same merchant or category:\n\(earlierChat)"
            }
            return LanguageModelSession(
                tools: askTools(modelContext: modelContext),
                instructions: instructions
            )
        case .unavailable(let reason), .notEnabled(let reason):
            throw OnDeviceAIError.modelUnavailable(reason)
        }
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
