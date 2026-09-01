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

    static let askInstructions = """
        You are Finance Wizard's on-device assistant. All money facts must come from tools. \
        Never invent amounts, merchants, or balances. Never reverse a comparison: if headline says you are ahead, do not say spending exceeded income. \
        When getMoneySnapshot returns a headline, lead with that headline (you may add one short sentence on top categories). \
        Credit card payments are transfers, not new spending. \
        For overall money or why the user feels broke, call getMoneySnapshot (monthOffset 0; also -1 to compare months). \
        Call getAccountBalances for cash or what is owed. \
        Call getRecurringCharges for subscriptions, repeating bills, and card payoff plans (My Loan, Pay Over Time, promo APR). \
        Call searchTransactions only for a named merchant or category, never for vague "any transactions to review". \
        When a tool row has name or cardLabel, say that string exactly. Never say CREDIT CARD or a last-four unless that field is that string. \
        Be concise. Treat currency as USD unless a tool says otherwise.
        """

    static func makeSession() throws -> LanguageModelSession {
        switch availabilityStatus() {
        case .available:
            return LanguageModelSession()
        case .unavailable(let reason), .notEnabled(let reason):
            throw OnDeviceAIError.modelUnavailable(reason)
        }
    }

    /// Chat session: developer instructions + ledger tools (Apple's tool-calling path).
    static func makeAskSession(modelContext: ModelContext) throws -> LanguageModelSession {
        switch availabilityStatus() {
        case .available:
            return LanguageModelSession(
                tools: [
                    MoneySnapshotTool(modelContext: modelContext),
                    AccountBalancesTool(modelContext: modelContext),
                    RecurringChargesTool(modelContext: modelContext),
                    SearchTransactionsTool(modelContext: modelContext),
                ],
                instructions: askInstructions
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
