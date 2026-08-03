//
//  ScreenshotPrivacy.swift
//  Finance Wizard
//
//  Screenshot / share mode: hide amounts and card last-fours in the UI.
//
//  Learning notes:
//  - Environment values are ambient settings SwiftUI views can read without prop-drilling.
//  - EnvironmentKey defines the default; EnvironmentValues is the bag of all environment keys.
//  - @Environment(\.key) pulls a value into a View property and refreshes when it changes.
//  - View is the SwiftUI protocol for UI pieces; body describes what to show.
//  - NSRegularExpression is older Foundation API for pattern matching (regex).
//

import SwiftUI

// MARK: - Environment

/// Private key type that registers `screenshotPrivacy` in the SwiftUI environment.
/// EnvironmentKey requires a static defaultValue used when nothing was set higher up.
private struct ScreenshotPrivacyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true, money and card last-four digits render as placeholders.
    /// get/set bridge this property to our custom EnvironmentKey.
    var screenshotPrivacy: Bool {
        get { self[ScreenshotPrivacyKey.self] }
        set { self[ScreenshotPrivacyKey.self] = newValue }
    }
}

// MARK: - Helpers

/// String formatting helpers for privacy mode (no UI by themselves).
enum ScreenshotPrivacy {
    /// UserDefaults key used by Settings to persist the toggle.
    static let storageKey = "settings.screenshotPrivacy"
    static let moneyPlaceholder = "$•••"
    static let digitsPlaceholder = "••••"

    /// Format a currency string, or return the money placeholder when privacy is on.
    /// ClosedRange<Int>? is an optional range of fraction digits (e.g. 0...0 for whole dollars).
    static func money(
        _ amount: Double,
        code: String = "USD",
        fractionLength: ClosedRange<Int>? = nil,
        privacy: Bool
    ) -> String {
        // Early exit: hide real numbers entirely in privacy mode
        guard !privacy else { return moneyPlaceholder }
        if let fractionLength {
            // FormatStyle API: .currency(code:).precision(...) configures how many decimals
            return amount.formatted(
                .currency(code: code).precision(.fractionLength(fractionLength))
            )
        }
        return amount.formatted(.currency(code: code))
    }

    /// Redact last-four style card numbers in account / product labels.
    static func cardText(_ text: String, privacy: Bool) -> String {
        guard privacy else { return text }
        var s = text

        // ···1234 or ...1234 → keep the dots, replace digits
        // try? turns a throwing initializer into an optional (nil if the pattern is invalid)
        if let re = try? NSRegularExpression(pattern: #"(···|\.\.\.)\d{4}"#) {
            s = re.stringByReplacingMatches(
                in: s,
                range: NSRange(s.startIndex..., in: s),
                withTemplate: "$1••••"
            )
        }

        // "ending in 1234"
        // (?i) in the pattern means case-insensitive
        if let re = try? NSRegularExpression(pattern: #"(?i)(ending in\s+)\d{4}"#) {
            s = re.stringByReplacingMatches(
                in: s,
                range: NSRange(s.startIndex..., in: s),
                withTemplate: "$1••••"
            )
        }

        // Trailing product label last-four: "Sapphire Reserve 0820"
        // $ means end of string in regex
        if let re = try? NSRegularExpression(pattern: #"(\s)\d{4}$"#) {
            s = re.stringByReplacingMatches(
                in: s,
                range: NSRange(s.startIndex..., in: s),
                withTemplate: "$1••••"
            )
        }

        // Bare last-four only
        if s.range(of: #"^\d{4}$"#, options: .regularExpression) != nil {
            return digitsPlaceholder
        }

        return s
    }

    /// "···0820" / "···••••" for explicit mask lines.
    static func maskLine(_ mask: String?, privacy: Bool) -> String? {
        guard let mask, !mask.isEmpty else { return nil }
        // Ternary: condition ? valueIfTrue : valueIfFalse
        return privacy ? "···••••" : "···\(mask)"
    }
}

// MARK: - Views

/// Currency that becomes `$•••` when screenshot privacy is on.
/// Conforming to View makes this usable inside any SwiftUI layout.
struct MoneyText: View {
    let amount: Double
    var code: String = "USD"
    var fractionLength: ClosedRange<Int>? = nil
    var prefix: String = ""
    var suffix: String = ""

    /// Reads the ambient screenshotPrivacy flag set higher in the view tree.
    @Environment(\.screenshotPrivacy) private var privacy

    /// Custom init so callers can write MoneyText(12.34) like Text.
    init(
        _ amount: Double,
        code: String = "USD",
        fractionLength: ClosedRange<Int>? = nil,
        prefix: String = "",
        suffix: String = ""
    ) {
        self.amount = amount
        self.code = code
        self.fractionLength = fractionLength
        self.prefix = prefix
        self.suffix = suffix
    }

    /// Required by View: the content SwiftUI draws for this type.
    var body: some View {
        Text(
            prefix
                + ScreenshotPrivacy.money(
                    amount,
                    code: code,
                    fractionLength: fractionLength,
                    privacy: privacy
                )
                + suffix
        )
    }
}

/// Account / card label that hides last-four digits in privacy mode.
struct CardText: View {
    let text: String

    @Environment(\.screenshotPrivacy) private var privacy

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(ScreenshotPrivacy.cardText(text, privacy: privacy))
    }
}
