//
//  OnDeviceAI.swift
//  Finance Wizard
//
//  Optional on-device AI via Apple Foundation Models. Not required to run the app.
//  Availability is implemented; session and category suggestion are stubs.
//

import Foundation
import FoundationModels

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

/// App-facing entry point for on-device AI.
enum OnDeviceAI {

    /// Maps `SystemLanguageModel.default.availability` into `OnDeviceAIAvailability`.
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

    /// Opens a `LanguageModelSession` when the model is available.
    static func makeSession() throws -> LanguageModelSession {
        throw OnDeviceAIError.notImplemented("makeSession")
    }

    /// Ask the on-device model for a spend category given a merchant / title.
    ///
    /// - Parameters:
    ///   - title: Transaction title (e.g. "STARBUCKS #1234")
    ///   - amount: Absolute dollars (optional context for the prompt)
    ///   - allowedCategories: App category names (keep the model on-rails)
    static func suggestCategory(
        title: String,
        amount: Double?,
        allowedCategories: [String]
    ) async throws -> String {
        throw OnDeviceAIError.notImplemented("suggestCategory")
    }
}

// MARK: - Errors

/// Errors AI helpers throw so the UI can show a message.
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
