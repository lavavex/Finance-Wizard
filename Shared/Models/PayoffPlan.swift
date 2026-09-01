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

    var shortHelp: String {
        switch self {
        case .myLoan:
            return "A lump sum from a card’s credit line (Chase My Loan). Pick the card charge (for example “My Chase Loan TO 2667”), then the fixed payment, APR, and term. Not the same as Pay Over Time."
        case .payOverTime:
            return "A purchase split into monthly installments (Chase Pay Over Time, Amex Plan It). Monthly payment plus an optional plan fee. Not the same as My Loan."
        case .promoAPR:
            return "A slice of the card balance at 0% or special APR until a date. Set a monthly payment to clear it before the promo ends."
        case .custom:
            return "Any other card balance you want to pay down on a monthly schedule."
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Next installment on or after today. Nil when the plan is done or past `endDate`.
    func nextPaymentDate(from now: Date = Date()) -> Date? {
        guard isActive else { return nil }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var cursor = cal.startOfDay(for: startDate)
        if cursor > today {
            if let end = endDate, cursor > cal.startOfDay(for: end) { return nil }
            return cursor
        }
        var hops = 0
        while cursor <= today, hops < 360 {
            guard let next = cal.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
            hops += 1
        }
        if let end = endDate, cursor > cal.startOfDay(for: end) { return nil }
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
