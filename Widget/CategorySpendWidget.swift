//
//  CategorySpendWidget.swift
//  Widget
//
//  Separate widget: spend by category charts (default horizontal bars).
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
}

struct CategorySpendProvider: AppIntentTimelineProvider {
    typealias Intent = CategorySpendConfigIntent

    func placeholder(in context: Context) -> CategorySpendEntry {
        CategorySpendEntry(
            date: Date(),
            snapshot: CategorySpendSnapshot(
                categories: [
                    CategorySpendSummary(category: "Dining", spent: 120, transactionCount: 8),
                    CategorySpendSummary(category: "Gas", spent: 80, transactionCount: 5),
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
        // Fewer slices/bars on small so labels and marks fit
        let limit: Int
        switch family {
        case .systemSmall: limit = 3
        case .systemMedium: limit = 5
        default: limit = 8
        }

        let snapshot = SharedStore.loadCategorySnapshot(
            period: configuration.period.snapshotPeriod,
            categoryLimit: limit
        )
        return CategorySpendEntry(
            date: Date(),
            snapshot: snapshot,
            chartFormat: configuration.chartStyle.chartFormat
        )
    }
}

// MARK: - View

struct CategorySpendWidgetView: View {
    var entry: CategorySpendEntry
    @Environment(\.widgetFamily) private var family

    private var isSmall: Bool { family == .systemSmall }

    private var periodShort: String {
        switch entry.snapshot.period {
        case .week: return "Week"
        case .month: return "Month"
        case .all: return "All"
        }
    }

    private var totalText: String {
        entry.snapshot.totalSpend.formatted(
            .currency(code: "USD").precision(.fractionLength(0))
        )
    }

    var body: some View {
        if isSmall {
            smallLayout
        } else {
            regularLayout
        }
    }

    // Small square: total + simple top categories OR ultra-compact chart
    // Prefer list for bars (more readable); pie still draws
    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Categories")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(periodShort)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if entry.snapshot.isEmptyOrError {
                Text(entry.snapshot.message ?? "No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            } else {
                Text(totalText)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Pie fits small; bars are clearer as a tiny ranked list
                if entry.chartFormat == .pie {
                    CategorySpendChartView(
                        categories: entry.snapshot.categories,
                        format: .pie,
                        compact: true,
                        ultraCompact: true
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Ranked mini-list (avoids axis/label clipping)
                    VStack(spacing: 2) {
                        ForEach(entry.snapshot.categories.prefix(3)) { item in
                            HStack(spacing: 4) {
                                Image(systemName: CategorySymbol.name(forCategory: item.category))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                                Text(item.category)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(
                                    item.spent.formatted(
                                        .currency(code: "USD").precision(.fractionLength(0))
                                    )
                                )
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .layoutPriority(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Medium / large: full compact chart
    private var regularLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("By Category")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(entry.snapshot.period.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if entry.snapshot.isEmptyOrError {
                Text(entry.snapshot.message ?? "No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 0)
            } else {
                Text(totalText)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                CategorySpendChartView(
                    categories: entry.snapshot.categories,
                    format: entry.chartFormat,
                    compact: true,
                    ultraCompact: false
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text("\(entry.snapshot.categories.count) categories")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
