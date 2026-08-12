//
//  OnDeviceAI.swift
//  Finance Wizard
//
//  On-device AI (Apple Foundation Models) — LEARNING SKELETON.
//  High-level pieces are named below. YOU fill in the TODO bodies.
//  Coach mode: implement one function at a time; ask when stuck.
//
//  Roadmap (do in order):
//  1) availabilityStatus()     — can we use the model on this device?
//  2) makeSession()            — open a chat-like session with the system model
//  3) suggestCategory(...)     — first real feature: help “Needs review”
//  4) (later) richer prompts / structured output
//

import Foundation
import FoundationModels

// MARK: - 1) Status the UI can show

/// Plain English result of “is on-device AI usable right now?”
/// You’ll map Apple’s `SystemLanguageModel.Availability` into these cases.
enum OnDeviceAIAvailability: Equatable {
    /// Model is ready — safe to call session / respond.
    case available
    /// Hardware or OS can’t run Apple Intelligence / Foundation Models.
    case unavailable(reason: String)
    /// Supported device, but user hasn’t enabled Intelligence, or model still downloading, etc.
    case notEnabled(reason: String)
}

// MARK: - 2) Service (namespace for AI helpers)

/// App-facing entry point for on-device AI.
/// `enum` with only `static` methods = no instances; just a toolbox of functions.
enum OnDeviceAI {

    // MARK: Step 1 — Availability (START HERE)

    /// Check whether the system on-device language model can be used.
    ///
    /// Swift ideas you’ll use:
    /// - `SystemLanguageModel.default` — the device’s built-in model
    /// - `.availability` — enum: available / unavailable / …
    /// - `switch` — pick a branch per case
    ///
    /// TODO: Implement me first.
    /// Hints:
    /// 1. `let model = SystemLanguageModel.default`
    /// 2. `switch model.availability { ... }`
    /// 3. Return `.available` or a reason string for the other cases
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
            }
        }
    }

    // MARK: Step 2 — Session

    /// Create a `LanguageModelSession` when the model is available.
    ///
    /// Swift ideas you’ll use:
    /// - `throws` / `try` — function can fail; caller must handle errors
    /// - optionals / `guard` — bail out early if not available
    ///
    /// TODO: After Step 1 works, implement me.
    /// Hints:
    /// 1. Call `availabilityStatus()`; if not `.available`, throw or return nil (pick one style)
    /// 2. `LanguageModelSession(model: SystemLanguageModel.default)`
    static func makeSession() throws -> LanguageModelSession {
        // TODO: Replace this stub.
        throw OnDeviceAIError.notImplemented("makeSession")
    }

    // MARK: Step 3 — First feature: category suggestion

    /// Ask the on-device model for a spend category given a merchant / title.
    ///
    /// - Parameters:
    ///   - title: Transaction title (e.g. "STARBUCKS #1234")
    ///   - amount: Absolute dollars (optional context for the prompt)
    ///   - allowedCategories: Your app’s category names (keep the model on-rails)
    ///
    /// Swift ideas you’ll use:
    /// - `async` / `await` — wait for the model without blocking the UI forever
    /// - string interpolation `"Hello \(name)"` — build the prompt
    /// - `session.respond(to:)` — send text, get text back
    ///
    /// TODO: After Steps 1–2 work, implement me.
    /// Hints:
    /// 1. `let session = try makeSession()`
    /// 2. Build a short prompt that lists allowedCategories
    /// 3. `let response = try await session.respond(to: prompt)`
    /// 4. Return `response.content` (trim / validate later)
    static func suggestCategory(
        title: String,
        amount: Double?,
        allowedCategories: [String]
    ) async throws -> String {
        // TODO: Replace this stub.
        throw OnDeviceAIError.notImplemented("suggestCategory")
    }
}

// MARK: - Errors (for throws)

/// Errors your AI helpers can throw so the UI can show a message.
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
