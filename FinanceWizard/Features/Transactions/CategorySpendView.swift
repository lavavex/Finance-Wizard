//
//  CategorySpendView.swift
//  Finance Wizard
//
//  Full-screen category spend charts opened from “Total Spend”.
//  Teaches: @Query (SwiftData), @State, init seeding State, List, toolbar, Navigation.
//

import SwiftUI
import SwiftData // needed for @Query and modelContainer in previews

// Chart of spend by category for a period (switchable formats)
/// Screen that charts how much you spent per category for a chosen period.
/// Conforms to View: SwiftUI redraws `body` when @Query / @State values change.
struct CategorySpendView: View {
    // @Query loads models from SwiftData and keeps this array in sync with the database.
    // When transactions are inserted/updated/deleted, the view updates automatically.
    @Query private var transactions: [Transaction]

    // @State stores view-owned data that can change over time.
    // Changing it tells SwiftUI to re-run body with the new value.
    // Period to analyze (matches list filters when passed in)
    @State private var period: SnapshotPeriod
    /// Which week/month to chart
    @State private var referenceDate: Date
    // Chart geometry (default horizontal bars)
    @State private var chartFormat: ChartFormat = .horizontalBar

    // Custom init: callers can seed the same period as the list you came from.
    // Underscore form `_period` is the underlying State wrapper (not the unwrapped value).
    // State(initialValue:) sets the starting value before the first body call.
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

    // Snapshot built with shared analytics (not stored in @State — cheap recompute).
    private var snapshot: CategorySpendSnapshot {
        TransactionAnalytics.makeCategorySnapshot(
            from: transactions,
            period: period,
            referenceDate: referenceDate,
            categoryLimit: nil
        )
    }

    var body: some View {
        // List is a scrollable container of rows/sections (like UITableView, but declarative).
        List {
            // Header totals
            // Section groups rows; optional header/footer strings appear above/below.
            Section {
                // HStack = horizontal stack; VStack = vertical stack; Spacer pushes content apart.
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Total Spend")
                            .font(.headline)
                        Text(periodLabel)
                            .font(.caption)
                            // foregroundStyle tints text (secondary = muted system gray).
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    MoneyText(snapshot.totalSpend)
                        .font(.title2.bold())
                }
                Text("\(snapshot.transactionCount) transactions · \(snapshot.categories.count) categories")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Chart type switcher
            Section("Chart type") {
                // $chartFormat is a Binding so the Picker can write the user’s choice into @State.
                Picker("Format", selection: $chartFormat) {
                    ForEach(ChartFormat.allCases) { format in
                        Label(format.displayName, systemImage: format.systemImage)
                            .tag(format)
                    }
                }
                // Segmented control style: equal-width tabs (iOS classic).
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
                    // Give Charts room inside a List row (grouped modifiers are easier to read together).
                    .frame(minHeight: chartHeight)
                    .padding(.vertical, 8)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            }

            // Numeric breakdown (same order as chart)
            // Leading ! means “not” — only show this section when there are categories.
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
                            MoneyText(item.spent)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
        // Navigation modifiers assume this view is inside a NavigationStack (parent supplies it).
        .navigationTitle("Categories")
        // .inline keeps a compact title in the nav bar (not large title).
        .navigationBarTitleDisplayMode(.inline)
        // toolbar adds buttons to the navigation bar.
        .toolbar {
            // ToolbarItem places one control; placement chooses left/right/etc.
            ToolbarItem(placement: .topBarTrailing) {
                // $period and $referenceDate pass Bindings so the menu can change our @State.
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
    // CGFloat is Core Graphics’ floating-point size type (used by frame heights).
    private var chartHeight: CGFloat {
        switch chartFormat {
        case .horizontalBar:
            // max(a, b) picks the larger value so short lists still have a minimum height.
            return max(220, CGFloat(snapshot.categories.count) * 36)
        case .verticalBar:
            return 280
        case .pie:
            return 300
        }
    }
}

// #Preview is a SwiftUI canvas macro — Xcode can show this screen without running the full app.
#Preview {
    // NavigationStack provides the navigation bar and title environment.
    NavigationStack {
        CategorySpendView(period: .month)
    }
    // modelContainer supplies an in-memory SwiftData store so @Query works in previews.
    .modelContainer(for: Transaction.self, inMemory: true)
}
