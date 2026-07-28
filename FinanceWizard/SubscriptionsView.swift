//
//  SubscriptionsView.swift
//  Finance Wizard
//
//  Likely recurring charges detected from spend history.
//

import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Query private var transactions: [Transaction]
    @Query private var bankAccounts: [BankAccount]

    private var candidates: [SubscriptionCandidate] {
        SubscriptionAnalytics.detect(in: transactions)
    }

    private var monthlyBurn: Double {
        SubscriptionAnalytics.totalMonthlyBurn(candidates)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Est. monthly burn")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(monthlyBurn, format: .currency(code: "USD"))
                            .font(.title2.weight(.bold))
                    }
                    Spacer()
                    Text("\(candidates.count) recurring")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            Section {
                if candidates.isEmpty {
                    ContentUnavailableView(
                        "No active subscriptions",
                        systemImage: "repeat.circle",
                        description: Text("Recurring charges show up here. Mark a yearly bill on the transaction if it’s missing.")
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
                                        Text(item.paymentMethods.joined(separator: " · "))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(item.typicalAmount, format: .currency(code: "USD"))
                                        .font(.body.weight(.semibold))
                                    Text("~\(item.estimatedMonthly.formatted(.currency(code: "USD")))/mo")
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
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Typical amount") {
                    Text(candidate.typicalAmount, format: .currency(code: "USD"))
                }
                LabeledContent("Cadence") {
                    Text(candidate.cadence.displayName)
                }
                LabeledContent("Est. monthly") {
                    Text(candidate.estimatedMonthly, format: .currency(code: "USD"))
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
