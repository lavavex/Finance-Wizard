//
//  Transaction.swift
//  Finance Wizard
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
    // Money value for expenses: stored negative (API sends positive expense amounts)
    // Income lives in the separate `Income` model and is never mixed into spend.
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

    /// Raw Plaid `payment_channel` (`online`, `in store`, `other`) when known.
    var plaidPaymentChannel: String?
    /// Effective rail: `debit` | `ach` | `other` (see PaymentRail).
    var paymentRail: String?
    /// When true, Sync will not overwrite `paymentRail`.
    var paymentRailLocked: Bool?

    /// Optional lock for **reward** earn category (e.g. Travel (Portal) vs Travel (Other)).
    /// Independent of general spend `category`. Nil → derive from category + title.
    var rewardCategoryOverride: String?

    /// User override for subscription detection: `nil` = auto,
    /// `"yearly"` / `"monthly"` / `"weekly"` = treat as that cadence,
    /// `"none"` = not a subscription.
    var subscriptionCadenceOverride: String?

    // MARK: - Plaid enrichment (optional; nil on CSV / older rows)

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

    /// Date to show in lists: authorized when known, else posted/bank date.
    var displayDate: Date { authorizedDate ?? date }

    /// Effective lock flag (nil → unlocked)
    var isCategoryLocked: Bool { categoryLocked ?? false }
    /// Effective lock flag (nil → unlocked)
    var isMultiplierLocked: Bool { multiplierLocked ?? false }

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

    var isDeclaredNotSubscription: Bool {
        let raw = subscriptionCadenceOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "none"
    }

    /// Reward earn bucket used for Benefits rates (override wins when set).
    var effectiveRewardCategory: RewardCategory {
        if let raw = rewardCategoryOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let match = RewardCategory.allCases.first(where: {
               $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame
           }) {
            return match
        }
        return RewardCategory.forTransaction(generalCategory: category, title: title)
    }

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
        overrideSource: String? = nil,
        plaidPaymentChannel: String? = nil,
        paymentRail: String? = nil,
        paymentRailLocked: Bool = false,
        rewardCategoryOverride: String? = nil,
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
        self.multiplier = multiplier
        self.categoryLocked = categoryLocked
        self.multiplierLocked = multiplierLocked
        self.overrideSource = overrideSource
        self.plaidPaymentChannel = plaidPaymentChannel
        self.paymentRail = paymentRail
        self.paymentRailLocked = paymentRailLocked
        self.rewardCategoryOverride = rewardCategoryOverride
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
