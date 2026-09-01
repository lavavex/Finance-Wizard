//
//  CardIssuerCatalog.swift
//  Finance Wizard
//
//  Issuer / last-four identity for matching a checking ACH to the same payment
//  on the card. Major US networks — not a per-user merchant list.
//

import Foundation

enum CardIssuerCatalog {
    /// Slug + substrings that identify an issuer in a title or account name.
    static let issuers: [(id: String, needles: [String])] = [
        ("apple", ["apple card"]),
        ("amex", ["american express", "amex", "blue cash"]),
        ("chase", ["chase"]),
        ("citi", ["citi", "citibank"]),
        ("capitalone", ["capital one"]),
        ("discover", ["discover"]),
        ("boa", ["bank of america"]),
        ("wellsfargo", ["wells fargo"]),
        ("usbank", ["us bank", "u.s. bank"]),
        ("barclays", ["barclays"]),
        ("synchrony", ["synchrony"]),
    ]

    static func issuerIds(in text: String) -> Set<String> {
        let t = text.lowercased()
        var ids = Set<String>()
        for (id, needles) in issuers {
            if needles.contains(where: { t.contains($0) }) {
                ids.insert("issuer:\(id)")
            }
        }
        return ids
    }

    /// True when a stored account/card label is the credit product, not the funding account.
    static func looksLikeCreditAccountName(_ name: String) -> Bool {
        let n = name.lowercased()
        if n.contains("credit card") || n.contains("creditcard") { return true }
        if n.contains("apple card") { return true }
        if issuerIds(in: n).isEmpty { return false }
        return n.contains("card") || n.contains("credit") || n.contains("visa")
            || n.contains("mastercard") || n.contains("amex")
    }
}
