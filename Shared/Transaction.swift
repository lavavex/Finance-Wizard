//
//  Transaction.swift
//  FinanceWidget
//
//  Created by roberth on 7/26/26.
//

import Foundation
import SwiftData

// A transaction saved on disk in the App Group store
@Model
final class Transaction {
    // Stable id from finance-sync (Plaid/local). UNIQUE stops duplicate rows on re-sync
    @Attribute(.unique) var transactionId: String

    var title: String
    // Money value: negative = expense, positive = income in our app
    var amount: Double
    var date: Date
    var category: String
    var paymentMethod: String
    var multiplier: Double

    // Optional so older stores can migrate without requiring a value on every row.
    // Treat nil as false in UI (see isCategoryLocked / isMultiplierLocked).
    var categoryLocked: Bool?
    var multiplierLocked: Bool?
    var overrideSource: String?

    /// Effective lock flag (nil → unlocked)
    var isCategoryLocked: Bool { categoryLocked ?? false }
    /// Effective lock flag (nil → unlocked)
    var isMultiplierLocked: Bool { multiplierLocked ?? false }

    init(
        transactionId: String,
        title: String,
        amount: Double,
        date: Date,
        category: String,
        paymentMethod: String,
        multiplier: Double,
        categoryLocked: Bool = false,
        multiplierLocked: Bool = false,
        overrideSource: String? = nil
    ) {
        self.transactionId = transactionId
        self.title = title
        self.amount = amount
        self.date = date
        self.category = category
        self.paymentMethod = paymentMethod
        self.multiplier = multiplier
        self.categoryLocked = categoryLocked
        self.multiplierLocked = multiplierLocked
        self.overrideSource = overrideSource
    }
}
