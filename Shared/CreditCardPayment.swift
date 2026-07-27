//
//  CreditCardPayment.swift
//  Finance Wizard
//
//  Card payments tracked separately so they never inflate Total Spend / Income.
//

import Foundation
import SwiftData

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

enum CreditAnalytics {
    static func payments(
        in rows: [CreditCardPayment],
        period: SnapshotPeriod,
        referenceDate: Date = Date()
    ) -> [CreditCardPayment] {
        guard let interval = TransactionAnalytics.dateInterval(
            for: period,
            referenceDate: referenceDate
        ) else {
            return rows
        }
        return rows.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    static func totalPaid(in rows: [CreditCardPayment]) -> Double {
        rows.reduce(0) { $0 + max(0, $1.amount) }
    }

    static func paidByCard(in rows: [CreditCardPayment]) -> [String: Double] {
        var map: [String: Double] = [:]
        for row in rows {
            let key = row.cardName.isEmpty ? "Unknown card" : row.cardName
            map[key, default: 0] += max(0, row.amount)
        }
        return map
    }
}
