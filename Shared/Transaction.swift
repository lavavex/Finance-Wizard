//
//  Transaction.swift
//  FinanceWidget
//
//  Created by roberth on 7/26/26.
//

// Foundation types like Date and String
import Foundation
// SwiftData = Apple's local database for models (app + future widget)
import SwiftData

// A transaction saved on disk in the App Group store
// @Model tells SwiftData to persist instances of this class
@Model
final class Transaction {
    // Stable id from finance-sync (Plaid/local). UNIQUE stops duplicate rows on re-sync
    @Attribute(.unique) var transactionId: String

    // Merchant / vendor display name
    var title: String
    // Money value: negative = expense, positive = income in our app
    var amount: Double
    // When the purchase happened
    var date: Date
    // Budget category (Dining, Gas (Car), …) — later: category alerts
    var category: String
    // Card / payment method — later: spend-by-card widget
    var paymentMethod: String
    // Points multiplier (e.g. 5 = 5x). points ≈ abs(amount) * multiplier
    var multiplier: Double

    // Create a new row (used when we insert the first time we see an id)
    init(
        transactionId: String,
        title: String,
        amount: Double,
        date: Date,
        category: String,
        paymentMethod: String,
        multiplier: Double
    ) {
        self.transactionId = transactionId
        self.title = title
        self.amount = amount
        self.date = date
        self.category = category
        self.paymentMethod = paymentMethod
        self.multiplier = multiplier
    }
}
