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
        makeEntry(for: configuration)
    }

    func timeline(for configuration: FinanceWidgetConfigIntent, in context: Context) async -> Timeline<FinanceEntry> {
        let entry = makeEntry(for: configuration)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(for configuration: FinanceWidgetConfigIntent) -> FinanceEntry {
        // Hide cards only affects the per-card list; totalSpend stays full period total
        let snapshot = SharedStore.loadSnapshot(
            period: configuration.period.snapshotPeriod,
            excludedCards: configuration.excludedCardNames,
            cardLimit: 8
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

    // Compact: Total Spend + period + amount + optional top cards
    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Total Spend")
                .font(.caption.weight(.semibold))
            Text(entry.snapshot.period.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if entry.snapshot.isEmptyOrError {
                Text(entry.snapshot.message ?? "No data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                // Full-period total (not reduced by hidden cards)
                Text(entry.snapshot.totalSpend, format: .currency(code: "USD"))
                    .font(.headline.weight(.bold))
                    .minimumScaleFactor(0.7)

                ForEach(entry.snapshot.cards.prefix(3)) { card in
                    HStack {
                        Text(card.cardName)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer()
                        Text(card.spent, format: .currency(code: "USD"))
                            .font(.caption2.weight(.medium))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // Wider layout
    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total Spend")
                        .font(.subheadline.weight(.semibold))
                    Text(entry.snapshot.period.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !entry.snapshot.isEmptyOrError {
                    Text(entry.snapshot.totalSpend, format: .currency(code: "USD"))
                        .font(.title3.weight(.bold))
                        .minimumScaleFactor(0.7)
                }
            }

            if entry.snapshot.isEmptyOrError {
                Text(entry.snapshot.message ?? "No data yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.snapshot.cards.prefix(family == .systemLarge ? 8 : 5)) { card in
                    HStack {
                        Text(card.cardName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(card.spent, format: .currency(code: "USD"))
                            .font(.caption.weight(.semibold))
                    }
                }
                Spacer(minLength: 0)
                Text("\(entry.snapshot.transactionCount) transactions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
                CardSpendSummary(cardName: "Chase Freedom", spent: 210.12, transactionCount: 10),
                CardSpendSummary(cardName: "Prime Visa", spent: 88.40, transactionCount: 5)
            ],
            totalSpend: 298.52,
            balance: -298.52,
            transactionCount: 40,
            period: .month,
            isEmptyOrError: false,
            message: nil
        )
    )
}
