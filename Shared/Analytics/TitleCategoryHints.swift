//
//  TitleCategoryHints.swift
//  Finance Wizard
//
//  Keyword fallbacks when PFC only says “Other” or Miscellaneous.
//  Patterns are category words (gas, wireless, installment) — not merchant names.
//

import Foundation

enum TitleCategoryHints {
    /// Refine a weak/generic category using words in the title.
    static func refine(category: String, title: String) -> String {
        let current = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWeak(current) else { return current }
        if let hinted = fromTitleKeywords(title) {
            return hinted
        }
        return current
    }

    /// True for buckets that mean “we don’t actually know.”
    static func isWeak(_ category: String) -> Bool {
        let c = category.lowercased()
        return c.isEmpty
            || c == KnownCategory.miscellaneous.rawValue.lowercased()
            || c == "other"
            || c == "debit"
    }

    /// Category from generic words in the merchant/description string.
    static func fromTitleKeywords(_ title: String) -> String? {
        let t = title.lowercased()
        if PayoffPlanRecognition.looksLikeInstallmentBillingTitle(title) {
            return KnownCategory.installment.rawValue
        }
        if PayoffPlanRecognition.looksLikeLoanDisbursement(title: title) {
            return KnownCategory.loan.rawValue
        }
        if t.contains("wireless") || t.contains("cellular") || t.contains("telecom")
            || t.contains("broadband") {
            return KnownCategory.homeInternet.rawValue
        }
        if t.contains("streaming") || t.contains("subscription") || t.contains("icloud") {
            return KnownCategory.subscriptions.rawValue
        }
        if t.contains("video game") || t.contains("gaming") || t.contains(" games")
            || t.hasSuffix(" games") {
            return KnownCategory.entertainment.rawValue
        }
        if t.contains("gasoline") || t.contains("gas station") || t.contains("fuel") {
            return KnownCategory.gas.rawValue
        }
        return nil
    }
}
