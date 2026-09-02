//
//  ScreenshotPrivacy.swift
//  Finance Wizard
//
//  Screenshot / share mode: hide amounts and card last-fours in the UI.
//

import SwiftUI

// MARK: - Environment

/// Private key type that registers `screenshotPrivacy` in the SwiftUI environment.
private struct ScreenshotPrivacyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// When true, money and card last-four digits render as placeholders.
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
    static func money(
        _ amount: Double,
        code: String = "USD",
        fractionLength: ClosedRange<Int>? = nil,
        privacy: Bool
    ) -> String {
        guard !privacy else { return moneyPlaceholder }
        if let fractionLength {
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
        if let re = try? NSRegularExpression(pattern: #"(···|\.\.\.)\d{4}"#) {
            s = re.stringByReplacingMatches(
                in: s,
                range: NSRange(s.startIndex..., in: s),
                withTemplate: "$1••••"
            )
        }

        // "ending in 1234"
        if let re = try? NSRegularExpression(pattern: #"(?i)(ending in\s+)\d{4}"#) {
            s = re.stringByReplacingMatches(
                in: s,
                range: NSRange(s.startIndex..., in: s),
                withTemplate: "$1••••"
            )
        }

        // Trailing product label last-four: "Sapphire Reserve 0820"
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

}

// MARK: - Views

/// Currency that becomes `$•••` when screenshot privacy is on.
struct MoneyText: View {
    let amount: Double
    var code: String = "USD"
    var fractionLength: ClosedRange<Int>? = nil
    var prefix: String = ""
    var suffix: String = ""

    @Environment(\.screenshotPrivacy) private var privacy

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
