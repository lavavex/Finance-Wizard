//
//  SharedStore.swift
//  Finance Wizard
//
//  Shared SwiftData configuration + filter/sort helpers used by app and widget.
//

import Foundation
import SwiftData

// One card's total spending for lists / widget breakdown
struct CardSpendSummary: Identifiable {
    // Identifiable needs a stable id — use the card name
    var id: String { cardName }
    // Payment method string from transactions (e.g. "Chase Freedom")
    let cardName: String
    // Total spent on this card as a positive number (easier to read)
    let spent: Double
    // How many transactions on this card (in the current filter)
    let transactionCount: Int
}

// One budget category’s total for charts
struct CategorySpendSummary: Identifiable {
    // Stable id = category name
    var id: String { category }
    // Budget category (Dining, Gas (Car), …)
    let category: String
    // Positive dollars spent in this category
    let spent: Double
    // How many transactions in this category
    let transactionCount: Int
}

// Chart layout options (app + category widget)
enum ChartFormat: String, CaseIterable, Identifiable, Sendable {
    // Default: bars grow left → right, categories on Y axis
    case horizontalBar
    // Bars grow bottom → top, categories on X axis
    case verticalBar
    // Pie / donut style (sector marks)
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

// Snapshot for category charts (app screen + category widget)
struct CategorySpendSnapshot {
    let categories: [CategorySpendSummary]
    let totalSpend: Double
    let transactionCount: Int
    let period: SnapshotPeriod
    let isEmptyOrError: Bool
    let message: String?
}

// Which calendar window totals use
enum SnapshotPeriod: String, CaseIterable, Identifiable, Sendable {
    // Calendar week containing `referenceDate` (locale-aware week start → end)
    case week
    // Calendar month containing `referenceDate` (1st → last day)
    case month
    // No date filter — every saved transaction
    case all

    var id: String { rawValue }

    // Short label for period pickers (not a specific month name)
    var displayName: String {
        switch self {
        case .week: return "This week"
        case .month: return "Month"
        case .all: return "All time"
        }
    }

    /// Header label for the active filter (e.g. "June 2026", "This month", "Jul 20–26")
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
            // Full month name, e.g. "July"
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.setLocalizedDateFormatFromTemplate("MMMM")
            return formatter.string(from: now)
        case .week:
            // Compact week range in the current month context, e.g. "Jul 20–26"
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else {
                return "Week"
            }
            let start = interval.start
            // interval.end is exclusive
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

// How a transaction list is ordered (app + reusable helpers)
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

// Snapshot of store data the widget (and app summary) can display
struct FinanceSnapshot {
    // Cards sorted by most spent first (after hide-card filter)
    let cards: [CardSpendSummary]
    // Period total across ALL cards (hide-card does NOT shrink this)
    // Positive = money spent (sum of abs amounts in period)
    let totalSpend: Double
    // Signed balance for the period across ALL cards (expenses negative in our model)
    let balance: Double
    // How many transactions are in the period (all cards)
    let transactionCount: Int
    // Which period was used
    let period: SnapshotPeriod
    // True if we could not open the store or nothing in the period
    let isEmptyOrError: Bool
    // Optional short status text
    let message: String?
}

// MARK: - Pure helpers (work on any array — app @Query or widget fetch)

enum TransactionAnalytics {
    // Normalize empty payment method strings
    static func cardName(for transaction: Transaction) -> String {
        transaction.paymentMethod.isEmpty ? "Unknown" : transaction.paymentMethod
    }

    // First moment of the week / month containing `now`, or nil for “all”
    static func startDate(for period: SnapshotPeriod, now: Date = Date()) -> Date? {
        dateInterval(for: period, referenceDate: now)?.start
    }

    /// Inclusive start / exclusive end for week or month; nil for all-time.
    /// `referenceDate` picks which week/month (any day inside that period works).
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
        var components = Set<DateComponents>()
        for transaction in transactions {
            components.insert(calendar.dateComponents([.year, .month], from: transaction.date))
        }
        components.insert(calendar.dateComponents([.year, .month], from: now))

        return components
            .compactMap { calendar.date(from: $0) }
            .sorted(by: >)
    }

    // Keep transactions in the selected period (does not hide cards).
    // For month/week, only rows inside that calendar interval are kept
    // (so “June” does not accidentally include July).
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

    // Drop transactions whose card is in the hide list
    static func excludingCards(_ transactions: [Transaction], excludedCards: Set<String>) -> [Transaction] {
        guard !excludedCards.isEmpty else { return transactions }
        return transactions.filter { !excludedCards.contains(cardName(for: $0)) }
    }

    // Filter by period, optional card hide, then sort
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

    // Sort a list without changing membership
    static func sorted(_ transactions: [Transaction], by sort: TransactionSort) -> [Transaction] {
        switch sort {
        case .dateNewest:
            return transactions.sorted { $0.date > $1.date }
        case .dateOldest:
            return transactions.sorted { $0.date < $1.date }
        case .amountLargest:
            // Largest magnitude first (biggest expense or income)
            return transactions.sorted { abs($0.amount) > abs($1.amount) }
        case .amountSmallest:
            return transactions.sorted { abs($0.amount) < abs($1.amount) }
        case .titleAZ:
            return transactions.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    // Positive dollars spent in a set of transactions
    static func totalSpend(in transactions: [Transaction]) -> Double {
        transactions.reduce(0) { $0 + abs($1.amount) }
    }

    // Signed balance (our model: expenses negative)
    static func balance(in transactions: [Transaction]) -> Double {
        transactions.reduce(0) { $0 + $1.amount }
    }

    // Unique card names, sorted A–Z
    static func paymentMethods(in transactions: [Transaction]) -> [String] {
        Set(transactions.map { cardName(for: $0) }).sorted()
    }

    // Normalize empty category strings
    static func categoryName(for transaction: Transaction) -> String {
        transaction.category.isEmpty ? "Uncategorized" : transaction.category
    }

    // Per-category spend for charts (period should already be applied by caller).
    // When limited, leftover spend is rolled into "Other" so pie slices always
    // sum to the same total shown in the center.
    static func categorySummaries(
        from transactions: [Transaction],
        categoryLimit: Int? = nil
    ) -> [CategorySpendSummary] {
        var spent: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for transaction in transactions {
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
        // Already sorted highest → lowest by callers; re-sort to be safe
        let sorted = items.sorted { $0.spent > $1.spent }

        guard let categoryLimit, sorted.count > categoryLimit else {
            return sorted
        }

        // Keep top (limit - 1) rows; merge the rest into Other
        let keepCount = max(1, categoryLimit - 1)
        let head = Array(sorted.prefix(keepCount))
        let tail = sorted.dropFirst(keepCount)
        let otherSpent = tail.reduce(0.0) { $0 + $1.spent }
        let otherCount = tail.reduce(0) { $0 + $1.transactionCount }

        if otherSpent <= 0 {
            return Array(sorted.prefix(categoryLimit))
        }

        // If "Other" is already in the head, fold the tail into that row
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

    // Full category chart snapshot for a period
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

        let inPeriodRows = inPeriod(allTransactions, period: period, referenceDate: referenceDate)
        if inPeriodRows.isEmpty {
            return CategorySpendSnapshot(
                categories: [],
                totalSpend: 0,
                transactionCount: 0,
                period: period,
                isEmptyOrError: true,
                message: "No spend in \(period.filterLabel(referenceDate: referenceDate).lowercased())"
            )
        }

        let categories = categorySummaries(from: inPeriodRows, categoryLimit: categoryLimit)
        // Total = sum of slices (includes Other) so the pie always adds up
        let sliceTotal = categories.reduce(0.0) { $0 + $1.spent }

        return CategorySpendSnapshot(
            categories: categories,
            totalSpend: sliceTotal,
            transactionCount: inPeriodRows.count,
            period: period,
            isEmptyOrError: false,
            message: nil
        )
    }

    // Per-card spend for a transaction set (already period-filtered as needed)
    // excludedCards: omit from the breakdown only (not from totalSpend callers)
    static func cardSummaries(
        from transactions: [Transaction],
        excludedCards: Set<String> = [],
        cardLimit: Int? = nil
    ) -> [CardSpendSummary] {
        // Only rows that should appear in the card breakdown
        let visible = excludingCards(transactions, excludedCards: excludedCards)

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

    // Build a widget/app summary:
    // - totalSpend / balance / transactionCount = ALL cards in period
    // - cards list = period rows minus excluded cards
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

        // Period only — used for the big total (ignores hide-card)
        let inPeriodRows = inPeriod(allTransactions, period: period)

        if inPeriodRows.isEmpty {
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
            from: inPeriodRows,
            excludedCards: excludedCards,
            cardLimit: cardLimit
        )

        return FinanceSnapshot(
            cards: cards,
            // Full period total — hide-card does not change this
            totalSpend: totalSpend(in: inPeriodRows),
            balance: balance(in: inPeriodRows),
            transactionCount: inPeriodRows.count,
            period: period,
            isEmptyOrError: false,
            message: nil
        )
    }
}

// MARK: - Store open / widget load

enum SharedStore {
    // Must match App Groups entitlement on BOTH app and widget targets
    static let appGroupID = "group.net.roberth.FinanceWizard"

    // File name for the SwiftData store inside the App Group container
    static let storeName = "FinanceTransactions"

    // Build a ModelContainer both app and widget can open
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        // Expenses + income share one App Group store; keep them as separate models
        // so spend analytics never accidentally include income.
        let schema = Schema([Transaction.self, Income.self])

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

    // Remove FinanceTransactions.store (+ WAL/SHM) from the App Group container
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

        // Also sweep any file that starts with the store name (covers -shm/-wal variants)
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

    // Unique payment method names currently in the store
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

    // Widget entry point: open store, then same analytics as the app
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

    // Category chart widget / shared load.
    // Pass categoryLimit: nil for “all categories” (pie loads full data, then
    // merges by color and applies the family limit on the final slices).
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
}
