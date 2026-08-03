//
//  RecurringStream.swift
//  Finance Wizard
//
//  Plaid /transactions/recurring/get streams (subscriptions & regular income).
//  Each stream is a pattern Plaid detected: e.g. Netflix monthly, biweekly payroll.
//

import Foundation
import SwiftData

/// One recurring money pattern from Plaid, persisted for budget / subscription UI.
@Model
final class RecurringStream {
    /// Plaid stream_id (unique).
    @Attribute(.unique) var streamId: String
    /// Owning Plaid Item id.
    var itemId: String
    /// `outflow` (subscription/bill) or `inflow` (payroll, etc.).
    var direction: String
    var streamDescription: String
    // Optional merchant when Plaid enriched the stream.
    var merchantName: String?
    var averageAmount: Double
    var lastAmount: Double
    /// Plaid frequency: WEEKLY, BIWEEKLY, SEMI_MONTHLY, MONTHLY, ANNUALLY, UNKNOWN, …
    var frequency: String
    var firstDate: Date?
    var lastDate: Date?
    var isActive: Bool
    /// JSON array of sample transaction_ids (Data? blob — see transactionIds computed property).
    var transactionIdsJSON: Data?
    var accountId: String?
    var updatedAt: Date

    // transactionIds parameter is [String] for callers; we encode to Data for storage.
    // try? JSONEncoder().encode(…) turns an array into JSON bytes, or nil on failure.
    init(
        streamId: String,
        itemId: String,
        direction: String,
        streamDescription: String,
        merchantName: String? = nil,
        averageAmount: Double,
        lastAmount: Double,
        frequency: String,
        firstDate: Date? = nil,
        lastDate: Date? = nil,
        isActive: Bool = true,
        transactionIds: [String] = [],
        accountId: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.streamId = streamId
        self.itemId = itemId
        self.direction = direction
        self.streamDescription = streamDescription
        self.merchantName = merchantName
        self.averageAmount = averageAmount
        self.lastAmount = lastAmount
        self.frequency = frequency
        self.firstDate = firstDate
        self.lastDate = lastDate
        self.isActive = isActive
        self.transactionIdsJSON = try? JSONEncoder().encode(transactionIds)
        self.accountId = accountId
        self.updatedAt = updatedAt
    }

    /// Decoded list of sample transaction ids (empty if missing or corrupt JSON).
    /// [String].self is a metatype: tells Decoder “expect an array of String.”
    var transactionIds: [String] {
        guard let transactionIdsJSON,
              let ids = try? JSONDecoder().decode([String].self, from: transactionIdsJSON) else {
            return []
        }
        return ids
    }

    /// Prefer merchant name; fall back to Plaid’s stream description.
    var displayName: String {
        let m = (merchantName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        return streamDescription
    }

    /// True when this stream is money leaving the account (subscription / bill).
    var isOutflow: Bool { direction.lowercased() == "outflow" }

    /// Maps Plaid frequency strings onto the app’s SubscriptionCadence enum when possible.
    /// Returning an optional enum means “unknown / unmapped” becomes nil.
    var subscriptionCadence: SubscriptionCadence? {
        switch frequency.uppercased() {
        case "WEEKLY", "WEEK": return .weekly
        case "BIWEEKLY", "BIWEEKLY_CALENDAR", "SEMI_MONTHLY", "SEMIMONTHLY", "MONTHLY", "MONTH":
            return .monthly
        case "ANNUALLY", "ANNUAL", "YEARLY", "YEAR":
            return .yearly
        default:
            // Map biweekly average to monthly for burn estimate
            return .monthly
        }
    }

    /// Estimated monthly burn/credit for budget.
    /// Converts weekly/biweekly/etc. averages into an approximate monthly dollar amount.
    var estimatedMonthly: Double {
        let amt = abs(averageAmount > 0 ? averageAmount : lastAmount)
        switch frequency.uppercased() {
        case "WEEKLY", "WEEK": return amt * (52.0 / 12.0)
        case "BIWEEKLY", "BIWEEKLY_CALENDAR": return amt * (26.0 / 12.0)
        case "SEMI_MONTHLY", "SEMIMONTHLY": return amt * 2
        case "ANNUALLY", "ANNUAL", "YEARLY", "YEAR": return amt / 12.0
        default: return amt
        }
    }
}
