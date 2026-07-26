//
//  CategorySpendWidget.swift
//  Widget
//
//  Separate widget: spend by category charts (default horizontal bars).
//  No “Categories” title — pie has total in the center; bars use SF Symbol labels.
//

import WidgetKit
import SwiftUI
import AppIntents
import Charts

// MARK: - Configuration

enum CategoryChartStyleOption: String, AppEnum {
    case horizontalBar
    case verticalBar
    case pie

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Chart Style")
    }

    static var caseDisplayRepresentations: [CategoryChartStyleOption: DisplayRepresentation] {
        [
            .horizontalBar: DisplayRepresentation(title: "Horizontal bars"),
            .verticalBar: DisplayRepresentation(title: "Vertical bars"),
            .pie: DisplayRepresentation(title: "Pie")
        ]
    }

    var chartFormat: ChartFormat {
        switch self {
        case .horizontalBar: return .horizontalBar
        case .verticalBar: return .verticalBar
        case .pie: return .pie
        }
    }
}

struct CategorySpendConfigIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Spend by Category" }
    static var description: IntentDescription {
        IntentDescription("Chart of spending by budget category. Default is horizontal bars.")
    }

    @Parameter(title: "Time range", default: .month)
    var period: SpendPeriodOption

    @Parameter(title: "Chart style", default: .horizontalBar)
    var chartStyle: CategoryChartStyleOption
}

// MARK: - Timeline

struct CategorySpendEntry: TimelineEntry {
    let date: Date
    let snapshot: CategorySpendSnapshot
    let chartFormat: ChartFormat
    /// Applied after pie color-merge (bars ignore this; snapshot is already limited).
    var pieSliceLimit: Int? = nil
}

struct CategorySpendProvider: AppIntentTimelineProvider {
    typealias Intent = CategorySpendConfigIntent

    func placeholder(in context: Context) -> CategorySpendEntry {
        CategorySpendEntry(
            date: Date(),
            snapshot: CategorySpendSnapshot(
                categories: [
                    CategorySpendSummary(category: "Dining", spent: 120, transactionCount: 8),
                    CategorySpendSummary(category: "Gas (Car)", spent: 80, transactionCount: 5),
                    CategorySpendSummary(category: "Groceries", spent: 200, transactionCount: 6)
                ],
                totalSpend: 400,
                transactionCount: 19,
                period: .month,
                isEmptyOrError: false,
                message: nil
            ),
            chartFormat: .horizontalBar
        )
    }

    func snapshot(for configuration: CategorySpendConfigIntent, in context: Context) async -> CategorySpendEntry {
        makeEntry(for: configuration, family: context.family)
    }

    func timeline(for configuration: CategorySpendConfigIntent, in context: Context) async -> Timeline<CategorySpendEntry> {
        let entry = makeEntry(for: configuration, family: context.family)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(for configuration: CategorySpendConfigIntent, family: WidgetFamily) -> CategorySpendEntry {
        // How many bars / pie slices this widget size can show
        let limit: Int
        switch family {
        case .systemSmall: limit = 6
        case .systemMedium: limit = 8
        default: limit = 10
        }

        let chartFormat = configuration.chartStyle.chartFormat
        // Pie merges budget categories into Apple Card color groups. Load *all*
        // raw categories so each color group can form its own slice; the chart
        // then applies `limit` to the merged slices. Bars still pre-limit.
        let snapshot = SharedStore.loadCategorySnapshot(
            period: configuration.period.snapshotPeriod,
            categoryLimit: chartFormat == .pie ? nil : limit
        )
        return CategorySpendEntry(
            date: Date(),
            snapshot: snapshot,
            chartFormat: chartFormat,
            pieSliceLimit: limit
        )
    }
}

// MARK: - View

struct CategorySpendWidgetView: View {
    var entry: CategorySpendEntry
    @Environment(\.widgetFamily) private var family

    private var isSmall: Bool { family == .systemSmall }

    var body: some View {
        Group {
            if entry.snapshot.isEmptyOrError {
                Text(entry.snapshot.message ?? "No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                // Chart fills the widget — no “Categories” title
                // Pie: total in the donut hole; bars: SF Symbol labels on the category axis
                CategorySpendChartView(
                    categories: entry.snapshot.categories,
                    totalSpend: entry.snapshot.totalSpend,
                    format: entry.chartFormat,
                    compact: !isSmall,
                    ultraCompact: isSmall,
                    pieSliceLimit: entry.pieSliceLimit
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget definition

struct CategorySpendWidget: Widget {
    let kind: String = "CategorySpendWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CategorySpendConfigIntent.self,
            provider: CategorySpendProvider()
        ) { entry in
            CategorySpendWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Spend by Category")
        .description("Chart of spending by category. Defaults to horizontal bars.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemSmall) {
    CategorySpendWidget()
} timeline: {
    CategorySpendEntry(
        date: .now,
        snapshot: CategorySpendSnapshot(
            categories: [
                CategorySpendSummary(category: "Dining", spent: 120, transactionCount: 8),
                CategorySpendSummary(category: "Gas (Car)", spent: 80, transactionCount: 5),
                CategorySpendSummary(category: "Groceries", spent: 200.55, transactionCount: 6)
            ],
            totalSpend: 400.55,
            transactionCount: 19,
            period: .month,
            isEmptyOrError: false,
            message: nil
        ),
        chartFormat: .horizontalBar
    )
}

#Preview(as: .systemSmall) {
    CategorySpendWidget()
} timeline: {
    CategorySpendEntry(
        date: .now,
        snapshot: CategorySpendSnapshot(
            categories: [
                CategorySpendSummary(category: "Dining", spent: 120, transactionCount: 8),
                CategorySpendSummary(category: "Gas (Car)", spent: 80, transactionCount: 5),
                CategorySpendSummary(category: "Groceries", spent: 200.55, transactionCount: 6)
            ],
            totalSpend: 400.55,
            transactionCount: 19,
            period: .month,
            isEmptyOrError: false,
            message: nil
        ),
        chartFormat: .pie
    )
}
