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
    typealias Intent = FinanceWizardConfigIntent

    func placeholder(in context: Context) -> FinanceEntry {
        FinanceEntry(
            date: Date(),
            snapshot: FinanceSnapshot(
                cards: [
                    CardSpendSummary(cardName: "Chase Freedom", spent: 120.50, transactionCount: 4),
                    CardSpendSummary(cardName: "Prime Visa", spent: 45.00, transactionCount: 2),
                    CardSpendSummary(cardName: "Amex", spent: 30.00, transactionCount: 1)
                ],
                totalSpend: 195.50,
                balance: -195.50,
                transactionCount: 12,
                period: .month,
                isEmptyOrError: false,
                message: nil
            )
        )
    }

    func snapshot(for configuration: FinanceWizardConfigIntent, in context: Context) async -> FinanceEntry {
        makeEntry(for: configuration, family: context.family)
    }

    func timeline(for configuration: FinanceWizardConfigIntent, in context: Context) async -> Timeline<FinanceEntry> {
        let entry = makeEntry(for: configuration, family: context.family)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func makeEntry(for configuration: FinanceWizardConfigIntent, family: WidgetFamily) -> FinanceEntry {
        // Small can show more rows with tight typography; medium/large get longer lists
        let cardLimit: Int
        switch family {
        case .systemSmall: cardLimit = 6
        case .systemMedium: cardLimit = 8
        default: cardLimit = 12
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
struct FinanceWizardView: View {
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

    // e.g. "July" or "Jul 20–26" instead of the word "Month"/"Week"
    private var periodLabel: String {
        entry.snapshot.period.widgetLabel()
    }

    // Compact currency ($1,234 not $1,234.00) for narrow width
    private var totalText: String {
        entry.snapshot.totalSpend.formatted(
            .currency(code: "USD").precision(.fractionLength(0))
        )
    }

    // How many card rows to draw for this size
    private var visibleCardLimit: Int {
        switch family {
        case .systemSmall: return 6
        case .systemMedium: return 8
        default: return 12
        }
    }

    // Small square: denser list so more cards fit
    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Single-line header
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Total Spend")
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 2)
                Text(periodLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
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
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Show as many cards as we loaded (up to visibleCardLimit)
                VStack(spacing: 1) {
                    ForEach(entry.snapshot.cards.prefix(visibleCardLimit)) { card in
                        HStack(spacing: 4) {
                            Text(card.cardName)
                                .font(.system(size: 10, weight: .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(
                                card.spent.formatted(
                                    .currency(code: "USD").precision(.fractionLength(0))
                                )
                            )
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .layoutPriority(1)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
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
                    Text(periodLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
                ForEach(entry.snapshot.cards.prefix(visibleCardLimit)) { card in
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
            intent: FinanceWizardConfigIntent.self,
            provider: FinanceProvider()
        ) { entry in
            FinanceWizardView(entry: entry)
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
                CardSpendSummary(cardName: "Chase Freedom", spent: 420.12, transactionCount: 10),
                CardSpendSummary(cardName: "Prime Visa", spent: 188.40, transactionCount: 5),
                CardSpendSummary(cardName: "Chase Freedom Unlimited", spent: 95.00, transactionCount: 4),
                CardSpendSummary(cardName: "Amex Blue Cash", spent: 72.10, transactionCount: 3),
                CardSpendSummary(cardName: "X Money", spent: 20.00, transactionCount: 1)
            ],
            totalSpend: 795.62,
            balance: -795.62,
            transactionCount: 40,
            period: .month,
            isEmptyOrError: false,
            message: nil
        )
    )
}
