//
//  AskConversation.swift
//  Finance Wizard
//
//  One Ask chat on the on-device model. Keeps the session within its context window, carries a
//  recap across new sessions, checks answers against tool results, and explains failures.
//

import Foundation
import FoundationModels
import SwiftData

struct AskChatTurn: Equatable {
    var isUser: Bool
    var text: String
}

struct AskReply: Equatable {
    var text: String
    var followUps: [String]
    /// Shown under the answer when an amount couldn't be matched to the user's data.
    var warning: String?
}

@MainActor
final class AskConversation {
    private let modelContext: ModelContext
    private var session: LanguageModelSession?
    private var recap = ""
    private let asked = AskQuestionBox()
    private var hasAnswered = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Loads the model early. `history` is what the chat already shows, so a question asked right
    /// after reopening the app still has its context.
    func prepare(history: [AskChatTurn]) {
        guard session == nil else { return }
        startSession(history: history)
        session?.prewarm()
    }

    func send(
        _ text: String,
        history: [AskChatTurn],
        onText: @escaping (String) -> Void
    ) async throws -> AskReply {
        if !Self.isFollowUp(text), let plan = await plan(for: text) {
            // The next question shouldn't lean on a session that never saw this one.
            session = nil
            return AskReply(text: AskPlan.chatText(plan.insight), followUps: plan.followUps)
        }
        // A new session per question, carrying the earlier questions. In one long session the model
        // picks worse tools as it fills, and it answers from old results instead of asking again.
        // A follow-up stays in the session, since it only makes sense with the last answer.
        if session == nil || (hasAnswered && !Self.isFollowUp(text)) { startSession(history: history) }
        hasAnswered = true
        // A follow-up like "Compare to last month" leans on the earlier question's months.
        asked.question = Self.isFollowUp(text) ? "compare " + text : text

        var answer: String
        do {
            answer = try await stream(text, onText: onText)
        } catch where Self.isContextOverflow(error) {
            startSession(history: history)
            answer = try await stream(text, onText: onText)
        }

        var unverified = unverifiedAmounts(in: answer, question: text)
        if !unverified.isEmpty {
            // One correction: the model usually recovers when told to use its tools.
            let correction = "Your answer included amounts that didn't come from a tool. Call the right tool and answer again using only its numbers."
            if let retried = try? await stream(correction, onText: onText) {
                answer = retried
                unverified = unverifiedAmounts(in: answer, question: text)
            }
        }

        return AskReply(
            text: answer,
            followUps: Self.followUps(afterTools: toolNamesInLastTurn()),
            warning: unverified.isEmpty
                ? nil
                : "This answer has amounts that don't match your data. Check them in the app."
        )
    }

    // MARK: - Plans

    /// A budget or payoff order when the question asks for one. The app's text is the whole
    /// answer, because a model rewording it can pair a real number with the wrong card.
    private func plan(for question: String) async -> (insight: MoneyInsight, followUps: [String])? {
        let intent = await OnDeviceAI.askIntent(for: question)
        guard intent != .lookup else { return nil }
        let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        let plans = (try? modelContext.fetch(FetchDescriptor<PayoffPlan>())) ?? []
        if intent == .payoff {
            return (AskPlan.payoff(accounts: accounts, plans: plans), ["What's due next?", "Help me make a budget"])
        }
        let income = (try? modelContext.fetch(FetchDescriptor<Income>())) ?? []
        let budget = AskPlan.budget(
            (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? [],
            income: income,
            accounts: accounts,
            plans: plans,
            incomeSource: AskPlan.incomeSource(namedIn: question, among: income)
        )
        return (budget, ["How do I pay off my cards?", "How's my budget?"])
    }

    // MARK: - Session

    var transcript: Transcript? { session?.transcript }

    private func startSession(history: [AskChatTurn]) {
        recap = Self.recap(of: history)
        session = try? OnDeviceAI.makeAskSession(modelContext: modelContext, earlierChat: recap, asked: asked)
    }

    private func stream(_ text: String, onText: (String) -> Void) async throws -> String {
        guard let session else { throw OnDeviceAIError.modelUnavailable("The model isn't ready.") }
        var answer = ""
        // Greedy, so a question gets the same tool and the same answer every time it's asked.
        for try await snapshot in session.streamResponse(to: text, options: GenerationOptions(sampling: .greedy)) {
            answer = snapshot.content
            onText(answer)
        }
        answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.isEmpty { throw OnDeviceAIError.emptyResponse }
        return answer
    }

    /// Wording that leans on the previous question, such as "And last month?".
    static func isFollowUp(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["and ", "what about", "how about", "same ", "compare", "show the", "how much in total"]
            .contains { lower.hasPrefix($0) }
    }

    /// The last few questions, for the instructions of a new session. Answers stay out, so the
    /// model can't repeat an old amount as if it were new.
    static func recap(of history: [AskChatTurn]) -> String {
        history.filter(\.isUser).suffix(3).map { "User: \($0.text.prefix(160))" }
            .joined(separator: "\n")
    }

    // MARK: - Checking answers

    private func unverifiedAmounts(in answer: String, question: String) -> [Double] {
        AskAnswerCheck.unverifiedAmounts(in: answer, facts: [question, recap] + toolOutputs())
    }

    private func toolOutputs() -> [String] {
        guard let session else { return [] }
        return session.transcript.compactMap { entry in
            guard case .toolOutput(let output) = entry else { return nil }
            return output.segments.map { segment in
                switch segment {
                case .text(let text): return text.content
                case .structure(let structure): return structure.content.jsonString
                default: return ""
                }
            }
            .joined(separator: " ")
        }
    }

    private func toolNamesInLastTurn() -> Set<String> {
        guard let session else { return [] }
        var names = Set<String>()
        for entry in session.transcript.reversed() {
            switch entry {
            case .prompt:
                if !names.isEmpty { return names }
            case .toolOutput(let output):
                names.insert(output.toolName)
            default:
                break
            }
        }
        return names
    }

    /// Next questions that follow from what was just answered.
    static func followUps(afterTools names: Set<String>) -> [String] {
        var tips: [String] = []
        if names.contains("getSpending") { tips += ["Compare to last month", "Show the largest charges"] }
        if names.contains("getMoneySnapshot") { tips += ["How's my budget?", "Compare to last month"] }
        if names.contains("getBudgetStatus") { tips += ["What's my biggest category?"] }
        if names.contains("getUpcomingPayments") { tips += ["What are my account balances?"] }
        if names.contains("getAccountBalances") { tips += ["What's due next?"] }
        if names.contains("getRecurringCharges") { tips += ["What's due next?"] }
        if names.contains("searchTransactions") { tips += ["How much in total?"] }
        if tips.isEmpty {
            tips = ["How much did I spend this month?", "How's my budget?", "What's due next?"]
        }
        var seen = Set<String>()
        return tips.filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }

    // MARK: - Failures

    static func isContextOverflow(_ error: Error) -> Bool {
        if #available(iOS 27.0, *), let modelError = error as? LanguageModelError,
           case .contextSizeExceeded = modelError {
            return true
        }
        if let generation = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generation {
            return true
        }
        return false
    }

    /// What to show instead of a framework error.
    static func message(for error: Error) -> String {
        if isContextOverflow(error) {
            return "This chat got too long for the on-device model. Ask again and it will start fresh."
        }
        if let local = error as? OnDeviceAIError {
            return local.errorDescription ?? fallbackMessage
        }
        if #available(iOS 27.0, *), let modelError = error as? LanguageModelError {
            switch modelError {
            case .guardrailViolation, .refusal:
                return blockedMessage
            case .rateLimited:
                return busyMessage
            case .unsupportedLanguageOrLocale:
                return languageMessage
            default:
                return fallbackMessage
            }
        }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation, .refusal:
                return blockedMessage
            case .rateLimited, .concurrentRequests:
                return busyMessage
            case .assetsUnavailable:
                return "Apple Intelligence is still getting ready on this device. Try again soon."
            case .unsupportedLanguageOrLocale:
                return languageMessage
            default:
                return fallbackMessage
            }
        }
        return fallbackMessage
    }

    private static let blockedMessage = "Apple Intelligence wouldn't answer that one. Try rewording it."
    private static let busyMessage = "Apple Intelligence is busy. Try again in a moment."
    private static let languageMessage = "Apple Intelligence doesn't support this language or region yet."
    private static let fallbackMessage = "Something went wrong with Apple Intelligence. Try again."
}
