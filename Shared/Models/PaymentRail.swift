//
//  PaymentRail.swift
//  Finance Wizard
//
//  Debit card vs ACH (and other). Plaid’s payment_channel is coarse
//  ("online" / "in store" / "other"); we infer a rail and let the user override.
//
//  “Rail” here means how the money left a checking account: card swipe (debit)
//  vs bank transfer / bill-pay (ACH). Reward rates can differ by rail.
//

import Foundation

/// How money left a depository (checking) account for a purchase.
///
/// Raw-value enum: each case’s String is "debit", "ach", or "other".
/// That string is what we store on Transaction.paymentRail for SwiftData simplicity.
enum PaymentRail: String, CaseIterable, Identifiable, Codable, Sendable {
    case debit
    case ach
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .debit: return "Debit card"
        case .ach: return "ACH / transfer"
        case .other: return "Other"
        }
    }

    var shortLabel: String {
        switch self {
        case .debit: return "Debit"
        case .ach: return "ACH"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .debit: return "creditcard"
        case .ach: return "building.columns"
        case .other: return "ellipsis.circle"
        }
    }

    /// Infer from Plaid `payment_channel` + merchant/title heuristics.
    /// static factory-style method: PaymentRail.infer(plaidChannel:title:)
    static func infer(plaidChannel: String?, title: String) -> PaymentRail {
        let lower = title.lowercased()
        let channel = (plaidChannel ?? "").lowercased()

        // Strong ACH / bank-rail signals in description
        if looksLikeACH(lower) { return .ach }

        // Card-present / POS
        if channel == "in store" || channel == "in-store" { return .debit }
        if looksLikeDebit(lower) { return .debit }

        // Online is ambiguous (could be debit or ACH bill-pay)
        if channel == "online" {
            if looksLikeBillPayACH(lower) { return .ach }
            // Default online spend on checking → treat as debit card / digital wallet
            return .debit
        }

        return .other
    }

    // private static helpers keep the public API small; only infer uses them.

    /// Keyword scan for ACH / transfer language in a lowercased title.
    private static func looksLikeACH(_ lower: String) -> Bool {
        let needles = [
            " ach", "ach ", "ach-", "-ach",
            "ppd ", "ccd ", "ctx ", "web ",
            "direct deposit", // rare on expenses but sometimes mislabeled
            "bank transfer", "external transfer",
            "a2a", "wire transfer", "wire fee",
            "ach payment", "ach debit", "ach withdraw",
            "electronic payment", // often bill-pay ACH
            "online transfer", "xfer ",
            "zelle", "venmo cashout", // peer rails (not debit card)
            "real time payment", "rtp ",
            "fednow",
            // Fintech ACH bill-pay labels (X Money EPAY → credit card)
            "epay", "e-pay", "epmt"
        ]
        // for-in where: only enter the body when the condition is true
        for n in needles where lower.contains(n) { return true }
        if lower.hasPrefix("ach") { return true }
        if lower == "epay" || lower == "e-pay" || lower == "epmt" { return true }
        return false
    }

    private static func looksLikeDebit(_ lower: String) -> Bool {
        let needles = [
            "debit", "pos purchase", "pos debit",
            "visa debit", "mastercard debit", "mc debit",
            "checkcard", "check card",
            "apple pay", "google pay", "samsung pay",
            "contactless"
        ]
        for n in needles where lower.contains(n) { return true }
        return false
    }

    private static func looksLikeBillPayACH(_ lower: String) -> Bool {
        lower.contains("bill pay") || lower.contains("billpay")
            || lower.contains("payment to ") || lower.contains("autopay")
    }
}

// MARK: - Extension on Transaction
//
// extension adds methods/properties to an existing type without editing its file
// (or without bloating the main model). Here we add rail helpers that belong
// with PaymentRail’s logic but live on each Transaction instance.

extension Transaction {
    /// User override if locked; otherwise stored rail (from Plaid infer).
    /// PaymentRail(rawValue:) returns optional — unknown strings fall through to infer.
    var effectivePaymentRail: PaymentRail {
        if let raw = paymentRail, let rail = PaymentRail(rawValue: raw) {
            return rail
        }
        return PaymentRail.infer(plaidChannel: plaidPaymentChannel, title: title)
    }

    /// Treats nil lock flag as unlocked (same pattern as categoryLocked).
    var isPaymentRailLocked: Bool { paymentRailLocked ?? false }
}
