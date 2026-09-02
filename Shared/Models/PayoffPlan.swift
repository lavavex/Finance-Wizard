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
        // FIX: "my loan" does not match Chase's real descriptor, "MY CHASE LOAN …" — the
        // product only got recognised when the row happened to also match the
        // "loan to <digits>" regex below. Match the branded names directly.
        // OLD: if t.contains("my loan") { return true }
        if t.contains("my loan") || t.contains("my chase loan") || t.contains("chase loan") {
            return true
        }
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
        // FIX: the enum documents this as covering "Chase Pay Over Time, Amex Plan It" but
        // neither issuer's actual descriptor was matched. Amex bills these as "Plan It" /
        // "PLAN IT FEE"; Chase's instalment product is "My Chase Plan". (Note "Pay Over
        // Time" is Amex's revolving feature, not Chase's — kept for existing rows.)
        // OLD:
        // if t.contains("pay over time") { return true }
        // if t.contains("installment") { return true }
        if t.contains("pay over time") { return true }
        if t.contains("plan it") || t.contains("planit") { return true }
        if t.contains("my chase plan") || t.contains("chase plan") { return true }
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
    /// FIX: this was documented as "Principal portion due each month", which contradicted
    /// both the editor ("Monthly payment is what hits the statement") and the math —
    /// recordPayment() subtracts interest from it before reducing the balance.
    /// The full amount billed each statement, interest / plan fee included.
    /// OLD: /// Principal portion due each month.
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

    /// Amount added to the card minimum each statement (what the issuer bills).
    var installmentTotal: Double {
        monthlyPayment
    }

    /// Principal this statement if remaining is split evenly over remaining months.
    var evenPrincipalThisMonth: Double? {
        PayoffPlanMath.evenPrincipal(remaining: remainingAmount, months: termMonths)
    }

    /// Pay Over Time: payment minus even principal. My Loan: remaining × APR / 12.
    var impliedMonthlyFee: Double? {
        if kind == .myLoan {
            return PayoffPlanMath.amortizingInterest(
                remaining: remainingAmount,
                aprPercent: aprPercent
            )
        }
        return PayoffPlanMath.impliedFee(
            payment: monthlyPayment,
            remaining: remainingAmount,
            months: termMonths
        )
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
            // FIX: adding a single month to a due date that is several months stale (a
            // Plaid item that stopped refreshing liabilities) still returned a past date,
            // so the plan showed as "due" on a day that has already gone. Roll forward
            // month by month until the date is actually in the future.
            // OLD: return cal.date(byAdding: .month, value: 1, to: due)
            return nextMonthly(from: due, after: today, calendar: cal)
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

    /// FIX: this divided remaining by payment and ignored interest, while recordPayment()
    /// correctly takes interest out of the payment first. A My Chase Loan or a non-zero
    /// promo APR therefore reported a payoff date earlier than it could ever happen, and
    /// missesEndDate() under-fired. Now amortised at the plan's APR (0% behaves as before).
    /// Whole months of `monthlyPayment` still needed. nil = the payment never clears the
    /// balance because it does not cover the monthly interest.
    /// OLD:
    /// var monthsToPayOff: Int {
    ///     guard monthlyPayment > 0, remainingAmount > 0 else { return 0 }
    ///     return Int(ceil(remainingAmount / monthlyPayment))
    /// }
    var monthsToPayOff: Int? {
        // FIX: for an issuer-scheduled plan the term is a contractual fact from the loan
        // email ("12 billing cycles"), not something to infer. Re-deriving it from payment
        // and APR came out one month long on the real $4,000 / 9.49% / $350.39 loan, because
        // Chase bills interest on a daily periodic rate rather than APR ÷ 12. Trust the term.
        if kind.followsCardStatement, let months = termMonths, months > 0 {
            return months
        }
        return PayoffPlanMath.monthsToPayOff(
            remaining: remainingAmount,
            payment: monthlyPayment,
            aprPercent: aprPercent
        )
    }

    func projectedPayoffDate(from now: Date = Date()) -> Date? {
        guard let months = monthsToPayOff else { return nil }
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

    /// True when a promo/end date exists and the current payment would miss it.
    func missesEndDate(from now: Date = Date()) -> Bool {
        guard let end = endDate else { return false }
        // FIX: a payment too small to cover the interest now yields a nil projection.
        // That is the worst case, not "no problem", so it must report as missing the date.
        guard let projected = projectedPayoffDate(from: now) else { return true }
        return Calendar.current.startOfDay(for: projected) > Calendar.current.startOfDay(for: end)
    }

    /// Subtract one month of principal. Fee / interest is not principal.
    func recordPayment() {
        let principal: Double
        if kind == .myLoan,
           let interest = PayoffPlanMath.amortizingInterest(
                remaining: remainingAmount,
                aprPercent: aprPercent
           ) {
            principal = max(0, monthlyPayment - interest)
        } else if let even = evenPrincipalThisMonth {
            principal = even
        } else {
            principal = monthlyPayment
        }
        remainingAmount = max(0, remainingAmount - principal)
        if let months = termMonths, months > 0 {
            termMonths = months - 1
        }
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

    /// Chase “Interest saving balance”: all non-loan balances + this statement’s
    /// loan/installment payments (not leftover loan principal). Paying this each
    /// cycle avoids purchase interest and keeps My Loan on its billing-cycle schedule.
    static func interestSavingBalance(on account: BankAccount, plans: [PayoffPlan]) -> Double {
        let issuer = plans.filter {
            $0.isActive && $0.kind.followsCardStatement && $0.isOn(account: account)
        }
        let leftoverFinancing = issuer.reduce(0) { $0 + $1.remainingAmount }
        let dueThisStatement = issuer.reduce(0) { $0 + $1.installmentTotal }
        let otherBalances = max(0, account.currentBalance - leftoverFinancing)
        return otherBalances + dueThisStatement
    }
}

/// Split a level statement payment into principal vs fee/interest.
enum PayoffPlanMath {
    static func evenPrincipal(remaining: Double, months: Int?) -> Double? {
        guard let months, months > 0, remaining > 0 else { return nil }
        return remaining / Double(months)
    }

    static func impliedFee(payment: Double, remaining: Double, months: Int?) -> Double? {
        guard let principal = evenPrincipal(remaining: remaining, months: months) else { return nil }
        return payment - principal
    }

    /// Level-payment APR (percent) from remaining, months, and the statement payment.
    /// Interest this statement for a fixed-APR loan: remaining × APR / 12.
    static func amortizingInterest(remaining: Double, aprPercent: Double?) -> Double? {
        guard let aprPercent, remaining > 0 else { return nil }
        return remaining * (aprPercent / 100.0) / 12.0
    }

    /// FIX: added so payoff projections stop ignoring interest (see PayoffPlan.monthsToPayOff).
    /// Whole months to clear `remaining` paying `payment` per month at `aprPercent`.
    /// nil when the payment never covers the monthly interest, so the balance never clears.
    static func monthsToPayOff(remaining: Double, payment: Double, aprPercent: Double?) -> Int? {
        guard remaining > 0.005 else { return 0 }
        guard payment > 0 else { return nil }
        let monthlyRate = max(0, (aprPercent ?? 0) / 100.0 / 12.0)
        if monthlyRate <= 0 {
            return Int(ceil(remaining / payment - 1e-9))
        }
        // A payment at or below one month's interest leaves the balance flat or growing.
        guard payment > remaining * monthlyRate + 0.005 else { return nil }
        let months = -log(1 - monthlyRate * remaining / payment) / log(1 + monthlyRate)
        guard months.isFinite, months > 0 else { return nil }
        return Int(ceil(months - 1e-9))
    }

    /// Level monthly payment that clears `remaining` in `months` at `aprPercent`.
    /// At 0% this is just remaining ÷ months.
    static func levelPayment(remaining: Double, months: Int, aprPercent: Double?) -> Double? {
        guard months > 0, remaining > 0 else { return nil }
        let n = Double(months)
        let monthlyRate = max(0, (aprPercent ?? 0) / 100.0 / 12.0)
        if monthlyRate <= 0 { return remaining / n }
        let growth = pow(1 + monthlyRate, n)
        guard growth.isFinite, growth > 1 else { return remaining / n }
        return remaining * monthlyRate * growth / (growth - 1)
    }

    static func impliedAPR(payment: Double, remaining: Double, months: Int?) -> Double? {
        guard let months, months > 0, remaining > 0, payment > 0 else { return nil }
        let n = Double(months)
        let total = payment * n
        if total < remaining - 0.05 { return nil }
        if abs(total - remaining) < 0.05 { return 0 }
        var r = 0.01
        for _ in 0..<60 {
            let one = 1 + r
            guard one > 0 else { return nil }
            let powN = pow(one, n)
            let denom = powN - 1
            guard abs(denom) > 1e-16 else { break }
            let f = remaining * r * powN / denom - payment
            let dPow = n * pow(one, n - 1)
            let dfNum = (powN + r * dPow) * denom - r * powN * dPow
            let df = remaining * dfNum / (denom * denom)
            guard abs(df) > 1e-16 else { break }
            let next = r - f / df
            if abs(next - r) < 1e-12 {
                r = next
                break
            }
            r = next
            if r <= -0.99 { r = 1e-8 }
        }
        if r < -1e-6 { return nil }
        return max(0, r * 12 * 100)
    }
}
