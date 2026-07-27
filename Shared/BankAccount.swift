//
//  BankAccount.swift
//  Finance Wizard
//
//  Linked Plaid accounts with balances + credit Liabilities fields.
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

    // MARK: - Credit Liabilities (`/liabilities/get`)

    /// true if a payment is currently overdue (when bank provides it)
    var isOverdue: Bool?
    var lastPaymentAmount: Double?
    var lastPaymentDate: Date?
    var lastStatementIssueDate: Date?
    var lastStatementBalance: Double?
    var minimumPaymentAmount: Double?
    var nextPaymentDueDate: Date?
    /// APR percentages from liabilities.credit.aprs
    var purchaseApr: Double?
    var cashApr: Double?
    var balanceTransferApr: Double?
    var specialApr: Double?
    /// When liabilities fields were last applied (nil = never)
    var liabilitiesSyncedAt: Date?

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

    /// True when any liabilities payment/APR fields are present.
    var hasLiabilitiesDetails: Bool {
        minimumPaymentAmount != nil
            || nextPaymentDueDate != nil
            || lastPaymentAmount != nil
            || lastStatementBalance != nil
            || purchaseApr != nil
            || cashApr != nil
            || balanceTransferApr != nil
            || isOverdue == true
    }

    /// Days until next payment due (negative if past due).
    var daysUntilDue: Int? {
        guard let due = nextPaymentDueDate else { return nil }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.startOfDay(for: due)
        return cal.dateComponents([.day], from: start, to: end).day
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
        lastSyncedAt: Date = Date(),
        isOverdue: Bool? = nil,
        lastPaymentAmount: Double? = nil,
        lastPaymentDate: Date? = nil,
        lastStatementIssueDate: Date? = nil,
        lastStatementBalance: Double? = nil,
        minimumPaymentAmount: Double? = nil,
        nextPaymentDueDate: Date? = nil,
        purchaseApr: Double? = nil,
        cashApr: Double? = nil,
        balanceTransferApr: Double? = nil,
        specialApr: Double? = nil,
        liabilitiesSyncedAt: Date? = nil
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
        self.isOverdue = isOverdue
        self.lastPaymentAmount = lastPaymentAmount
        self.lastPaymentDate = lastPaymentDate
        self.lastStatementIssueDate = lastStatementIssueDate
        self.lastStatementBalance = lastStatementBalance
        self.minimumPaymentAmount = minimumPaymentAmount
        self.nextPaymentDueDate = nextPaymentDueDate
        self.purchaseApr = purchaseApr
        self.cashApr = cashApr
        self.balanceTransferApr = balanceTransferApr
        self.specialApr = specialApr
        self.liabilitiesSyncedAt = liabilitiesSyncedAt
    }

    /// Whether a transaction payment_method string belongs to this account (mask / exact).
    func matchesPaymentMethod(_ method: String) -> Bool {
        let m = method.trimmingCharacters(in: .whitespacesAndNewlines)
        let plaid = plaidDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if m.caseInsensitiveCompare(plaid) == .orderedSame { return true }
        if m.caseInsensitiveCompare(name) == .orderedSame { return true }
        if let mask, !mask.isEmpty, m.contains(mask) { return true }
        return false
    }

    /// Best BankAccount match for a payment method label among linked accounts.
    static func matching(paymentMethod: String, in accounts: [BankAccount]) -> BankAccount? {
        // Prefer credit accounts with mask match, then any match
        let hits = accounts.filter { $0.matchesPaymentMethod(paymentMethod) }
        if let credit = hits.first(where: \.isCredit) { return credit }
        return hits.first
    }
}
