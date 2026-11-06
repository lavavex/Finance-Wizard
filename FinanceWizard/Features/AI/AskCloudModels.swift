//
//  AskCloudModels.swift
//  Finance Wizard
//
//  The models Ask can use, and each cloud provider's API key and consent. Keys are the user's own.
//

import Foundation

enum AskProvider: String, CaseIterable, Identifiable {
    case anthropic
    case xai

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: return "Claude"
        case .xai: return "Grok"
        }
    }

    var company: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .xai: return "xAI"
        }
    }

    var privacyURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://www.anthropic.com/legal/privacy")!
        case .xai: return URL(string: "https://x.ai/legal/privacy-policy")!
        }
    }

    var keysURL: URL {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")!
        case .xai: return URL(string: "https://console.x.ai")!
        }
    }

    private var keychainAccount: String { "ask.apiKey.\(rawValue)" }
    private var consentKey: String { "ask.cloudConsent.\(rawValue)" }

    var apiKey: String? {
        guard let key = PlaidKeychain.get(account: keychainAccount), !key.isEmpty else { return nil }
        return key
    }

    /// Whether the user agreed to send data to this provider. Removing the key withdraws it.
    var hasConsent: Bool { UserDefaults.standard.bool(forKey: consentKey) }

    var isReady: Bool { apiKey != nil && hasConsent }

    func saveKeyAndConsent(_ key: String) throws {
        try PlaidKeychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), account: keychainAccount)
        UserDefaults.standard.set(true, forKey: consentKey)
    }

    func removeKeyAndConsent() {
        PlaidKeychain.delete(account: keychainAccount)
        UserDefaults.standard.removeObject(forKey: consentKey)
    }
}

/// Lasting facts the user told a cloud model, like a cancelled subscription or what a vague payment
/// is. Kept on this device and sent to cloud models with each question. Sample data never saves any.
enum AskNotes {
    private static let key = "ask.notes"
    static let maximumCount = 30
    static let maximumLength = 200

    static var all: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    /// Returns the saved text, or nil if there was nothing new to save.
    @discardableResult
    static func add(_ note: String) -> String? {
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
        guard !text.isEmpty, !DemoMode.isActive else { return nil }
        var notes = all
        guard !notes.contains(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) else { return nil }
        notes.append(text)
        UserDefaults.standard.set(Array(notes.suffix(maximumCount)), forKey: key)
        return text
    }

    /// Removes every note containing the text. Returns how many.
    @discardableResult
    static func remove(matching text: String) -> Int {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !DemoMode.isActive else { return 0 }
        let notes = all
        let kept = notes.filter { !$0.localizedCaseInsensitiveContains(needle) }
        UserDefaults.standard.set(kept, forKey: key)
        return notes.count - kept.count
    }

    static func remove(_ note: String) {
        UserDefaults.standard.set(all.filter { $0 != note }, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum AskModel: String, CaseIterable, Identifiable {
    case onDevice = "on-device"
    case claudeOpus = "claude-opus-5-5"
    case claudeSonnet = "claude-sonnet-5-5"
    case claudeHaiku = "claude-haiku-5-5"
    case grok47 = "grok-4.7"
    case grok43 = "grok-4.3"

    var id: String { rawValue }

    /// Nil when the model runs on this device.
    var provider: AskProvider? {
        switch self {
        case .onDevice: return nil
        case .claudeOpus, .claudeSonnet, .claudeHaiku: return .anthropic
        case .grok47, .grok43: return .xai
        }
    }

    var name: String {
        switch self {
        case .onDevice: return "On-device"
        case .claudeOpus: return "Claude Opus 5.5"
        case .claudeSonnet: return "Claude Sonnet 5.5"
        case .claudeHaiku: return "Claude Haiku 5.5"
        case .grok47: return "Grok 4.7"
        case .grok43: return "Grok 4.3"
        }
    }

    var isReady: Bool {
        guard let provider else { return true }
        return provider.isReady
    }

    private static let selectedKey = "ask.selectedModel"

    static var selected: AskModel {
        get {
            let stored = UserDefaults.standard.string(forKey: selectedKey).flatMap(AskModel.init(rawValue:))
            guard let stored, stored.isReady else { return .onDevice }
            return stored
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedKey) }
    }

    /// One model from each other family, for comparing an answer.
    func alternatives() -> [AskModel] {
        let selected = AskModel.selected
        let families: [AskProvider?] = [nil, .anthropic, .xai]
        return families.filter { $0 != provider }.compactMap { family in
            guard let family else { return .onDevice }
            if selected.provider == family { return selected }
            return AskModel.allCases.first { $0.provider == family }
        }
    }
}
