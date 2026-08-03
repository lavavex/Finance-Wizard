//
//  TransactionSearch.swift
//  Finance Wizard
//
//  Client-side search over title, category, amount, and last-four.
//
//  Learning notes:
//  - “Client-side” means filtering happens in the app, not on a server.
//  - filter { } builds a new array of elements that pass a test (predicate).
//  - Double(...) tries to parse text into a number; fails → nil.
//  - Key path \.isNumber is used with filter to keep only digit characters.
//

import Foundation

/// Helpers for matching user search text against transactions.
enum TransactionSearch {
    /// Case-insensitive match on title, category, payment method, amount text, last-4.
    /// Returns true when the empty query means “show everything.”
    static func matches(
        _ tx: Transaction,
        query: String,
        accounts: [BankAccount] = []
    ) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty search = match all (caller often uses this before filtering)
        guard !q.isEmpty else { return true }
        let lower = q.lowercased()

        // Simple substring checks on main text fields
        if tx.title.lowercased().contains(lower) { return true }
        if tx.category.lowercased().contains(lower) { return true }
        if tx.paymentMethod.lowercased().contains(lower) { return true }
        if tx.transactionId.lowercased().contains(lower) { return true }

        // Amount: allow "12.34", "12", "$12"
        let amountDigits = lower.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        if let target = Double(amountDigits) {
            // Exact (within a cent)
            if abs(abs(tx.amount) - target) < 0.005 { return true }
            // Prefix-ish: "12" matches 12.99
            let absStr = String(format: "%.2f", abs(tx.amount))
            if absStr.hasPrefix(amountDigits) || absStr.contains(amountDigits) {
                return true
            }
        }

        // Last four from payment method or linked account
        // filter(\.isNumber) keeps only characters that are digits
        let digitsOnly = lower.filter(\.isNumber)
        if digitsOnly.count == 4 {
            if tx.paymentMethod.contains(digitsOnly) { return true }
            if let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts),
               let mask = account.mask, mask.contains(digitsOnly) || mask == digitsOnly {
                return true
            }
            let label = CardLabelStore.label(
                paymentMethod: tx.paymentMethod,
                accountId: BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts)?.accountId,
                fallback: tx.paymentMethod
            )
            if label.contains(digitsOnly) { return true }
        }

        // Display nickname (user-edited card label)
        let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts)
        let label = CardLabelStore.label(
            paymentMethod: tx.paymentMethod,
            accountId: account?.accountId,
            fallback: tx.paymentMethod
        )
        if label.lowercased().contains(lower) { return true }

        return false
    }

    /// Returns only transactions that match `query` (or all if query is blank).
    static func filter(
        _ transactions: [Transaction],
        query: String,
        accounts: [BankAccount] = []
    ) -> [Transaction] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return transactions }
        // $0 is the shorthand for “the current element” inside the closure
        return transactions.filter { matches($0, query: q, accounts: accounts) }
    }
}

/// Same idea as TransactionSearch, but for Income rows (paychecks, deposits, etc.).
enum IncomeSearch {
    /// Match source, category, account name/mask, or exact amount text.
    static func matches(_ row: Income, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let lower = q.lowercased()
        if row.source.lowercased().contains(lower) { return true }
        if row.category.lowercased().contains(lower) { return true }
        // Optional account fields: treat nil as empty string with ?? ""
        if (row.accountName ?? "").lowercased().contains(lower) { return true }
        if (row.accountMask ?? "").contains(lower.filter(\.isNumber)) { return true }
        let amountDigits = lower.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        if let target = Double(amountDigits), abs(row.amount - target) < 0.005 {
            return true
        }
        return false
    }

    static func filter(_ rows: [Income], query: String) -> [Income] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { matches($0, query: q) }
    }
}
