//
//  AppleCardCSVImport.swift
//  Finance Wizard
//
//  Import Apple Card CSV exports from Wallet / card.apple.com.
//  Typical columns: Transaction Date, Clearing Date, Description, Merchant,
//  Category, Type, Amount (USD) [, Purchased By, City, State, Zip, Country,
//  Daily Cash %, Daily Cash Amount].
//
//  Upsert = update if a row with the same stable id exists, otherwise insert.
//  Re-importing the same CSV updates rows instead of duplicating them.
//

import Foundation
import SwiftData
import CryptoKit

/// Errors thrown when the CSV cannot be imported (empty file, bad header, etc.).
enum AppleCardCSVImportError: LocalizedError {
    case empty
    case noHeader
    case noRecognizedColumns
    case noRows

    var errorDescription: String? {
        switch self {
        case .empty: return "The CSV file is empty."
        case .noHeader: return "Could not read a header row from the CSV."
        case .noRecognizedColumns:
            return "This doesn’t look like an Apple Card export (need Date, Description/Merchant, Amount)."
        case .noRows: return "No transaction rows found in the CSV."
        }
    }
}

/// Counts of what the importer did — returned to the UI for a summary message.
struct AppleCardCSVImportReport: Sendable {
    var purchases: Int = 0
    var payments: Int = 0
    var credits: Int = 0
    var skipped: Int = 0

    /// Builds a short human-readable summary like “Apple Card: 12 purchases, 1 payment”.
    var summary: String {
        var parts: [String] = []
        if purchases > 0 { parts.append("\(purchases) purchases") }
        if payments > 0 { parts.append("\(payments) payments") }
        if credits > 0 { parts.append("\(credits) credits/refunds") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if parts.isEmpty { return "No Apple Card rows imported." }
        return "Apple Card: " + parts.joined(separator: ", ")
    }
}

/// Apple Card CSV import helpers.
enum AppleCardCSVImporter {
    static let paymentMethod = AppleCardAccount.paymentMethod
    static let institutionName = AppleCardAccount.institutionName

    /// Upsert rows from Apple Card CSV into SwiftData.
    /// Throws on empty/invalid CSV; returns a report of counts on success.
    @MainActor
    static func importCSV(data: Data, modelContext: ModelContext) throws -> AppleCardCSVImportReport {
        // Try UTF-8 first, then Latin-1 (some exports use different encodings).
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppleCardCSVImportError.empty
        }

        let rows = CSVParser.parse(text)
        guard let header = rows.first else { throw AppleCardCSVImportError.noHeader }
        let map = columnMap(header)
        // Need date, amount, and at least one of description or merchant.
        guard map.date != nil, map.amount != nil, map.description != nil || map.merchant != nil else {
            throw AppleCardCSVImportError.noRecognizedColumns
        }

        // Treat Apple Card as a linked credit account (not “Other spend”).
        _ = AppleCardAccount.ensureLinked(in: modelContext)

        var report = AppleCardCSVImportReport()
        let body = rows.dropFirst()
        guard !body.isEmpty else { throw AppleCardCSVImportError.noRows }

        for cols in body {
            guard apply(cols: cols, map: map, modelContext: modelContext, report: &report) else {
                report.skipped += 1
                continue
            }
        }

        // After CSV import, force account ensure + rate apply once (not on every app open).
        AppleCardAccount.ensureIfNeeded(in: modelContext, transactions: [], force: true)
        AppleCardAccount.reapplyUnlockedMultipliers(in: modelContext)
        try modelContext.save()
        return report
    }

    // MARK: - Row apply

    /// Parses one CSV data row and upserts the right model(s). Returns false if the row is unusable.
    @MainActor
    private static func apply(
        cols: [String],
        map: ColumnMap,
        modelContext: ModelContext,
        report: inout AppleCardCSVImportReport
    ) -> Bool {
        func col(_ idx: Int?) -> String {
            guard let idx, idx < cols.count else { return "" }
            return cols[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let dateStr = col(map.date)
        guard let date = parseDate(dateStr) else { return false }

        let amountRaw = col(map.amount)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Allow literal zero amounts; reject empty/non-numeric.
        guard let amountAbs = Double(amountRaw), amountAbs != 0 || amountRaw == "0" || amountRaw == "0.0" else {
            return false
        }

        let merchant = col(map.merchant)
        let description = col(map.description)
        let title = merchant.isEmpty ? (description.isEmpty ? "Apple Card" : description) : merchant
        let appleCategory = col(map.category)
        let typeRaw = col(map.type).lowercased()
        let type = normalizeType(typeRaw, title: title, amount: amountAbs)

        // Stable id from content so re-import updates the same logical row.
        let stableId = stableTransactionId(
            date: date,
            amount: amountAbs,
            title: title,
            type: typeRaw,
            description: description
        )

        switch type {
        case .payment:
            // Card payment: record both a CreditCardPayment and a negative expense for the ledger.
            upsertPayment(
                id: stableId,
                title: title.isEmpty ? "Apple Card Payment" : title,
                amount: abs(amountAbs),
                date: date,
                modelContext: modelContext
            )
            upsertExpense(
                id: stableId,
                title: title.isEmpty ? "Apple Card Payment" : title,
                // Negative amount: money leaving the card / reducing spend total.
                amount: -abs(amountAbs),
                date: date,
                category: TransactionAnalytics.creditCardPaymentCategory,
                categoryLocked: true,
                multiplier: 0,
                multiplierLocked: true,
                overrideSource: "apple-card-csv",
                paymentRail: PaymentRail.ach.rawValue,
                modelContext: modelContext
            )
            report.payments += 1

        case .credit:
            // Refund / statement credit — store as income so it doesn’t inflate spend.
            upsertIncome(
                id: stableId,
                source: title,
                amount: abs(amountAbs),
                date: date,
                category: "Refund",
                modelContext: modelContext
            )
            // Remove any prior expense mis-import.
            deleteExpense(id: stableId, modelContext: modelContext)
            report.credits += 1

        case .purchase:
            let category = mapAppleCategory(appleCategory)
            // 2% base Daily Cash; higher reward categories applied via CardBenefitsStore.
            let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
            let mult = CardBenefitsStore.resolvedMultiplier(
                accountId: AppleCardAccount.accountId,
                paymentMethod: paymentMethod,
                generalCategory: category,
                title: title,
                accounts: accounts,
                on: date
            )
            upsertExpense(
                id: stableId,
                title: title,
                amount: -abs(amountAbs),
                date: date,
                category: category,
                categoryLocked: false,
                // Default to 2x Daily Cash if resolver returns 0.
                multiplier: mult > 0 ? mult : 2,
                multiplierLocked: false,
                overrideSource: "apple-card-csv",
                paymentRail: PaymentRail.debit.rawValue,
                modelContext: modelContext
            )
            // Purchases should not leave a stale payment row from a previous type guess.
            deleteCreditPayment(id: stableId, modelContext: modelContext)
            report.purchases += 1
        }

        return true
    }

    /// How we classify a CSV row for storage (purchase vs payment vs refund/credit).
    private enum RowType {
        case purchase
        case payment
        case credit
    }

    /// Maps the CSV Type column (and title heuristics) into RowType.
    private static func normalizeType(_ raw: String, title: String, amount: Double) -> RowType {
        let t = raw.lowercased()
        let lower = title.lowercased()
        if t.contains("payment") { return .payment }
        if t.contains("credit") || t.contains("refund") || t.contains("return") { return .credit }
        if t.contains("purchase") || t.contains("fee") || t.contains("interest") { return .purchase }
        // Heuristic when Type column missing.
        if lower.contains("payment") && lower.contains("apple") { return .payment }
        if lower.contains("ach deposit") || lower.contains("refund") { return .credit }
        // Default: spend. `amount` kept in the signature for future heuristics.
        _ = amount
        return .purchase
    }

    /// Maps Apple’s free-form category labels into this app’s KnownCategory names.
    private static func mapAppleCategory(_ apple: String) -> String {
        let c = apple.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if c.isEmpty { return KnownCategory.miscellaneous.rawValue }
        if c.contains("parking") || c.contains("transit") || c.contains("rideshare") || c.contains("taxi") {
            return KnownCategory.transit.rawValue
        }
        if c.contains("gas") || c.contains("fuel") {
            return KnownCategory.gas.rawValue
        }
        if c.contains("grocery") || c.contains("grocer") { return KnownCategory.groceries.rawValue }
        if c.contains("restaurant") || c.contains("food") || c.contains("coffee") || c.contains("dining") {
            return KnownCategory.dining.rawValue
        }
        if c.contains("entertainment") || c.contains("music") || c.contains("movie") || c.contains("game") {
            return KnownCategory.entertainment.rawValue
        }
        if c.contains("shopping") || c.contains("retail") || c.contains("clothing") {
            return KnownCategory.shopping.rawValue
        }
        if c.contains("airline") || c.contains("hotel") || c.contains("travel") {
            return KnownCategory.travel.rawValue
        }
        if c.contains("health") || c.contains("medical") || c.contains("pharmacy") {
            return KnownCategory.health.rawValue
        }
        if c.contains("personal") {
            return KnownCategory.personalCare.rawValue
        }
        if c.contains("rent") || c.contains("mortgage") || c.contains("housing") {
            return KnownCategory.housing.rawValue
        }
        if c.contains("internet") || c.contains("phone") || c.contains("cable") {
            return KnownCategory.homeInternet.rawValue
        }
        if c.contains("utilities") || c.contains("electric") || c.contains("water") {
            return KnownCategory.utilities.rawValue
        }
        if c.contains("education") || c.contains("tuition") {
            return KnownCategory.education.rawValue
        }
        if c.contains("pet") {
            return KnownCategory.pets.rawValue
        }
        if c.contains("gift") || c.contains("donation") || c.contains("charity") {
            return KnownCategory.giftsDonations.rawValue
        }
        if c.contains("fee") {
            return KnownCategory.fees.rawValue
        }
        if c.contains("payment") { return TransactionAnalytics.creditCardPaymentCategory }
        if c.contains("other") { return KnownCategory.miscellaneous.rawValue }
        // Prefer a known category; otherwise Miscellaneous (avoid free-form Apple labels drifting).
        if let known = KnownCategory.canonicalName(for: apple) {
            return known
        }
        return KnownCategory.miscellaneous.rawValue
    }

    // MARK: - Upserts

    /// Insert or update a Transaction (spend) with the given id.
    /// Respects user locks: won’t overwrite category/multiplier/rail if the user locked them
    /// (unless the previous override was from this same CSV importer).
    @MainActor
    private static func upsertExpense(
        id: String,
        title: String,
        amount: Double,
        date: Date,
        category: String,
        categoryLocked: Bool,
        multiplier: Double,
        multiplierLocked: Bool,
        overrideSource: String,
        paymentRail: String,
        modelContext: ModelContext
    ) {
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { row in
                row.transactionId == id
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = title
            existing.amount = amount
            existing.date = date
            existing.paymentMethod = paymentMethod
            if !existing.isCategoryLocked || existing.overrideSource == "apple-card-csv"
                || TransactionAnalytics.isExcludedFromSpendCategory(existing.category) {
                existing.category = category
                existing.categoryLocked = categoryLocked
            }
            if !existing.isMultiplierLocked || existing.overrideSource == "apple-card-csv" {
                existing.multiplier = multiplier
                existing.multiplierLocked = multiplierLocked
            }
            existing.overrideSource = overrideSource
            if !existing.isPaymentRailLocked {
                existing.paymentRail = paymentRail
            }
            existing.plaidPaymentChannel = "other"
        } else {
            modelContext.insert(
                Transaction(
                    transactionId: id,
                    title: title,
                    amount: amount,
                    date: date,
                    category: category,
                    paymentMethod: paymentMethod,
                    multiplier: multiplier,
                    categoryLocked: categoryLocked,
                    multiplierLocked: multiplierLocked,
                    overrideSource: overrideSource,
                    plaidPaymentChannel: "other",
                    paymentRail: paymentRail,
                    paymentRailLocked: false
                )
            )
        }
    }

    /// Insert or update a CreditCardPayment row for an Apple Card payment.
    @MainActor
    private static func upsertPayment(
        id: String,
        title: String,
        amount: Double,
        date: Date,
        modelContext: ModelContext
    ) {
        var descriptor = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { row in
                row.transactionId == id
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.amount = amount
            existing.date = date
            existing.cardName = paymentMethod
            existing.title = title
            existing.institutionName = institutionName
            existing.creditAccountId = AppleCardAccount.accountId
        } else {
            modelContext.insert(
                CreditCardPayment(
                    transactionId: id,
                    amount: amount,
                    date: date,
                    cardName: paymentMethod,
                    sourceAccount: nil,
                    title: title,
                    creditAccountId: AppleCardAccount.accountId,
                    institutionName: institutionName
                )
            )
        }
    }

    /// Insert or update an Income row (used for refunds / statement credits).
    @MainActor
    private static func upsertIncome(
        id: String,
        source: String,
        amount: Double,
        date: Date,
        category: String,
        modelContext: ModelContext
    ) {
        var descriptor = FetchDescriptor<Income>(
            predicate: #Predicate<Income> { row in
                row.transactionId == id
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.source = source
            existing.amount = amount
            existing.date = date
            existing.category = category
            existing.accountName = paymentMethod
            existing.sourceInstitution = institutionName
            existing.kind = "income"
        } else {
            modelContext.insert(
                Income(
                    transactionId: id,
                    source: source,
                    amount: amount,
                    date: date,
                    category: category,
                    accountName: paymentMethod,
                    accountMask: nil,
                    sourceInstitution: institutionName,
                    rawName: source,
                    pfc: nil,
                    pending: false,
                    kind: "income"
                )
            )
        }
    }

    /// Deletes a Transaction with the given id if present (e.g. when reclassifying as credit).
    @MainActor
    private static func deleteExpense(id: String, modelContext: ModelContext) {
        var descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { row in
                row.transactionId == id
            }
        )
        descriptor.fetchLimit = 1
        if let row = try? modelContext.fetch(descriptor).first {
            modelContext.delete(row)
        }
    }

    /// Deletes a CreditCardPayment with the given id if present.
    @MainActor
    private static func deleteCreditPayment(id: String, modelContext: ModelContext) {
        var descriptor = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { row in
                row.transactionId == id
            }
        )
        descriptor.fetchLimit = 1
        if let row = try? modelContext.fetch(descriptor).first {
            modelContext.delete(row)
        }
    }

    // MARK: - Columns

    /// Maps logical fields (date, amount, …) to zero-based column indexes in the CSV header.
    private struct ColumnMap {
        var date: Int?
        var amount: Int?
        var description: Int?
        var merchant: Int?
        var category: Int?
        var type: Int?
    }

    /// Scans header cells and fills ColumnMap by matching common Apple Card / export names.
    private static func columnMap(_ header: [String]) -> ColumnMap {
        var map = ColumnMap()
        for (i, raw) in header.enumerated() {
            let h = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // First matching name wins for each field.
            if map.date == nil,
               h == "transaction date" || h == "date" || h == "purchase date"
                || h == "trans date" || h.hasPrefix("transaction date") {
                map.date = i
            } else if map.amount == nil,
                      h == "amount (usd)" || h == "amount" || h == "amount(usd)"
                        || h == "transaction amount" || h.hasPrefix("amount") {
                map.amount = i
            } else if map.merchant == nil, h == "merchant" || h == "merchant name" {
                map.merchant = i
            } else if map.description == nil,
                      h == "description" || h == "desc" || h == "payee" || h == "memo" {
                map.description = i
            } else if map.category == nil, h == "category" || h == "apple category" {
                map.category = i
            } else if map.type == nil, h == "type" || h == "transaction type" {
                map.type = i
            }
        }
        // Prefer Transaction Date over Clearing Date if both present — already first match.
        return map
    }

    /// Tries several common date string formats until one succeeds.
    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formats = [
            "MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd",
            "MM/dd/yy", "M/d/yy",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ]
        let formatter = DateFormatter()
        // en_US_POSIX + GMT: fixed parsing of machine-like date strings (not locale-dependent).
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for f in formats {
            formatter.dateFormat = f
            if let d = formatter.date(from: trimmed) { return d }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: trimmed) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: trimmed)
    }

    /// Stable id so re-import updates instead of duplicating.
    /// Hashes date+amount+title+type+description with SHA-256 and prefixes `applecard:`.
    private static func stableTransactionId(
        date: Date,
        amount: Double,
        title: String,
        type: String,
        description: String
    ) -> String {
        // startOfDay so the same calendar day always hashes the same.
        let day = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: date))
        let raw = "\(day)|\(String(format: "%.2f", amount))|\(title)|\(type)|\(description)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        // First 16 bytes of SHA-256 as hex — short stable id, not a full digest.
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "applecard:\(hex)"
    }
}

// MARK: - Minimal CSV parser (RFC 4180-ish)

/// Character-by-character CSV parser that handles commas, newlines, and quoted fields.
/// RFC 4180-style: fields may be quoted with ", and "" inside quotes means a literal quote.
enum CSVParser {
    /// Parses entire CSV text into rows of field strings.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    // Two quotes in a row ("") → one literal " in the field.
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                field.append(c)
                i += 1
                continue
            }
            switch c {
            case "\"":
                inQuotes = true
                i += 1
            case ",":
                row.append(field)
                field = ""
                i += 1
            case "\n":
                row.append(field)
                field = ""
                // Skip completely empty rows (single empty field only).
                if !(row.count == 1 && row[0].isEmpty) {
                    rows.append(row)
                }
                row = []
                i += 1
            case "\r":
                // Handle \r\n as one break.
                if i + 1 < chars.count, chars[i + 1] == "\n" {
                    i += 1
                }
                row.append(field)
                field = ""
                if !(row.count == 1 && row[0].isEmpty) {
                    rows.append(row)
                }
                row = []
                i += 1
            default:
                field.append(c)
                i += 1
            }
        }
        // Flush last field/row if the file doesn’t end with a newline.
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
        }
        return rows
    }
}
