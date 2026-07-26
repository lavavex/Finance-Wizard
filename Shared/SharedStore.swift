//
//  SharedStore.swift
//  FinanceWidget
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

// Which calendar window totals use
enum SnapshotPeriod: String, CaseIterable, Identifiable, Sendable {
    // Current calendar week (locale-aware start of week → now)
    case week
    // Current calendar month (1st of month → now)
    case month
    // No date filter — every saved transaction
    case all

    var id: String { rawValue }

    // Short label for pickers and headers
    var displayName: String {
        switch self {
        case .week: return "This week"
        case .month: return "This month"
        case .all: return "All time"
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

    // First moment of the current week / month, or distant past for “all”
    static func startDate(for period: SnapshotPeriod, now: Date = Date()) -> Date? {
        let calendar = Calendar.current
        switch period {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start
        case .all:
            // nil means “no lower bound”
            return nil
        }
    }

    // Keep transactions in the selected period (does not hide cards)
    static func inPeriod(_ transactions: [Transaction], period: SnapshotPeriod) -> [Transaction] {
        guard let start = startDate(for: period) else {
            return transactions
        }
        return transactions.filter { $0.date >= start }
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
        excludedCards: Set<String> = [],
        sort: TransactionSort = .dateNewest
    ) -> [Transaction] {
        let byPeriod = inPeriod(transactions, period: period)
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
    static let appGroupID = "group.net.roberth.FinanceWidget"

    // File name for the SwiftData store inside the App Group container
    static let storeName = "FinanceTransactions"

    // Build a ModelContainer both app and widget can open
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([Transaction.self])

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

        return try ModelContainer(for: schema, configurations: [configuration])
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
}
