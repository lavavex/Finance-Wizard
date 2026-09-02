//
//  SharedStore.swift
//  Finance Wizard
//
//  Shared SwiftData configuration + filter/sort helpers used by app and widget.
//  App and widget are separate processes; they share one on-disk store via an
//  App Group container. Analytics is pure math on arrays so both use the same totals.
//

import Foundation
import SwiftData

// MARK: - Summary value types

/// One card's total spending for lists / widget breakdown.
struct CardSpendSummary: Identifiable {
    var id: String { cardName }
    let cardName: String
    /// Positive dollars spent on this card.
    let spent: Double
    let transactionCount: Int
}

/// One budget category’s total for charts.
struct CategorySpendSummary: Identifiable {
    var id: String { category }
    let category: String
    /// Positive dollars spent in this category.
    let spent: Double
    let transactionCount: Int
}

/// Chart layout options (app + category widget).
enum ChartFormat: String, CaseIterable, Identifiable, Sendable {
    case horizontalBar
    case verticalBar
    case pie

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .horizontalBar: return "Horizontal bars"
        case .verticalBar: return "Vertical bars"
        case .pie: return "Pie"
        }
    }

    var systemImage: String {
        switch self {
        case .horizontalBar: return "chart.bar.xaxis"
        case .verticalBar: return "chart.bar"
        case .pie: return "chart.pie.fill"
        }
    }
}

/// Snapshot for category charts (app screen + category widget).
struct CategorySpendSnapshot {
    let categories: [CategorySpendSummary]
    let totalSpend: Double
    let transactionCount: Int
    let period: SnapshotPeriod
    let isEmptyOrError: Bool
    let message: String?
}

/// One checking/savings (or other cash) account for the balances widget.
struct DepositBalanceRow: Identifiable, Sendable {
    var id: String { accountId }
    let accountId: String
    let displayName: String
    let institutionName: String
    let kind: DepositoryKind
    /// Available when known, else ledger current balance
    let balance: Double
    let mask: String?
}

/// Widget snapshot: cash on hand across depository accounts.
struct DepositBalancesSnapshot: Sendable {
    let accounts: [DepositBalanceRow]
    let totalBalance: Double
    let checkingTotal: Double
    let savingsTotal: Double
    let otherTotal: Double
    let lastSyncedAt: Date?
    let isEmptyOrError: Bool
    let message: String?
}

// MARK: - Period & sort enums

/// Which calendar window totals use.
/// week / month use Calendar.dateInterval; all means no date filter.
enum SnapshotPeriod: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .week: return "This week"
        case .month: return "Month"
        case .all: return "All time"
        }
    }

    /// Header label for the active filter (e.g. "June 2026", "This month", "Jul 20–26").
    func filterLabel(
        referenceDate: Date = Date(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        switch self {
        case .all:
            return "All time"
        case .month:
            if calendar.isDate(referenceDate, equalTo: now, toGranularity: .month) {
                return "This month"
            }
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: referenceDate)
        case .week:
            if calendar.isDate(referenceDate, equalTo: now, toGranularity: .weekOfYear) {
                return "This week"
            }
            return widgetLabel(now: referenceDate, calendar: calendar)
        }
    }

    /// Widget-friendly label using the real calendar period (e.g. "July", "Jul 20–26")
    func widgetLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .all:
            return "All"
        case .month:
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.setLocalizedDateFormatFromTemplate("MMMM")
            return formatter.string(from: now)
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else {
                return "Week"
            }
            let start = interval.start
            // interval.end is exclusive (first moment of next week)
            let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            let startText = formatter.string(from: start)
            let endText = formatter.string(from: end)
            return "\(startText)–\(endText)"
        }
    }
}

/// How a transaction list is ordered (app + reusable helpers).
enum TransactionSort: String, CaseIterable, Identifiable, Sendable {
    case dateNewest
    case dateOldest
    case amountLargest
    case amountSmallest
    case titleAZ

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateNewest: return "Date (newest)"
        case .dateOldest: return "Date (oldest)"
        case .amountLargest: return "Amount (largest)"
        case .amountSmallest: return "Amount (smallest)"
        case .titleAZ: return "Name (A–Z)"
        }
    }
}

/// Snapshot of store data the widget (and app summary) can display.
struct FinanceSnapshot {
    /// Cards sorted by most spent first (after hide-card filter).
    let cards: [CardSpendSummary]
    /// Period total across ALL cards (hide-card does NOT shrink this). Positive = money spent.
    let totalSpend: Double
    /// Signed period balance across ALL cards (expenses are negative in our model).
    let balance: Double
    let transactionCount: Int
    let period: SnapshotPeriod
    let isEmptyOrError: Bool
    let message: String?
}

// MARK: - Pure helpers (work on any array — app @Query or widget fetch)

/// Filter, sort, and aggregate expense transactions for charts and widgets.
enum TransactionAnalytics {
    /// Canonical label for credit-card bill payments (not real spend).
    nonisolated static let creditCardPaymentCategory = "Credit Card Payment"
    /// Card-line disbursement (Chase My Loan) — not spend and not a bill payment.
    nonisolated static let loanCategory = "Loan"
    /// Card statement credit / merchant refund — not spend and not income.
    nonisolated static let refundCategory = "Refund"
    /// Monthly installment billing — original purchase already counted.
    nonisolated static let installmentCategory = "Installment"

    /// Categories excluded from Total Spend, charts, and card spend rollups.
    static func isExcludedFromSpend(_ transaction: Transaction) -> Bool {
        isExcludedFromSpendCategory(transaction.category)
    }

    /// String form so callers without a full Transaction can still check.
    nonisolated static func isExcludedFromSpendCategory(_ category: String) -> Bool {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return c == creditCardPaymentCategory.lowercased()
            || c == "credit card payments"
            || c == "card payment"
            || c == "card payments"
            || c == loanCategory.lowercased()
            || c == refundCategory.lowercased()
            || c == installmentCategory.lowercased()
    }

    nonisolated static func isCreditCardPaymentCategory(_ category: String) -> Bool {
        let c = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return c == creditCardPaymentCategory.lowercased()
            || c == "credit card payments"
            || c == "card payment"
            || c == "card payments"
    }

    /// Rows that count toward spend / utilization of budget categories.
    static func spendOnly(_ transactions: [Transaction]) -> [Transaction] {
        transactions.filter { !isExcludedFromSpend($0) }
    }

    static func cardName(for transaction: Transaction) -> String {
        transaction.paymentMethod.isEmpty ? "Unknown" : transaction.paymentMethod
    }

    /// Inclusive start / exclusive end for week or month; nil for all-time.
    static func dateInterval(
        for period: SnapshotPeriod,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> DateInterval? {
        switch period {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: referenceDate)
        case .month:
            return calendar.dateInterval(of: .month, for: referenceDate)
        case .all:
            return nil
        }
    }

    /// Start of the calendar month that contains `date`.
    static func monthStart(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// Month starts that appear in the data (newest first), always including the current month.
    static func availableMonthStarts(
        in transactions: [Transaction],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Date] {
        availableMonthStarts(from: transactions.map(\.date), now: now, calendar: calendar)
    }

    /// Month starts from any date list (payments, income, etc.).
    static func availableMonthStarts(
        from dates: [Date],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Date] {
        var components = Set<DateComponents>()
        for date in dates {
            components.insert(calendar.dateComponents([.year, .month], from: date))
        }
        components.insert(calendar.dateComponents([.year, .month], from: now))

        return components
            .compactMap { calendar.date(from: $0) }
            .sorted(by: >)
    }

    /// Keep transactions in the selected period (does not hide cards).
    static func inPeriod(
        _ transactions: [Transaction],
        period: SnapshotPeriod,
        referenceDate: Date = Date()
    ) -> [Transaction] {
        guard let interval = dateInterval(for: period, referenceDate: referenceDate) else {
            return transactions
        }
        return transactions.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    /// Drop transactions whose card is in the hide list.
    static func excludingCards(_ transactions: [Transaction], excludedCards: Set<String>) -> [Transaction] {
        guard !excludedCards.isEmpty else { return transactions }
        return transactions.filter { !excludedCards.contains(cardName(for: $0)) }
    }

    static func filter(
        _ transactions: [Transaction],
        period: SnapshotPeriod,
        referenceDate: Date = Date(),
        excludedCards: Set<String> = [],
        sort: TransactionSort = .dateNewest
    ) -> [Transaction] {
        let byPeriod = inPeriod(transactions, period: period, referenceDate: referenceDate)
        let byCard = excludingCards(byPeriod, excludedCards: excludedCards)
        return sorted(byCard, by: sort)
    }

    static func sorted(_ transactions: [Transaction], by sort: TransactionSort) -> [Transaction] {
        switch sort {
        case .dateNewest:
            return transactions.sorted { $0.date > $1.date }
        case .dateOldest:
            return transactions.sorted { $0.date < $1.date }
        case .amountLargest:
            return transactions.sorted { abs($0.amount) > abs($1.amount) }
        case .amountSmallest:
            return transactions.sorted { abs($0.amount) < abs($1.amount) }
        case .titleAZ:
            return transactions.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    /// Positive dollars spent (excludes credit-card bill payments).
    static func totalSpend(in transactions: [Transaction]) -> Double {
        spendOnly(transactions).reduce(0) { $0 + abs($1.amount) }
    }

    /// Signed balance of spend rows only (bill payments excluded).
    static func balance(in transactions: [Transaction]) -> Double {
        spendOnly(transactions).reduce(0) { $0 + $1.amount }
    }

    static func paymentMethods(in transactions: [Transaction]) -> [String] {
        Set(transactions.map { cardName(for: $0) }).sorted()
    }

    static func categoryName(for transaction: Transaction) -> String {
        transaction.category.isEmpty ? "Uncategorized" : transaction.category
    }

    /// Per-category spend for charts (period should already be applied by caller).
    /// When limited, leftover spend is rolled into "Other" so pie slices always
    /// sum to the same total shown in the center.
    static func categorySummaries(
        from transactions: [Transaction],
        categoryLimit: Int? = nil
    ) -> [CategorySpendSummary] {
        var spent: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for transaction in spendOnly(transactions) {
            let cat = categoryName(for: transaction)
            spent[cat, default: 0] += abs(transaction.amount)
            counts[cat, default: 0] += 1
        }

        let sorted = spent.map { name, amount in
            CategorySpendSummary(
                category: name,
                spent: amount,
                transactionCount: counts[name] ?? 0
            )
        }
        .sorted { $0.spent > $1.spent }

        return limitCategorySummaries(sorted, to: categoryLimit)
    }

    /// Keep the top spend rows; roll the rest into a single "Other" bucket.
    /// Used for bar charts (raw categories) and pie (after color-group merge).
    static func limitCategorySummaries(
        _ items: [CategorySpendSummary],
        to categoryLimit: Int?
    ) -> [CategorySpendSummary] {
        let sorted = items.sorted { $0.spent > $1.spent }

        guard let categoryLimit, sorted.count > categoryLimit else {
            return sorted
        }

        let keepCount = max(1, categoryLimit - 1)
        let head = Array(sorted.prefix(keepCount))
        let tail = sorted.dropFirst(keepCount)
        let otherSpent = tail.reduce(0.0) { $0 + $1.spent }
        let otherCount = tail.reduce(0) { $0 + $1.transactionCount }

        if otherSpent <= 0 {
            return Array(sorted.prefix(categoryLimit))
        }

        if let otherIndex = head.firstIndex(where: {
            $0.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "other"
        }) {
            var merged = head
            let existing = merged[otherIndex]
            merged[otherIndex] = CategorySpendSummary(
                category: existing.category,
                spent: existing.spent + otherSpent,
                transactionCount: existing.transactionCount + otherCount
            )
            return merged.sorted { $0.spent > $1.spent }
        }

        return head + [
            CategorySpendSummary(
                category: "Other",
                spent: otherSpent,
                transactionCount: otherCount
            )
        ]
    }

    static func makeCategorySnapshot(
        from allTransactions: [Transaction],
        period: SnapshotPeriod,
        referenceDate: Date = Date(),
        categoryLimit: Int? = nil
    ) -> CategorySpendSnapshot {
        if allTransactions.isEmpty {
            return CategorySpendSnapshot(
                categories: [],
                totalSpend: 0,
                transactionCount: 0,
                period: period,
                isEmptyOrError: true,
                message: "Open the app and tap Sync"
            )
        }

        let index = PeriodSpendIndex.build(
            transactions: allTransactions,
            period: period,
            referenceDate: referenceDate
        )
        let spendRows = index.spendTransactions
        if spendRows.isEmpty {
            return CategorySpendSnapshot(
                categories: [],
                totalSpend: 0,
                transactionCount: 0,
                period: period,
                isEmptyOrError: true,
                message: "No spend in \(period.filterLabel(referenceDate: referenceDate).lowercased())"
            )
        }

        let categories = categorySummaries(from: spendRows, categoryLimit: categoryLimit)
        let sliceTotal = categories.reduce(0.0) { $0 + $1.spent }

        return CategorySpendSnapshot(
            categories: categories,
            totalSpend: sliceTotal,
            transactionCount: spendRows.count,
            period: period,
            isEmptyOrError: false,
            message: nil
        )
    }

    /// Per-card spend (already period-filtered). `excludedCards` omits from the breakdown only.
    static func cardSummaries(
        from transactions: [Transaction],
        excludedCards: Set<String> = [],
        cardLimit: Int? = nil
    ) -> [CardSpendSummary] {
        let visible = excludingCards(spendOnly(transactions), excludedCards: excludedCards)

        var spent: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for transaction in visible {
            let card = cardName(for: transaction)
            spent[card, default: 0] += abs(transaction.amount)
            counts[card, default: 0] += 1
        }

        var list = spent.map { name, amount in
            CardSpendSummary(
                cardName: name,
                spent: amount,
                transactionCount: counts[name] ?? 0
            )
        }
        .sorted { $0.spent > $1.spent }

        if let cardLimit {
            list = Array(list.prefix(cardLimit))
        }
        return list
    }

    /// Widget/app summary: headline totals include ALL cards; `cards` respects hide-card.
    static func makeSnapshot(
        from allTransactions: [Transaction],
        period: SnapshotPeriod,
        excludedCards: Set<String> = [],
        cardLimit: Int = 6
    ) -> FinanceSnapshot {
        if allTransactions.isEmpty {
            return FinanceSnapshot(
                cards: [],
                totalSpend: 0,
                balance: 0,
                transactionCount: 0,
                period: period,
                isEmptyOrError: true,
                message: "Open the app and tap Sync"
            )
        }

        let index = PeriodSpendIndex.build(
            transactions: allTransactions,
            period: period
        )

        if index.spendTransactions.isEmpty {
            return FinanceSnapshot(
                cards: [],
                totalSpend: 0,
                balance: 0,
                transactionCount: 0,
                period: period,
                isEmptyOrError: true,
                message: "No spend in \(period.displayName.lowercased())"
            )
        }

        let cards = cardSummaries(
            from: index.spendTransactions,
            excludedCards: excludedCards,
            cardLimit: cardLimit
        )

        return FinanceSnapshot(
            cards: cards,
            totalSpend: index.totalSpend,
            balance: index.spendBalance,
            transactionCount: index.spendTransactions.count,
            period: period,
            isEmptyOrError: false,
            message: nil
        )
    }
}

// MARK: - Store open / widget load

/// Opens the shared App Group SwiftData store and loads widget/app snapshots.
enum SharedStore {
    /// Must match App Groups entitlement on both app and widget targets.
    nonisolated static let appGroupID = "group.net.roberth.FinanceWizard"

    static let storeName = "FinanceTransactions"

    /// Every SwiftData `@Model` in the App Group store.
    /// Adding a type here also wipes it on “Wipe then restore.”
    static let schema = Schema([
        Transaction.self,
        Income.self,
        BankAccount.self,
        CreditCardPayment.self,
        BudgetPlan.self,
        PayoffPlan.self
    ])

    /// Deletes every row of every schema type. Used by wipe-then-restore so
    /// models added after an old backup was taken do not linger.
    static func wipeAllModels(in context: ModelContext) throws {
        try context.delete(model: Transaction.self)
        try context.delete(model: Income.self)
        try context.delete(model: BankAccount.self)
        try context.delete(model: CreditCardPayment.self)
        try context.delete(model: BudgetPlan.self)
        try context.delete(model: PayoffPlan.self)
    }

    /// Build a ModelContainer both app and widget can open.
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        // Expenses + income share one App Group store as separate models.
        let schema = Self.schema

        if inMemory {
            let configuration = ModelConfiguration(
                storeName,
                schema: schema,
                isStoredInMemoryOnly: true
            )
            return try ModelContainer(for: schema, configurations: [configuration])
        }

        let configuration = ModelConfiguration(
            storeName,
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier(appGroupID)
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Schema changed (e.g. new fields) and lightweight migration failed.
            // Delete the App Group store and create a fresh empty one so the app launches.
            // User can Sync again to re-download transactions + income.
            print("SwiftData open failed, resetting store: \(error)")
            deletePersistentStoreFiles()
            return try ModelContainer(for: schema, configurations: [configuration])
        }
    }

    /// Remove FinanceTransactions.store (+ WAL/SHM) from the App Group container.
    private static func deletePersistentStoreFiles() {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return }

        let support = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)

        let base = support.appendingPathComponent(storeName)
        let candidates = [
            base.appendingPathExtension("store"),
            URL(fileURLWithPath: base.path + ".store"),
            support.appendingPathComponent("\(storeName).store"),
            support.appendingPathComponent("\(storeName).store-shm"),
            support.appendingPathComponent("\(storeName).store-wal"),
            support.appendingPathComponent("\(storeName).store-journal")
        ]

        if let files = try? FileManager.default.contentsOfDirectory(
            at: support,
            includingPropertiesForKeys: nil
        ) {
            for file in files where file.lastPathComponent.hasPrefix(storeName) {
                try? FileManager.default.removeItem(at: file)
            }
        }

        for url in candidates {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func allPaymentMethods() -> [String] {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let transactions = try context.fetch(FetchDescriptor<Transaction>())
            return TransactionAnalytics.paymentMethods(in: transactions)
        } catch {
            return []
        }
    }

    static func loadSnapshot(
        period: SnapshotPeriod = .month,
        excludedCards: Set<String> = [],
        cardLimit: Int = 6
    ) -> FinanceSnapshot {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<Transaction>())
            return TransactionAnalytics.makeSnapshot(
                from: all,
                period: period,
                excludedCards: excludedCards,
                cardLimit: cardLimit
            )
        } catch {
            return FinanceSnapshot(
                cards: [],
                totalSpend: 0,
                balance: 0,
                transactionCount: 0,
                period: period,
                isEmptyOrError: true,
                message: "Store error"
            )
        }
    }

    /// Category chart widget / shared load. `categoryLimit: nil` = all categories (pie path).
    static func loadCategorySnapshot(
        period: SnapshotPeriod = .month,
        categoryLimit: Int? = 8
    ) -> CategorySpendSnapshot {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<Transaction>())
            return TransactionAnalytics.makeCategorySnapshot(
                from: all,
                period: period,
                categoryLimit: categoryLimit
            )
        } catch {
            return CategorySpendSnapshot(
                categories: [],
                totalSpend: 0,
                transactionCount: 0,
                period: period,
                isEmptyOrError: true,
                message: "Store error"
            )
        }
    }

    /// Checking + savings (+ other depository) balances for the home-screen widget.
    static func loadDepositBalancesSnapshot(accountLimit: Int = 12) -> DepositBalancesSnapshot {
        do {
            let container = try makeContainer()
            let context = ModelContext(container)
            let all = try context.fetch(FetchDescriptor<BankAccount>())
            let deposit = all.filter(\.isDepository)

            if deposit.isEmpty {
                return DepositBalancesSnapshot(
                    accounts: [],
                    totalBalance: 0,
                    checkingTotal: 0,
                    savingsTotal: 0,
                    otherTotal: 0,
                    lastSyncedAt: nil,
                    isEmptyOrError: true,
                    message: "Link a bank in Settings, then Sync"
                )
            }

            let rows: [DepositBalanceRow] = deposit
                .map { account in
                    DepositBalanceRow(
                        accountId: account.accountId,
                        displayName: account.displayName,
                        institutionName: account.institutionName,
                        kind: account.depositoryKind,
                        balance: account.displayCashBalance,
                        mask: account.mask
                    )
                }
                .sorted { $0.balance > $1.balance }

            let limited = Array(rows.prefix(accountLimit))
            let checking = rows.filter { $0.kind == .checking }.reduce(0.0) { $0 + $1.balance }
            let savings = rows.filter { $0.kind == .savings }.reduce(0.0) { $0 + $1.balance }
            let other = rows.filter { $0.kind == .other }.reduce(0.0) { $0 + $1.balance }
            let lastSync = deposit.compactMap(\.lastSyncedAt).max()

            return DepositBalancesSnapshot(
                accounts: limited,
                totalBalance: checking + savings + other,
                checkingTotal: checking,
                savingsTotal: savings,
                otherTotal: other,
                lastSyncedAt: lastSync,
                isEmptyOrError: false,
                message: nil
            )
        } catch {
            return DepositBalancesSnapshot(
                accounts: [],
                totalBalance: 0,
                checkingTotal: 0,
                savingsTotal: 0,
                otherTotal: 0,
                lastSyncedAt: nil,
                isEmptyOrError: true,
                message: "Store error"
            )
        }
    }
}
