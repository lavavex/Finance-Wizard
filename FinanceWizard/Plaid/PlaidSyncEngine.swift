//
//  PlaidSyncEngine.swift
//  Finance Wizard
//
//  Pulls /transactions/sync + /accounts/get for every linked Item.
//  Transfers / credit-card payments never enter Total Spend or Income.
//

import Foundation
import SwiftData
import WidgetKit

struct PlaidSyncReport: Sendable {
    var itemLines: [String] = []
    var expensesUpserted: Int = 0
    var incomeUpserted: Int = 0
    var creditPaymentsUpserted: Int = 0
    var removed: Int = 0
    var skippedTransfers: Int = 0
    var cleanedLegacy: Int = 0
    var accountsUpdated: Int = 0
    var liabilitiesUpdated: Int = 0
    var warnings: [String] = []

    var summary: String {
        var lines: [String] = []
        lines.append(contentsOf: itemLines)
        lines.append("Expenses upserted: \(expensesUpserted)")
        lines.append("Income upserted: \(incomeUpserted)")
        lines.append("Card payments tracked: \(creditPaymentsUpserted)")
        if skippedTransfers > 0 { lines.append("Skipped transfers: \(skippedTransfers)") }
        if cleanedLegacy > 0 { lines.append("Removed mis-filed transfers: \(cleanedLegacy)") }
        if accountsUpdated > 0 { lines.append("Accounts refreshed: \(accountsUpdated)") }
        if liabilitiesUpdated > 0 { lines.append("Credit details refreshed: \(liabilitiesUpdated)") }
        if removed > 0 { lines.append("Removed by bank: \(removed)") }
        if !warnings.isEmpty {
            lines.append("Warnings:")
            lines.append(contentsOf: warnings.map { "• \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

private struct AccountMeta {
    var label: String
    var type: String
    var subtype: String
}

enum PlaidSyncEngine {
    /// Sync all linked Items. If `resetCursors`, start from full history again.
    @MainActor
    static func syncAll(
        modelContext: ModelContext,
        resetCursors: Bool = false,
        includePending: Bool = false,
        progress: ((String) -> Void)? = nil
    ) async throws -> PlaidSyncReport {
        try PlaidCredentialsStore.requireConfigured()
        var items = PlaidItemStore.loadItems()
        guard !items.isEmpty else {
            throw PlaidAPIError.http(
                status: 0,
                code: nil,
                message: "No banks linked. Open Settings → Link bank account."
            )
        }

        if resetCursors {
            for i in items.indices {
                items[i].transactionsCursor = ""
            }
            PlaidItemStore.saveItems(items)
            items = PlaidItemStore.loadItems()
        }

        var report = PlaidSyncReport()

        // Drop older rows that were stored as spend/income but look like transfers/payments
        VendorRulesStore.removeBillPayMisrules()
        report.cleanedLegacy = cleanLegacyMisclassifiedRows(modelContext: modelContext)
        // Stale BankAccounts from unlinked/replaced Items (e.g. duped X Money after Relink)
        _ = cleanupStaleBankAccounts(modelContext: modelContext)

        for item in items {
            progress?("Syncing \(item.institutionName)…")
            do {
                let itemReport = try await syncItem(
                    item,
                    modelContext: modelContext,
                    includePending: includePending,
                    progress: progress
                )
                report.expensesUpserted += itemReport.expensesUpserted
                report.incomeUpserted += itemReport.incomeUpserted
                report.creditPaymentsUpserted += itemReport.creditPaymentsUpserted
                report.removed += itemReport.removed
                report.skippedTransfers += itemReport.skippedTransfers
                report.accountsUpdated += itemReport.accountsUpdated
                report.liabilitiesUpdated += itemReport.liabilitiesUpdated
                report.itemLines.append(
                    "\(item.institutionName): +\(itemReport.expensesUpserted) exp / +\(itemReport.incomeUpserted) inc / \(itemReport.creditPaymentsUpserted) card pmts"
                )
            } catch {
                report.warnings.append("\(item.institutionName): \(error.localizedDescription)")
                report.itemLines.append("\(item.institutionName): failed")
            }
        }

        try modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        return report
    }

    // MARK: - Per item

    @MainActor
    private static func syncItem(
        _ item: PlaidLinkedItem,
        modelContext: ModelContext,
        includePending: Bool,
        progress: ((String) -> Void)?
    ) async throws -> PlaidSyncReport {
        var report = PlaidSyncReport()
        var cursor: String? = item.transactionsCursor.isEmpty ? nil : item.transactionsCursor
        var pageStartCursor = cursor
        var hasMore = true
        var accountMeta: [String: AccountMeta] = [:]
        var safety = 0

        while hasMore {
            safety += 1
            if safety > 200 {
                throw PlaidAPIError.http(status: 0, code: nil, message: "Sync pagination safety limit hit.")
            }

            progress?("\(item.institutionName): page \(safety)…")

            let page: TransactionsSyncPage
            do {
                page = try await PlaidAPIClient.transactionsSync(
                    accessToken: item.accessToken,
                    cursor: cursor
                )
            } catch {
                if case PlaidAPIError.http(_, let code, _) = error,
                   code == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" {
                    cursor = pageStartCursor
                    continue
                }
                throw error
            }

            if let accounts = page.accounts {
                for account in accounts {
                    let label = accountDisplayName(account: account, institution: item.institutionName)
                    accountMeta[account.account_id] = AccountMeta(
                        label: label,
                        type: account.type ?? "",
                        subtype: account.subtype ?? ""
                    )
                }
            }

            for tx in page.added + page.modified {
                if tx.pending == true && !includePending { continue }
                applyTransaction(
                    tx,
                    item: item,
                    accountMeta: accountMeta,
                    modelContext: modelContext,
                    report: &report
                )
            }

            for removed in page.removed {
                if deleteLocal(transactionID: removed.transaction_id, modelContext: modelContext) {
                    report.removed += 1
                }
            }

            hasMore = page.has_more
            cursor = page.next_cursor
            if !hasMore {
                pageStartCursor = cursor
            }
        }

        if let cursor, !cursor.isEmpty {
            PlaidItemStore.updateCursor(itemID: item.id, cursor: cursor)
        }

        // Balances / credit limits + institution logo (Plaid metadata, not product card photos)
        progress?("\(item.institutionName): balances…")
        var institutionId: String?
        do {
            institutionId = try await PlaidAPIClient.itemInstitutionID(accessToken: item.accessToken)
            if let institutionId {
                do {
                    let branding = try await PlaidAPIClient.institutionBranding(institutionID: institutionId)
                    InstitutionLogoCache.store(
                        institutionID: branding.institutionID,
                        name: branding.name ?? item.institutionName,
                        logoBase64: branding.logoBase64,
                        primaryColorHex: branding.primaryColorHex
                    )
                    // Also index under the Link display name (e.g. "Chase") when Plaid’s name differs
                    if branding.name?.caseInsensitiveCompare(item.institutionName) != .orderedSame {
                        InstitutionLogoCache.store(
                            institutionID: branding.institutionID,
                            name: item.institutionName,
                            logoBase64: branding.logoBase64,
                            primaryColorHex: branding.primaryColorHex
                        )
                    }
                } catch {
                    report.warnings.append(
                        "\(item.institutionName) logo: \(error.localizedDescription)"
                    )
                }
            }
        } catch {
            report.warnings.append("\(item.institutionName) institution: \(error.localizedDescription)")
        }

        do {
            let details = try await PlaidAPIClient.accountsGet(accessToken: item.accessToken)
            report.accountsUpdated = upsertAccounts(
                details,
                item: item,
                institutionId: institutionId,
                modelContext: modelContext
            )
        } catch {
            report.warnings.append("\(item.institutionName) balances: \(error.localizedDescription)")
        }

        // Credit APR / due dates / min payment (Liabilities product)
        progress?("\(item.institutionName): credit details…")
        do {
            let creditLiabilities = try await PlaidAPIClient.liabilitiesGet(accessToken: item.accessToken)
            report.liabilitiesUpdated = applyCreditLiabilities(
                creditLiabilities,
                modelContext: modelContext
            )
        } catch {
            if case PlaidAPIError.http(_, let code, let message) = error {
                // Expected when Item was linked before Liabilities, product still warming up, or unsupported.
                let softCodes: Set<String> = [
                    "PRODUCTS_NOT_SUPPORTED",
                    "PRODUCT_NOT_READY",
                    "PRODUCT_NOT_ENABLED",
                    "INVALID_PRODUCT",
                    "ADDITIONAL_CONSENT_REQUIRED",
                    "NO_LIABILITY_ACCOUNTS"
                ]
                if let code, softCodes.contains(code) {
                    if code == "PRODUCT_NOT_READY" {
                        report.warnings.append(
                            "\(item.institutionName): credit details still preparing — Sync again in a few minutes."
                        )
                    } else if code == "PRODUCTS_NOT_SUPPORTED" || code == "NO_LIABILITY_ACCOUNTS" {
                        // Institution has no credit liabilities data — silent for depository-only Items.
                    } else if code == "PRODUCT_NOT_ENABLED"
                                || code == "INVALID_PRODUCT"
                                || code == "ADDITIONAL_CONSENT_REQUIRED" {
                        report.warnings.append(
                            "\(item.institutionName): re-link bank to enable credit details (APR, due date)."
                        )
                    } else {
                        report.warnings.append("\(item.institutionName) liabilities: \(message)")
                    }
                } else {
                    report.warnings.append("\(item.institutionName) liabilities: \(error.localizedDescription)")
                }
            } else {
                report.warnings.append("\(item.institutionName) liabilities: \(error.localizedDescription)")
            }
        }

        return report
    }

    // MARK: - Apply one Plaid transaction

    @MainActor
    private static func applyTransaction(
        _ tx: PlaidTransaction,
        item: PlaidLinkedItem,
        accountMeta: [String: AccountMeta],
        modelContext: ModelContext,
        report: inout PlaidSyncReport
    ) {
        let title = (tx.merchant_name?.isEmpty == false ? tx.merchant_name : tx.name)
            ?? tx.original_description
            ?? "Transaction"

        guard let date = parseDate(tx.date) else { return }

        let meta = accountMeta[tx.account_id]
        let paymentMethod = meta?.label ?? item.paymentMethodLabel
        let accountType = meta?.type
        let accountSubtype = meta?.subtype

        let kind = PlaidCategoryMapper.classify(
            amount: tx.amount,
            pfc: tx.personal_finance_category,
            title: title,
            accountType: accountType,
            accountSubtype: accountSubtype
        )

        switch kind {
        case .transfer:
            // Ensure we don't leave a mis-filed spend/income row from an older sync
            _ = deleteLocal(transactionID: tx.transaction_id, modelContext: modelContext)
            report.skippedTransfers += 1
            return

        case .creditPayment:
            // Not income; show as Transaction with special category (excluded from Total Spend)
            deleteIncomeOnly(transactionID: tx.transaction_id, modelContext: modelContext)
            upsertCreditPayment(
                tx: tx,
                title: title,
                date: date,
                paymentMethod: paymentMethod,
                accountType: accountType,
                institutionName: item.institutionName,
                modelContext: modelContext
            )
            upsertCreditPaymentExpense(
                tx: tx,
                title: title,
                date: date,
                paymentMethod: paymentMethod,
                modelContext: modelContext
            )
            report.creditPaymentsUpserted += 1

        case .spending:
            // Don't keep a parallel income / payment row if type flipped
            deleteIncomeOnly(transactionID: tx.transaction_id, modelContext: modelContext)
            deleteCreditPaymentOnly(transactionID: tx.transaction_id, modelContext: modelContext)
            upsertExpense(
                tx: tx,
                title: title,
                date: date,
                paymentMethod: paymentMethod,
                accountId: tx.account_id,
                modelContext: modelContext
            )
            report.expensesUpserted += 1

        case .income:
            deleteExpenseOnly(transactionID: tx.transaction_id, modelContext: modelContext)
            deleteCreditPaymentOnly(transactionID: tx.transaction_id, modelContext: modelContext)
            upsertIncome(
                tx: tx,
                title: title,
                date: date,
                paymentMethod: paymentMethod,
                pfcDetailed: tx.personal_finance_category?.detailed,
                modelContext: modelContext
            )
            report.incomeUpserted += 1
        }
    }

    // MARK: - Upserts

    @MainActor
    private static func upsertExpense(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        paymentMethod: String,
        accountId: String,
        modelContext: ModelContext
    ) {
        let targetId = tx.transaction_id
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { row in
                row.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1

        let defaultCategory = PlaidCategoryMapper.expenseCategory(from: tx.personal_finance_category)
        let rule = VendorRulesStore.match(vendor: title, paymentMethod: paymentMethod)
        let mappedCategory = rule?.category ?? defaultCategory
        let channel = tx.payment_channel
        let inferredRail = PaymentRail.infer(plaidChannel: channel, title: title)
        let bankAccount = fetchBankAccount(accountId: accountId, modelContext: modelContext)
        let allAccounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        let railMultiplier = bankAccount?.rewardMultiplier(for: inferredRail)
        let rewardsEligible = CardBenefitsStore.isRewardsEligible(
            account: bankAccount,
            paymentMethod: paymentMethod
        )
        let benefitsRate = CardBenefitsStore.resolvedMultiplier(
            accountId: accountId,
            paymentMethod: paymentMethod,
            generalCategory: mappedCategory,
            title: title,
            accounts: allAccounts
        )
        // Preference: vendor learn → depository debit/ACH (X Money) → Benefits rates on cards only.
        // Plain Chase checking is not rewards-eligible → multiplier 0 (no points).
        let mappedMultiplier: Double = {
            if let ruleMult = rule?.multiplier { return ruleMult }
            if !rewardsEligible { return 0 }
            if let railMultiplier { return railMultiplier }
            return benefitsRate
        }()
        let amount = -abs(tx.amount)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = title
            existing.amount = amount
            existing.date = date
            existing.paymentMethod = paymentMethod
            existing.plaidPaymentChannel = channel
            if !existing.isPaymentRailLocked {
                existing.paymentRail = inferredRail.rawValue
            }
            if !existing.isCategoryLocked {
                existing.category = mappedCategory
            }
            if !existing.isMultiplierLocked {
                let cat = existing.isCategoryLocked ? existing.category : mappedCategory
                let rail = existing.effectivePaymentRail
                if let ruleMult = rule?.multiplier {
                    existing.multiplier = ruleMult
                } else if !rewardsEligible {
                    existing.multiplier = 0
                } else if let railMult = bankAccount?.rewardMultiplier(for: rail) {
                    // X Money: debit 3%, ACH 0%
                    existing.multiplier = railMult
                } else {
                    existing.multiplier = CardBenefitsStore.resolvedMultiplier(
                        accountId: accountId,
                        paymentMethod: paymentMethod,
                        generalCategory: cat,
                        title: title,
                        accounts: allAccounts,
                        on: date,
                        rewardCategoryOverride: existing.rewardCategoryOverride
                    )
                }
            }
        } else {
            modelContext.insert(
                Transaction(
                    transactionId: targetId,
                    title: title,
                    amount: amount,
                    date: date,
                    category: mappedCategory,
                    paymentMethod: paymentMethod,
                    multiplier: mappedMultiplier,
                    categoryLocked: false,
                    multiplierLocked: false,
                    overrideSource: rule != nil ? "rule" : (railMultiplier != nil ? "account-rail" : nil),
                    plaidPaymentChannel: channel,
                    paymentRail: inferredRail.rawValue,
                    paymentRailLocked: false
                )
            )
        }
    }

    @MainActor
    private static func fetchBankAccount(
        accountId: String,
        modelContext: ModelContext
    ) -> BankAccount? {
        let id = accountId
        var descriptor = FetchDescriptor<BankAccount>(
            predicate: #Predicate<BankAccount> { account in
                account.accountId == id
            }
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    @MainActor
    private static func upsertIncome(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        paymentMethod: String,
        pfcDetailed: String?,
        modelContext: ModelContext
    ) {
        let targetId = tx.transaction_id
        var descriptor = FetchDescriptor<Income>(
            predicate: #Predicate<Income> { row in
                row.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1

        let category = PlaidCategoryMapper.incomeCategory(
            from: tx.personal_finance_category,
            name: title
        )
        let amount = abs(tx.amount)
        let pending = tx.pending ?? false
        let parts = paymentMethod.components(separatedBy: " ···")
        let accountName = parts.first
        let accountMask = parts.count > 1 ? parts[1] : nil

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.source = title
            existing.amount = amount
            existing.date = date
            existing.category = category
            existing.accountName = accountName
            existing.accountMask = accountMask
            existing.sourceInstitution = accountName
            existing.rawName = tx.name
            existing.pfc = pfcDetailed
            existing.pending = pending
            existing.kind = "income"
        } else {
            modelContext.insert(
                Income(
                    transactionId: targetId,
                    source: title,
                    amount: amount,
                    date: date,
                    category: category,
                    accountName: accountName,
                    accountMask: accountMask,
                    sourceInstitution: accountName,
                    rawName: tx.name,
                    pfc: pfcDetailed,
                    pending: pending,
                    kind: "income"
                )
            )
        }
    }

    @MainActor
    private static func upsertCreditPayment(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        paymentMethod: String,
        accountType: String?,
        institutionName: String,
        modelContext: ModelContext
    ) {
        let targetId = tx.transaction_id
        var descriptor = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { row in
                row.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1

        let amount = abs(tx.amount)
        // Prefer the credit account name when the txn is on the card itself
        let onCredit = (accountType ?? "").lowercased() == "credit"
        let maskFromTitle = CreditAnalytics.extractMask(from: title)
        let cardName: String = {
            if onCredit { return paymentMethod }
            if let mask = maskFromTitle {
                // Prefer a real linked credit account label when mask matches
                if let match = findCreditAccount(mask: mask, modelContext: modelContext) {
                    return match.plaidDisplayName
                }
                return inferCardName(from: title) ?? "Card ···\(mask)"
            }
            return inferCardName(from: title) ?? paymentMethod
        }()
        let sourceAccount = onCredit ? nil : paymentMethod
        let creditAccountId: String? = {
            if onCredit { return tx.account_id }
            if let mask = maskFromTitle,
               let match = findCreditAccount(mask: mask, modelContext: modelContext) {
                return match.accountId
            }
            return nil
        }()

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.amount = amount
            existing.date = date
            existing.cardName = cardName
            existing.sourceAccount = sourceAccount
            existing.title = title
            existing.creditAccountId = creditAccountId ?? existing.creditAccountId
            existing.institutionName = institutionName
        } else {
            modelContext.insert(
                CreditCardPayment(
                    transactionId: targetId,
                    amount: amount,
                    date: date,
                    cardName: cardName,
                    sourceAccount: sourceAccount,
                    title: title,
                    creditAccountId: creditAccountId,
                    institutionName: institutionName
                )
            )
        }
    }

    @MainActor
    private static func findCreditAccount(mask: String, modelContext: ModelContext) -> BankAccount? {
        let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        return all.first { account in
            account.isCredit && account.mask == mask
        }
    }

    /// List-visible row for a bill payment; category is excluded from Total Spend.
    @MainActor
    private static func upsertCreditPaymentExpense(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        paymentMethod: String,
        modelContext: ModelContext
    ) {
        let targetId = tx.transaction_id
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { row in
                row.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1

        let category = TransactionAnalytics.creditCardPaymentCategory
        let amount = -abs(tx.amount)
        let channel = tx.payment_channel
        let rail = PaymentRail.infer(plaidChannel: channel, title: title)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = title
            existing.amount = amount
            existing.date = date
            existing.paymentMethod = paymentMethod
            existing.plaidPaymentChannel = channel
            // Bill pays always use this category (fixes mis-learns like EPAY → Shopping)
            existing.category = category
            existing.categoryLocked = true
            existing.multiplier = 0
            existing.multiplierLocked = true
            if !existing.isPaymentRailLocked {
                // ACH bill-pay codes (EPAY) should not stay as debit
                existing.paymentRail = looksLikeACHBillPay(title) ? PaymentRail.ach.rawValue : rail.rawValue
            }
            existing.overrideSource = "credit-payment"
        } else {
            modelContext.insert(
                Transaction(
                    transactionId: targetId,
                    title: title,
                    amount: amount,
                    date: date,
                    category: category,
                    paymentMethod: paymentMethod,
                    multiplier: 0,
                    categoryLocked: true,
                    multiplierLocked: true,
                    overrideSource: "credit-payment",
                    plaidPaymentChannel: channel,
                    paymentRail: (looksLikeACHBillPay(title) ? PaymentRail.ach : rail).rawValue,
                    paymentRailLocked: false
                )
            )
        }
    }

    private static func looksLikeACHBillPay(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower == "epay" || lower.contains("epay") || lower.contains("ach pmt")
            || lower.contains("ach payment") || lower.contains("e-pay")
    }

    /// Best-effort card label from a payment description.
    private static func inferCardName(from title: String) -> String? {
        let lower = title.lowercased()
        let brands = [
            ("apple card", "Apple Card"),
            ("amex", "Amex"),
            ("american express", "Amex"),
            ("chase", "Chase"),
            ("citi", "Citi"),
            ("capital one", "Capital One"),
            ("discover", "Discover"),
            ("prime visa", "Prime Visa"),
            ("wells fargo", "Wells Fargo")
        ]
        for (needle, label) in brands where lower.contains(needle) {
            return label
        }
        return nil
    }

    @MainActor
    private static func upsertAccounts(
        _ details: [PlaidAccountDetail],
        item: PlaidLinkedItem,
        institutionId: String?,
        modelContext: ModelContext
    ) -> Int {
        var count = 0
        for detail in details {
            // #Predicate only accepts simple local constants (not detail.account_id)
            let accountId = detail.account_id
            let name = detail.name ?? detail.official_name ?? item.institutionName
            let type = detail.type ?? "other"
            let current = detail.balances?.current ?? 0
            let available = detail.balances?.available
            let limit = detail.balances?.limit

            var descriptor = FetchDescriptor<BankAccount>(
                predicate: #Predicate<BankAccount> { account in
                    account.accountId == accountId
                }
            )
            descriptor.fetchLimit = 1

            if let existing = try? modelContext.fetch(descriptor).first {
                existing.itemId = item.id
                existing.name = name
                existing.officialName = detail.official_name
                existing.mask = detail.mask
                existing.type = type
                existing.subtype = detail.subtype
                existing.institutionName = item.institutionName
                existing.currentBalance = current
                existing.availableBalance = available
                existing.creditLimit = limit
                if let institutionId {
                    existing.institutionId = institutionId
                }
                existing.lastSyncedAt = Date()
                CardBenefitsStore.applyDepositoryRailRewards(to: existing)
            } else {
                let account = BankAccount(
                    accountId: accountId,
                    itemId: item.id,
                    name: name,
                    officialName: detail.official_name,
                    mask: detail.mask,
                    type: type,
                    subtype: detail.subtype,
                    institutionName: item.institutionName,
                    currentBalance: current,
                    availableBalance: available,
                    creditLimit: limit,
                    institutionId: institutionId,
                    lastSyncedAt: Date()
                )
                CardBenefitsStore.applyDepositoryRailRewards(to: account)
                modelContext.insert(account)
            }
            count += 1
        }

        // Drop local rows for this Item that Plaid no longer returns (deselected on Relink).
        pruneAccounts(forItemId: item.id, keepingAccountIds: Set(details.map(\.account_id)), modelContext: modelContext)

        // Seed Benefits rates for newly recognized products (won't overwrite saved profiles)
        let allAccounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        _ = CardBenefitsStore.autoApplyKnownProducts(accounts: allAccounts)

        return count
    }

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

    /// Same calendar day + amount + title + soft payment method → keep one expense row.
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
                // Prefer user locks, then a payment method still matched to a live account
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

    private static func transactionKeepScore(_ tx: Transaction, accounts: [BankAccount]) -> Int {
        var score = 0
        if tx.isCategoryLocked { score += 4 }
        if tx.isMultiplierLocked { score += 2 }
        if tx.isPaymentRailLocked { score += 1 }
        if BankAccount.matching(paymentMethod: tx.paymentMethod, in: accounts) != nil {
            score += 8
        }
        // Prefer non–Apple Card only when both are same method family (already grouped)
        return score
    }

    private static func normalizeDedupeText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Collapse “X Money Checking ···1234” vs “X Money Checking” for fingerprinting.
    private static func normalizePaymentMethodForDedupe(_ method: String) -> String {
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
            // Prefer existing institution id on any account for this item
            let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
            return all.first(where: { $0.itemId == item.id })?.institutionId
        }()
        let n = upsertAccounts(details, item: item, institutionId: institutionId, modelContext: modelContext)
        _ = cleanupStaleBankAccounts(modelContext: modelContext)
        return n
    }

    /// Merge `/liabilities/get` credit rows onto existing `BankAccount`s by account_id.
    @MainActor
    private static func applyCreditLiabilities(
        _ liabilities: [PlaidCreditLiability],
        modelContext: ModelContext
    ) -> Int {
        var count = 0
        let now = Date()
        for liability in liabilities {
            guard let accountId = liability.account_id, !accountId.isEmpty else { continue }

            var descriptor = FetchDescriptor<BankAccount>(
                predicate: #Predicate<BankAccount> { account in
                    account.accountId == accountId
                }
            )
            descriptor.fetchLimit = 1
            guard let account = try? modelContext.fetch(descriptor).first else { continue }

            account.isOverdue = liability.is_overdue
            account.lastPaymentAmount = liability.last_payment_amount
            account.lastPaymentDate = liability.last_payment_date.flatMap(parseDate)
            account.lastStatementIssueDate = liability.last_statement_issue_date.flatMap(parseDate)
            account.lastStatementBalance = liability.last_statement_balance
            account.minimumPaymentAmount = liability.minimum_payment_amount
            account.nextPaymentDueDate = liability.next_payment_due_date.flatMap(parseDate)
            account.liabilitiesSyncedAt = now

            // Reset APR slots then fill from payload
            account.purchaseApr = nil
            account.cashApr = nil
            account.balanceTransferApr = nil
            account.specialApr = nil
            for apr in liability.aprs ?? [] {
                guard let pct = apr.apr_percentage else { continue }
                switch (apr.apr_type ?? "").lowercased() {
                case "purchase_apr":
                    account.purchaseApr = pct
                case "cash_apr":
                    account.cashApr = pct
                case "balance_transfer_apr":
                    account.balanceTransferApr = pct
                case "special":
                    account.specialApr = pct
                default:
                    break
                }
            }
            count += 1
        }
        return count
    }

    // MARK: - Cleanup / delete helpers

    /// Re-home mis-filed spend/income that look like transfers or card payments.
    @MainActor
    private static func cleanLegacyMisclassifiedRows(modelContext: ModelContext) -> Int {
        var fixed = 0
        if let expenses = try? modelContext.fetch(FetchDescriptor<Transaction>()) {
            for row in expenses {
                let lower = row.title.lowercased()
                if PlaidCategoryMapper.looksLikeCardPaymentTitlePublic(lower)
                    || TransactionAnalytics.isExcludedFromSpendCategory(row.category) {
                    // Promote to proper bill-payment category + CreditCardPayment row
                    if !TransactionAnalytics.isExcludedFromSpendCategory(row.category) {
                        row.category = TransactionAnalytics.creditCardPaymentCategory
                        row.categoryLocked = true
                        row.multiplier = 0
                        row.multiplierLocked = true
                        row.overrideSource = row.overrideSource ?? "legacy-credit-payment"
                        fixed += 1
                    }
                    ensureCreditPaymentFromTransaction(row, modelContext: modelContext)
                    continue
                }
                if PlaidCategoryMapper.looksLikeNonSpendTitle(row.title) {
                    // Other transfers: drop from expense stream
                    modelContext.delete(row)
                    fixed += 1
                }
            }
        }
        if let income = try? modelContext.fetch(FetchDescriptor<Income>()) {
            for row in income where PlaidCategoryMapper.looksLikeNonSpendTitle(row.source) {
                modelContext.delete(row)
                fixed += 1
            }
        }
        return fixed
    }

    @MainActor
    private static func ensureCreditPaymentFromTransaction(
        _ row: Transaction,
        modelContext: ModelContext
    ) {
        let targetId = row.transactionId
        var descriptor = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { p in
                p.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1
        if (try? modelContext.fetch(descriptor).first) != nil { return }
        modelContext.insert(
            CreditCardPayment(
                transactionId: row.transactionId,
                amount: abs(row.amount),
                date: row.date,
                cardName: row.paymentMethod,
                sourceAccount: row.paymentMethod,
                title: row.title,
                creditAccountId: nil,
                institutionName: nil
            )
        )
    }

    @MainActor
    private static func deleteLocal(transactionID: String, modelContext: ModelContext) -> Bool {
        var any = false
        if deleteExpenseOnly(transactionID: transactionID, modelContext: modelContext) { any = true }
        if deleteIncomeOnly(transactionID: transactionID, modelContext: modelContext) { any = true }
        if deleteCreditPaymentOnly(transactionID: transactionID, modelContext: modelContext) { any = true }
        return any
    }

    @MainActor
    private static func deleteLocalExpenseOrIncomeOnly(
        transactionID: String,
        modelContext: ModelContext
    ) -> Bool {
        var any = false
        if deleteExpenseOnly(transactionID: transactionID, modelContext: modelContext) { any = true }
        if deleteIncomeOnly(transactionID: transactionID, modelContext: modelContext) { any = true }
        return any
    }

    @MainActor
    @discardableResult
    private static func deleteExpenseOnly(transactionID: String, modelContext: ModelContext) -> Bool {
        // Capture as local constant for #Predicate (parameter refs can fail on some toolchains)
        let targetId = transactionID
        var desc = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { row in
                row.transactionId == targetId
            }
        )
        desc.fetchLimit = 1
        if let row = try? modelContext.fetch(desc).first {
            modelContext.delete(row)
            return true
        }
        return false
    }

    @MainActor
    @discardableResult
    private static func deleteIncomeOnly(transactionID: String, modelContext: ModelContext) -> Bool {
        let targetId = transactionID
        var desc = FetchDescriptor<Income>(
            predicate: #Predicate<Income> { row in
                row.transactionId == targetId
            }
        )
        desc.fetchLimit = 1
        if let row = try? modelContext.fetch(desc).first {
            modelContext.delete(row)
            return true
        }
        return false
    }

    @MainActor
    @discardableResult
    private static func deleteCreditPaymentOnly(transactionID: String, modelContext: ModelContext) -> Bool {
        let targetId = transactionID
        var desc = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { row in
                row.transactionId == targetId
            }
        )
        desc.fetchLimit = 1
        if let row = try? modelContext.fetch(desc).first {
            modelContext.delete(row)
            return true
        }
        return false
    }

    private static func accountDisplayName(account: PlaidAccount, institution: String) -> String {
        let name = account.name ?? account.official_name ?? institution
        if let mask = account.mask, !mask.isEmpty {
            return "\(name) ···\(mask)"
        }
        return name
    }

    private static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}
