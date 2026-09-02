//
//  PlaidSyncMaintenance.swift
//  Finance Wizard
//
//  Housekeeping that runs around a sync rather than during it: pruning accounts Plaid no
//  longer returns, collapsing duplicate rows, and the one-off repair pass for rows an older
//  classifier mis-filed. Split out of PlaidSyncEngine.swift.
//
//  Access note: the helpers below were `private` inside PlaidSyncEngine. Moving them to a
//  separate file makes them module-internal — they are still not part of any public surface.
//

import Foundation
import SwiftData

extension PlaidSyncEngine {
    /// Remove `BankAccount`s on this Item that are no longer linked at Plaid.
    @MainActor
    static func pruneAccounts(
        forItemId itemId: String,
        keepingAccountIds: Set<String>,
        modelContext: ModelContext
    ) {
        let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        for account in all where account.itemId == itemId && !keepingAccountIds.contains(account.accountId) {
            modelContext.delete(account)
        }
    }

    /// Drop local accounts whose Plaid Item was unlinked (or replaced) but rows were left behind.
    /// Keeps the synthetic Apple Card account.
    @MainActor
    @discardableResult
    static func pruneOrphanBankAccounts(modelContext: ModelContext) -> Int {
        let linkedIds = Set(PlaidItemStore.loadItems().map(\.id))
        let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        var removed = 0
        for account in all {
            if AppleCardAccount.isAppleCard(account: account) { continue }
            if linkedIds.contains(account.itemId) { continue }
            modelContext.delete(account)
            removed += 1
        }
        return removed
    }

    /// Collapse obvious duplicates (same institution + mask + type) left after Relink created a new account_id.
    /// Keeps the row on a currently linked Item with the newest `lastSyncedAt`.
    @MainActor
    @discardableResult
    static func dedupeBankAccounts(modelContext: ModelContext) -> Int {
        let linkedIds = Set(PlaidItemStore.loadItems().map(\.id))
        let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        var groups: [String: [BankAccount]] = [:]
        for account in all {
            if AppleCardAccount.isAppleCard(account: account) { continue }
            let key = [
                account.institutionName.lowercased(),
                (account.mask ?? "").lowercased(),
                account.type.lowercased(),
                (account.subtype ?? "").lowercased(),
                account.name.lowercased()
            ].joined(separator: "|")
            groups[key, default: []].append(account)
        }

        var removed = 0
        for (_, var rows) in groups where rows.count > 1 {
            // Prefer accounts still on a live Item, then most recently synced
            rows.sort { a, b in
                let aLive = linkedIds.contains(a.itemId)
                let bLive = linkedIds.contains(b.itemId)
                if aLive != bLive { return aLive && !bLive }
                return a.lastSyncedAt > b.lastSyncedAt
            }
            let keep = rows[0]
            for orphan in rows.dropFirst() {
                // Only drop when we have a clear duplicate of the kept row
                let sameMask = (keep.mask ?? "") == (orphan.mask ?? "")
                let sameName = keep.name.caseInsensitiveCompare(orphan.name) == .orderedSame
                guard sameMask || sameName else { continue }
                modelContext.delete(orphan)
                removed += 1
            }
        }
        return removed
    }

    /// Orphans + account/tx duplicates (safe to run on Sync / Settings / after Relink).
    @MainActor
    @discardableResult
    static func cleanupStaleBankAccounts(modelContext: ModelContext) -> Int {
        let a = pruneOrphanBankAccounts(modelContext: modelContext)
        let b = dedupeBankAccounts(modelContext: modelContext)
        // Relink creates new Plaid transaction_ids for the same real-world spend;
        // remove content duplicates left after the old Item was dropped.
        let c = dedupeTransactions(modelContext: modelContext)
        let d = dedupeIncome(modelContext: modelContext)
        return a + b + c + d
    }

    // MARK: - Transaction / income content dedupe

    /// Same calendar day + amount + title + soft payment method → keep one expense row.
    /// Locks win when choosing which duplicate to keep.
    @MainActor
    @discardableResult
    static func dedupeTransactions(modelContext: ModelContext) -> Int {
        let all = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        guard all.count > 1 else { return 0 }

        let cal = Calendar.current
        let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        var groups: [String: [Transaction]] = [:]
        groups.reserveCapacity(all.count)

        for tx in all {
            let day = cal.startOfDay(for: tx.date).timeIntervalSince1970
            let amountKey = String(format: "%.2f", abs(tx.amount))
            let titleKey = normalizeDedupeText(tx.title)
            let methodKey = normalizePaymentMethodForDedupe(tx.paymentMethod)
            let key = "\(day)|\(amountKey)|\(titleKey)|\(methodKey)"
            groups[key, default: []].append(tx)
        }

        var removed = 0
        for (_, var rows) in groups where rows.count > 1 {
            rows.sort { a, b in
                let aScore = transactionKeepScore(a, accounts: accounts)
                let bScore = transactionKeepScore(b, accounts: accounts)
                if aScore != bScore { return aScore > bScore }
                return a.transactionId < b.transactionId
            }
            for drop in rows.dropFirst() {
                modelContext.delete(drop)
                removed += 1
            }
        }
        return removed
    }

    /// Same day + amount + source (+ account mask when present) → keep one income row.
    @MainActor
    @discardableResult
    static func dedupeIncome(modelContext: ModelContext) -> Int {
        let all = (try? modelContext.fetch(FetchDescriptor<Income>())) ?? []
        guard all.count > 1 else { return 0 }

        let cal = Calendar.current
        var groups: [String: [Income]] = [:]
        for row in all {
            let day = cal.startOfDay(for: row.date).timeIntervalSince1970
            let amountKey = String(format: "%.2f", abs(row.amount))
            let sourceKey = normalizeDedupeText(row.source)
            let maskKey = (row.accountMask ?? "").lowercased()
            let key = "\(day)|\(amountKey)|\(sourceKey)|\(maskKey)"
            groups[key, default: []].append(row)
        }

        var removed = 0
        for (_, var rows) in groups where rows.count > 1 {
            rows.sort { $0.transactionId < $1.transactionId }
            for drop in rows.dropFirst() {
                modelContext.delete(drop)
                removed += 1
            }
        }
        return removed
    }

    /// Higher score = keep this duplicate when content-deduping expenses.
    static func transactionKeepScore(_ tx: Transaction, accounts: [BankAccount]) -> Int {
        var score = 0
        if tx.isCategoryLocked { score += 4 }
        if tx.isPaymentRailLocked { score += 1 }
        if BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts) != nil {
            score += 8
        }
        // Prefer non–Apple Card only when both are same method family (already grouped)
        return score
    }

    /// Lowercase + collapse whitespace for fingerprint keys.
    static func normalizeDedupeText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Collapse “X Money Checking ···1234” vs “X Money Checking” for fingerprinting.
    static func normalizePaymentMethodForDedupe(_ method: String) -> String {
        var t = method.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        t = t.replacingOccurrences(of: #"···\d+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\.{3}\d+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// After Relink / Link, refresh balances and drop accounts removed in Link.
    @MainActor
    static func reconcileItemAccounts(
        item: PlaidLinkedItem,
        modelContext: ModelContext
    ) async throws -> Int {
        let details = try await PlaidAPIClient.accountsGet(accessToken: item.accessToken)
        let institutionId: String? = {
            let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
            return all.first(where: { $0.itemId == item.id })?.institutionId
        }()
        let n = upsertAccounts(details, item: item, institutionId: institutionId, modelContext: modelContext)
        _ = cleanupStaleBankAccounts(modelContext: modelContext)
        return n
    }

    // MARK: - Liabilities → BankAccount
}
