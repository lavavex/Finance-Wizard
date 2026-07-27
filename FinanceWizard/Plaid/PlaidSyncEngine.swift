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
        report.cleanedLegacy = cleanLegacyMisclassifiedRows(modelContext: modelContext)

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
                if let branding = try? await PlaidAPIClient.institutionBranding(institutionID: institutionId) {
                    InstitutionLogoCache.store(
                        institutionID: branding.institutionID,
                        name: branding.name,
                        logoBase64: branding.logoBase64,
                        primaryColorHex: branding.primaryColorHex
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
            // Remove from spend/income if previously mis-filed
            _ = deleteLocalExpenseOrIncomeOnly(
                transactionID: tx.transaction_id,
                modelContext: modelContext
            )
            upsertCreditPayment(
                tx: tx,
                title: title,
                date: date,
                paymentMethod: paymentMethod,
                accountType: accountType,
                institutionName: item.institutionName,
                modelContext: modelContext
            )
            report.creditPaymentsUpserted += 1

        case .spending:
            // Don't keep a parallel income row if type flipped
            deleteIncomeOnly(transactionID: tx.transaction_id, modelContext: modelContext)
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
        let railMultiplier = bankAccount?.rewardMultiplier(for: inferredRail)
        // Preference: vendor learn rule → account debit/ACH default → 1.0
        let mappedMultiplier = rule?.multiplier ?? railMultiplier ?? 1.0
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
                // Re-resolve with locked rail if user set one
                let rail = existing.effectivePaymentRail
                let mult = rule?.multiplier
                    ?? bankAccount?.rewardMultiplier(for: rail)
                    ?? 1.0
                existing.multiplier = mult
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
        let cardName = onCredit ? paymentMethod : inferCardName(from: title) ?? paymentMethod
        let sourceAccount = onCredit ? nil : paymentMethod
        let creditAccountId = onCredit ? tx.account_id : nil

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
            } else {
                modelContext.insert(
                    BankAccount(
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
                )
            }
            count += 1
        }
        return count
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

    /// Remove spend/income rows that look like transfers or card payments (legacy syncs).
    @MainActor
    private static func cleanLegacyMisclassifiedRows(modelContext: ModelContext) -> Int {
        var removed = 0
        if let expenses = try? modelContext.fetch(FetchDescriptor<Transaction>()) {
            for row in expenses where PlaidCategoryMapper.looksLikeNonSpendTitle(row.title) {
                modelContext.delete(row)
                removed += 1
            }
        }
        if let income = try? modelContext.fetch(FetchDescriptor<Income>()) {
            for row in income where PlaidCategoryMapper.looksLikeNonSpendTitle(row.source) {
                modelContext.delete(row)
                removed += 1
            }
        }
        return removed
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
