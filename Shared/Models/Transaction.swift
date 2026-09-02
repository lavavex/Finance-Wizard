//
//  Transaction.swift
//  Finance Wizard
//
//  One expense / purchase row saved on disk. This is the main “money out” model
//  used by lists, charts, and widgets. Income is a separate model so spend totals
//  never accidentally include paychecks.
//

import Foundation
import SwiftData

/// A single spend transaction persisted in the App Group SwiftData store.
@Model
final class Transaction {
    /// Stable id from finance-sync (Plaid/local). Unique so re-sync cannot duplicate rows.
    @Attribute(.unique) var transactionId: String

    var title: String
    /// Expenses are stored negative (API often sends positive spend). Income is a separate model.
    var amount: Double
    var date: Date
    var category: String
    var paymentMethod: String

    /// Nil on older rows; treat as false (see isCategoryLocked).
    var categoryLocked: Bool?
    var overrideSource: String?

    /// Raw Plaid `payment_channel` (`online`, `in store`, `other`) when known.
    var plaidPaymentChannel: String?
    /// Effective rail: `debit` | `ach` | `other` (see PaymentRail).
    var paymentRail: String?
    /// When true, Sync will not overwrite `paymentRail`.
    var paymentRailLocked: Bool?

    /// User override for subscription detection: `nil` = auto,
    /// `"yearly"` / `"monthly"` / `"weekly"` = treat that vendor as that cadence
    /// (amount may vary), `"none"` = not a subscription.
    var subscriptionCadenceOverride: String?

    // MARK: - Plaid enrichment (nil on CSV / older rows)

    /// When the charge was authorized (prefer over `date` for posted txs when present).
    var authorizedDate: Date?
    /// Pending twin id — when a posted tx arrives, we drop the pending row.
    var pendingTransactionId: String?
    /// Plaid account_id (for cleanup when accounts are unlinked).
    var plaidAccountId: String?
    /// Stable merchant entity id when Plaid provides one.
    var merchantEntityId: String?
    /// Enriched merchant name (may differ from `title`).
    var merchantName: String?
    /// Merchant / counterparty logo URL (https).
    var logoURL: String?
    /// Merchant website.
    var website: String?
    /// PFC confidence: VERY_HIGH / HIGH / MEDIUM / LOW / UNKNOWN
    var pfcConfidence: String?
    /// Still pending at the bank.
    var isPending: Bool?

    // MARK: - Computed properties

    /// Date to show in lists: authorized when known, else posted/bank date.
    var displayDate: Date { authorizedDate ?? date }

    /// Effective lock flag (nil → unlocked).
    var isCategoryLocked: Bool { categoryLocked ?? false }

    /// Parsed subscription cadence override (user-declared).
    var declaredSubscriptionCadence: SubscriptionCadence? {
        guard let raw = subscriptionCadenceOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty, raw != "none", raw != "auto" else {
            return nil
        }
        return SubscriptionCadence(rawValue: raw)
    }

    /// True when the user explicitly said this is not a subscription.
    var isDeclaredNotSubscription: Bool {
        let raw = subscriptionCadenceOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "none"
    }

    init(
        transactionId: String,
        title: String,
        amount: Double,
        date: Date,
        category: String,
        paymentMethod: String,
        categoryLocked: Bool = false,
        overrideSource: String? = nil,
        plaidPaymentChannel: String? = nil,
        paymentRail: String? = nil,
        paymentRailLocked: Bool = false,
        subscriptionCadenceOverride: String? = nil,
        authorizedDate: Date? = nil,
        pendingTransactionId: String? = nil,
        plaidAccountId: String? = nil,
        merchantEntityId: String? = nil,
        merchantName: String? = nil,
        logoURL: String? = nil,
        website: String? = nil,
        pfcConfidence: String? = nil,
        isPending: Bool? = nil
    ) {
        self.transactionId = transactionId
        self.title = title
        self.amount = amount
        self.date = date
        self.category = category
        self.paymentMethod = paymentMethod
        self.categoryLocked = categoryLocked
        self.overrideSource = overrideSource
        self.plaidPaymentChannel = plaidPaymentChannel
        self.paymentRail = paymentRail
        self.paymentRailLocked = paymentRailLocked
        self.subscriptionCadenceOverride = subscriptionCadenceOverride
        self.authorizedDate = authorizedDate
        self.pendingTransactionId = pendingTransactionId
        self.plaidAccountId = plaidAccountId
        self.merchantEntityId = merchantEntityId
        self.merchantName = merchantName
        self.logoURL = logoURL
        self.website = website
        self.pfcConfidence = pfcConfidence
        self.isPending = isPending
    }
}
