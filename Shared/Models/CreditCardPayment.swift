//
//  CreditCardPayment.swift
//  Finance Wizard
//
//  Card payments tracked separately so they never inflate Total Spend / Income.
//  Paying your Visa from checking is transferring debt, not new spending —
//  that is why this model is its own SwiftData type.
//

import Foundation
import SwiftData

/// One credit-card bill payment row (Plaid or inferred), stored outside spend.
@Model
final class CreditCardPayment {
    /// Plaid transaction_id (unique)
    @Attribute(.unique) var transactionId: String
    /// Positive dollars paid toward the card
    var amount: Double
    var date: Date
    /// Credit card / account display name
    var cardName: String
    /// Optional funding account (checking, etc.)
    var sourceAccount: String?
    var title: String
    /// Plaid account_id of the credit account when known
    var creditAccountId: String?
    var institutionName: String?

    init(
        transactionId: String,
        amount: Double,
        date: Date,
        cardName: String,
        sourceAccount: String? = nil,
        title: String,
        creditAccountId: String? = nil,
        institutionName: String? = nil
    ) {
        self.transactionId = transactionId
        self.amount = amount
        self.date = date
        self.cardName = cardName
        self.sourceAccount = sourceAccount
        self.title = title
        self.creditAccountId = creditAccountId
        self.institutionName = institutionName
    }
}

// MARK: - Analytics helpers
// Namespace enum: only static methods; groups payment math for widgets and UI.

/// Filter, sum, and dedupe credit-card payments for a calendar period.
enum CreditAnalytics {
    /// Payments in a week/month (or all), after collapsing bank duplicates.
    static func payments(
        in rows: [CreditCardPayment],
        period: SnapshotPeriod,
        referenceDate: Date = Date()
    ) -> [CreditCardPayment] {
        guard let interval = TransactionAnalytics.dateInterval(
            for: period,
            referenceDate: referenceDate
        ) else {
            return deduplicated(rows)
        }
        let filtered = rows.filter { $0.date >= interval.start && $0.date < interval.end }
        return deduplicated(filtered)
    }

    /// Sum after collapsing checking-side + credit-side duplicates of the same bill pay.
    static func totalPaid(in rows: [CreditCardPayment]) -> Double {
        deduplicated(rows).reduce(0) { $0 + max(0, $1.amount) }
    }

    /// Totals keyed by card display name — dictionary [String: Double].
    /// map[key, default: 0] += x creates the key with 0 if missing, then adds.
    static func paidByCard(in rows: [CreditCardPayment]) -> [String: Double] {
        var map: [String: Double] = [:]
        for row in deduplicated(rows) {
            let key = row.cardName.isEmpty ? "Unknown card" : row.cardName
            map[key, default: 0] += max(0, row.amount)
        }
        return map
    }

    /// Banks post the same payment twice (ACH out of checking + “Payment Thank You” on the card).
    /// Keep one row per day/amount/mask, preferring the side with `creditAccountId`.
    ///
    /// Builds a dictionary keyed by "day|amount|mask"; the value is the best row seen.
    /// Closure preferNew is a nested function that decides whether to replace the stored row.
    static func deduplicated(_ rows: [CreditCardPayment]) -> [CreditCardPayment] {
        let cal = Calendar.current
        var best: [String: CreditCardPayment] = [:]

        for row in rows {
            let day = cal.startOfDay(for: row.date)
            let dayKey = ISO8601DateFormatter().string(from: day)
            let amountKey = String(format: "%.2f", max(0, row.amount))
            // ?? chains: first non-nil mask wins.
            let mask = extractMask(from: row.cardName)
                ?? extractMask(from: row.title)
                ?? extractMask(from: row.sourceAccount ?? "")
                ?? "nomask"
            let key = "\(dayKey)|\(amountKey)|\(mask.lowercased())"

            if let existing = best[key] {
                // Prefer linked credit account id; then more specific card name
                let preferNew: Bool = {
                    if existing.creditAccountId == nil, row.creditAccountId != nil { return true }
                    if existing.creditAccountId != nil, row.creditAccountId == nil { return false }
                    if existing.cardName.count < row.cardName.count { return true }
                    return false
                }()
                if preferNew { best[key] = row }
            } else {
                best[key] = row
            }
        }

        // Dictionary .values is unordered; sort newest first for stable UI lists.
        return best.values.sorted { $0.date > $1.date }
    }

    /// Last 4 digits from “···0820”, “ending in 0820”, etc.
    /// Uses String.range(of:options: .regularExpression) for simple pattern matching.
    static func extractMask(from text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        // ···1234 or ...1234
        if let r = text.range(of: #"[\·\.]{2,4}(\d{4})"#, options: .regularExpression) {
            let s = String(text[r])
            return String(s.suffix(4))
        }
        if let r = text.range(of: #"ending in\s*(\d{4})"#, options: [.regularExpression, .caseInsensitive]) {
            let s = String(text[r])
            return String(s.suffix(4))
        }
        if let r = text.range(of: #"\b(\d{4})\b"#, options: .regularExpression) {
            // only if string is short / card-like
            let digits = String(text[r])
            if text.count <= 40 { return digits }
        }
        return nil
    }
}
