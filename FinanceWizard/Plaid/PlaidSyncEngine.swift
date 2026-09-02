//
//  PlaidSyncEngine.swift
//  Finance Wizard
//
//  Pulls /transactions/sync + /accounts/get for every linked Item.
//  Transfers / credit-card payments never enter Total Spend or Income.
//
//  HIGH-LEVEL SYNC CONTROL FLOW (syncAll → syncItem):
//  1. Require Plaid credentials; load all linked Items.
//  2. Optionally reset cursors (full re-download of history).
//  3. Clean legacy mis-filed rows + stale BankAccounts.
//  4. For each Item (syncItem):
//     a. Seed account type/label map from local BankAccounts.
//     b. /item/get → Relink status + liabilities product flag.
//     c. /accounts/get → upsert balances / account types.
//     d. Optional /transactions/refresh (paid add-on).
//     e. Loop /transactions/sync pages until has_more is false:
//        apply added+modified rows; delete removed ids; save cursor.
//     f. Institution logo branding.
//     g. /liabilities/get → APR / due dates on credit accounts.
//  5. modelContext.save() + reload all widgets.
//

import Foundation
import SwiftData
import WidgetKit

// MARK: - Sync report (UI summary)

/// Counts and messages returned after a full or partial sync.
struct PlaidSyncReport: Sendable {
    var itemLines: [String] = []
    var expensesUpserted: Int = 0
    var incomeUpserted: Int = 0
    var creditPaymentsUpserted: Int = 0
    var removed: Int = 0
    var pendingMerged: Int = 0
    var skippedTransfers: Int = 0
    var cleanedLegacy: Int = 0
    var accountsUpdated: Int = 0
    var liabilitiesUpdated: Int = 0
    var refreshedItems: Int = 0
    var warnings: [String] = []

    /// Multi-line human-readable summary for Settings / alerts.
    var summary: String {
        var lines: [String] = []
        lines.append(contentsOf: itemLines)
        lines.append("Expenses upserted: \(expensesUpserted)")
        lines.append("Income upserted: \(incomeUpserted)")
        lines.append("Card payments tracked: \(creditPaymentsUpserted)")
        if pendingMerged > 0 { lines.append("Pending→posted merged: \(pendingMerged)") }
        if skippedTransfers > 0 { lines.append("Skipped transfers: \(skippedTransfers)") }
        if cleanedLegacy > 0 { lines.append("Removed mis-filed transfers: \(cleanedLegacy)") }
        if accountsUpdated > 0 { lines.append("Accounts refreshed: \(accountsUpdated)") }
        if liabilitiesUpdated > 0 { lines.append("Credit details refreshed: \(liabilitiesUpdated)") }
        if refreshedItems > 0 { lines.append("Forced bank refresh: \(refreshedItems)") }
        if removed > 0 { lines.append("Removed by bank: \(removed)") }
        if !warnings.isEmpty {
            lines.append("Warnings:")
            lines.append(contentsOf: warnings.map { "• \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Account metadata cache

/// Lightweight per-account info used while classifying transactions.
/// Dictionary key is Plaid account_id.
private struct AccountMeta {
    var label: String
    var type: String
    var subtype: String
}

// MARK: - Sync engine

/// Orchestrates Plaid → local SwiftData sync for all linked banks.
enum PlaidSyncEngine {
    /// Soft-fail Plaid product codes (add-on not enabled / not ready / unsupported).
    /// When these appear, we log a warning and continue instead of aborting the whole sync.
    private static let softProductCodes: Set<String> = [
        "PRODUCTS_NOT_SUPPORTED",
        "PRODUCT_NOT_READY",
        "PRODUCT_NOT_ENABLED",
        "INVALID_PRODUCT",
        "ADDITIONAL_CONSENT_REQUIRED",
        "NO_LIABILITY_ACCOUNTS",
        "ITEM_PRODUCT_NOT_READY"
    ]

    // MARK: - Entry point: sync all Items

    /// Sync all linked Items. If `resetCursors`, start from full history again.
    /// - Parameter modelContext: SwiftData context for inserts/updates/deletes.
    /// - Parameter resetCursors: Empty every Item’s cursor before syncing.
    /// - Parameter forceRefresh: call `/transactions/refresh` before sync (paid add-on; soft-fails).
    /// - Parameter includePending: store pending txs (merged to posted via `pending_transaction_id`).
    /// - Parameter progress: Optional UI callback with status strings (e.g. "Syncing Chase…").
    /// - Returns: Aggregated PlaidSyncReport for display.
    @MainActor
    static func syncAll(
        modelContext: ModelContext,
        resetCursors: Bool = false,
        includePending: Bool = true,
        forceRefresh: Bool = false,
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

        // Empty cursors → next /transactions/sync returns full history for each Item.
        if resetCursors {
            for i in items.indices {
                items[i].transactionsCursor = ""
            }
            PlaidItemStore.saveItems(items)
            items = PlaidItemStore.loadItems()
        }

        var report = PlaidSyncReport()

        // Drop older rows that were stored as spend/income but look like transfers/payments
        // PERF: cleanLegacyMisclassifiedRows full-scans every Transaction and Income row with
        // ~20 string ops each, so it grew with history and re-ran on every sync. The rules it
        // applies only change when the classifier changes — run it once per classifier version.
        VendorRulesStore.removeBillPayMisrules()
        // Rows stored before day strings were parsed locally sit at UTC midnight — a day early.
        if UserDefaults.standard.integer(forKey: dayAnchorVersionKey) < dayAnchorVersion {
            _ = reanchorStoredDays(modelContext: modelContext)
            UserDefaults.standard.set(dayAnchorVersion, forKey: dayAnchorVersionKey)
        }
        if UserDefaults.standard.integer(forKey: legacyCleanupVersionKey) < legacyCleanupVersion {
            report.cleanedLegacy = cleanLegacyMisclassifiedRows(modelContext: modelContext)
            UserDefaults.standard.set(legacyCleanupVersion, forKey: legacyCleanupVersionKey)
        }
        // Stale BankAccounts from unlinked/replaced Items (e.g. duped X Money after Relink)
        _ = cleanupStaleBankAccounts(modelContext: modelContext)

        // Preload accounts once for payment-method matching (avoids N fetches per tx).
        let allAccounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []

        // One Item at a time: failures become warnings so other banks still sync.
        for item in items {
            progress?("Syncing \(item.institutionName)…")
            do {
                let itemReport = try await syncItem(
                    item,
                    modelContext: modelContext,
                    includePending: includePending,
                    forceRefresh: forceRefresh,
                    allAccounts: allAccounts,
                    progress: progress
                )
                report.expensesUpserted += itemReport.expensesUpserted
                report.incomeUpserted += itemReport.incomeUpserted
                report.creditPaymentsUpserted += itemReport.creditPaymentsUpserted
                report.removed += itemReport.removed
                report.pendingMerged += itemReport.pendingMerged
                report.skippedTransfers += itemReport.skippedTransfers
                report.accountsUpdated += itemReport.accountsUpdated
                report.liabilitiesUpdated += itemReport.liabilitiesUpdated
                report.refreshedItems += itemReport.refreshedItems
                report.warnings.append(contentsOf: itemReport.warnings)
                report.itemLines.append(
                    "\(item.institutionName): +\(itemReport.expensesUpserted) exp / +\(itemReport.incomeUpserted) inc / \(itemReport.creditPaymentsUpserted) card pmts"
                )
            } catch {
                // Per-item failure: record and continue with remaining banks.
                report.warnings.append("\(item.institutionName): \(error.localizedDescription)")
                report.itemLines.append("\(item.institutionName): failed")
            }
        }

        let plans = (try? modelContext.fetch(FetchDescriptor<PayoffPlan>())) ?? []
        let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        PayoffPlanProgress.applyStatementProgress(plans: plans, accounts: accounts)

        try modelContext.save()
        WidgetCenter.shared.reloadAllTimelines()
        return report
    }

    // MARK: - Per-Item sync

    /// Full pipeline for one linked bank: status → balances → tx pages → logo → liabilities → recurring.
    /// - Parameter allAccounts: Preloaded BankAccounts (payment-method matching / labels).
    @MainActor
    private static func syncItem(
        _ item: PlaidLinkedItem,
        modelContext: ModelContext,
        includePending: Bool,
        forceRefresh: Bool,
        allAccounts: [BankAccount],
        progress: ((String) -> Void)?
    ) async throws -> PlaidSyncReport {
        var report = PlaidSyncReport()
        // Empty cursor = full history from Plaid.
        var cursor: String? = item.transactionsCursor.isEmpty ? nil : item.transactionsCursor
        // If Plaid mutates mid-pagination, restart from this safe point.
        var pageStartCursor = cursor
        var hasMore = true
        var accountMeta: [String: AccountMeta] = [:]
        var safety = 0
        // Refresh account list after balances upsert so later txs see new cards.
        var accountsCache = allAccounts

        // Seed account types/labels BEFORE the tx loop. Incremental /transactions/sync
        // pages often omit `accounts`, so without this credit-side payments (amount < 0)
        // get mis-filed as "Other Income".
        for account in allAccounts where account.itemId == item.id {
            accountMeta[account.accountId] = AccountMeta(
                label: account.plaidDisplayName,
                type: account.type,
                subtype: account.subtype ?? ""
            )
        }

        // --- Step A: Item health (login required → Relink) + product access (liabilities) ---
        progress?("\(item.institutionName): status…")
        var institutionId: String?
        var itemHasLiabilitiesProduct = false
        do {
            let status = try await PlaidAPIClient.itemGet(accessToken: item.accessToken)
            institutionId = status.institutionID
            itemHasLiabilitiesProduct = status.hasLiabilitiesProduct
            PlaidItemStore.updateItemStatus(
                itemID: item.id,
                errorCode: status.errorCode,
                errorMessage: status.errorMessage
            )
            if status.needsRelink {
                let msg = status.errorMessage ?? status.errorCode ?? "Login required"
                report.warnings.append(
                    "\(item.institutionName): needs Relink — \(msg)"
                )
            }
            if !itemHasLiabilitiesProduct {
                report.warnings.append(
                    "\(item.institutionName): Liabilities not on this Item yet — swipe Relink in Settings (adds APR/due dates product), then Sync."
                )
            }
        } catch {
            report.warnings.append("\(item.institutionName) status: \(error.localizedDescription)")
        }

        // --- Step B: Fresh balances + account types early so classification has credit/depository flags ---
        progress?("\(item.institutionName): balances…")
        do {
            let details = try await PlaidAPIClient.accountsGet(accessToken: item.accessToken)
            report.accountsUpdated = upsertAccounts(
                details,
                item: item,
                institutionId: institutionId,
                modelContext: modelContext
            )
            accountsCache = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? accountsCache
            for detail in details {
                let label = {
                    let name = detail.name ?? detail.official_name ?? item.institutionName
                    if let mask = detail.mask, !mask.isEmpty { return "\(name) ···\(mask)" }
                    return name
                }()
                accountMeta[detail.account_id] = AccountMeta(
                    label: label,
                    type: detail.type ?? "",
                    subtype: detail.subtype ?? ""
                )
            }
        } catch {
            report.warnings.append("\(item.institutionName) balances: \(error.localizedDescription)")
        }

        // --- Step C: Optional on-demand bank pull before cursor sync ---
        if forceRefresh {
            progress?("\(item.institutionName): force refresh…")
            do {
                _ = try await PlaidAPIClient.transactionsRefresh(accessToken: item.accessToken)
                report.refreshedItems = 1
            } catch {
                if case PlaidAPIError.http(_, let code, _) = error,
                   let code, softProductCodes.contains(code) {
                    report.warnings.append(
                        "\(item.institutionName): force refresh unavailable (\(code)). Using normal sync."
                    )
                } else {
                    report.warnings.append(
                        "\(item.institutionName) refresh: \(error.localizedDescription)"
                    )
                }
            }
        }

        // --- Step D: Cursor pagination loop for /transactions/sync ---
        // While has_more, request next page; apply added/modified; delete removed.
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
                // Plaid race: data changed mid-pagination → restart from pageStartCursor.
                if case PlaidAPIError.http(_, let code, _) = error,
                   code == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" {
                    cursor = pageStartCursor
                    continue
                }
                throw error
            }

            // Some pages include accounts[]; merge into our meta map.
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
                    allAccounts: accountsCache,
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
                // Successful full pass — next mutation restart can use this cursor.
                pageStartCursor = cursor
            }
        }

        // Persist opaque cursor so the next sync only gets deltas.
        if let cursor, !cursor.isEmpty {
            PlaidItemStore.updateCursor(itemID: item.id, cursor: cursor)
        }

        // --- Step E: Institution logo (Plaid metadata, not product card photos) ---
        if let institutionId {
            progress?("\(item.institutionName): branding…")
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

        // --- Step F: Credit APR / due dates / min payment (Liabilities product) ---
        progress?("\(item.institutionName): credit details…")
        let creditAccountCount = ((try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? [])
            .filter { $0.itemId == item.id && $0.isCredit }
            .count
        do {
            let creditLiabilities = try await PlaidAPIClient.liabilitiesGet(accessToken: item.accessToken)
            report.liabilitiesUpdated = applyCreditLiabilities(
                creditLiabilities,
                modelContext: modelContext
            )
            if creditAccountCount > 0 && creditLiabilities.isEmpty {
                report.warnings.append(
                    "\(item.institutionName): \(creditAccountCount) credit card(s) linked but Plaid returned no APR/due-date rows. Enable **Liabilities** in Plaid Dashboard → Products, Relink and keep credit cards selected / share liability data, then Sync again."
                )
            } else if creditAccountCount > 0 && report.liabilitiesUpdated == 0 {
                report.warnings.append(
                    "\(item.institutionName): liabilities payload didn’t match local credit accounts (account_id mismatch). Full re-sync or Relink may help."
                )
            }
        } catch {
            if case PlaidAPIError.http(_, let code, let message) = error {
                let code = code ?? ""
                if code == "PRODUCT_NOT_READY" || code == "ITEM_PRODUCT_NOT_READY" {
                    report.warnings.append(
                        "\(item.institutionName): credit details still preparing — Sync again in a few minutes."
                    )
                } else if code == "PRODUCTS_NOT_SUPPORTED" {
                    if creditAccountCount > 0 {
                        report.warnings.append(
                            "\(item.institutionName): Plaid doesn’t support Liabilities for these credit accounts (APR/due date unavailable)."
                        )
                    }
                    // Silent for depository-only Items.
                } else if code == "NO_LIABILITY_ACCOUNTS" {
                    if creditAccountCount > 0 {
                        report.warnings.append(
                            "\(item.institutionName): no liability data shared — Relink, select your credit cards, and allow liability/details sharing in the bank OAuth screen."
                        )
                    }
                } else if code == "PRODUCT_NOT_ENABLED" || code == "INVALID_PRODUCT" {
                    report.warnings.append(
                        "\(item.institutionName): enable **Liabilities** under Plaid Dashboard → Team → Products (then Relink + Sync)."
                    )
                } else if code == "ADDITIONAL_CONSENT_REQUIRED" {
                    report.warnings.append(
                        "\(item.institutionName): Plaid needs your consent for credit details (ADDITIONAL_CONSENT_REQUIRED). Settings → Relink this bank, accept the data-sharing screen for liabilities, then Sync."
                    )
                } else if softProductCodes.contains(code) {
                    report.warnings.append("\(item.institutionName) liabilities: \(message)")
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

    /// Classify a single Plaid row and upsert/delete the matching local models.
    /// Flow: merge pending twin → resolve title/date/account → classify → switch on kind.
    @MainActor
    private static func applyTransaction(
        _ tx: PlaidTransaction,
        item: PlaidLinkedItem,
        accountMeta: [String: AccountMeta],
        allAccounts: [BankAccount],
        modelContext: ModelContext,
        report: inout PlaidSyncReport
    ) {
        // Posted row supersedes its pending twin (different transaction_id).
        if let pendingId = tx.pending_transaction_id,
           !pendingId.isEmpty,
           pendingId != tx.transaction_id {
            if deleteLocal(transactionID: pendingId, modelContext: modelContext) {
                report.pendingMerged += 1
            }
        }

        // Prefer merchant_name, then name, then original_description.
        let title = (tx.merchant_name?.isEmpty == false ? tx.merchant_name : tx.name)
            ?? tx.original_description
            ?? "Transaction"

        if abs(tx.amount) < 0.005 {
            _ = deleteLocal(transactionID: tx.transaction_id, modelContext: modelContext)
            return
        }

        guard let date = parseDate(tx.date) else { return }
        // Prefer authorized date for display; keep posted `date` as bank settle day.
        let authorizedDate = tx.authorized_date.flatMap(parseDate)

        // Prefer sync-page meta, then local BankAccount (covers missing accounts[] pages).
        let bank = allAccounts.first { $0.accountId == tx.account_id }
        let meta = accountMeta[tx.account_id]
        let paymentMethod = meta?.label
            ?? bank?.plaidDisplayName
            ?? item.paymentMethodLabel
        let accountType: String? = {
            if let t = meta?.type, !t.isEmpty { return t }
            return bank?.type
        }()
        let accountSubtype: String? = {
            if let s = meta?.subtype, !s.isEmpty { return s }
            return bank?.subtype
        }()

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
                allAccounts: allAccounts,
                modelContext: modelContext
            )
            upsertCreditPaymentExpense(
                tx: tx,
                title: title,
                date: date,
                authorizedDate: authorizedDate,
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
                authorizedDate: authorizedDate,
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

        case .adjustment:
            deleteIncomeOnly(transactionID: tx.transaction_id, modelContext: modelContext)
            deleteCreditPaymentOnly(transactionID: tx.transaction_id, modelContext: modelContext)
            let pfc = tx.personal_finance_category?.detailed
            let category = PayoffPlanRecognition.looksLikeLoanDisbursement(title: title, pfc: pfc)
                ? KnownCategory.loan.rawValue
                : KnownCategory.refund.rawValue
            upsertAdjustment(
                tx: tx,
                title: title,
                date: date,
                authorizedDate: authorizedDate,
                paymentMethod: paymentMethod,
                category: category,
                modelContext: modelContext
            )
            report.expensesUpserted += 1
        }
    }

    // MARK: - Upserts (expense / income / credit payment)

    /// Insert or update a local expense Transaction from a Plaid spend row.
    /// Respects user locks (category / payment rail) when present.
    @MainActor
    private static func upsertExpense(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        authorizedDate: Date?,
        paymentMethod: String,
        accountId: String,
        modelContext: ModelContext
    ) {
        // #Predicate cannot capture function parameters directly.
        let targetId = tx.transaction_id
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { row in
                row.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1

        let defaultCategory = PlaidCategoryMapper.expenseCategory(
            from: tx.personal_finance_category,
            title: title
        )
        let isMyLoan = PayoffPlanRecognition.looksLikeLoanDisbursement(title: title)
        // Vendor learn-rule may override the category.
        let rule = isMyLoan ? nil : VendorRulesStore.match(vendor: title, paymentMethod: paymentMethod)
        let mappedCategory = isMyLoan ? KnownCategory.loan.rawValue : (rule?.category ?? defaultCategory)
        let channel = tx.payment_channel
        let inferredRail = PaymentRail.infer(plaidChannel: channel, title: title)
        // App stores expenses as negative amounts.
        let amount = -abs(tx.amount)
        let pending = tx.pending ?? false

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = title
            existing.amount = amount
            existing.date = date
            existing.paymentMethod = paymentMethod
            existing.plaidPaymentChannel = channel
            applyEnrichment(to: existing, from: tx, authorizedDate: authorizedDate, isPending: pending)
            // Purchases Plaid tagged as CREDIT_CARD_PAYMENT (e.g. Best Buy in-store).
            // FIX: this is the same rescue as in cleanLegacyMisclassifiedRows, and the
            // `!looksLikeNonSpendTitle` guard added there was never mirrored here — so a
            // transfer-worded bill pay reaching this path would have its payment row deleted
            // and its category unlocked. It also ignored the user's category lock, which the
            // block below honours. Both corrected.
            if TransactionAnalytics.isCreditCardPaymentCategory(existing.category),
               !existing.isCategoryLocked,
               !PlaidCategoryMapper.looksLikeCardPaymentTitlePublic(title),
               !PlaidCategoryMapper.looksLikeNonSpendTitle(title) {
                existing.category = mappedCategory
                existing.categoryLocked = false
                existing.overrideSource = nil
                deleteCreditPaymentOnly(transactionID: targetId, modelContext: modelContext)
            }
            if isMyLoan {
                // Reclassify old “bill pay” filings of My Chase Loan.
                existing.category = KnownCategory.loan.rawValue
                existing.categoryLocked = true
                if existing.overrideSource == "credit-payment"
                    || existing.overrideSource == "legacy-credit-payment" {
                    existing.overrideSource = "my-loan"
                }
            }
            // Locks: user edits win over automatic re-classification on later syncs.
            if !existing.isPaymentRailLocked {
                existing.paymentRail = inferredRail.rawValue
            }
            if !existing.isCategoryLocked {
                existing.category = mappedCategory
            }
        } else {
            let row = Transaction(
                transactionId: targetId,
                title: title,
                amount: amount,
                date: date,
                category: mappedCategory,
                paymentMethod: paymentMethod,
                categoryLocked: isMyLoan,
                overrideSource: isMyLoan ? "my-loan" : (rule != nil ? "rule" : nil),
                plaidPaymentChannel: channel,
                paymentRail: inferredRail.rawValue,
                paymentRailLocked: false,
                authorizedDate: authorizedDate,
                pendingTransactionId: tx.pending_transaction_id,
                plaidAccountId: tx.account_id,
                merchantEntityId: tx.resolvedMerchantEntityID,
                merchantName: tx.merchant_name,
                logoURL: tx.resolvedLogoURL,
                website: tx.resolvedWebsite,
                pfcConfidence: tx.personal_finance_category?.confidence_level,
                isPending: pending
            )
            modelContext.insert(row)
        }
    }

    /// Card refund / loan proceeds: visible ledger row, excluded from spend and income.
    @MainActor
    private static func upsertAdjustment(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        authorizedDate: Date?,
        paymentMethod: String,
        category: String,
        modelContext: ModelContext
    ) {
        let targetId = tx.transaction_id
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { row in
                row.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1
        let amount = abs(tx.amount)
        let pending = tx.pending ?? false
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = title
            existing.amount = amount
            existing.date = date
            existing.paymentMethod = paymentMethod
            existing.category = category
            existing.categoryLocked = true
            existing.overrideSource = "adjustment"
            applyEnrichment(to: existing, from: tx, authorizedDate: authorizedDate, isPending: pending)
        } else {
            let row = Transaction(
                transactionId: targetId,
                title: title,
                amount: amount,
                date: date,
                category: category,
                paymentMethod: paymentMethod,
                categoryLocked: true,
                overrideSource: "adjustment",
                plaidPaymentChannel: tx.payment_channel,
                authorizedDate: authorizedDate,
                pendingTransactionId: tx.pending_transaction_id,
                plaidAccountId: tx.account_id,
                merchantEntityId: tx.resolvedMerchantEntityID,
                merchantName: tx.merchant_name,
                logoURL: tx.resolvedLogoURL,
                website: tx.resolvedWebsite,
                pfcConfidence: tx.personal_finance_category?.confidence_level,
                isPending: pending
            )
            modelContext.insert(row)
        }
    }

    /// Map Plaid enrichment fields onto a local expense row (logo, website, pending, etc.).
    private static func applyEnrichment(
        to row: Transaction,
        from tx: PlaidTransaction,
        authorizedDate: Date?,
        isPending: Bool
    ) {
        if let authorizedDate {
            row.authorizedDate = authorizedDate
        }
        if let pendingId = tx.pending_transaction_id, !pendingId.isEmpty {
            row.pendingTransactionId = pendingId
        }
        row.plaidAccountId = tx.account_id
        if let entity = tx.resolvedMerchantEntityID { row.merchantEntityId = entity }
        if let name = tx.merchant_name, !name.isEmpty { row.merchantName = name }
        if let logo = tx.resolvedLogoURL { row.logoURL = logo }
        if let site = tx.resolvedWebsite { row.website = site }
        if let conf = tx.personal_finance_category?.confidence_level {
            row.pfcConfidence = conf
        }
        row.isPending = isPending
    }


    /// Insert or update an Income model for a Plaid money-in row.
    /// Income amounts are stored positive (abs of Plaid’s negative inflow).
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

    /// Insert or update a CreditCardPayment tracking row (payoff UI, not Total Spend).
    @MainActor
    private static func upsertCreditPayment(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        paymentMethod: String,
        accountType: String?,
        institutionName: String,
        allAccounts: [BankAccount],
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
        // Resolve the mask once — it was looked up separately for the name and for the id.
        let maskMatch = maskFromTitle.flatMap { findCreditAccount(mask: $0, in: allAccounts) }
        let cardName: String = {
            if onCredit { return paymentMethod }
            if let mask = maskFromTitle {
                // Prefer a real linked credit account label when mask matches
                if let maskMatch { return maskMatch.plaidDisplayName }
                return inferCardName(from: title) ?? "Card ···\(mask)"
            }
            return inferCardName(from: title) ?? paymentMethod
        }()
        let sourceAccount = onCredit ? nil : paymentMethod
        let creditAccountId: String? = {
            if onCredit { return tx.account_id }
            return maskMatch?.accountId
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

    /// PERF: this used to run a full `BankAccount` fetch on every call, and
    /// `upsertCreditPayment` calls it twice per payment row — roughly 480 whole-table reads
    /// per sync at this account's volume. The caller already holds the preloaded array.
    /// OLD: let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
    private static func findCreditAccount(mask: String, in accounts: [BankAccount]) -> BankAccount? {
        accounts.first { $0.isCredit && $0.mask == mask }
    }

    /// List-visible expense row for a bill payment; category is excluded from Total Spend.
    /// Locks the category so learn-rules cannot reclassify EPAY as Shopping.
    @MainActor
    private static func upsertCreditPaymentExpense(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        authorizedDate: Date?,
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
        let pending = tx.pending ?? false

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = title
            existing.amount = amount
            existing.date = date
            existing.paymentMethod = paymentMethod
            existing.plaidPaymentChannel = channel
            // Bill pays always use this category (fixes mis-learns like EPAY → Shopping)
            existing.category = category
            existing.categoryLocked = true
            if !existing.isPaymentRailLocked {
                // ACH bill-pay codes (EPAY) should not stay as debit
                existing.paymentRail = looksLikeACHBillPay(title) ? PaymentRail.ach.rawValue : rail.rawValue
            }
            existing.overrideSource = "credit-payment"
            applyEnrichment(to: existing, from: tx, authorizedDate: authorizedDate, isPending: pending)
        } else {
            modelContext.insert(
                Transaction(
                    transactionId: targetId,
                    title: title,
                    amount: amount,
                    date: date,
                    category: category,
                    paymentMethod: paymentMethod,
                    categoryLocked: true,
                    overrideSource: "credit-payment",
                    plaidPaymentChannel: channel,
                    paymentRail: (looksLikeACHBillPay(title) ? PaymentRail.ach : rail).rawValue,
                    paymentRailLocked: false,
                    authorizedDate: authorizedDate,
                    pendingTransactionId: tx.pending_transaction_id,
                    plaidAccountId: tx.account_id,
                    merchantEntityId: tx.resolvedMerchantEntityID,
                    merchantName: tx.merchant_name,
                    logoURL: tx.resolvedLogoURL,
                    website: tx.resolvedWebsite,
                    pfcConfidence: tx.personal_finance_category?.confidence_level,
                    isPending: pending
                )
            )
        }
    }

    // MARK: - Recurring streams


    /// True for ACH bill-pay codes that should use PaymentRail.ach.
    private static func looksLikeACHBillPay(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower == "epay" || lower.contains("epay") || lower.contains("ach pmt")
            || lower.contains("ach payment") || lower.contains("e-pay")
    }

    /// Best-effort card label from a payment description.
    private static func inferCardName(from title: String) -> String? {
        let lower = title.lowercased()
        let brands = [
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

    // MARK: - Accounts upsert / prune / dedupe

    /// Create or update BankAccount rows from `/accounts/get`, prune deselected accounts,
    /// and seed known card benefits profiles.
    @MainActor
    // Called from PlaidSyncMaintenance (reconcileItemAccounts), so not file-private.
    static func upsertAccounts(
        _ details: [PlaidAccountDetail],
        item: PlaidLinkedItem,
        institutionId: String?,
        modelContext: ModelContext
    ) -> Int {
        var count = 0
        for detail in details {
            // #Predicate only accepts simple local constants (not `detail.account_id`).
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
                modelContext.insert(account)
            }
            count += 1
        }

        // Drop local rows for this Item that Plaid no longer returns (deselected on Relink).
        pruneAccounts(forItemId: item.id, keepingAccountIds: Set(details.map(\.account_id)), modelContext: modelContext)

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
            // FIX: Chase returns 0 rather than omitting the field, and Optional(0.0) is
            // non-nil — so every "if let min = minimumPaymentAmount" fallback was unreachable
            // and the Accounts screen printed "Min $0.00" on a card carrying $4,000.
            // Normalise once here so no display site has to special-case it.
            // OLD: account.minimumPaymentAmount = liability.minimum_payment_amount
            account.minimumPaymentAmount = liability.minimum_payment_amount
                .flatMap { $0 > 0.005 ? $0 : nil }
            account.nextPaymentDueDate = liability.next_payment_due_date.flatMap(parseDate)
            account.liabilitiesSyncedAt = now

            // Reset APR slots then fill from payload
            account.purchaseApr = nil
            account.cashApr = nil
            account.balanceTransferApr = nil
            account.specialApr = nil
            for apr in liability.aprs ?? [] {
                guard let pct = apr.apr_percentage else { continue }
                let t = (apr.apr_type ?? "").lowercased()
                // Plaid uses purchase_apr / cash_apr / …; accept a few variants.
                if t.contains("purchase") {
                    account.purchaseApr = pct
                } else if t.contains("cash") {
                    account.cashApr = pct
                } else if t.contains("balance_transfer") || t.contains("balance transfer") {
                    account.balanceTransferApr = pct
                } else if t.contains("special") || t.contains("promo") {
                    // FIX: this assigned unconditionally, so with several special APRs —
                    // routine on Amex, where each Plan It plan reports one — only the last
                    // entry in the payload survived, and CardDetailView defaulted a promo
                    // payoff plan off whichever one that happened to be. There is one slot,
                    // so keep the lowest: that is the promo rate the user is tracking.
                    // OLD: account.specialApr = pct
                    account.specialApr = min(account.specialApr ?? pct, pct)
                } else if account.purchaseApr == nil {
                    // Unknown type → first unknown becomes purchase APR so something shows.
                    account.purchaseApr = pct
                }
            }
            count += 1
        }
        return count
    }

    // MARK: - Cleanup / delete helpers

    /// Bump when the classifier changes so the one-off repair pass runs again.
    /// v2: bill-pay vs loan-disbursement ordering, issuer credits, plan fees.
    /// v3: stop the purchase-rescue branch deleting payment rows for transfer-worded bill pays.
    /// v4: drop payment rows mirrored for Loan / Refund / Installment edits.
    static let legacyCleanupVersion = 4
    static let legacyCleanupVersionKey = "plaid.legacyCleanup.v"

    /// Re-home mis-filed spend/income that look like transfers or card payments.
    /// Runs at the start of syncAll so older imports get corrected before new pages apply.
    @MainActor
    private static func cleanLegacyMisclassifiedRows(modelContext: ModelContext) -> Int {
        var fixed = 0
        if let expenses = try? modelContext.fetch(FetchDescriptor<Transaction>()) {
            for row in expenses {
                if abs(row.amount) < 0.005
                    || row.title.lowercased().contains("daily cash adjustment") {
                    modelContext.delete(row)
                    fixed += 1
                    continue
                }
                let lower = row.title.lowercased()
                if PayoffPlanRecognition.looksLikeInstallmentBillingTitle(row.title),
                   !TransactionAnalytics.isExcludedFromSpendCategory(row.category)
                    || row.category.caseInsensitiveCompare(TransactionAnalytics.installmentCategory) != .orderedSame {
                    row.category = TransactionAnalytics.installmentCategory
                    row.categoryLocked = true
                    fixed += 1
                    continue
                }
                if !row.isCategoryLocked {
                    let refined = TitleCategoryHints.refine(category: row.category, title: row.title)
                    if refined != row.category {
                        row.category = refined
                        fixed += 1
                    }
                }
                if let known = KnownCategory.canonicalName(for: row.category),
                   known != row.category,
                   !row.isCategoryLocked {
                    row.category = known
                    fixed += 1
                }
                // Repair rows a previous build mis-filed: the loan-disbursement PFC check
                // used to outrank the bill-pay check, so card payments were stored as
                // positive "Loan" adjustments and their CreditCardPayment rows deleted.
                // A card-payment title on an adjustment row is always the payment.
                if row.overrideSource == "adjustment",
                   row.category.caseInsensitiveCompare(KnownCategory.loan.rawValue) == .orderedSame,
                   PlaidCategoryMapper.looksLikeCardPaymentTitlePublic(lower) {
                    row.category = TransactionAnalytics.creditCardPaymentCategory
                    row.categoryLocked = true
                    row.amount = -abs(row.amount)
                    row.overrideSource = "legacy-credit-payment"
                    ensureCreditPaymentFromTransaction(row, modelContext: modelContext)
                    fixed += 1
                    continue
                }

                // A payment row must only exist for a card payment. Editing a charge to Loan,
                // Refund or Installment used to mirror one, so drop any that linger.
                if !TransactionAnalytics.isCreditCardPaymentCategory(row.category),
                   TransactionAnalytics.isExcludedFromSpendCategory(row.category) {
                    if deleteCreditPaymentOnly(transactionID: row.transactionId, modelContext: modelContext) {
                        fixed += 1
                    }
                    continue
                }

                // Only real bill-pay titles/categories — not Loan / Refund / Installment.
                if PlaidCategoryMapper.looksLikeCardPaymentTitlePublic(lower)
                    || TransactionAnalytics.isCreditCardPaymentCategory(row.category) {
                    // FIX: this rescues a purchase Plaid mis-tagged as CREDIT_CARD_PAYMENT
                    // (a Best Buy swipe, say) by re-categorising it and deleting the mirrored
                    // payment row. "The title doesn't look like a payment" was far too broad a
                    // test for "this is a purchase": a checking-side bill pay posts as
                    // "Ach Deposit Internet Transfer From Account E", which matches no payment
                    // needle — so 86 real payments ($29,152) had their CreditCardPayment rows
                    // deleted and were re-filed as Shopping, after which the transfer rule
                    // below removed the transactions entirely on the next pass. Require the
                    // title to not read as a transfer / non-spend descriptor first.
                    if TransactionAnalytics.isCreditCardPaymentCategory(row.category),
                       !PlaidCategoryMapper.looksLikeCardPaymentTitlePublic(lower),
                       !PlaidCategoryMapper.looksLikeNonSpendTitle(row.title) {
                        row.category = TitleCategoryHints.fromTitleKeywords(row.title)
                            ?? KnownCategory.shopping.rawValue
                        row.categoryLocked = false
                        row.overrideSource = nil
                        deleteCreditPaymentOnly(transactionID: row.transactionId, modelContext: modelContext)
                        fixed += 1
                        continue
                    }
                    if !TransactionAnalytics.isCreditCardPaymentCategory(row.category) {
                        row.category = TransactionAnalytics.creditCardPaymentCategory
                        row.categoryLocked = true
                        row.overrideSource = row.overrideSource ?? "legacy-credit-payment"
                        fixed += 1
                    }
                    ensureCreditPaymentFromTransaction(row, modelContext: modelContext)
                    continue
                }
                if PlaidCategoryMapper.looksLikeNonSpendTitle(row.title) {
                    modelContext.delete(row)
                    fixed += 1
                }
            }
        }
        if let income = try? modelContext.fetch(FetchDescriptor<Income>()) {
            for row in income {
                let lower = row.source.lowercased()
                let pfc = row.pfc
                if PayoffPlanRecognition.looksLikeLoanDisbursement(title: row.source, pfc: pfc) {
                    let method = row.accountDisplay
                    let id = row.transactionId
                    let title = row.source
                    let amount = abs(row.amount)
                    let date = row.date
                    modelContext.delete(row)
                    ensureAdjustmentFromParts(
                        transactionId: id,
                        title: title,
                        amount: amount,
                        date: date,
                        paymentMethod: method,
                        category: KnownCategory.loan.rawValue,
                        modelContext: modelContext
                    )
                    fixed += 1
                    continue
                }
                if incomeLooksLikeCardAccount(row) {
                    let method = row.accountDisplay
                    let id = row.transactionId
                    let title = row.source
                    let amount = abs(row.amount)
                    let date = row.date
                    modelContext.delete(row)
                    if PlaidCategoryMapper.looksLikeCardPaymentTitlePublic(lower) {
                        ensureCreditPaymentFromParts(
                            transactionId: id,
                            title: title,
                            amount: amount,
                            date: date,
                            paymentMethod: method,
                            modelContext: modelContext
                        )
                    } else {
                        ensureAdjustmentFromParts(
                            transactionId: id,
                            title: title,
                            amount: amount,
                            date: date,
                            paymentMethod: method,
                            category: KnownCategory.refund.rawValue,
                            modelContext: modelContext
                        )
                    }
                    fixed += 1
                    continue
                }
                if PlaidCategoryMapper.looksLikeCardPaymentTitlePublic(lower)
                    || PlaidCategoryMapper.looksLikeNonSpendTitle(row.source) {
                    let id = row.transactionId
                    let title = row.source
                    let amount = abs(row.amount)
                    let date = row.date
                    let method = row.accountDisplay
                    modelContext.delete(row)
                    ensureCreditPaymentFromParts(
                        transactionId: id,
                        title: title,
                        amount: amount,
                        date: date,
                        paymentMethod: method,
                        modelContext: modelContext
                    )
                    fixed += 1
                }
            }
        }
        return fixed
    }

    private static func incomeLooksLikeCardAccount(_ row: Income) -> Bool {
        let n = (row.accountName ?? "") + " " + (row.sourceInstitution ?? "")
        return CardIssuerCatalog.looksLikeCreditAccountName(n)
            || n.lowercased().contains("credit card")
            || n.lowercased().contains("apple card")
    }

    /// Visible Loan / Refund row converted from mis-filed Income.
    @MainActor
    private static func ensureAdjustmentFromParts(
        transactionId: String,
        title: String,
        amount: Double,
        date: Date,
        paymentMethod: String,
        category: String,
        modelContext: ModelContext
    ) {
        let targetId = transactionId
        var txDesc = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { t in
                t.transactionId == targetId
            }
        )
        txDesc.fetchLimit = 1
        if let existing = try? modelContext.fetch(txDesc).first {
            existing.title = title
            existing.amount = abs(amount)
            existing.date = date
            existing.paymentMethod = paymentMethod
            existing.category = category
            existing.categoryLocked = true
            existing.overrideSource = "adjustment"
        } else {
            modelContext.insert(
                Transaction(
                    transactionId: transactionId,
                    title: title,
                    amount: abs(amount),
                    date: date,
                    category: category,
                    paymentMethod: paymentMethod,
                    categoryLocked: true,
                    overrideSource: "adjustment"
                )
            )
        }
    }

    /// Create CreditCardPayment + excluded-spend Transaction from loose fields (legacy income cleanup).
    @MainActor
    private static func ensureCreditPaymentFromParts(
        transactionId: String,
        title: String,
        amount: Double,
        date: Date,
        paymentMethod: String,
        modelContext: ModelContext
    ) {
        let targetId = transactionId
        var payDesc = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { p in
                p.transactionId == targetId
            }
        )
        payDesc.fetchLimit = 1
        if (try? modelContext.fetch(payDesc).first) == nil {
            modelContext.insert(
                CreditCardPayment(
                    transactionId: transactionId,
                    amount: amount,
                    date: date,
                    cardName: paymentMethod,
                    sourceAccount: paymentMethod,
                    title: title,
                    creditAccountId: nil,
                    institutionName: nil
                )
            )
        }

        var txDesc = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { t in
                t.transactionId == targetId
            }
        )
        txDesc.fetchLimit = 1
        if let existing = try? modelContext.fetch(txDesc).first {
            existing.title = title
            existing.amount = -abs(amount)
            existing.date = date
            existing.paymentMethod = paymentMethod
            existing.category = TransactionAnalytics.creditCardPaymentCategory
            existing.categoryLocked = true
            existing.overrideSource = existing.overrideSource ?? "legacy-credit-payment"
        } else {
            modelContext.insert(
                Transaction(
                    transactionId: transactionId,
                    title: title,
                    amount: -abs(amount),
                    date: date,
                    category: TransactionAnalytics.creditCardPaymentCategory,
                    paymentMethod: paymentMethod,
                    categoryLocked: true,
                    overrideSource: "legacy-credit-payment"
                )
            )
        }
    }

    /// Ensure a CreditCardPayment exists for an expense row already marked as bill pay.
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

    /// Delete expense + income + credit-payment local rows for one Plaid transaction_id.
    /// Returns true if anything was deleted.
    @MainActor
    // Called from PlaidSyncMaintenance.dedupeTransactions, so not file-private.
    @discardableResult
    static func deleteLocal(transactionID: String, modelContext: ModelContext) -> Bool {
        var any = false
        if deleteExpenseOnly(transactionID: transactionID, modelContext: modelContext) { any = true }
        if deleteIncomeOnly(transactionID: transactionID, modelContext: modelContext) { any = true }
        if deleteCreditPaymentOnly(transactionID: transactionID, modelContext: modelContext) { any = true }
        return any
    }

    /// Delete one Transaction by Plaid transaction_id if it exists.
    @MainActor
    @discardableResult
    private static func deleteExpenseOnly(transactionID: String, modelContext: ModelContext) -> Bool {
        // #Predicate cannot capture function parameters directly.
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

    /// Delete one Income by Plaid transaction_id if it exists.
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

    /// Delete one CreditCardPayment by Plaid transaction_id if it exists.
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

    // MARK: - Small helpers

    /// "Chase Checking ···1234" style label for sync-page account stubs.
    private static func accountDisplayName(account: PlaidAccount, institution: String) -> String {
        let name = account.name ?? account.official_name ?? institution
        if let mask = account.mask, !mask.isEmpty {
            return "\(name) ···\(mask)"
        }
        return name
    }

    /// Shared yyyy-MM-dd parser. en_US_POSIX + GMT so Plaid dates parse regardless of locale.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // FIX: this parsed bank day strings at UTC midnight while every consumer reads them
        // with Calendar.current. West of Greenwich that lands on the previous local day: a
        // 2026-09-01 charge counted in August's spend and budget, a due date of 2026-09-15
        // displayed as "Sep 14", and statement close days came out one short. Plaid sends a
        // calendar day, not an instant — parse it in the device's zone.
        // OLD: formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Parse Plaid’s "yyyy-MM-dd" date string into a Date (nil if malformed).
    private static func parseDate(_ string: String) -> Date? {
        dayFormatter.date(from: string)
    }
}
