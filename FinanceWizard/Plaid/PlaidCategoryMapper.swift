//
//  PlaidCategoryMapper.swift
//  Finance Wizard
//
//  Map Plaid personal_finance_category → app labels + cash-flow classification.
//  Transfers & credit-card payments must never inflate Total Spend / Income.
//

import Foundation

/// How a Plaid row should land in the app.
enum PlaidFlowKind: String, Sendable {
    /// Real expense → Transaction (stored negative)
    case spending
    /// Real income → Income model
    case income
    /// Savings / internal account moves — skip spend & income
    case transfer
    /// Paying a credit card bill — track for payoff UI, not spend/income
    case creditPayment
}

enum PlaidCategoryMapper {
    // MARK: - Classification

    /// Classify a Plaid transaction for storage / analytics.
    /// - Parameters:
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

        // --- Credit-card payments (highest priority among non-spend) ---
        if isCreditCardPayment(primary: primary, detailed: detailed, titleLower: lower, accountType: type, amount: amount) {
            return .creditPayment
        }

        // --- Internal / savings transfers ---
        if isTransfer(primary: primary, detailed: detailed, titleLower: lower, accountSubtype: subtype) {
            return .transfer
        }

        // Real money out / in
        return amount >= 0 ? .spending : .income
    }

    /// Payment toward a credit card (checking ACH out, or negative amount on the card itself).
    private static func isCreditCardPayment(
        primary: String,
        detailed: String,
        titleLower: String,
        accountType: String,
        amount: Double
    ) -> Bool {
        // Payment applied *on the credit account* (Plaid: money in = negative)
        if accountType == "credit" && amount < 0 {
            return true
        }

        if detailed.contains("CREDIT_CARD_PAYMENT") {
            return true
        }
        // Loan payments only when clearly a revolving card (not mortgage / auto)
        if primary == "LOAN_PAYMENTS"
            && (detailed.contains("CREDIT_CARD") || detailed.contains("CREDIT_CARD_PAYMENT")) {
            return true
        }
        if primary == "LOAN_PAYMENTS" && looksLikeCardPaymentTitle(titleLower) {
            return true
        }
        if (primary == "TRANSFER_OUT" || primary == "TRANSFER_IN")
            && (detailed.contains("CREDIT_CARD") || detailed.contains("LOAN")) {
            return true
        }

        if looksLikeCardPaymentTitle(titleLower) {
            return true
        }
        return false
    }

    /// Public wrapper for legacy cleanup / UI.
    static func looksLikeCardPaymentTitlePublic(_ lower: String) -> Bool {
        looksLikeCardPaymentTitle(lower)
    }

    private static func looksLikeCardPaymentTitle(_ lower: String) -> Bool {
        // Explicit bank strings
        if lower.contains("payment thank you") { return true }
        if lower.contains("thank you - web") || lower.contains("thank you-web") { return true }
        if lower.contains("autopay") && lower.contains("payment") { return true }
        if lower.contains("automatic payment") { return true }
        if lower.contains("credit card payment") || lower.contains("creditcard payment") { return true }
        if lower.contains("card payment") { return true }
        if lower.contains("payment to credit") { return true }
        if lower.contains("online payment from chk") { return true }
        // "Payment to Chase card ending in 1234" / "Payment to Amex"
        if lower.hasPrefix("payment to ") && (lower.contains("card") || lower.contains("amex")
            || lower.contains("chase") || lower.contains("citi") || lower.contains("capital one")
            || lower.contains("discover") || lower.contains("apple card")) {
            return true
        }
        // "Chase Credit Crd Autopay"
        if lower.contains("crd") && (lower.contains("autopay") || lower.contains("payment")) {
            return true
        }
        if lower.contains("epayment") || lower.contains("e-payment") {
            return true
        }
        return false
    }

    private static func isTransfer(
        primary: String,
        detailed: String,
        titleLower: String,
        accountSubtype: String
    ) -> Bool {
        // All transfer primaries (savings ↔ checking, etc.)
        if primary == "TRANSFER_IN" || primary == "TRANSFER_OUT" {
            return true
        }
        // Internal bank bookkeeping sometimes under other primaries
        if detailed.contains("ACCOUNT_TRANSFER")
            || detailed.contains("INTERNAL_ACCOUNT_TRANSFER")
            || detailed.contains("SAVINGS") && detailed.contains("TRANSFER") {
            return true
        }

        // Title heuristics (when PFC is weak)
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
        // "Save As You Go" / "to savings" / "from savings"
        if titleLower.contains("to savings") || titleLower.contains("from savings")
            || titleLower.contains("to checking") || titleLower.contains("from checking") {
            return true
        }
        if titleLower.contains("savings transfer") || titleLower.contains("transfer savings") {
            return true
        }
        // Keep real purchases like "TransferWise" / "Transfer Fee" out of false positives
        // by requiring transfer-like structure when only the word "transfer" appears alone as activity.
        if titleLower == "transfer" || titleLower.hasPrefix("transfer ") {
            return true
        }

        _ = accountSubtype
        return false
    }

    // MARK: - Display categories

    /// Human-readable expense category from PFC primary/detailed.
    static func expenseCategory(from pfc: PlaidPFC?) -> String {
        let primary = (pfc?.primary ?? "").uppercased()
        let detailed = (pfc?.detailed ?? "").uppercased()

        if detailed.contains("GAS") || detailed.contains("FUEL") {
            return "Gas (Car)"
        }
        if detailed.contains("GROCER") {
            return "Groceries"
        }
        if detailed.contains("COFFEE") || detailed.contains("RESTAURANT") || detailed.contains("FAST_FOOD") {
            return "Dining"
        }
        if detailed.contains("SUBSCRIPTION") || detailed.contains("STREAMING") {
            return "Subscriptions"
        }
        if detailed.contains("INTERNET") || detailed.contains("UTILITIES") {
            return "Home Internet"
        }
        if detailed.contains("INSURANCE") {
            return "Car Insurance"
        }

        switch primary {
        case "FOOD_AND_DRINK":
            return "Dining"
        case "GENERAL_MERCHANDISE", "GENERAL_SERVICES":
            return "Shopping"
        case "TRANSPORTATION":
            return "Gas (Car)"
        case "TRAVEL":
            return "Travel"
        case "ENTERTAINMENT":
            return "Subscriptions"
        case "PERSONAL_CARE", "MEDICAL", "HEALTHCARE":
            return "Personal Care"
        case "RENT_AND_UTILITIES":
            return "Home Internet"
        case "LOAN_PAYMENTS":
            if detailed.contains("CREDIT_CARD") {
                return TransactionAnalytics.creditCardPaymentCategory
            }
            return "Miscellaneous"
        case "BANK_FEES":
            return "Miscellaneous"
        default:
            if primary.isEmpty { return "Miscellaneous" }
            return primary
                .lowercased()
                .split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
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
