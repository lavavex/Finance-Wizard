//
//  BalancesWidget.swift
//  Widget
//
//  Checking & savings balances from linked Plaid depository accounts.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline

struct BalancesEntry: TimelineEntry {
    let date: Date
    let snapshot: DepositBalancesSnapshot
}

struct BalancesProvider: TimelineProvider {
    func placeholder(in context: Context) -> BalancesEntry {
        BalancesEntry(
            date: Date(),
            snapshot: DepositBalancesSnapshot(
                accounts: [
                    DepositBalanceRow(
                        accountId: "1",
                        displayName: "Chase Total Checking",
                        institutionName: "Chase",
                        kind: .checking,
                        balance: 2_450.12,
                        mask: "1234"
                    ),
                    DepositBalanceRow(
                        accountId: "2",
                        displayName: "Savings",
                        institutionName: "Chase",
                        kind: .savings,
                        balance: 8_120.00,
                        mask: "5678"
                    )
                ],
                totalBalance: 10_570.12,
                checkingTotal: 2_450.12,
                savingsTotal: 8_120.00,
                otherTotal: 0,
                lastSyncedAt: Date(),
                isEmptyOrError: false,
                message: nil
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BalancesEntry) -> Void) {
        completion(makeEntry(family: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BalancesEntry>) -> Void) {
        let entry = makeEntry(family: context.family)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func makeEntry(family: WidgetFamily) -> BalancesEntry {
        let limit: Int
        switch family {
        case .systemSmall: limit = 4
        case .systemMedium: limit = 6
        default: limit = 10
        }
        return BalancesEntry(
            date: Date(),
            snapshot: SharedStore.loadDepositBalancesSnapshot(accountLimit: limit)
        )
    }
}

// MARK: - View

struct BalancesWidgetView: View {
    var entry: BalancesEntry
    @Environment(\.widgetFamily) private var family

    private var isSmall: Bool { family == .systemSmall }

    private var totalText: String {
        entry.snapshot.totalBalance.formatted(
            .currency(code: "USD").precision(.fractionLength(0...2))
        )
    }

    var body: some View {
        Group {
            if entry.snapshot.isEmptyOrError {
                emptyState
            } else if isSmall {
                smallLayout
            } else {
                mediumLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Cash", systemImage: "building.columns.fill")
                .font(.caption.weight(.semibold))
            Text(entry.snapshot.message ?? "No accounts")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Cash")
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 2)
                Text(kindSummary)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text(totalText)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.45)

            VStack(spacing: 2) {
                ForEach(entry.snapshot.accounts.prefix(4)) { row in
                    accountRow(row, compact: true)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Checking & Savings")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(kindSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 4)
                Text(totalText)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .layoutPriority(1)
            }

            // Quick totals by kind when we have both
            if entry.snapshot.checkingTotal > 0 || entry.snapshot.savingsTotal > 0 {
                HStack(spacing: 10) {
                    if entry.snapshot.checkingTotal != 0 {
                        kindChip(
                            title: "Checking",
                            amount: entry.snapshot.checkingTotal,
                            color: .blue
                        )
                    }
                    if entry.snapshot.savingsTotal != 0 {
                        kindChip(
                            title: "Savings",
                            amount: entry.snapshot.savingsTotal,
                            color: .green
                        )
                    }
                    if entry.snapshot.otherTotal != 0 {
                        kindChip(
                            title: "Other",
                            amount: entry.snapshot.otherTotal,
                            color: .orange
                        )
                    }
                }
            }

            VStack(spacing: 4) {
                ForEach(entry.snapshot.accounts) { row in
                    accountRow(row, compact: false)
                }
            }

            Spacer(minLength: 0)

            if let synced = entry.snapshot.lastSyncedAt {
                Text("Synced \(synced.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var kindSummary: String {
        var parts: [String] = []
        let checkingCount = entry.snapshot.accounts.filter { $0.kind == .checking }.count
        let savingsCount = entry.snapshot.accounts.filter { $0.kind == .savings }.count
        let otherCount = entry.snapshot.accounts.filter { $0.kind == .other }.count
        // Prefer counts from full totals presence
        if entry.snapshot.checkingTotal != 0 || checkingCount > 0 {
            parts.append("Checking")
        }
        if entry.snapshot.savingsTotal != 0 || savingsCount > 0 {
            parts.append("Savings")
        }
        if entry.snapshot.otherTotal != 0 || otherCount > 0 {
            parts.append("Other")
        }
        return parts.isEmpty ? "Balances" : parts.joined(separator: " · ")
    }

    private func kindChip(title: String, amount: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(color)
            Text(
                amount.formatted(
                    .currency(code: "USD").precision(.fractionLength(0...2))
                )
            )
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accountRow(_ row: DepositBalanceRow, compact: Bool) -> some View {
        HStack(spacing: compact ? 4 : 6) {
            Image(systemName: row.kind.systemImage)
                .font(compact ? .system(size: 9) : .caption2)
                .foregroundStyle(kindColor(row.kind))
                .frame(width: compact ? 12 : 14, alignment: .center)

            Text(shortName(row))
                .font(compact ? .system(size: 10) : .caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(moneyLabel(row.balance, compact: compact))
            .font(compact ? .system(size: 10, weight: .semibold) : .caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)
        }
    }

    private func kindColor(_ kind: DepositoryKind) -> Color {
        switch kind {
        case .checking: return .blue
        case .savings: return .green
        case .other: return .orange
        }
    }

    private func moneyLabel(_ amount: Double, compact: Bool) -> String {
        if compact {
            return amount.formatted(
                .currency(code: "USD").precision(.fractionLength(0))
            )
        }
        return amount.formatted(
            .currency(code: "USD").precision(.fractionLength(0...2))
        )
    }

    /// Prefer a short label for tight widget width.
    private func shortName(_ row: DepositBalanceRow) -> String {
        let name = row.displayName
        if name.count <= 22 { return name }
        if !row.institutionName.isEmpty {
            let kind = row.kind.displayName
            if let mask = row.mask, !mask.isEmpty {
                return "\(row.institutionName) \(kind) ···\(mask)"
            }
            return "\(row.institutionName) \(kind)"
        }
        return name
    }
}

// MARK: - Widget

struct BalancesWidget: Widget {
    let kind: String = "BalancesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BalancesProvider()) { entry in
            BalancesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Checking & Savings")
        .description("Balances for linked checking and savings accounts.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

#Preview(as: .systemSmall) {
    BalancesWidget()
} timeline: {
    BalancesEntry(
        date: .now,
        snapshot: DepositBalancesSnapshot(
            accounts: [
                DepositBalanceRow(
                    accountId: "1",
                    displayName: "Chase Checking ···1234",
                    institutionName: "Chase",
                    kind: .checking,
                    balance: 2_450.12,
                    mask: "1234"
                ),
                DepositBalanceRow(
                    accountId: "2",
                    displayName: "Savings ···5678",
                    institutionName: "Chase",
                    kind: .savings,
                    balance: 8_120.00,
                    mask: "5678"
                )
            ],
            totalBalance: 10_570.12,
            checkingTotal: 2_450.12,
            savingsTotal: 8_120.00,
            otherTotal: 0,
            lastSyncedAt: .now,
            isEmptyOrError: false,
            message: nil
        )
    )
}
