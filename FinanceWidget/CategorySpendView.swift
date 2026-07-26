//
//  CategorySpendView.swift
//  FinanceWidget
//
//  Full-screen category spend charts opened from “Total Spend”.
//

import SwiftUI
import SwiftData

// Chart of spend by category for a period (switchable formats)
struct CategorySpendView: View {
    // All transactions from SwiftData
    @Query private var transactions: [Transaction]

    // Period to analyze (matches list filters when passed in)
    @State private var period: SnapshotPeriod
    /// Which week/month to chart
    @State private var referenceDate: Date
    // Chart geometry (default horizontal bars)
    @State private var chartFormat: ChartFormat = .horizontalBar

    // Caller can seed the same period as the list you came from
    init(
        period: SnapshotPeriod = .month,
        referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    ) {
        _period = State(initialValue: period)
        _referenceDate = State(initialValue: referenceDate)
    }

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    // Snapshot built with shared analytics
    private var snapshot: CategorySpendSnapshot {
        TransactionAnalytics.makeCategorySnapshot(
            from: transactions,
            period: period,
            referenceDate: referenceDate,
            categoryLimit: nil
        )
    }

    var body: some View {
        List {
            // Header totals
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Spend")
                            .font(.headline)
                        Text(periodLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(snapshot.totalSpend, format: .currency(code: "USD"))
                        .font(.title2.bold())
                }
                Text("\(snapshot.transactionCount) transactions · \(snapshot.categories.count) categories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Chart type switcher
            Section("Chart type") {
                Picker("Format", selection: $chartFormat) {
                    ForEach(ChartFormat.allCases) { format in
                        Label(format.displayName, systemImage: format.systemImage)
                            .tag(format)
                    }
                }
                .pickerStyle(.segmented)
            }

            // The chart
            Section("By category") {
                if snapshot.isEmptyOrError {
                    Text(snapshot.message ?? "No data")
                        .foregroundStyle(.secondary)
                } else {
                    CategorySpendChartView(
                        categories: snapshot.categories,
                        totalSpend: snapshot.totalSpend,
                        format: chartFormat,
                        compact: false,
                        ultraCompact: false
                    )
                    // Give Charts room inside a List row
                    .frame(minHeight: chartHeight)
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }

            // Numeric breakdown (same order as chart)
            if !snapshot.categories.isEmpty {
                Section("Breakdown") {
                    ForEach(snapshot.categories) { item in
                        HStack(spacing: 12) {
                            Image(systemName: CategoryStyle.symbolName(for: item.category))
                                .foregroundStyle(CategoryStyle.color(for: item.category))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.category)
                                Text("\(item.transactionCount) transactions")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.spent, format: .currency(code: "USD"))
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PeriodFilterMenu(
                    period: $period,
                    referenceDate: $referenceDate,
                    transactions: transactions,
                    showTitle: true
                )
            }
        }
    }

    // Taller chart for horizontal bars (many categories need vertical space)
    private var chartHeight: CGFloat {
        switch chartFormat {
        case .horizontalBar:
            return max(220, CGFloat(snapshot.categories.count) * 36)
        case .verticalBar:
            return 280
        case .pie:
            return 300
        }
    }
}

#Preview {
    NavigationStack {
        CategorySpendView(period: .month)
    }
    .modelContainer(for: Transaction.self, inMemory: true)
}
