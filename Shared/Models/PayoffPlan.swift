//
//  PayoffPlan.swift
//  Finance Wizard
//
//  User-declared installment / promo payoff on a credit card.
//  Card-line loans, purchase installments, and promo APR are different products.
//

import Foundation
import SwiftData

/// How this slice of a card balance is being paid down.
enum PayoffPlanKind: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Lump sum against a card’s credit line (Chase My Loan). Fixed payment + APR + term.
    case myLoan
    /// A purchase converted to installments (Chase Pay Over Time, Amex Plan It).
    case payOverTime
    /// Promo / 0% APR on a balance until a date (e.g. AmEx intro APR).
    case promoAPR
    /// Any other scheduled card-balance payoff.
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .myLoan: return "My Loan"
        case .payOverTime: return "Pay Over Time"
        case .promoAPR: return "Promo APR"
        case .custom: return "Balance payoff"
        }
    }

    /// Issuer-scheduled: payment is part of the card minimum and due on the statement due date.
    var followsCardStatement: Bool {
        self == .myLoan || self == .payOverTime
    }

    var shortHelp: String {
        switch self {
        case .myLoan:
            return "A lump sum against the card’s credit line. The monthly amount is added to the card minimum and due on the same day as the card."
        case .payOverTime:
            return "A purchase billed in installments. The monthly amount (plus any plan fee) is added to the card minimum and due with the card."
        case .promoAPR:
            return "Pay a promo or 0% balance down by a date you choose. Size the monthly extra so it clears before that date."
        case .custom:
            return "Pay a slice of this card down by a date you choose."
        }
    }

    var systemImage: String {
        switch self {
        case .myLoan: return "banknote"
        case .payOverTime: return "calendar.badge.clock"
        case .promoAPR: return "percent"
        case .custom: return "creditcard"
        }
    }
}

/// Title / PFC heuristics for installment billing and card-line loan proceeds.
enum PayoffPlanRecognition {
    /// Card-line loan posting or checking deposit (any issuer).
    /// Plaid `LOAN_DISBURSEMENTS`, or titles like “My Loan TO 2667” / “loan proceeds”.
    static func looksLikeLoanDisbursement(title: String, pfc: String? = nil) -> Bool {
        let p = (pfc ?? "").uppercased()
        if p.contains("LOAN_DISBURSEMENTS") { return true }
        let t = title.lowercased()
        if t.contains("student loan") || t.contains("auto loan") { return false }
        if t.contains("loan payment") || t.contains("loan pmt") || t.contains("loan pymt") {
            return false
        }
        if t.contains("loan disbursement") || t.contains("loan proceeds") { return true }
        if t.contains("my loan") { return true }
        if t.range(of: #"loan to \d"#, options: .regularExpression) != nil { return true }
        return false
    }

    /// Short plan name from a disbursement title (“My Loan TO 2667” → “My Loan”).
    static func displayName(fromTitle title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: " TO ", options: .caseInsensitive) {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    /// Recurring installment billing of an existing purchase (Apple Card CSV, Pay Over Time, Plan It).
    static func looksLikeInstallmentBillingTitle(_ title: String) -> Bool {
        let t = title.lowercased()
        if t.contains("pay over time") { return true }
        if t.contains("installment") { return true }
        return false
    }
}

/// One scheduled payoff of a card balance or purchase, shown on Recurring like a bill.
@Model
final class PayoffPlan {
    @Attribute(.unique) var planId: String
    /// `PayoffPlanKind.rawValue`
    var kindRaw: String
    var name: String
    /// Linked `BankAccount.accountId` when known.
    var accountId: String?
    /// Card / payment-method label for matching and display.
    var paymentMethod: String
    /// Principal (or purchase amount) when the plan started.
    var originalAmount: Double
    /// What is still owed on this plan (user-updated; Record payment subtracts the monthly payment).
    var remainingAmount: Double
    /// Principal portion due each month.
    var monthlyPayment: Double
    /// Extra monthly plan fee (Pay Over Time). Does not reduce remaining.
    var monthlyFee: Double?
    /// APR percent (My Loan / promo). 0 means 0%.
    var aprPercent: Double?
    /// First installment date (calendar day-of-month is reused each month).
    var startDate: Date
    /// Promo end or last scheduled payment, when known.
    var endDate: Date?
    /// Original term in months, when known.
    var termMonths: Int?
    /// Original purchase (Pay Over Time) or the card disbursement (My Loan).
    var linkedTransactionId: String?
    var notes: String?
    var isEnded: Bool
    /// Last statement close we already subtracted a monthly payment for (issuer plans).
    var lastAppliedStatementDate: Date?
    var createdAt: Date
    var updatedAt: Date

    var kind: PayoffPlanKind {
        get { PayoffPlanKind(rawValue: kindRaw) ?? .custom }
        set { kindRaw = newValue.rawValue }
    }

    /// Still being paid down.
    var isActive: Bool {
        !isEnded && remainingAmount > 0.005
    }

    /// What hits the card bill each month (payment + optional fee).
    var installmentTotal: Double {
        monthlyPayment + (monthlyFee ?? 0)
    }

    init(
        planId: String = UUID().uuidString,
        kind: PayoffPlanKind,
        name: String,
        accountId: String? = nil,
        paymentMethod: String,
        originalAmount: Double,
        remainingAmount: Double,
        monthlyPayment: Double,
        monthlyFee: Double? = nil,
        aprPercent: Double? = nil,
        startDate: Date = Date(),
        endDate: Date? = nil,
        termMonths: Int? = nil,
        linkedTransactionId: String? = nil,
        notes: String? = nil,
        isEnded: Bool = false,
        lastAppliedStatementDate: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.planId = planId
        self.kindRaw = kind.rawValue
        self.name = name
        self.accountId = accountId
        self.paymentMethod = paymentMethod
        self.originalAmount = originalAmount
        self.remainingAmount = remainingAmount
        self.monthlyPayment = monthlyPayment
        self.monthlyFee = monthlyFee
        self.aprPercent = aprPercent
        self.startDate = startDate
        self.endDate = endDate
        self.termMonths = termMonths
        self.linkedTransactionId = linkedTransactionId
        self.notes = notes
        self.isEnded = isEnded
        self.lastAppliedStatementDate = lastAppliedStatementDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func isOn(account: BankAccount) -> Bool {
        if let id = accountId, id == account.accountId { return true }
        return account.matchesPaymentMethod(paymentMethod)
    }

    /// Subtract monthly payments for statement closes after `lastAppliedStatementDate`.
    /// First time we see a statement we only stamp the date — remaining is the current balance.
    func applyStatementProgress(lastStatement: Date?, now: Date = Date()) {
        guard kind.followsCardStatement, isActive, let lastStatement else { return }
        let cal = Calendar.current
        let stmt = cal.startOfDay(for: lastStatement)
        if let applied = lastAppliedStatementDate {
            let appliedDay = cal.startOfDay(for: applied)
            guard stmt > appliedDay else { return }
            let months = max(1, cal.dateComponents([.month], from: appliedDay, to: stmt).month ?? 1)
            for _ in 0..<months {
                recordPayment()
                if !isActive { break }
            }
        }
        lastAppliedStatementDate = stmt
        updatedAt = now
    }

    /// Next amount due. Loans / installments use the card’s statement due date when known.
    func nextPaymentDate(cardDueDate: Date? = nil, from now: Date = Date()) -> Date? {
        guard isActive else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        if kind.followsCardStatement {
            guard let due = cardDueDate.map({ cal.startOfDay(for: $0) }) else {
                return nextMonthly(from: startDate, after: today, calendar: cal)
            }
            if due >= today { return due }
            return cal.date(byAdding: .month, value: 1, to: due)
        }
        let next = nextMonthly(from: startDate, after: today, calendar: cal)
        if let end = endDate, let next, next > cal.startOfDay(for: end) { return nil }
        return next
    }

    private func nextMonthly(from start: Date, after today: Date, calendar: Calendar) -> Date? {
        var cursor = calendar.startOfDay(for: start)
        if cursor >= today { return cursor }
        var hops = 0
        while cursor < today, hops < 360 {
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { return nil }
            cursor = next
            hops += 1
        }
        return cursor
    }

    /// Whole months of `monthlyPayment` still needed (ignores fee).
    var monthsToPayOff: Int {
        guard monthlyPayment > 0, remainingAmount > 0 else { return 0 }
        return Int(ceil(remainingAmount / monthlyPayment))
    }

    func projectedPayoffDate(from now: Date = Date()) -> Date? {
        let months = monthsToPayOff
        guard months > 0 else { return now }
        return Calendar.current.date(byAdding: .month, value: months, to: now)
    }

    /// Months from `now` until `endDate`, at least 1 when the end is still in the future.
    func monthsUntilEnd(from now: Date = Date()) -> Int? {
        guard let end = endDate else { return nil }
        let cal = Calendar.current
        let months = cal.dateComponents(
            [.month],
            from: cal.startOfDay(for: now),
            to: cal.startOfDay(for: end)
        ).month ?? 0
        if end < now { return 0 }
        return max(1, months)
    }

    /// Equal monthly principal to clear `remainingAmount` by `endDate`.
    func suggestedMonthlyPayment(from now: Date = Date()) -> Double? {
        guard let months = monthsUntilEnd(from: now), months > 0, remainingAmount > 0 else {
            return nil
        }
        return remainingAmount / Double(months)
    }

    /// True when a promo/end date exists and the current payment would miss it.
    func missesEndDate(from now: Date = Date()) -> Bool {
        guard let end = endDate, let projected = projectedPayoffDate(from: now) else {
            return false
        }
        return Calendar.current.startOfDay(for: projected) > Calendar.current.startOfDay(for: end)
    }

    /// Subtract one monthly principal payment. Marks ended at ~zero.
    func recordPayment() {
        remainingAmount = max(0, remainingAmount - monthlyPayment)
        if remainingAmount <= 0.005 {
            remainingAmount = 0
            isEnded = true
        }
        updatedAt = Date()
    }

    func markPaidOff() {
        remainingAmount = 0
        isEnded = true
        updatedAt = Date()
    }
}

enum PayoffPlanProgress {
    @MainActor
    static func applyStatementProgress(plans: [PayoffPlan], accounts: [BankAccount]) {
        for plan in plans where plan.isActive && plan.kind.followsCardStatement {
            let account = accounts.first { plan.isOn(account: $0) }
            plan.applyStatementProgress(lastStatement: account?.lastStatementIssueDate)
        }
    }

    static func installmentIncludedInMin(on account: BankAccount, plans: [PayoffPlan]) -> Double {
        plans
            .filter { $0.isActive && $0.kind.followsCardStatement && $0.isOn(account: account) }
            .reduce(0) { $0 + $1.installmentTotal }
    }

    static func extraPrincipalThisStatement(on account: BankAccount, plans: [PayoffPlan]) -> Double {
        plans
            .filter { $0.isActive && !$0.kind.followsCardStatement && $0.isOn(account: account) }
            .reduce(0) { $0 + $1.monthlyPayment }
    }
}
