//
//  CategorySpendChart.swift
//  FinanceWidget
//
//  Reusable category spend charts (app screen + widget).
//

import SwiftUI
import Charts

// Draws category spend in one of several formats (default: horizontal bars)
struct CategorySpendChartView: View {
    // Data already sorted (typically highest spend first)
    let categories: [CategorySpendSummary]
    // Which chart geometry to use
    var format: ChartFormat = .horizontalBar
    // Compact layout for medium/large widgets
    var compact: Bool = false
    // Ultra-tight layout for systemSmall (minimal axes / labels)
    var ultraCompact: Bool = false

    var body: some View {
        if categories.isEmpty {
            if ultraCompact {
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
        case .horizontalBar:
            Chart(categories) { item in
                BarMark(
                    x: .value("Spent", item.spent),
                    y: .value("Category", shortLabel(item.category, max: ultraCompact ? 8 : 14))
                )
                .foregroundStyle(by: .value("Category", item.category))
                .cornerRadius(ultraCompact ? 2 : 4)
            }
            .chartLegend(.hidden)
            .chartXAxis {
                if ultraCompact {
                    // Hide cluttered axis numbers on small widgets
                    AxisMarks(values: .automatic(desiredCount: 2)) { _ in
                        AxisGridLine()
                    }
                } else {
                    AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0)))
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let name = value.as(String.self) {
                            Text(name)
                                .font(ultraCompact ? .system(size: 9) : (compact ? .caption2 : .caption))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.padding(.leading, ultraCompact ? 0 : 2)
            }

        case .verticalBar:
            Chart(categories) { item in
                BarMark(
                    x: .value("Category", shortLabel(item.category, max: ultraCompact ? 4 : 8)),
                    y: .value("Spent", item.spent)
                )
                .foregroundStyle(by: .value("Category", item.category))
                .cornerRadius(ultraCompact ? 2 : 4)
            }
            .chartLegend(.hidden)
            .chartYAxis {
                if ultraCompact {
                    AxisMarks(values: .automatic(desiredCount: 2)) { _ in
                        AxisGridLine()
                    }
                } else {
                    AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0)))
                }
            }
            .chartXAxis {
                if ultraCompact {
                    AxisMarks { _ in
                        // No labels — colors only on small size
                    }
                } else {
                    AxisMarks { value in
                        AxisValueLabel(orientation: .vertical) {
                            if let name = value.as(String.self) {
                                Text(name)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

        case .pie:
            Chart(categories) { item in
                SectorMark(
                    angle: .value("Spent", item.spent),
                    innerRadius: .ratio(ultraCompact ? 0.50 : (compact ? 0.45 : 0.5)),
                    angularInset: ultraCompact ? 1 : 1.5
                )
                .foregroundStyle(by: .value("Category", item.category))
                .cornerRadius(ultraCompact ? 2 : 3)
            }
            // Legend eats vertical space — hide on small
            .chartLegend(ultraCompact ? .hidden : (compact ? .bottom : .trailing))
        }
    }

    // Truncate long category names so axes don’t wrap or clip
    private func shortLabel(_ name: String, max: Int) -> String {
        if name.count <= max { return name }
        return String(name.prefix(max - 1)) + "…"
    }
}
