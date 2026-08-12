//
//  SubscriptionsView.swift
//  Finance Wizard
//
//  Blank starter for tracking subscriptions / recurring transactions.
//

import SwiftUI
import SwiftData

private struct FakeSubscription: Identifiable {
    let id = UUID()
    let name: String
    let cadence: String
    let lastCharged: String
    let amount: Double
    let monthly: Double
    let isUserMarked: Bool
}

struct SubscriptionsView: View {
    // @Query = give me every Transaction from the database; refresh if they change.
    @Query private var transactions: [Transaction]

    // STEP 2a (you already added this):
    // @State = this screen owns the value; UI can update when it changes.
    // candidates = real subscription rows after we scan (starts empty).
    @State private var candidates: [SubscriptionCandidate] = []
    // isScanning = true while detection runs; false when finished.
    @State private var isScanning = true

    private let samples: [FakeSubscription] = [
        FakeSubscription(
            name: "Rent",
            cadence: "Monthly",
            lastCharged: "Aug 2, 2026",
            amount: 1200.00,
            monthly: 1200.00,
            isUserMarked: true
        )
    ]

    private var totalMonthly: Double {
        samples.reduce(0) { $0 + $1.monthly }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Est. Monthly")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MoneyText(totalMonthly)
                                .font(.title2.weight(.bold))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(samples.count) recurring")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            // STEP 2d — TYPE HERE: replace the Sample Data line below with a label
                            // that shows "Scanning…" while isScanning is true, else "Found N real"
                            // (proves detection works; list still uses fake Rent until Step 3).
                            //
                            //
                            Text(isScanning ? "Scanning..." : "Found \(candidates.count) real")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // STEP 3a — TYPE HERE: switch this section from fake `samples` to real `candidates`.
                // - Empty check: candidates.isEmpty (not samples)
                // - ForEach: ForEach(candidates) { item in subscriptionRow(item) }
                //   = for each real subscription, build one row
                // Leave the ContentUnavailableView text as-is for now.
                Section {
                    if samples.isEmpty {
                        ContentUnavailableView(
                            "No Active Subscriptions Found",
                            systemImage: "repeat.circle",
                            description: Text("Recurring charges will show up here.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(samples) { item in
                            subscriptionRow(item)
                        }
                    }
                } header: {
                    Text("Active Subscriptions")
                }
            }
            // ↓↓↓ THIS is .navigationTitle — it hangs off List (the line right above’s closing `}`).
            // It sets the big nav-bar title to "Subscriptions". Easy to miss because it is NOT
            // inside NavigationStack { } as its own line at the top — it’s a *modifier* on List.
            .navigationTitle("Subscriptions")
            // STEP 2b — TYPE HERE: after the title, add .task { await rescan() }
            // .task = when this screen appears, run async work.
            // await = wait for rescan to finish (it may pause while working).
            .task {
                await rescan()
            }
        }
    }

    // STEP 3b — TYPE HERE: change this row helper to use real data.
    // 1) Parameter type: FakeSubscription → SubscriptionCandidate
    // 2) Field names change (fake → real):
    //      isUserMarked  → isUserDeclared
    //      name          → displayVendor
    //      cadence       → cadence.displayName   (enum → "Monthly" string)
    //      lastCharged   → lastDate.formatted(date: .abbreviated, time: .omitted)
    //      amount        → typicalAmount
    //      monthly       → estimatedMonthly
    @ViewBuilder
    private func subscriptionRow(_ item: FakeSubscription) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.isUserMarked ? "checkmark.seal.fill" : "repeat.circle.fill")
                .font(.title3)
                .foregroundStyle(item.isUserMarked ? .green : .indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text("\(item.cadence) · last \(item.lastCharged)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(item.amount)
                    .font(.body.weight(.semibold))
                MoneyText(item.monthly, prefix: "~", suffix: "/mo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // STEP 2c — TYPE HERE: rescan() function (still inside this struct, before the final `}`).
    // @MainActor = update UI state on the main thread.
    // async = allowed to pause and wait (await).
    // Body should:
    //   1) isScanning = true
    //   2) snaps = SubscriptionAnalytics.snapshots(from: transactions)
    //   3) found = await Task.detached { SubscriptionAnalytics.detect(snapshots: snaps) }.value
    //   4) candidates = found
    //   5) isScanning = false
    @MainActor
    private func rescan() async {
        isScanning = true
        let snaps = SubscriptionAnalytics.snapshots(from: transactions)
        let found = await Task.detached(priority: .userInitiated) {
            SubscriptionAnalytics.detect(snapshots: snaps)
        }.value
        candidates = found
        isScanning = false
    }
}

#Preview {
    SubscriptionsView()
}

