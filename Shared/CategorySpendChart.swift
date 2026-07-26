//
//  CategorySpendChart.swift
//  FinanceWidget
//
//  Category spend charts.
//  Bar icons/$ are BarMark.annotations so they stay locked to the correct bar.
//  Pie uses two separate Chart views for label position.
//

import SwiftUI
import Charts

struct CategorySpendChartView: View {
    let categories: [CategorySpendSummary]
    var totalSpend: Double = 0
    var format: ChartFormat = .horizontalBar
    var compact: Bool = false
    var ultraCompact: Bool = false
    /// Max pie slices after Apple Card color merge (bars use pre-limited `categories`).
    var pieSliceLimit: Int? = nil

    private var categoryNames: [String] { categories.map(\.category) }

    // Fixed Apple Card–style colors per category name (not by bar index)
    private var paletteColors: [Color] {
        CategoryStyle.colors(for: categoryNames)
    }

    private var totalText: String { dollarString(totalSpend) }

    /// Highest spend first (individual categories — bars / default)
    private var orderedCategories: [CategorySpendSummary] { categories }

    /// Pie: merge same-color categories first, then apply slice limit.
    /// (Limiting raw categories first was collapsing 6 rows into ~4 color slices.)
    private var pieCombinedCategories: [CategorySpendSummary] {
        let combined = CategoryStyle.combineByColor(categories)
        return TransactionAnalytics.limitCategorySummaries(combined, to: pieSliceLimit)
    }

    /// Explicit category order for bar scales (highest spend first)
    private var categoryDomain: [String] {
        orderedCategories.map(\.category)
    }

    /// Largest bar value — used so X/Y value scales start at 0 (not negative).
    /// Leading annotations were expanding the domain below zero and centering bars.
    private var maxSpent: Double {
        max(orderedCategories.map(\.spent).max() ?? 0, 1)
    }

    /// Domain 0…max with a little headroom for trailing / top $ labels
    private var spendDomain: ClosedRange<Double> {
        0...(maxSpent * 1.18)
    }

    var body: some View {
        if categories.isEmpty {
            if ultraCompact || compact {
                Text("No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(
                    "No category data",
                    systemImage: "chart.bar.xaxis",
                    description: Text("Sync transactions to see spend by category.")
                )
            }
        } else {
            chart
        }
    }

    @ViewBuilder
    private var chart: some View {
        switch format {
        case .horizontalBar: horizontalBars
        case .verticalBar: verticalBars
        case .pie: pieChart
        }
    }

    // MARK: - Helpers

    private func color(for category: String) -> Color {
        CategoryStyle.color(for: category)
    }

    private func dollarString(_ value: Double) -> String {
        value.rounded().formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    private func applyCategoryColors<V: View>(_ content: V) -> some View {
        content.chartForegroundStyleScale(domain: categoryNames, range: paletteColors)
    }

    private var totalSpendHeader: some View {
        Text(totalText)
            .font(ultraCompact ? .caption.weight(.bold) : .subheadline.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: ultraCompact ? .center : .leading)
            .accessibilityLabel("Total spend \(totalText)")
    }

    // MARK: - Horizontal bars
    // Icons + $ are annotations on each BarMark → always the correct row.
    // No separate icon column (those drifted / reversed against the plot).

    private var horizontalBars: some View {
        VStack(alignment: .leading, spacing: ultraCompact ? 4 : 6) {
            totalSpendHeader

            applyCategoryColors(
                Chart(orderedCategories) { item in
                    BarMark(
                        x: .value("Spent", item.spent),
                        y: .value("Category", item.category)
                    )
                    .foregroundStyle(by: .value("Category", item.category))
                    .cornerRadius(ultraCompact ? 3 : 4)
                    // Icon locked to this bar
                    .annotation(position: .leading, alignment: .trailing, spacing: 6) {
                        Image(systemName: CategorySymbol.name(forCategory: item.category))
                            .font(ultraCompact ? .system(size: 12, weight: .semibold) : .body.weight(.semibold))
                            .foregroundStyle(color(for: item.category))
                            .accessibilityLabel(item.category)
                    }
                    // $ locked to this bar
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        Text(dollarString(item.spent))
                            .font(ultraCompact ? .system(size: 9, weight: .semibold) : .caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .chartLegend(.hidden)
                .chartYScale(domain: categoryDomain)
                // Force spend axis to start at $0 — never negative / centered
                .chartXScale(domain: spendDomain)
                .chartYAxis(.hidden)
                .chartXAxis {
                    if ultraCompact {
                        AxisMarks(values: .automatic(desiredCount: 2)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        }
                    } else {
                        AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0)))
                    }
                }
                .chartPlotStyle { plot in
                    // Visual inset for icons/$ only — does not expand the value domain
                    plot
                        .padding(.leading, ultraCompact ? 22 : 28)
                        .padding(.trailing, ultraCompact ? 32 : 44)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Vertical bars
    // Icon + $ as bottom annotations on each BarMark → always the correct column.

    private var verticalBars: some View {
        VStack(alignment: .leading, spacing: ultraCompact ? 4 : 6) {
            totalSpendHeader

            applyCategoryColors(
                Chart(orderedCategories) { item in
                    BarMark(
                        x: .value("Category", item.category),
                        y: .value("Spent", item.spent)
                    )
                    .foregroundStyle(by: .value("Category", item.category))
                    .cornerRadius(ultraCompact ? 3 : 4)
                    .annotation(position: .bottom, alignment: .center, spacing: 4) {
                        VStack(spacing: ultraCompact ? 2 : 3) {
                            Image(systemName: CategorySymbol.name(forCategory: item.category))
                                .font(ultraCompact ? .system(size: 11, weight: .semibold) : .body.weight(.semibold))
                                .foregroundStyle(color(for: item.category))
                            Text(dollarString(item.spent))
                                .font(ultraCompact ? .system(size: 8, weight: .semibold) : .caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                        }
                        .accessibilityLabel("\(item.category), \(dollarString(item.spent))")
                    }
                }
                .chartLegend(.hidden)
                .chartXScale(domain: categoryDomain)
                // Force spend axis to start at $0 — never negative / centered
                .chartYScale(domain: spendDomain)
                .chartXAxis(.hidden)
                .chartYAxis {
                    if ultraCompact {
                        AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        }
                    } else {
                        AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0)))
                    }
                }
                .chartPlotStyle { plot in
                    plot.padding(.bottom, ultraCompact ? 30 : 40)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pie
    // Layer order: colored ring → icons (masked to each wedge) → $ amounts
    // (unmasked so text stays fully readable) → center total.

    private var pieInnerRatio: CGFloat { 0.50 }
    /// Thin clear band where Chart places the overlay annotation (mid-ring).
    private var pieLabelInner: CGFloat { 0.64 }
    private var pieLabelOuter: CGFloat { 0.84 }

    private var pieChart: some View {
        // Merge Dining+Coffee, Shopping+Groceries, etc. into one slice per color
        let slices = pieCombinedCategories
        let sliceNames = slices.map(\.category)
        let sliceColors = CategoryStyle.colors(for: sliceNames)
        let sliceTotal = max(slices.reduce(0) { $0 + $1.spent }, 0.0001)

        return ZStack {
            // Colored donut only
            Chart(slices) { item in
                SectorMark(
                    angle: .value("Spent", item.spent),
                    innerRadius: .ratio(pieInnerRatio),
                    outerRadius: .ratio(1.0),
                    angularInset: 1.5
                )
                .foregroundStyle(by: .value("Category", item.category))
                .cornerRadius(3)
            }
            .chartForegroundStyleScale(domain: sliceNames, range: sliceColors)
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { $0.padding(0) }

            // Icons only — each masked to its own sector so they cut at the wedge edge
            ForEach(slices) { item in
                let share = item.spent / sliceTotal
                if share >= (ultraCompact ? 0.05 : 0.04) {
                    pieLabelChart(slices: slices) { sector in
                        if sector.id == item.id {
                            pieSegmentIcon(for: item, share: share)
                        }
                    }
                    .compositingGroup()
                    .mask {
                        // Same SectorMark layout as the colored pie → edges match
                        Chart(slices) { sector in
                            SectorMark(
                                angle: .value("Spent", sector.spent),
                                innerRadius: .ratio(pieInnerRatio),
                                outerRadius: .ratio(1.0),
                                angularInset: 1.5
                            )
                            .foregroundStyle(sector.id == item.id ? Color.white : Color.clear)
                            .cornerRadius(3)
                        }
                        .chartLegend(.hidden)
                        .chartXAxis(.hidden)
                        .chartYAxis(.hidden)
                        .chartPlotStyle { $0.padding(0) }
                    }
                    .allowsHitTesting(false)
                }
            }

            // $ amounts — same sector centers, no wedge mask (text must stay whole)
            pieLabelChart(slices: slices) { item in
                let share = item.spent / sliceTotal
                if share >= (ultraCompact ? 0.05 : 0.04) {
                    pieSegmentAmount(for: item)
                }
            }
            .allowsHitTesting(false)

            // Grand total in the hole
            Text(totalText)
                .font(ultraCompact ? .subheadline.weight(.bold) : .title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .frame(maxWidth: ultraCompact ? 72 : 110)
                .allowsHitTesting(false)
                .accessibilityLabel("Total spend \(totalText)")
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Clear mid-ring Chart used only to place annotations on true sector centers.
    private func pieLabelChart<Content: View>(
        slices: [CategorySpendSummary],
        @ViewBuilder annotation: @escaping (CategorySpendSummary) -> Content
    ) -> some View {
        Chart(slices) { sector in
            SectorMark(
                angle: .value("Spent", sector.spent),
                innerRadius: .ratio(pieLabelInner),
                outerRadius: .ratio(pieLabelOuter),
                angularInset: 1.5
            )
            .foregroundStyle(.clear)
            .annotation(position: .overlay) {
                annotation(sector)
            }
        }
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(0) }
    }

    /// Category icon (clipped by sector mask).
    @ViewBuilder
    private func pieSegmentIcon(for item: CategorySpendSummary, share: Double) -> some View {
        let iconSize: CGFloat = ultraCompact
            ? (share > 0.3 ? 30 : 24)
            : (share > 0.3 ? 36 : 30)

        Image(systemName: CategorySymbol.name(forCategory: item.category))
            .font(.system(size: iconSize, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.white.opacity(ultraCompact ? 0.40 : 0.48))
            .accessibilityHidden(true)
    }

    /// Dollar label drawn above icons — not sector-masked.
    @ViewBuilder
    private func pieSegmentAmount(for item: CategorySpendSummary) -> some View {
        Text(dollarString(item.spent))
            .font(ultraCompact ? .system(size: 11, weight: .bold) : .system(size: 13, weight: .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
            .shadow(color: .black.opacity(0.55), radius: 1.5, y: 0.5)
            .fixedSize()
            .accessibilityLabel("\(item.category), \(dollarString(item.spent))")
    }
}
