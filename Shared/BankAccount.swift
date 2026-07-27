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
    var lastSyncedAt: Date

    var displayName: String {
        if let mask, !mask.isEmpty {
            return "\(name) ···\(mask)"
        }
        return name
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
        self.lastSyncedAt = lastSyncedAt
    }
}
