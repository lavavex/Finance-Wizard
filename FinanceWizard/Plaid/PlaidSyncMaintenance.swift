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
    /// When an employer is also a merchant, Plaid tags some paychecks as salary and others as a
    /// purchase from that merchant. A deposit from a source Plaid has identified as payroll is
    /// payroll too, if it's paycheck-sized, so a small store refund keeps its label.
    @MainActor
    @discardableResult
    static func relabelPayrollDeposits(modelContext: ModelContext) -> Int {
        let rows = (try? modelContext.fetch(FetchDescriptor<Income>())) ?? []
        let bySource = Dictionary(grouping: rows) {
            $0.source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        var relabeled = 0
        for group in bySource.values {
            let paychecks = group.filter { isPayrollPFC($0.pfc) }.map(\.amount).sorted()
            guard !paychecks.isEmpty else { continue }
            let minimum = paychecks[paychecks.count / 2] * 0.25
            for row in group where row.category == "Other Income"
                && row.amount >= minimum
                && !(row.pfc ?? "").uppercased().hasPrefix("INCOME") {
                row.category = "Payroll"
                relabeled += 1
            }
        }
        return relabeled
    }

    /// One bank names a paycheck's employer and another shows only the payroll code from the
    /// same bank line, like "PAYROLLXYZ". A paycheck known only by a code takes the employer's
    /// name when exactly one named employer's bank line carries that code.
    @MainActor
    @discardableResult
    static func nameIncomeByPayrollCode(modelContext: ModelContext) -> Int {
        let rows = ((try? modelContext.fetch(FetchDescriptor<Income>())) ?? []).filter { isPayrollPFC($0.pfc) }
        let employers = employersByPayrollCode(rows.map { ($0.source, $0.rawName) })
        var renamed = 0
        for row in rows where isBankLine(source: row.source, rawName: row.rawName) {
            let names = Set(payrollCodes(in: row.source).compactMap { employers[$0] })
            guard names.count == 1, let name = names.first, name != row.source else { continue }
            row.source = name
            renamed += 1
        }
        return renamed
    }

    /// Codes that belong to a single named employer. A code two employers share says nothing.
    static func employersByPayrollCode(_ paychecks: [(source: String, rawName: String?)]) -> [String: String] {
        var names: [String: Set<String>] = [:]
        for paycheck in paychecks where !isBankLine(source: paycheck.source, rawName: paycheck.rawName) {
            for code in payrollCodes(in: paycheck.rawName ?? "") {
                names[code, default: []].insert(paycheck.source)
            }
        }
        return names.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// True when the bank's own line is all there is, so nobody has named the payer.
    private static func isBankLine(source: String, rawName: String?) -> Bool {
        let raw = (rawName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw.caseInsensitiveCompare(source.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    /// Long tokens of a bank line, minus words any employer's line could carry.
    private static func payrollCodes(in line: String) -> Set<String> {
        let generic: Set<String> = [
            "DIRECTDEP", "DIRECTDEPOSIT", "DIRDEPOSIT", "PAYCHECK", "PAYROLLS", "DEPOSITS",
            "CORPORATION", "INCORPORATED", "PAYMENTS", "TRANSFER", "REIMBURSEMENT", "EMPLOYEE",
            "EMPLOYER", "SERVICES", "COMPANIES", "INTERNATIONAL", "HOLDINGS", "ENTERPRISES",
        ]
        let tokens = line.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(tokens.filter { $0.count >= 8 && !generic.contains($0) })
    }

    private static func isPayrollPFC(_ pfc: String?) -> Bool {
        let detailed = (pfc ?? "").uppercased()
        return detailed.contains("SALARY") || detailed.contains("WAGES") || detailed.contains("PAYROLL")
    }

    /// Some banks post a card payment as a bare "ACH PMT" or "PAYMENT", which reads the same as
    /// any bill. When a linked card received that exact amount within a few days, and no other
    /// bank row already accounts for it, the bank row is that payment and not spending.
    /// - Returns: How many rows were refiled as card payments.
    @MainActor
    @discardableResult
    static func pairVaguePaymentsWithCards(modelContext: ModelContext) -> Int {
        let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        let rows = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
        let paired = vaguePaymentsMatchingCardPayments(
            in: rows,
            creditAccountIds: Set(accounts.filter(\.isCredit).map(\.accountId))
        )
        for row in paired {
            row.category = TransactionAnalytics.creditCardPaymentCategory
            row.categoryLocked = true
            row.overrideSource = "credit-payment"
            // The card's own row already records this payment, so a second one would double Total paid.
            deleteCreditPaymentOnly(transactionID: row.transactionId, modelContext: modelContext)
        }
        return paired.count
    }

    /// The card's row can post a few days before the bank's, and rarely after.
    private static let cardPostsBeforeBankDays = -5...2

    static func vaguePaymentsMatchingCardPayments(
        in rows: [Transaction],
        creditAccountIds: Set<String>,
        calendar: Calendar = .current
    ) -> [Transaction] {
        func cents(_ row: Transaction) -> Int { Int((abs(row.amount) * 100).rounded()) }
        func isOnCard(_ row: Transaction) -> Bool {
            row.plaidAccountId.map(creditAccountIds.contains) ?? false
        }
        let payments = rows.filter { TransactionAnalytics.isCreditCardPaymentCategory($0.category) }
        var received = Dictionary(grouping: payments.filter(isOnCard), by: cents)

        /// Uses up the nearest card row for this bank row, so one payment can't explain two.
        func claim(for bank: Transaction) -> Bool {
            let key = cents(bank)
            let bankDay = calendar.startOfDay(for: bank.date)
            let nearest = (received[key] ?? []).enumerated()
                .compactMap { index, card -> (index: Int, gap: Int)? in
                    let cardDay = calendar.startOfDay(for: card.date)
                    guard let days = calendar.dateComponents([.day], from: bankDay, to: cardDay).day,
                          cardPostsBeforeBankDays.contains(days) else { return nil }
                    return (index, abs(days))
                }
                .min { $0.gap < $1.gap }
            guard let nearest else { return false }
            received[key]?.remove(at: nearest.index)
            return true
        }

        let byDate: (Transaction, Transaction) -> Bool = { $0.date < $1.date }
        // Bank rows already known as payments claim their card rows first.
        for bank in payments.filter({ !isOnCard($0) && $0.plaidAccountId != nil }).sorted(by: byDate) {
            _ = claim(for: bank)
        }
        return rows
            .filter {
                $0.plaidAccountId != nil && !isOnCard($0) && !$0.isCategoryLocked
                    && !TransactionAnalytics.isExcludedFromSpendCategory($0.category)
                    && MoneyInsights.looksLikeVaguePayment($0.title)
            }
            .sorted(by: byDate)
            .filter(claim)
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
    @MainActor
    @discardableResult
    static func pruneOrphanBankAccounts(modelContext: ModelContext) -> Int {
        // Demo accounts belong to no linked Item.
        if DemoMode.isActive { return 0 }
        let linkedIds = PlaidItemStore.linkedItemIDs
        let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        var removed = 0
        for account in all {
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
        let linkedIds = PlaidItemStore.linkedItemIDs
        let all = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
        var groups: [String: [BankAccount]] = [:]
        for account in all {
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
        return a + b + c
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
            // FIX: the group key is day|amount|title|method with no transaction id, so two
            // genuinely distinct purchases — the same coffee twice in one day, or equal
            // payments to two cards — collided and one was deleted permanently, with the
            // mirrored CreditCardPayment/Income left behind. Only collapse rows that are
            // really the same row re-delivered under a new id: that happens when an account
            // is relinked, so require the rows to come from different Plaid accounts.
            let distinctAccounts = Set(rows.map { $0.plaidAccountId ?? "" })
            guard distinctAccounts.count > 1 else { continue }
            rows.sort { a, b in
                let aScore = transactionKeepScore(a, accounts: accounts)
                let bScore = transactionKeepScore(b, accounts: accounts)
                if aScore != bScore { return aScore > bScore }
                return a.transactionId < b.transactionId
            }
            for drop in rows.dropFirst() {
                // Route through deleteLocal so the mirrored payment / income row goes too.
                deleteLocal(transactionID: drop.transactionId, modelContext: modelContext)
                removed += 1
            }
        }
        return removed
    }

    /// Same day + amount + source (+ account mask when present) → keep one income row.
    /// Income rows don't record their Plaid account, so this can't tell a re-delivered row from
    /// two real deposits. Only run it after a bank was linked again as a new Item.
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
        // Both rows are already in the same method family; prefer the live one
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

// MARK: - Day-string re-anchoring

extension PlaidSyncEngine {
    /// Bump when stored dates need re-anchoring again.
    /// v2: also re-anchors PayoffPlan dates. v1 missed them, so a plan's statement stamp
    /// disagreed with its account's by a day and applyStatementProgress read that as a cycle.
    static let dayAnchorVersion = 2
    static let dayAnchorVersionKey = "plaid.dayAnchor.v"

    /// One-off repair for rows stored while day strings were parsed at UTC midnight.
    ///
    /// Those rows sit at 00:00 UTC, which is the *previous* day everywhere west of Greenwich,
    /// so they were filtered, bucketed and displayed a day early. Re-stamp each one to local
    /// midnight of the calendar day it was always meant to represent (its UTC y/m/d).
    /// Rows already at local midnight are left alone, so running twice is harmless.
    @MainActor
    @discardableResult
    static func reanchorStoredDays(modelContext: ModelContext) -> Int {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let local = Calendar.current

        /// nil when the date is not sitting exactly on a UTC midnight (already local, or a
        /// real timestamp we must not touch).
        func reanchored(_ date: Date) -> Date? {
            let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            guard c.hour == 0, c.minute == 0, c.second == 0 else { return nil }
            var out = DateComponents()
            out.year = c.year
            out.month = c.month
            out.day = c.day
            guard let shifted = local.date(from: out), shifted != date else { return nil }
            return shifted
        }

        var changed = 0
        for row in (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? [] {
            if let d = reanchored(row.date) { row.date = d; changed += 1 }
            if let a = row.authorizedDate, let d = reanchored(a) { row.authorizedDate = d }
        }
        for row in (try? modelContext.fetch(FetchDescriptor<Income>())) ?? [] {
            if let d = reanchored(row.date) { row.date = d; changed += 1 }
        }
        for row in (try? modelContext.fetch(FetchDescriptor<CreditCardPayment>())) ?? [] {
            if let d = reanchored(row.date) { row.date = d; changed += 1 }
        }
        // PayoffPlan was missed on the first pass: its statement stamp stayed at UTC
        // midnight while the account's moved, and applyStatementProgress read that one-day
        // gap as a whole new cycle.
        for plan in (try? modelContext.fetch(FetchDescriptor<PayoffPlan>())) ?? [] {
            if let d = reanchored(plan.startDate) { plan.startDate = d; changed += 1 }
            if let v = plan.endDate, let d = reanchored(v) { plan.endDate = d }
            if let v = plan.lastAppliedStatementDate, let d = reanchored(v) {
                plan.lastAppliedStatementDate = d
            }
        }
        for account in (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? [] {
            if let v = account.lastPaymentDate, let d = reanchored(v) { account.lastPaymentDate = d }
            if let v = account.lastStatementIssueDate, let d = reanchored(v) { account.lastStatementIssueDate = d }
            if let v = account.nextPaymentDueDate, let d = reanchored(v) { account.nextPaymentDueDate = d }
        }
        return changed
    }
}
