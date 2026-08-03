//
//  BankAccount.swift
//  Finance Wizard
//
//  Linked Plaid accounts with balances + credit Liabilities fields.
//  One row per bank/credit account the user has connected (or Apple Card synthetic).
//

import Foundation
import SwiftData

/// Cash account bucket for widgets / lists (Plaid depository subtypes).
///
/// Small enums like this keep UI labels, icons, and grouping logic in one place.
/// String raw values + CaseIterable make pickers and switch statements easy.
enum DepositoryKind: String, Sendable, CaseIterable, Identifiable {
    case checking
    case savings
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .checking: return "Checking"
        case .savings: return "Savings"
        case .other: return "Cash"
        }
    }

    /// SF Symbol name for SwiftUI Image(systemName:).
    var systemImage: String {
        switch self {
        case .checking: return "building.columns.fill"
        case .savings: return "leaf.fill"
        case .other: return "banknote.fill"
        }
    }
}

/// One linked account (checking, savings, credit card, etc.) in SwiftData.
@Model
final class BankAccount {
    /// Plaid account_id (unique)
    @Attribute(.unique) var accountId: String
    /// Parent Plaid Item id (one Item can own several accounts at the same bank)
    var itemId: String
    var name: String
    var officialName: String?
    /// Last digits shown by the bank (e.g. "0820")
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
    // Optional fields stay nil until Plaid returns liabilities data for credit cards.

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

    // MARK: - Depository reward multipliers (e.g. X Money 3% debit, 0% ACH)
    // Multipliers as fractions: 0.03 means 3% cash back.

    /// Applied to new debit-rail spend when multiplier is not locked (e.g. 0.03 ≈ 3% cashback).
    var debitRewardMultiplier: Double?
    /// Applied to new ACH-rail spend when multiplier is not locked (often 0 or 1).
    var achRewardMultiplier: Double?

    // MARK: - Computed helpers for UI

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

    /// Subtitle under the nickname (institution / original Plaid name).
    /// Omits last-four when the display name already ends with it (product pick → "Card 1234").
    var subtitleDetail: String {
        let customLabel = CardLabelStore.label(accountId: accountId, fallback: plaidDisplayName)
        var parts: [String] = []
        if !institutionName.isEmpty {
            parts.append(institutionName)
        }
        if let mask, !mask.isEmpty {
            let endsWithMask = customLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasSuffix(mask)
            if !endsWithMask {
                parts.append("···\(mask)")
            }
        }
        // If user renamed (e.g. product + last 4), also show original Plaid account name
        if customLabel != plaidDisplayName {
            parts.insert(plaidDisplayName, at: 0)
        }
        return parts.joined(separator: " · ")
    }

    /// True when Plaid type string is credit (case-insensitive).
    var isCredit: Bool {
        type.lowercased() == "credit"
    }

    var isDepository: Bool {
        type.lowercased() == "depository"
    }

    /// Checking / savings / other cash (money market, prepaid, etc.).
    /// Inspects subtype and name with simple string contains checks.
    var depositoryKind: DepositoryKind {
        let sub = (subtype ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let name = self.name.lowercased()
        if sub.contains("saving") || name.contains("saving") { return .savings }
        if sub.contains("check") || name.contains("check") || name.contains("spend") {
            return .checking
        }
        if sub.contains("money market") || sub.contains("cash management") || sub.contains("prepaid") {
            return .other
        }
        // Plaid often uses exact subtype strings
        switch sub {
        case "checking", "paypal": return .checking
        case "savings", "cd", "hsa": return .savings
        default: return .other
        }
    }

    /// Preferred cash balance for display (available when bank provides it).
    var displayCashBalance: Double {
        availableBalance ?? currentBalance
    }

    /// Reward multiplier for a payment rail, if configured on this account.
    /// switch on an enum is exhaustive: every PaymentRail case must be handled.
    func rewardMultiplier(for rail: PaymentRail) -> Double? {
        switch rail {
        case .debit: return debitRewardMultiplier
        case .ach: return achRewardMultiplier
        case .other: return nil
        }
    }

    /// 0…1 when limit known; nil otherwise.
    /// min/max clamp utilization so bad data never goes outside 0–100%.
    var utilization: Double? {
        guard isCredit, let limit = creditLimit, limit > 0 else { return nil }
        return min(max(currentBalance / limit, 0), 1)
    }

    /// True when any liabilities payment/APR fields are present.
    /// || short-circuits: first true stops evaluating the rest.
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
        liabilitiesSyncedAt: Date? = nil,
        debitRewardMultiplier: Double? = nil,
        achRewardMultiplier: Double? = nil
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
        self.debitRewardMultiplier = debitRewardMultiplier
        self.achRewardMultiplier = achRewardMultiplier
    }

    /// Whether a transaction payment_method string belongs to this account (mask / exact).
    func matchesPaymentMethod(_ method: String) -> Bool {
        let m = method.trimmingCharacters(in: .whitespacesAndNewlines)
        let plaid = plaidDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        // caseInsensitiveCompare returns ComparisonResult; .orderedSame means equal ignoring case.
        if m.caseInsensitiveCompare(plaid) == .orderedSame { return true }
        if m.caseInsensitiveCompare(name) == .orderedSame { return true }
        if let mask, !mask.isEmpty, m.contains(mask) { return true }
        // Synthetic Apple Card account matches CSV / Wallet payment method
        if AppleCardAccount.isAppleCard(account: self), AppleCardAccount.isAppleCard(paymentMethod: method) {
            return true
        }
        return false
    }

    /// Best BankAccount match for a payment method label among linked accounts.
    /// static method: call as BankAccount.matching(paymentMethod:in:) without an instance.
    static func matching(paymentMethod: String, in accounts: [BankAccount]) -> BankAccount? {
        // Prefer credit accounts with mask match, then any match
        let hits = accounts.filter { $0.matchesPaymentMethod(paymentMethod) }
        // \.isCredit is a key path — shorthand for { $0.isCredit }
        if let credit = hits.first(where: \.isCredit) { return credit }
        return hits.first
    }
}
