//
//  PlaidCategoryMapper.swift
//  Finance Wizard
//
//  Map Plaid personal_finance_category → app labels + cash-flow classification.
//  Transfers & credit-card payments must never inflate Total Spend / Income.
//
//  Plaid signs amounts as: positive = money out (spend), negative = money in.
//  personal_finance_category (PFC) has primary + detailed strings like FOOD_AND_DRINK.
//

import Foundation

// MARK: - Cash-flow kind

/// How a Plaid row should land in the app.
enum PlaidFlowKind: String, Sendable {
    /// Real expense → Transaction (stored negative in the app’s local model)
    case spending
    /// Real income → Income model
    case income
    /// Savings / internal account moves — skip spend & income
    case transfer
    /// Paying a credit card bill — track for payoff UI, not spend/income
    case creditPayment
    /// Card refund / statement credit / loan proceeds — visible, not spend, not income
    case adjustment
}

// MARK: - Mapper

/// Stateless helpers that classify Plaid rows and map them to app category names.
enum PlaidCategoryMapper {
    // MARK: - Classification

    /// Classify a Plaid transaction for storage / analytics.
    /// Priority order: credit-card payment → transfer → spend vs income by amount sign.
    /// - Parameters:
    ///   - amount: Plaid amount (+ outflow, − inflow).
    ///   - pfc: Plaid personal_finance_category (primary + detailed), if present.
    ///   - title: Merchant / description string for heuristics when PFC is weak.
    ///   - accountType: Plaid account `type` (credit, depository, …)
    ///   - accountSubtype: e.g. credit card, checking, savings
    static func classify(
        amount: Double,
        pfc: PlaidPFC?,
        title: String,
        accountType: String?,
        accountSubtype: String?
    ) -> PlaidFlowKind {
        let primary = (pfc?.primary ?? "").uppercased()
        let detailed = (pfc?.detailed ?? "").uppercased()
        let lower = title.lowercased()
        let type = (accountType ?? "").lowercased()
        let subtype = (accountSubtype ?? "").lowercased()

        // Card-line loan: charge on the card is Loan; deposit to checking is not earnings.
        if PayoffPlanRecognition.looksLikeLoanDisbursement(title: title, pfc: detailed) {
            if type == "credit", amount >= 0 { return .spending }
            if amount < 0 { return .adjustment }
        }

        // Must run before transfer/income: on credit accounts payments are amount < 0
        // and otherwise become "Other Income".
        if isCreditCardPayment(primary: primary, detailed: detailed, titleLower: lower, accountType: type, amount: amount) {
            return .creditPayment
        }

        // Card-side money-in that is not a bill pay: refunds and issuer credits.
        if type == "credit", amount < 0 {
            return .adjustment
        }

        // Do not treat credit-account money-in as a generic transfer (bill pays often
        // land as TRANSFER_IN without a strong title).
        if isTransfer(primary: primary, detailed: detailed, titleLower: lower, accountSubtype: subtype),
           !(type == "credit" && amount < 0) {
            return .transfer
        }

        // Real money out / in (Plaid: +outflow, −inflow)
        return amount >= 0 ? .spending : .income
    }

    /// Payment toward a credit card (checking ACH out, or “Payment Thank You” on the card).
    ///
    /// On credit accounts Plaid uses **negative amount** for *any* money-in
    /// (bill payments **and** refunds / statement credits / cash-back). Never treat
    /// “credit + amount < 0” alone as a bill payment — that mis-filed merchants like
    /// Best Buy returns and StubHub credits as Credit Card Payment.
    private static func isCreditCardPayment(
        primary: String,
        detailed: String,
        titleLower: String,
        accountType: String,
        amount: Double
    ) -> Bool {
        let onCredit = accountType == "credit"

        if PayoffPlanRecognition.looksLikeLoanDisbursement(title: titleLower) {
            return false
        }

        if detailed.contains("CREDIT_CARD_PAYMENT") {
            // On the card, money *out* is a purchase — PFC CREDIT_CARD_PAYMENT is not enough.
            if onCredit && amount > 0 { return false }
            return true
        }
        // Loan payments only when clearly a revolving card (not mortgage / auto)
        if primary == "LOAN_PAYMENTS"
            && (detailed.contains("CREDIT_CARD") || detailed.contains("CREDIT_CARD_PAYMENT")) {
            if onCredit && amount > 0 { return false }
            return true
        }
        if primary == "LOAN_PAYMENTS" && (looksLikeCardPaymentTitle(titleLower) || onCredit) {
            // On the card itself, money-in LOAN_PAYMENTS is a bill payment; money-out is not.
            if onCredit && amount > 0 { return false }
            return true
        }
        if (primary == "TRANSFER_OUT" || primary == "TRANSFER_IN")
            && detailed.contains("CREDIT_CARD") {
            return true
        }

        if looksLikeCardPaymentTitle(titleLower) {
            return true
        }

        // Credit-account money-in with payment-ish PFC / wording.
        // Avoid treating merchant refunds (Best Buy, StubHub credit) as bill pays.
        if onCredit && amount < 0 {
            if primary == "TRANSFER_IN" || primary == "TRANSFER_OUT" {
                return !looksLikeMerchantRefundTitle(titleLower)
            }
            if detailed.contains("PAYMENT") && !detailed.contains("INTEREST") {
                return !looksLikeMerchantRefundTitle(titleLower)
            }
            if looksLikeSoftCreditPaymentTitle(titleLower) {
                return true
            }
        }

        // Checking/depository outflow that is clearly a card bill pay (ACH to issuer).
        if !onCredit && amount > 0 && looksLikeIssuerBillPayTitle(titleLower) {
            return true
        }

        return false
    }

    /// Public wrapper for legacy cleanup / UI.
    static func looksLikeCardPaymentTitlePublic(_ lower: String) -> Bool {
        looksLikeCardPaymentTitle(lower)
    }

    /// Strong title heuristics that usually mean “this is a card bill payment.”
    private static func looksLikeCardPaymentTitle(_ lower: String) -> Bool {
        if looksLikeMerchantRefundTitle(lower) { return false }
        if PayoffPlanRecognition.looksLikeLoanDisbursement(title: lower) { return false }

        if lower.contains("payment thank you") { return true }
        if lower.contains("thank you") && (lower.contains("payment") || lower.contains("pymt")
            || lower.contains("web") || lower.contains("mobile") || lower.contains("online")) {
            return true
        }
        if lower.contains("mobile payment") && lower.contains("thank you") { return true }
        if lower.contains("thank you - web") || lower.contains("thank you-web")
            || lower.contains("thank you-mobile") || lower.contains("thank you - mobile")
            || lower.contains("thankyou") {
            return true
        }
        if lower.contains("autopay") {
            return true
        }
        if lower.contains("automatic payment") { return true }
        if lower.contains("credit card payment") || lower.contains("creditcard payment") { return true }
        if lower.contains("card payment") { return true }
        if lower.contains("payment to credit") { return true }
        if lower.contains("online payment from chk") { return true }
        if lower.contains("online payment") && (lower.contains("thank") || lower.contains("card")) {
            return true
        }
        if lower.contains("ach pmt") || lower.contains("ach payment") || lower.contains("ach pymt") {
            return true
        }
        if lower.contains("payment received") || lower.contains("pymt received")
            || lower.contains("payment - thank") || lower.contains("payment-thank") {
            return true
        }
        // "Payment to Chase card ending in 1234" / "Payment to Amex"
        if lower.hasPrefix("payment to ") && (lower.contains("card") || lower.contains("amex")
            || lower.contains("chase") || lower.contains("citi") || lower.contains("capital one")
            || lower.contains("discover") || lower.contains("apple card")
            || lower.contains("american express")) {
            return true
        }
        // "Chase Credit Crd Autopay"
        if lower.contains("crd") && (lower.contains("autopay") || lower.contains("payment") || lower.contains("pmt")) {
            return true
        }
        if lower.contains("epayment") || lower.contains("e-payment") {
            return true
        }
        // X Money / fintech ACH bill-pay codes (e.g. EPAY → Chase card)
        if lower == "epay" || lower == "e-pay" || lower.hasPrefix("epay ")
            || lower.hasPrefix("e-pay ") || lower == "epmt" || lower == "e pmt" {
            return true
        }
        if lower == "apple card" || lower.hasPrefix("apple card payment") {
            return true
        }
        if lower.contains("american express") && (lower.contains("ach") || lower.contains("pmt")
            || lower.contains("payment") || lower.contains("epay")) {
            return true
        }
        if looksLikeIssuerBillPayTitle(lower) {
            return true
        }
        return false
    }

    /// Softer match for money-in on the **credit account** only.
    /// Used when we already know account type is credit and amount is negative.
    private static func looksLikeSoftCreditPaymentTitle(_ lower: String) -> Bool {
        if looksLikeMerchantRefundTitle(lower) { return false }
        if lower.contains("payment") || lower.contains("pymt") || lower.contains("pmt") {
            return true
        }
        if lower.contains("thank you") || lower.contains("thankyou") { return true }
        if lower.contains("autopay") || lower.contains("auto pay") { return true }
        if lower.contains("online") && lower.contains("pay") { return true }
        return false
    }

    /// Checking-side ACH to known card issuers.
    private static func looksLikeIssuerBillPayTitle(_ lower: String) -> Bool {
        let issuers = [
            "american express", "amex", "chase card", "chase credit", "chase sapphire",
            "chase freedom", "citi card", "citi credit", "capital one", "discover card",
            "apple card", "bank of america card", "wells fargo card", "us bank card",
            "barclays", "synchrony"
        ]
        let looksPay = lower.contains("payment") || lower.contains("pmt") || lower.contains("pymt")
            || lower.contains("autopay") || lower.contains("ach") || lower.contains("epay")
            || lower.hasPrefix("payment to")
        guard looksPay else { return false }
        return issuers.contains { lower.contains($0) }
    }

    /// Merchant refunds / statement credits that must not be treated as bill payments.
    private static func looksLikeMerchantRefundTitle(_ lower: String) -> Bool {
        if lower.contains("statement credit") || lower.contains("store credit") { return true }
        if lower.contains("cash reward") || lower.contains("your cash reward") { return true }
        if lower.contains("annual fee refund") || lower.contains("fee refund") { return true }
        if lower.hasPrefix("offer:") { return true }
        if lower.contains("refund") || lower.contains("return") || lower.contains("reversal") {
            return true
        }
        if lower.contains("cashback") || lower.contains("cash back") { return true }
        // Issuer credits (“TRAVEL CREDIT $300/YEAR”) — not the words “credit card”.
        if lower.contains("credit"), !lower.contains("credit card"), !lower.contains("creditcard") {
            if lower.contains("$") || lower.contains("/year") || lower.contains("annual") {
                return true
            }
        }
        return false
    }

    /// True when the row looks like moving money between the user’s own accounts.
    private static func isTransfer(
        primary: String,
        detailed: String,
        titleLower: String,
        accountSubtype: String
    ) -> Bool {
        if primary == "TRANSFER_IN" || primary == "TRANSFER_OUT" {
            return true
        }
        if detailed.contains("ACCOUNT_TRANSFER")
            || detailed.contains("INTERNAL_ACCOUNT_TRANSFER")
            || detailed.contains("SAVINGS") && detailed.contains("TRANSFER") {
            return true
        }

        if titleLower.contains("transfer to") || titleLower.contains("transfer from") {
            return true
        }
        if titleLower.contains("xfer") || titleLower.contains("xfr ") {
            return true
        }
        if titleLower.contains("online transfer") || titleLower.contains("mobile transfer") {
            return true
        }
        if titleLower.contains("internal transfer") {
            return true
        }
        if titleLower.contains("to savings") || titleLower.contains("from savings")
            || titleLower.contains("to checking") || titleLower.contains("from checking") {
            return true
        }
        if titleLower.contains("savings transfer") || titleLower.contains("transfer savings") {
            return true
        }
        // Keep real purchases like "TransferWise" / "Transfer Fee" out of false positives
        // by requiring transfer-like structure when only the word "transfer" appears alone.
        if titleLower == "transfer" || titleLower.hasPrefix("transfer ") {
            return true
        }

        // Intentionally unused (kept for future subtype-based rules).
        _ = accountSubtype
        return false
    }

    // MARK: - Display categories

    /// Human-readable expense category from PFC primary/detailed.
    /// Always returns a `KnownCategory` spend name (or Credit Card Payment).
    /// Detailed strings are checked first (more specific), then primary buckets.
    static func expenseCategory(from pfc: PlaidPFC?, title: String = "") -> String {
        if PayoffPlanRecognition.looksLikeLoanDisbursement(title: title) {
            return KnownCategory.loan.rawValue
        }
        if PayoffPlanRecognition.looksLikeInstallmentBillingTitle(title) {
            return KnownCategory.installment.rawValue
        }
        let primary = (pfc?.primary ?? "").uppercased()
        let detailed = (pfc?.detailed ?? "").uppercased()

        if detailed.contains("GAS_STATION") || detailed.contains("GAS_")
            || (detailed.contains("FUEL") && !detailed.contains("REFUEL")) {
            return KnownCategory.gas.rawValue
        }
        if detailed.contains("EV_CHARGING") || detailed.contains("ELECTRIC_VEHICLE") {
            return KnownCategory.gas.rawValue
        }
        if detailed.contains("GROCER") {
            return KnownCategory.groceries.rawValue
        }
        if detailed.contains("COFFEE") || detailed.contains("RESTAURANT")
            || detailed.contains("FAST_FOOD") || detailed.contains("FOOD_DELIVERY") {
            return KnownCategory.dining.rawValue
        }
        if detailed.contains("STREAMING") || detailed.contains("SUBSCRIPTION")
            || detailed.contains("DIGITAL_PURCHASE") && detailed.contains("ENTERTAINMENT") {
            return KnownCategory.subscriptions.rawValue
        }
        if detailed.contains("INTERNET") || detailed.contains("CABLE")
            || detailed.contains("TELECOM") || detailed.contains("PHONE") {
            return KnownCategory.homeInternet.rawValue
        }
        if detailed.contains("RENT") || detailed.contains("MORTGAGE") {
            return KnownCategory.housing.rawValue
        }
        if detailed.contains("UTILITIES") || detailed.contains("ELECTRIC")
            || detailed.contains("WATER") || detailed.contains("SEWAGE")
            || detailed.contains("GARBAGE") {
            return KnownCategory.utilities.rawValue
        }
        if detailed.contains("INSURANCE") {
            return KnownCategory.carInsurance.rawValue
        }
        if detailed.contains("PHARMACY") || detailed.contains("DENTAL")
            || detailed.contains("VISION") || detailed.contains("HOSPITAL")
            || detailed.contains("PHYSICIAN") || detailed.contains("PRIMARY_CARE") {
            return KnownCategory.health.rawValue
        }
        if detailed.contains("GYM") || detailed.contains("FITNESS")
            || detailed.contains("HAIR") || detailed.contains("SPA") {
            return KnownCategory.personalCare.rawValue
        }
        if detailed.contains("PET") || detailed.contains("VETERINAR") {
            return KnownCategory.pets.rawValue
        }
        if detailed.contains("EDUCATION") || detailed.contains("TUITION")
            || detailed.contains("STUDENT") && detailed.contains("LOAN") == false {
            return KnownCategory.education.rawValue
        }
        if detailed.contains("DONATION") || detailed.contains("CHARIT")
            || detailed.contains("GIFT") && !detailed.contains("CARD") {
            return KnownCategory.giftsDonations.rawValue
        }
        if detailed.contains("PARKING") || detailed.contains("TOLLS")
            || detailed.contains("PUBLIC_TRANSIT") || detailed.contains("TAXI")
            || detailed.contains("RIDESHARE") || detailed.contains("RIDE_SHARE") {
            return KnownCategory.transit.rawValue
        }
        if detailed.contains("AIRLINE") || detailed.contains("LODGING")
            || detailed.contains("HOTEL") || detailed.contains("CAR_RENTAL") {
            return KnownCategory.travel.rawValue
        }
        if detailed.contains("ENTERTAINMENT") || detailed.contains("MUSIC")
            || detailed.contains("MOVIE") || detailed.contains("VIDEO_GAMES")
            || detailed.contains("SPORTING") {
            return KnownCategory.entertainment.rawValue
        }
        if detailed.contains("BANK_FEE") || detailed.contains("ATM")
            || detailed.contains("OVERDRAFT") || detailed.contains("LATE_FEE") {
            return KnownCategory.fees.rawValue
        }

        switch primary {
        case "FOOD_AND_DRINK":
            return KnownCategory.dining.rawValue
        case "GENERAL_MERCHANDISE":
            return KnownCategory.shopping.rawValue
        case "GENERAL_SERVICES":
            // Services often = subscriptions / home services — shopping is a safer budget bucket
            // than inventing a free-form label.
            return KnownCategory.shopping.rawValue
        case "TRANSPORTATION":
            // Gas already handled above; remaining transit-like spend.
            return KnownCategory.transit.rawValue
        case "TRAVEL":
            return KnownCategory.travel.rawValue
        case "ENTERTAINMENT":
            return KnownCategory.entertainment.rawValue
        case "PERSONAL_CARE":
            return KnownCategory.personalCare.rawValue
        case "MEDICAL", "HEALTHCARE":
            return KnownCategory.health.rawValue
        case "RENT_AND_UTILITIES":
            return KnownCategory.utilities.rawValue
        case "LOAN_PAYMENTS":
            if detailed.contains("CREDIT_CARD") {
                return TransactionAnalytics.creditCardPaymentCategory
            }
            if detailed.contains("MORTGAGE") || detailed.contains("HOME") {
                return KnownCategory.housing.rawValue
            }
            if detailed.contains("STUDENT") {
                return KnownCategory.education.rawValue
            }
            return TitleCategoryHints.refine(category: KnownCategory.miscellaneous.rawValue, title: title)
        case "BANK_FEES":
            return KnownCategory.fees.rawValue
        case "GOVERNMENT_AND_NON_PROFIT":
            if detailed.contains("DONATION") || detailed.contains("CHARIT") {
                return KnownCategory.giftsDonations.rawValue
            }
            return TitleCategoryHints.refine(category: KnownCategory.miscellaneous.rawValue, title: title)
        default:
            // Never invent free-form titles like "Income" / "Transfer Out" — stay in KnownCategory.
            return TitleCategoryHints.refine(category: KnownCategory.miscellaneous.rawValue, title: title)
        }
    }

    /// Income category label for money-in rows.
    static func incomeCategory(from pfc: PlaidPFC?, name: String) -> String {
        let primary = (pfc?.primary ?? "").uppercased()
        let detailed = (pfc?.detailed ?? "").uppercased()
        let lower = name.lowercased()

        if detailed.contains("INTEREST") || lower.contains("interest") {
            return "Interest"
        }
        if detailed.contains("REFUND") || primary.contains("REFUND") || lower.contains("refund") {
            return "Refund"
        }
        if detailed.contains("PAYROLL") || detailed.contains("SALARY")
            || lower.contains("payroll") || lower.contains("direct dep") {
            return "Payroll"
        }
        if lower.contains("direct deposit") || detailed.contains("DIRECT_DEPOSIT") {
            return "Direct Deposit"
        }
        return "Other Income"
    }

    /// Whether an *already stored* expense/income title looks like a transfer or card payment
    /// (used to clean up rows that were imported before better filtering).
    static func looksLikeNonSpendTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        if looksLikeCardPaymentTitle(lower) { return true }
        if isTransfer(primary: "", detailed: "", titleLower: lower, accountSubtype: "") {
            return true
        }
        return false
    }
}
