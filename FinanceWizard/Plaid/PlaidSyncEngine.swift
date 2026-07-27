//
//  PlaidSyncEngine.swift
//  Finance Wizard
//
//  Pulls /transactions/sync for every linked Item and upserts into SwiftData.
//

import Foundation
import SwiftData
import WidgetKit

struct PlaidSyncReport: Sendable {
    var itemLines: [String] = []
    var expensesUpserted: Int = 0
    var incomeUpserted: Int = 0
    var removed: Int = 0
    var skippedTransfers: Int = 0
    var warnings: [String] = []

    var summary: String {
        var lines: [String] = []
        lines.append(contentsOf: itemLines)
        lines.append("Expenses upserted: \(expensesUpserted)")
        lines.append("Income upserted: \(incomeUpserted)")
        if removed > 0 { lines.append("Removed: \(removed)") }
        if skippedTransfers > 0 { lines.append("Skipped transfers: \(skippedTransfers)") }
        if !warnings.isEmpty {
            lines.append("Warnings:")
            lines.append(contentsOf: warnings.map { "• \($0)" })
        }
        return lines.joined(separator: "\n")
    }
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
                report.removed += itemReport.removed
                report.skippedTransfers += itemReport.skippedTransfers
                report.itemLines.append(
                    "\(item.institutionName): +\(itemReport.expensesUpserted) exp / +\(itemReport.incomeUpserted) inc"
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
        // If pagination fails mid-way, restart from this page’s starting cursor
        var pageStartCursor = cursor
        var hasMore = true
        var accountLabels: [String: String] = [:]
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
                // Mutation during pagination — restart from pageStartCursor
                if case PlaidAPIError.http(_, let code, _) = error,
                   code == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" {
                    cursor = pageStartCursor
                    continue
                }
                throw error
            }

            // Map account_id → display payment method
            if let accounts = page.accounts {
                for account in accounts {
                    accountLabels[account.account_id] = accountDisplayName(
                        account: account,
                        institution: item.institutionName
                    )
                }
            }

            for tx in page.added + page.modified {
                if tx.pending == true && !includePending { continue }
                applyTransaction(
                    tx,
                    item: item,
                    accountLabels: accountLabels,
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
            if hasMore {
                // Next page continues from next_cursor; keep original page start for retry
                if pageStartCursor == cursor {
                    // still on first page of this update batch
                }
                cursor = page.next_cursor
            } else {
                cursor = page.next_cursor
                pageStartCursor = cursor
            }
        }

        if let cursor, !cursor.isEmpty {
            PlaidItemStore.updateCursor(itemID: item.id, cursor: cursor)
        }

        return report
    }

    // MARK: - Apply one Plaid transaction

    @MainActor
    private static func applyTransaction(
        _ tx: PlaidTransaction,
        item: PlaidLinkedItem,
        accountLabels: [String: String],
        modelContext: ModelContext,
        report: inout PlaidSyncReport
    ) {
        let title = (tx.merchant_name?.isEmpty == false ? tx.merchant_name : tx.name)
            ?? tx.original_description
            ?? "Transaction"

        if PlaidCategoryMapper.isInternalTransfer(pfc: tx.personal_finance_category, name: title) {
            report.skippedTransfers += 1
            return
        }

        guard let date = parseDate(tx.date) else { return }

        let paymentMethod = accountLabels[tx.account_id] ?? item.paymentMethodLabel
        let pfcDetailed = tx.personal_finance_category?.detailed

        // Plaid: positive amount = money out; negative = money in
        if tx.amount >= 0 {
            upsertExpense(
                tx: tx,
                title: title,
                date: date,
                paymentMethod: paymentMethod,
                pfcDetailed: pfcDetailed,
                modelContext: modelContext
            )
            report.expensesUpserted += 1
        } else {
            upsertIncome(
                tx: tx,
                title: title,
                date: date,
                paymentMethod: paymentMethod,
                pfcDetailed: pfcDetailed,
                modelContext: modelContext
            )
            report.incomeUpserted += 1
        }
    }

    @MainActor
    private static func upsertExpense(
        tx: PlaidTransaction,
        title: String,
        date: Date,
        paymentMethod: String,
        pfcDetailed: String?,
        modelContext: ModelContext
    ) {
        let targetId = tx.transaction_id
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.transactionId == targetId }
        )
        descriptor.fetchLimit = 1

        let defaultCategory = PlaidCategoryMapper.expenseCategory(from: tx.personal_finance_category)
        let rule = VendorRulesStore.match(vendor: title, paymentMethod: paymentMethod)
        let mappedCategory = rule?.category ?? defaultCategory
        let mappedMultiplier = rule?.multiplier ?? 1.0

        // Store expenses as negative (app convention)
        let amount = -abs(tx.amount)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = title
            existing.amount = amount
            existing.date = date
            existing.paymentMethod = paymentMethod
            // Respect user locks from local edits
            if !existing.isCategoryLocked {
                existing.category = mappedCategory
            }
            if !existing.isMultiplierLocked {
                existing.multiplier = mappedMultiplier
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
                    overrideSource: rule != nil ? "rule" : nil
                )
            )
        }
        _ = pfcDetailed // reserved for future UI
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
            predicate: #Predicate { $0.transactionId == targetId }
        )
        descriptor.fetchLimit = 1

        let category = PlaidCategoryMapper.incomeCategory(
            from: tx.personal_finance_category,
            name: title
        )
        let amount = abs(tx.amount)
        let pending = tx.pending ?? false

        // Split payment method into name / mask if "Name ···1234"
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
    private static func deleteLocal(transactionID: String, modelContext: ModelContext) -> Bool {
        var expenseDesc = FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.transactionId == transactionID }
        )
        expenseDesc.fetchLimit = 1
        if let row = try? modelContext.fetch(expenseDesc).first {
            // Don’t delete user-locked rows? Still remove if bank removed it.
            modelContext.delete(row)
            return true
        }

        var incomeDesc = FetchDescriptor<Income>(
            predicate: #Predicate { $0.transactionId == transactionID }
        )
        incomeDesc.fetchLimit = 1
        if let row = try? modelContext.fetch(incomeDesc).first {
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
