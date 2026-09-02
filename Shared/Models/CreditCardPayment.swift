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
        sumPaid(deduplicated(rows))
    }

    /// Sum rows that are already deduplicated. Callers holding the output of
    /// `payments(in:period:)` should use this — running dedup twice is O(n²) for nothing.
    static func sumPaid(_ rows: [CreditCardPayment]) -> Double {
        rows.reduce(0) { $0 + max(0, $1.amount) }
    }

    /// Checking ACH and the card’s “Thank You” can land 0–3 days apart (Apple Card, EPAY).
    /// Pair same amount + same card identity; do not merge two different cards that happen
    /// to be paid the same dollars (e.g. $1000 Apple vs $1000 Amex).
    static let duplicateWindowDays = 3

    static func deduplicated(_ rows: [CreditCardPayment]) -> [CreditCardPayment] {
        let cal = Calendar.current
        let sorted = rows.sorted { $0.date < $1.date }
        var used = Set<String>()
        var chosen: [CreditCardPayment] = []

        for row in sorted {
            if used.contains(row.transactionId) { continue }
            var group = [row]
            let rowDay = cal.startOfDay(for: row.date)
            for other in sorted {
                if other.transactionId == row.transactionId { continue }
                if used.contains(other.transactionId) { continue }
                if abs(other.amount - row.amount) > 0.021 { continue }
                let otherDay = cal.startOfDay(for: other.date)
                let days = abs(cal.dateComponents([.day], from: rowDay, to: otherDay).day ?? 99)
                if days > duplicateWindowDays { continue }
                if isSamePayment(row, other) {
                    group.append(other)
                }
            }
            for item in group { used.insert(item.transactionId) }
            chosen.append(preferredPayment(in: group))
        }

        return chosen.sorted { $0.date > $1.date }
    }

    /// True when two rows are the checking-side and card-side of one bill pay.
    static func isSamePayment(_ a: CreditCardPayment, _ b: CreditCardPayment) -> Bool {
        let ia = paymentIdentities(a)
        let ib = paymentIdentities(b)
        let ma = ia.first { $0.hasPrefix("mask:") }
        let mb = ib.first { $0.hasPrefix("mask:") }
        // Last-four of the *card* is the strongest match; different fours are different cards.
        if let ma, let mb { return ma == mb }
        let issuersA = ia.filter { $0.hasPrefix("issuer:") }
        let issuersB = ib.filter { $0.hasPrefix("issuer:") }
        if !issuersA.isEmpty, !issuersB.isEmpty {
            return !issuersA.isDisjoint(with: issuersB)
        }
        // Unlabeled funding (EPAY) vs a card Thank You of the same amount.
        return isCardSide(a) != isCardSide(b)
    }

    private static func preferredPayment(in group: [CreditCardPayment]) -> CreditCardPayment {
        group.max { a, b in
            let ac = isCardSide(a) ? 1 : 0
            let bc = isCardSide(b) ? 1 : 0
            if ac != bc { return ac < bc }
            if (a.creditAccountId == nil) != (b.creditAccountId == nil) {
                return a.creditAccountId == nil
            }
            return a.cardName.count < b.cardName.count
        } ?? group[0]
    }

    private static func isCardSide(_ row: CreditCardPayment) -> Bool {
        if row.creditAccountId != nil { return true }
        if CardIssuerCatalog.looksLikeCreditAccountName(row.cardName) { return true }
        let t = row.title.lowercased()
        if t.contains("thank you") || t.contains("thankyou") { return true }
        if t.contains("ach deposit") { return true }
        return false
    }

    /// Card identity: last-four of the *card* (not the funding account) or issuer slug.
    static func paymentIdentities(_ row: CreditCardPayment) -> Set<String> {
        var ids = Set<String>()
        let title = row.title.lowercased()
        let card = row.cardName.lowercased()
        let blob = title + " " + card

        ids.formUnion(CardIssuerCatalog.issuerIds(in: blob))

        if let mask = extractMask(from: row.title),
           title.contains("ending in") || title.contains("card ending") {
            ids.insert("mask:\(mask)")
        }
        if CardIssuerCatalog.looksLikeCreditAccountName(row.cardName),
           let mask = extractMask(from: row.cardName) {
            ids.insert("mask:\(mask)")
        }
        return ids
    }

    /// Last 4 digits from “···0820”, “ending in 0820”, etc.
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
            let digits = String(text[r])
            if text.count <= 40 { return digits }
        }
        return nil
    }
}
