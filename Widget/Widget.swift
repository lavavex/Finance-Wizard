//
//  Widget.swift
//  Widget
//
//  Configurable home-screen widget: Total Spend + optional card breakdown.
//

import WidgetKit
import SwiftUI
import AppIntents

// One timeline tick the widget will draw
struct FinanceEntry: TimelineEntry {
    // When this entry is considered "current"
    let date: Date
    // Precomputed totals from SharedStore
    let snapshot: FinanceSnapshot
}

// Supplies placeholder, snapshot, and timeline entries using the user's config
struct FinanceProvider: AppIntentTimelineProvider {
    typealias Intent = FinanceWidgetConfigIntent

    func placeholder(in context: Context) -> FinanceEntry {
        FinanceEntry(
            date: Date(),
            snapshot: FinanceSnapshot(
                cards: [
                    CardSpendSummary(cardName: "Chase Freedom", spent: 120.50, transactionCount: 4),
                    CardSpendSummary(cardName: "Prime Visa", spent: 45.00, transactionCount: 2)
                ],
                totalSpend: 165.50,
                balance: -165.50,
                transactionCount: 12,
                period: .month,
                isEmptyOrError: false,
                message: nil
            )
        )
    }

    func snapshot(for configuration: FinanceWidgetConfigIntent, in context: Context) async -> FinanceEntry {
        makeEntry(for: configuration, family: context.family)
    }

    func timeline(for configuration: FinanceWidgetConfigIntent, in context: Context) async -> Timeline<FinanceEntry> {
        let entry = makeEntry(for: configuration, family: context.family)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(for configuration: FinanceWidgetConfigIntent, family: WidgetFamily) -> FinanceEntry {
        // Small square: only enough rows to fit without clipping
        let cardLimit: Int
        switch family {
        case .systemSmall: cardLimit = 2
        case .systemMedium: cardLimit = 4
        default: cardLimit = 8
        }

        let snapshot = SharedStore.loadSnapshot(
            period: configuration.period.snapshotPeriod,
            excludedCards: configuration.excludedCardNames,
            cardLimit: cardLimit
        )
        return FinanceEntry(date: Date(), snapshot: snapshot)
    }
}

// The SwiftUI view drawn on the Home Screen
struct FinanceWidgetView: View {
    var entry: FinanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallLayout
        default:
            mediumLayout
        }
    }

    // Short period label for tight layouts
    private var periodShort: String {
        switch entry.snapshot.period {
        case .week: return "Week"
        case .month: return "Month"
        case .all: return "All"
        }
    }

    // Compact currency ($1,234 not $1,234.00) for narrow width
    private var totalText: String {
        entry.snapshot.totalSpend.formatted(
            .currency(code: "USD").precision(.fractionLength(0))
        )
    }

    // Small square: header + total + at most 2 card rows — no overflow
    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Single-line header
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Total Spend")
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
                // Big total — scales down rather than wrapping
                Text(totalText)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Fixed number of compact rows
                VStack(spacing: 2) {
                    ForEach(entry.snapshot.cards.prefix(2)) { card in
                        HStack(spacing: 4) {
                            Text(card.cardName)
                                .font(.system(size: 11, weight: .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(
                                card.spent.formatted(
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
        // Keep content inside the widget chrome
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // Wider layout (medium / large)
    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Spend")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(entry.snapshot.period.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !entry.snapshot.isEmptyOrError {
                    Text(totalText)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .layoutPriority(1)
                }
            }

            if entry.snapshot.isEmptyOrError {
                Text(entry.snapshot.message ?? "No data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Spacer(minLength: 0)
            } else {
                let rowLimit = family == .systemLarge ? 8 : 4
                ForEach(entry.snapshot.cards.prefix(rowLimit)) { card in
                    HStack(spacing: 6) {
                        Text(card.cardName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(
                            card.spent.formatted(
                                .currency(code: "USD").precision(.fractionLength(0...2))
                            )
                        )
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    }
                }
                Spacer(minLength: 0)
                Text("\(entry.snapshot.transactionCount) transactions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FinanceHomeWidget: Widget {
    let kind: String = "FinanceHomeWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: FinanceWidgetConfigIntent.self,
            provider: FinanceProvider()
        ) { entry in
            FinanceWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Total Spend")
        .description("Week or month total spend. Hide cards from the breakdown only.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemSmall) {
    FinanceHomeWidget()
} timeline: {
    FinanceEntry(
        date: .now,
        snapshot: FinanceSnapshot(
            cards: [
                CardSpendSummary(cardName: "Chase Freedom Unlimited", spent: 1210.12, transactionCount: 10),
                CardSpendSummary(cardName: "Blue Cash Everyday® Card from American Express", spent: 88.40, transactionCount: 5)
            ],
            totalSpend: 1298.52,
            balance: -1298.52,
            transactionCount: 40,
            period: .month,
            isEmptyOrError: false,
            message: nil
        )
    )
}
