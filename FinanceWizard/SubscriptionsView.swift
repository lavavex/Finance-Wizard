//
//  SubscriptionsView.swift
//  Finance Wizard
//
//  Recurring charges: prefer Plaid Recurring Streams, fall back to local heuristics.
//

import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Query private var transactions: [Transaction]
    @Query private var bankAccounts: [BankAccount]
    @Query(
        filter: #Predicate<RecurringStream> { $0.isActive == true },
        sort: \RecurringStream.lastDate,
        order: .reverse
    )
    private var activeStreams: [RecurringStream]

    @State private var candidates: [SubscriptionCandidate] = []
    @State private var monthlyBurn: Double = 0
    @State private var isScanning = true
    @State private var usingPlaidStreams = false

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Est. monthly burn")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isScanning && candidates.isEmpty {
                            ProgressView()
                        } else {
                            MoneyText(monthlyBurn)
                                .font(.title2.weight(.bold))
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(isScanning && candidates.isEmpty ? "Scanning…" : "\(candidates.count) recurring")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if usingPlaidStreams && !candidates.isEmpty {
                            Text("Plaid streams")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No active subscriptions",
                        systemImage: "repeat.circle",
                        description: Text("Recurring charges show up here after Sync. Mark a yearly bill on the transaction if it’s missing.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(candidates) { item in
                        NavigationLink {
                            SubscriptionDetailView(candidate: item)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.isUserDeclared ? "checkmark.seal.fill" : "repeat.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(item.isUserDeclared ? .green : .indigo)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayVendor)
                                        .font(.body.weight(.semibold))
                                        .lineLimit(2)
                                    Text("\(item.cadence.displayName) · \(item.occurrenceCount)× · last \(item.lastDate.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(item.confidenceNote)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                    if !item.paymentMethods.isEmpty {
                                        CardText(item.paymentMethods.joined(separator: " · "))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 2) {
                                    MoneyText(item.typicalAmount)
                                        .font(.body.weight(.semibold))
                                    MoneyText(item.estimatedMonthly, prefix: "~", suffix: "/mo")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } header: {
                Text("Active subscriptions")
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(transactions.count)|\(activeStreams.count)") {
            await rescan()
        }
    }

    @MainActor
    private func rescan() async {
        isScanning = true

        // Prefer Plaid outflow streams when Sync has populated them.
        let outflow = activeStreams.filter(\.isOutflow)
        if !outflow.isEmpty {
            let fromPlaid = outflow.compactMap { stream -> SubscriptionCandidate? in
                guard let cadence = stream.subscriptionCadence else { return nil }
                let typical = abs(stream.averageAmount > 0 ? stream.averageAmount : stream.lastAmount)
                guard typical >= 0.99 else { return nil }
                let last = stream.lastDate ?? stream.updatedAt
                let methods: [String] = {
                    guard let accountId = stream.accountId,
                          let account = bankAccounts.first(where: { $0.accountId == accountId }) else {
                        return []
                    }
                    return [account.plaidDisplayName]
                }()
                return SubscriptionCandidate(
                    displayVendor: stream.displayName,
                    normalizedVendor: SubscriptionAnalytics.normalizeVendor(stream.displayName),
                    typicalAmount: typical,
                    cadence: cadence,
                    estimatedMonthly: stream.estimatedMonthly,
                    occurrenceCount: max(stream.transactionIds.count, 1),
                    lastDate: last,
                    paymentMethods: methods,
                    sampleTransactionIds: stream.transactionIds,
                    confidenceNote: "Plaid · \(stream.frequency)",
                    isUserDeclared: false
                )
            }
            .filter { SubscriptionAnalytics.isActive($0) }
            .sorted { $0.estimatedMonthly > $1.estimatedMonthly }

            // Merge user-declared heuristics that Plaid may have missed (yearly etc.)
            let snaps = SubscriptionAnalytics.snapshots(from: transactions)
            let heuristic = await Task.detached(priority: .userInitiated) {
                SubscriptionAnalytics.detect(snapshots: snaps)
            }.value
            let declaredOnly = heuristic.filter(\.isUserDeclared)
            var merged = fromPlaid
            var claimed = Set(fromPlaid.map { SubscriptionAnalytics.normalizeVendor($0.displayVendor) })
            for d in declaredOnly {
                let key = d.normalizedVendor
                guard !claimed.contains(key) else { continue }
                claimed.insert(key)
                merged.append(d)
            }
            merged.sort { $0.estimatedMonthly > $1.estimatedMonthly }

            candidates = merged
            monthlyBurn = SubscriptionAnalytics.totalMonthlyBurn(merged)
            usingPlaidStreams = !fromPlaid.isEmpty
            isScanning = false
            return
        }

        // Fallback: local cadence detection
        let snaps = SubscriptionAnalytics.snapshots(from: transactions)
        let found = await Task.detached(priority: .userInitiated) {
            SubscriptionAnalytics.detect(snapshots: snaps)
        }.value
        candidates = found
        monthlyBurn = SubscriptionAnalytics.totalMonthlyBurn(found)
        usingPlaidStreams = false
        isScanning = false
    }
}

private struct SubscriptionDetailView: View {
    let candidate: SubscriptionCandidate
    @Query private var transactions: [Transaction]
    @Query private var bankAccounts: [BankAccount]

    private var related: [Transaction] {
        let ids = Set(candidate.sampleTransactionIds)
        let norm = candidate.normalizedVendor
        return transactions
            .filter {
                ids.contains($0.transactionId)
                    || SubscriptionAnalytics.normalizeVendor($0.title) == norm
            }
            .sorted { $0.displayDate > $1.displayDate }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Typical amount") {
                    MoneyText(candidate.typicalAmount)
                }
                LabeledContent("Cadence") {
                    Text(candidate.cadence.displayName)
                }
                LabeledContent("Est. monthly") {
                    MoneyText(candidate.estimatedMonthly)
                }
                LabeledContent("Seen") {
                    Text("\(candidate.occurrenceCount) times")
                }
                LabeledContent("Last charged") {
                    Text(candidate.lastDate, style: .date)
                }
                if candidate.isUserDeclared {
                    Label("Marked by you", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Section("Recent charges") {
                ForEach(related.prefix(20)) { tx in
                    NavigationLink {
                        TransactionDetailView(transaction: tx)
                    } label: {
                        let matched = BankAccount.matching(
                            paymentMethod: tx.paymentMethod,
                            in: bankAccounts
                        )
                        TransactionRowView(
                            transaction: tx,
                            institutionId: matched?.institutionId,
                            institutionName: matched?.institutionName
                        )
                    }
                }
            }
        }
        .navigationTitle(candidate.displayVendor)
        .navigationBarTitleDisplayMode(.inline)
    }
}
