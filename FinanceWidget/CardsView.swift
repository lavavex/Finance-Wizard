//
//  CardsView.swift
//  FinanceWidget
//
//  Second tab: browse spend and transactions grouped by card.
//

import SwiftUI
import SwiftData

// List of cards → drill into one card’s transactions
struct CardsView: View {
    // All saved transactions (same store as the rest of the app)
    @Query private var transactions: [Transaction]

    // Shared period filter (week / month / all time)
    @State private var period: SnapshotPeriod = .month
    // How rows inside a card are sorted
    @State private var sort: TransactionSort = .dateNewest

    // Cards for the current period (no hide list on this tab — show every card)
    private var cardSummaries: [CardSpendSummary] {
        let inPeriod = TransactionAnalytics.inPeriod(transactions, period: period)
        return TransactionAnalytics.cardSummaries(from: inPeriod, cardLimit: nil)
    }

    // Full-period total spend (all cards)
    private var periodTotalSpend: Double {
        let inPeriod = TransactionAnalytics.inPeriod(transactions, period: period)
        return TransactionAnalytics.totalSpend(in: inPeriod)
    }

    var body: some View {
        NavigationStack {
            List {
                // Summary header
                Section {
                    HStack {
                        Text("Total Spend")
                            .font(.headline)
                        Spacer()
                        Text(periodTotalSpend, format: .currency(code: "USD"))
                            .font(.title3.bold())
                    }
                    Text(period.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // One row per card — tap to see its transactions
                Section("Cards") {
                    if cardSummaries.isEmpty {
                        Text("No cards in this period. Sync data or pick another range.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(cardSummaries) { card in
                            // Push to a detail list for this payment method
                            NavigationLink {
                                CardDetailView(
                                    cardName: card.cardName,
                                    period: period,
                                    sort: sort
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    // Card-style SF Symbol (not a merchant logo)
                                    Image(systemName: CategorySymbol.name(forPaymentMethod: card.cardName))
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .frame(width: 28, alignment: .center)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(card.cardName)
                                            .font(.body)
                                        Text("\(card.transactionCount) transactions")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(card.spent, format: .currency(code: "USD"))
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("By Card")
            .toolbar {
                // Period filter (same options as widget / all-transactions tab)
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Period", selection: $period) {
                            ForEach(SnapshotPeriod.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Label(period.displayName, systemImage: "calendar")
                    }
                }
                // Sort used when you open a card’s transactions
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(TransactionSort.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
    }
}

// Transactions for a single payment method
struct CardDetailView: View {
    // Card / payment method name to show
    let cardName: String
    // Period inherited from the cards list
    let period: SnapshotPeriod
    // Sort inherited from the cards list
    let sort: TransactionSort

    // All transactions; we filter in memory with shared helpers
    @Query private var transactions: [Transaction]

    // Rows for this card + period + sort
    private var cardRows: [Transaction] {
        let inPeriod = TransactionAnalytics.inPeriod(transactions, period: period)
        let forCard = inPeriod.filter {
            TransactionAnalytics.cardName(for: $0) == cardName
        }
        return TransactionAnalytics.sorted(forCard, by: sort)
    }

    private var cardSpend: Double {
        TransactionAnalytics.totalSpend(in: cardRows)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Total")
                    Spacer()
                    Text(cardSpend, format: .currency(code: "USD"))
                        .font(.headline)
                }
                Text("\(period.displayName) · \(cardRows.count) transactions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transactions") {
                if cardRows.isEmpty {
                    Text("No transactions for this card in the selected period.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cardRows) { transaction in
                        TransactionRowView(transaction: transaction)
                    }
                }
            }
        }
        .navigationTitle(cardName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Shared row UI used on All Transactions and By Card detail
struct TransactionRowView: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            // Category SF Symbol (from Shared/CategorySymbol.swift)
            Image(systemName: CategorySymbol.name(forCategory: transaction.category))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, alignment: .center)
                .accessibilityLabel(transaction.category)

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.title)
                    .font(.body)
                Text("\(transaction.category) · \(transaction.paymentMethod)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(transaction.amount, format: .currency(code: "USD"))
                    .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
                Text("\(transaction.multiplier.formatted())x")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    CardsView()
        .modelContainer(for: Transaction.self, inMemory: true)
}
