//
//  PlaidCategoryMapper.swift
//  Finance Wizard
//
//  Map Plaid personal_finance_category → app category labels.
//

import Foundation

enum PlaidCategoryMapper {
    /// Human-readable expense category from PFC primary/detailed.
    static func expenseCategory(from pfc: PlaidPFC?) -> String {
        let primary = (pfc?.primary ?? "").uppercased()
        let detailed = (pfc?.detailed ?? "").uppercased()

        // Prefer detailed when it maps cleanly
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
        case "LOAN_PAYMENTS", "BANK_FEES":
            return "Miscellaneous"
        default:
            if primary.isEmpty { return "Miscellaneous" }
            // Prettify PRIMARY_NAME → Primary name
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

    /// True when the transaction looks like an internal transfer (skip from spend/income).
    static func isInternalTransfer(pfc: PlaidPFC?, name: String) -> Bool {
        let primary = (pfc?.primary ?? "").uppercased()
        let detailed = (pfc?.detailed ?? "").uppercased()
        if primary == "TRANSFER_IN" || primary == "TRANSFER_OUT" {
            // Keep external-looking transfers; skip pure account transfers when detailed says so
            if detailed.contains("ACCOUNT_TRANSFER")
                || detailed.contains("INTERNAL")
                || detailed.contains("SAVINGS") {
                return true
            }
            // Credit card payment often labeled TRANSFER — skip so payoffs don’t inflate spend/income
            if detailed.contains("CREDIT_CARD_PAYMENT") || detailed.contains("LOAN_PAYMENTS") {
                return true
            }
        }
        let lower = name.lowercased()
        if lower.contains("payment thank you") || lower.contains("autopay") && lower.contains("payment") {
            return true
        }
        return false
    }
}
