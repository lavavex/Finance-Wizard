//
//  BankAccount.swift
//  Finance Wizard
//
//  Linked Plaid accounts with balances (credit utilization lives here).
//

import Foundation
import SwiftData

@Model
final class BankAccount {
    /// Plaid account_id (unique)
    @Attribute(.unique) var accountId: String
    /// Parent Plaid Item id
    var itemId: String
    var name: String
    var officialName: String?
    var mask: String?
    /// depository | credit | loan | investment | other
    var type: String
    var subtype: String?
    var institutionName: String
    /// Current balance from Plaid (for credit: amount owed; for depository: ledger balance)
    var currentBalance: Double
    var availableBalance: Double?
    /// Credit limit when type == credit (nil for checking/savings)
    var creditLimit: Double?
    /// Plaid institution_id when known (for logo lookup)
    var institutionId: String?
    var lastSyncedAt: Date

    /// Plaid-derived label (e.g. "Credit Card ···0820") before user nickname.
    var plaidDisplayName: String {
        if let mask, !mask.isEmpty {
            return "\(name) ···\(mask)"
        }
        return name
    }

    /// User nickname when set, otherwise Plaid label.
    var displayName: String {
        CardLabelStore.label(accountId: accountId, fallback: plaidDisplayName)
    }

    /// Subtitle under the nickname (mask / original Plaid name).
    var subtitleDetail: String {
        var parts: [String] = []
        if !institutionName.isEmpty {
            parts.append(institutionName)
        }
        if let mask, !mask.isEmpty {
            parts.append("···\(mask)")
        }
        // If user renamed, also show original account name
        if CardLabelStore.label(accountId: accountId, fallback: plaidDisplayName) != plaidDisplayName {
            parts.insert(plaidDisplayName, at: 0)
        }
        return parts.joined(separator: " · ")
    }

    var isCredit: Bool {
        type.lowercased() == "credit"
    }

    /// 0…1 when limit known; nil otherwise
    var utilization: Double? {
        guard isCredit, let limit = creditLimit, limit > 0 else { return nil }
        return min(max(currentBalance / limit, 0), 1)
    }

    init(
        accountId: String,
        itemId: String,
        name: String,
        officialName: String? = nil,
        mask: String? = nil,
        type: String,
        subtype: String? = nil,
        institutionName: String,
        currentBalance: Double,
        availableBalance: Double? = nil,
        creditLimit: Double? = nil,
        institutionId: String? = nil,
        lastSyncedAt: Date = Date()
    ) {
        self.accountId = accountId
        self.itemId = itemId
        self.name = name
        self.officialName = officialName
        self.mask = mask
        self.type = type
        self.subtype = subtype
        self.institutionName = institutionName
        self.currentBalance = currentBalance
        self.availableBalance = availableBalance
        self.creditLimit = creditLimit
        self.institutionId = institutionId
        self.lastSyncedAt = lastSyncedAt
    }
}
