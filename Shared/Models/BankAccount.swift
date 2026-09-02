//
//  BankAccount.swift
//  Finance Wizard
//
//  Linked Plaid accounts with balances + credit Liabilities fields.
//  One row per bank/credit account the user has connected.
//

import Foundation
import SwiftData

/// Cash account bucket for widgets / lists (Plaid depository subtypes).
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

    /// 0…1 when limit known; nil otherwise.
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
        // FIX: a bare substring search on a 4-digit mask matched any longer number that
        // happened to contain it (mask "1234" matched "…12340"). Require the mask to stand
        // alone as a last-four group.
        // OLD: if let mask, !mask.isEmpty, m.contains(mask) { return true }
        if let mask, !mask.isEmpty, Self.containsStandaloneMask(m, mask: mask) { return true }
        return false
    }

    /// True when `mask` appears in `text` as its own digit group rather than inside a
    /// longer number: "···0820" and "ending 0820" match, "12340" does not match "1234".
    static func containsStandaloneMask(_ text: String, mask: String) -> Bool {
        guard !mask.isEmpty else { return false }
        var searchStart = text.startIndex
        while let found = text.range(of: mask, range: searchStart..<text.endIndex) {
            let precededByDigit = found.lowerBound > text.startIndex
                && text[text.index(before: found.lowerBound)].isNumber
            let followedByDigit = found.upperBound < text.endIndex
                && text[found.upperBound].isNumber
            if !precededByDigit && !followedByDigit { return true }
            guard found.upperBound < text.endIndex else { return false }
            searchStart = found.upperBound
        }
        return false
    }

    /// Best BankAccount match for a payment method label among linked accounts.
    /// FIX: returning `hits.first(where: \.isCredit)` silently picked an arbitrary card
    /// whenever two accounts matched — Amex supplementary cards commonly share a last-five,
    /// so spend could be attributed to the wrong card's rewards profile. Prefer an exact
    /// label match, and return nil rather than guess when it is still ambiguous.
    /// OLD:
    /// let hits = accounts.filter { $0.matchesPaymentMethod(paymentMethod) }
    /// if let credit = hits.first(where: \.isCredit) { return credit }
    /// return hits.first
    static func matching(paymentMethod: String, in accounts: [BankAccount]) -> BankAccount? {
        let hits = accounts.filter { $0.matchesPaymentMethod(paymentMethod) }
        if hits.count <= 1 { return hits.first }

        let trimmed = paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines)
        let exact = hits.filter {
            let plaid = $0.plaidDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.caseInsensitiveCompare(plaid) == .orderedSame
                || trimmed.caseInsensitiveCompare($0.name) == .orderedSame
        }
        if exact.count == 1 { return exact.first }

        let pool = exact.isEmpty ? hits : exact
        let credit = pool.filter(\.isCredit)
        if credit.count == 1 { return credit.first }
        // Still ambiguous — no match is better than the wrong card.
        return nil
    }
}
