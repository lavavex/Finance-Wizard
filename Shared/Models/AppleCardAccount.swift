//
//  AppleCardAccount.swift
//  Finance Wizard
//
//  Apple Card is usually CSV-imported (not Plaid). We still model it as a
//  linked credit account so it appears under Credit cards — never “Other spend.”
//  Default Daily Cash is 2% unless a higher reward category applies.
//

import Foundation
import SwiftData
import UIKit

/// Helpers to detect, create, and maintain a local “Apple Card” BankAccount row.
enum AppleCardAccount {
    /// Stable local id (not a Plaid account_id).
    static let accountId = "local:apple-card"
    static let itemId = "local:apple-card-item"
    static let paymentMethod = "Apple Card"
    static let institutionName = "Apple Card"
    static let productId = "apple_card"

    /// True if a transaction’s paymentMethod string looks like Apple Card.
    static func isAppleCard(paymentMethod: String) -> Bool {
        let m = paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return m == "apple card" || m.hasPrefix("apple card")
    }

    /// True if this BankAccount row is the synthetic Apple Card account.
    static func isAppleCard(account: BankAccount) -> Bool {
        account.accountId == accountId
            || account.institutionName.localizedCaseInsensitiveContains("apple card")
            || account.name.localizedCaseInsensitiveContains("apple card")
    }

    /// Insert or refresh the synthetic credit account + benefits product (2% base).
    @MainActor
    @discardableResult
    static func ensureLinked(in modelContext: ModelContext) -> BankAccount {
        let id = accountId
        var descriptor = FetchDescriptor<BankAccount>(
            predicate: #Predicate<BankAccount> { $0.accountId == id }
        )
        descriptor.fetchLimit = 1

        let account: BankAccount
        if let existing = try? modelContext.fetch(descriptor).first {
            account = existing
            account.name = paymentMethod
            account.officialName = paymentMethod
            account.type = "credit"
            account.subtype = "credit card"
            account.institutionName = institutionName
            account.lastSyncedAt = Date()
        } else {
            account = BankAccount(
                accountId: accountId,
                itemId: itemId,
                name: paymentMethod,
                officialName: paymentMethod,
                mask: nil,
                type: "credit",
                subtype: "credit card",
                institutionName: institutionName,
                currentBalance: 0,
                availableBalance: nil,
                creditLimit: nil,
                institutionId: nil
            )
            modelContext.insert(account)
        }

        // Benefits: Apple Card product @ 2% default (higher category rates win)
        let existing = CardBenefitsStore.profile(
            accountId: accountId,
            paymentMethod: paymentMethod
        )
        if existing.productKey == nil || existing.productKey != productId,
           let product = CardProductCatalog.product(id: productId) {
            // Don't clobber user-edited rates if they already saved a custom profile
            // without product key — only auto-apply when empty / unmatched.
            if existing.productKey == nil,
               existing.categoryMultipliers.isEmpty,
               abs(existing.defaultMultiplier - 1) < 0.001 {
                CardBenefitsStore.applyProduct(
                    product,
                    accountId: accountId,
                    paymentMethod: paymentMethod,
                    mask: nil
                )
            } else if existing.productKey == nil {
                // Profile exists (method key) but no product — attach product rates
                CardBenefitsStore.applyProduct(
                    product,
                    accountId: accountId,
                    paymentMethod: paymentMethod,
                    mask: nil
                )
            }
        }

        // Bundled Apple mark (cleaned from screenshot) — not from Plaid
        InstitutionLogoCache.seedBundledLogos()
        // Do NOT re-walk every transaction here — that freezes the UI on launch.
        try? modelContext.save()
        return account
    }

    private static var didEnsureThisSession = false

    /// Ensure link when any Apple Card activity exists (CSV history without re-import).
    /// Runs at most once per process unless forced (e.g. after CSV import).
    @MainActor
    static func ensureIfNeeded(
        in modelContext: ModelContext,
        transactions: [Transaction],
        force: Bool = false
    ) {
        if didEnsureThisSession, !force { return }
        let id = accountId
        var descriptor = FetchDescriptor<BankAccount>(
            predicate: #Predicate<BankAccount> { $0.accountId == id }
        )
        descriptor.fetchLimit = 1
        let exists = (try? modelContext.fetch(descriptor).first) != nil
        let hasAppleSpend = !exists && transactions.contains {
            isAppleCard(paymentMethod: $0.paymentMethod)
        }
        if hasAppleSpend || exists {
            _ = ensureLinked(in: modelContext)
        }
        didEnsureThisSession = true
    }

    /// Unlocked Apple Card rows → product rate (2% base or higher category).
    @MainActor
    static func reapplyUnlockedMultipliers(in modelContext: ModelContext) {
        let all = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        for tx in all where isAppleCard(paymentMethod: tx.paymentMethod) {
            if tx.isMultiplierLocked { continue }
            if TransactionAnalytics.isExcludedFromSpendCategory(tx.category) {
                tx.multiplier = 0
                continue
            }
            tx.multiplier = CardBenefitsStore.resolvedMultiplier(
                accountId: accountId,
                paymentMethod: paymentMethod,
                generalCategory: tx.category,
                title: tx.title,
                accounts: accounts,
                on: tx.date,
                rewardCategoryOverride: tx.rewardCategoryOverride
            )
            // Normalize label so account matching is stable
            if tx.paymentMethod != paymentMethod {
                tx.paymentMethod = paymentMethod
            }
        }
    }
}
