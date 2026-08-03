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

// MARK: - What is @Model?
//
// SwiftData’s @Model turns a class into something that can be stored in a local
// database (similar idea to Core Data, but simpler to write).
//
// • final class  — “final” means no other type may subclass this class.
// • Stored properties (var title, var amount, …) become columns in the store.
// • Computed properties (var displayDate { … }) are NOT stored; they are
//   calculated on the fly from other fields each time you read them.
// • The ? after a type (e.g. Bool?) means optional: the value can be a real
//   value OR nil (missing). Useful when older saved rows never had that field.

/// A single spend transaction persisted in the App Group SwiftData store.
@Model
final class Transaction {
    // @Attribute(.unique) tells SwiftData: no two rows may share this value.
    // Stable id from finance-sync (Plaid/local). UNIQUE stops duplicate rows on re-sync.
    @Attribute(.unique) var transactionId: String

    var title: String
    // Money value for expenses: stored negative (API often sends positive expense amounts;
    // the app normalizes so “spend” math can use abs() or signed sums consistently).
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
    // These fields come from the bank link (Plaid). CSV imports leave them nil.
    // Optional types keep migration safe when the schema gains new columns.

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
    //
    // A computed property has a body in braces and no stored value of its own.
    // Reading `tx.displayDate` runs this code every time. The ?? operator means
    // “use the left side if non-nil, otherwise use the right side.”

    /// Date to show in lists: authorized when known, else posted/bank date.
    var displayDate: Date { authorizedDate ?? date }

    /// Effective lock flag (nil → unlocked). Nil-coalescing keeps optionals easy to use as Bool.
    var isCategoryLocked: Bool { categoryLocked ?? false }
    /// Effective lock flag (nil → unlocked)
    var isMultiplierLocked: Bool { multiplierLocked ?? false }

    /// Parsed subscription cadence override (user-declared).
    /// guard let … else { return nil } exits early if decoding/parsing fails.
    var declaredSubscriptionCadence: SubscriptionCadence? {
        guard let raw = subscriptionCadenceOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !raw.isEmpty, raw != "none", raw != "auto" else {
            return nil
        }
        // rawValue init on an enum returns an optional: nil if the string is unknown.
        return SubscriptionCadence(rawValue: raw)
    }

    /// True when the user explicitly said this is not a subscription.
    var isDeclaredNotSubscription: Bool {
        let raw = subscriptionCadenceOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return raw == "none"
    }

    /// Reward earn bucket used for Benefits rates (override wins when set).
    /// Demonstrates optional chaining (?.) and first(where:) to search a collection.
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

    // init is the constructor. Parameters with `= value` are optional to pass —
    // callers can omit them and get the default. self.property = parameter copies
    // the argument into the stored property on this instance.
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
