//
//  CategorySpendChart.swift
//  FinanceWidget
//
//  Category spend charts. Pie labels use SectorMark.annotation so they are
//  always attached to the correct slice (no hand-rolled angle math).
//

import SwiftUI
import Charts

struct CategorySpendChartView: View {
    let categories: [CategorySpendSummary]
    var totalSpend: Double = 0
    var format: ChartFormat = .horizontalBar
    var compact: Bool = false
    var ultraCompact: Bool = false

    private let palette: [Color] = [
        .blue, .orange, .green, .pink, .purple,
        .teal, .indigo, .mint, .cyan, .yellow, .red, .brown
    ]

    private var categoryNames: [String] { categories.map(\.category) }
    private var paletteColors: [Color] {
        categories.indices.map { palette[$0 % palette.count] }
    }

    private var totalText: String { dollarString(totalSpend) }

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
        guard let index = categories.firstIndex(where: { $0.category == category }) else {
            return .secondary
        }
        return palette[index % palette.count]
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

    private var horizontalBars: some View {
        VStack(alignment: .leading, spacing: ultraCompact ? 4 : 6) {
            totalSpendHeader

            applyCategoryColors(
                Chart(categories) { item in
                    BarMark(
                        x: .value("Spent", item.spent),
                        y: .value("Category", item.category)
                    )
                    .foregroundStyle(by: .value("Category", item.category))
                    .cornerRadius(ultraCompact ? 3 : 4)
                    .annotation(position: .trailing, alignment: .leading, spacing: 4) {
                        Text(dollarString(item.spent))
                            .font(ultraCompact ? .system(size: 9, weight: .semibold) : .caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    if ultraCompact {
                        AxisMarks(values: .automatic(desiredCount: 2)) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        }
                    } else {
                        AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0)))
                    }
                }
                .chartYAxis {
                    AxisMarks(values: .automatic) { value in
                        // Named anchors only (no custom UnitPoint)
                        AxisValueLabel(anchor: .leading) {
                            if let name = value.as(String.self) {
                                Image(systemName: CategorySymbol.name(forCategory: name))
                                    .font(ultraCompact ? .system(size: 12, weight: .semibold) : .body.weight(.semibold))
                                    .foregroundStyle(color(for: name))
                                    .accessibilityLabel(name)
                            }
                        }
                    }
                }
                .chartPlotStyle { plot in
                    plot.padding(.trailing, ultraCompact ? 28 : 40)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Vertical bars

    private var verticalBars: some View {
        VStack(alignment: .leading, spacing: ultraCompact ? 4 : 8) {
            totalSpendHeader

            applyCategoryColors(
                Chart(categories) { item in
                    BarMark(
                        x: .value("Category", item.category),
                        y: .value("Spent", item.spent)
                    )
                    .foregroundStyle(by: .value("Category", item.category))
                    .cornerRadius(ultraCompact ? 3 : 4)
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text(dollarString(item.spent))
                            .font(ultraCompact ? .system(size: 8, weight: .semibold) : .caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                }
                .chartLegend(.hidden)
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
                    plot.padding(.top, ultraCompact ? 14 : 18)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                ForEach(categories) { item in
                    Image(systemName: CategorySymbol.name(forCategory: item.category))
                        .font(ultraCompact ? .system(size: 12, weight: .semibold) : .body.weight(.semibold))
                        .foregroundStyle(color(for: item.category))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(item.category)
                }
            }
        }
    }

    // MARK: - Pie
    //
    // Two *separate* Chart views in a ZStack (NOT two SectorMark series in one Chart —
    // that doubles the angle sum and collapses the pie).
    //
    // Chart A: full colored donut (no annotations)
    // Chart B: invisible thinner band closer to center + annotations (pulls labels inward)
    // Both use the same data/order so slices match angularly.

    /// Visible donut hole (also used for clip shape)
    private var pieInnerRatio: CGFloat { 0.50 }

    /// Invisible label band — near the middle of the visible ring
    /// (hole 0.50 → rim 1.0). Not too outer, not too inner.
    private var pieLabelInner: CGFloat { 0.64 }
    private var pieLabelOuter: CGFloat { 0.84 }

    private var pieChart: some View {
        ZStack {
            // A) Visible pie — no annotations (full size, clean geometry)
            applyCategoryColors(
                Chart(categories) { item in
                    SectorMark(
                        angle: .value("Spent", item.spent),
                        innerRadius: .ratio(pieInnerRatio),
                        outerRadius: .ratio(1.0),
                        angularInset: 1.5
                    )
                    .foregroundStyle(by: .value("Category", item.category))
                    .cornerRadius(3)
                }
                .chartLegend(.hidden)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartPlotStyle { $0.padding(0) }
            )

            // B) Label layer only — own Chart so angles stay a full 360° pie
            Chart(categories) { item in
                SectorMark(
                    angle: .value("Spent", item.spent),
                    innerRadius: .ratio(pieLabelInner),
                    outerRadius: .ratio(pieLabelOuter),
                    angularInset: 1.5
                )
                // Fully transparent — only exists so annotation centroid is mid-inner ring
                .foregroundStyle(.clear)
                .annotation(position: .overlay) {
                    pieSegmentWatermark(for: item)
                }
            }
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { $0.padding(0) }
            .allowsHitTesting(false)
            // Clip watermarks to the visible donut ring (slight cut inside + outside)
            .clipShape(DonutClipShape(innerRatio: pieInnerRatio), style: FillStyle(eoFill: true))

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

    /// Icon behind (watermark); amount in front on the z-axis.
    @ViewBuilder
    private func pieSegmentWatermark(for item: CategorySpendSummary) -> some View {
        let share = item.spent / max(totalSpend, 0.0001)
        if share < (ultraCompact ? 0.05 : 0.04) {
            EmptyView()
        } else {
            let iconSize: CGFloat = ultraCompact
                ? (share > 0.25 ? 28 : 22)
                : (share > 0.25 ? 34 : 28)

            ZStack {
                Image(systemName: CategorySymbol.name(forCategory: item.category))
                    .font(.system(size: iconSize, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.white.opacity(ultraCompact ? 0.40 : 0.46))

                Text(dollarString(item.spent))
                    .font(ultraCompact ? .system(size: 11, weight: .bold) : .system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .shadow(color: .black.opacity(0.55), radius: 1.5, y: 0.5)
            }
            .fixedSize()
            .accessibilityLabel("\(item.category), \(dollarString(item.spent))")
        }
    }
}

// Donut-shaped clip: outer circle minus inner hole (even-odd fill)
private struct DonutClipShape: Shape {
    var innerRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        var path = Path()
        path.addEllipse(in: CGRect(
            x: center.x - outer,
            y: center.y - outer,
            width: outer * 2,
            height: outer * 2
        ))
        path.addEllipse(in: CGRect(
            x: center.x - inner,
            y: center.y - inner,
            width: inner * 2,
            height: inner * 2
        ))
        return path
    }
}
