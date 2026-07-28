//
//  ReviewQueueView.swift
//  Finance Wizard
//
//  Batch-friendly list of transactions that need a human pass.
//

import SwiftUI
import SwiftData
import WidgetKit

struct ReviewQueueView: View {
    @Query private var transactions: [Transaction]
    @Query private var bankAccounts: [BankAccount]
    @Environment(\.modelContext) private var modelContext

    @State private var filter: ReviewQueueReason? = nil
    @State private var statusMessage: String?

    private var items: [ReviewQueueItem] {
        let all = ReviewQueueAnalytics.items(in: transactions, accounts: bankAccounts)
        guard let filter else { return all }
        return all.filter { $0.reasons.contains(filter) }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    Text("All").tag(Optional<ReviewQueueReason>.none)
                    ForEach(ReviewQueueReason.allCases) { reason in
                        Text(reason.title).tag(Optional(reason))
                    }
                }
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            Section {
                if items.isEmpty {
                    ContentUnavailableView(
                        "All clear",
                        systemImage: "checkmark.seal",
                        description: Text("Nothing needs review right now.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(items) { item in
                        NavigationLink {
                            TransactionDetailView(transaction: item.transaction)
                        } label: {
                            ReviewQueueRow(item: item, accounts: bankAccounts)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if item.reasons.contains(.billPayCandidate) {
                                Button("Bill pay") {
                                    markBillPay(item.transaction)
                                }
                                .tint(.orange)
                            }
                            if item.reasons.contains(.unlockedDefaultMultiplier) {
                                Button("Lock rate") {
                                    lockCurrentRate(item.transaction)
                                }
                                .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if item.reasons.contains(.ambiguousRail) {
                                Button("Debit") {
                                    setRail(item.transaction, .debit)
                                }
                                .tint(.green)
                                Button("ACH") {
                                    setRail(item.transaction, .ach)
                                }
                                .tint(.purple)
                            }
                        }
                    }
                }
            } header: {
                Text("\(items.count) to review")
            }
        }
        .navigationTitle("Needs review")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func markBillPay(_ tx: Transaction) {
        tx.category = KnownCategory.creditCardPayment.rawValue
        tx.categoryLocked = true
        tx.multiplier = 0
        tx.multiplierLocked = true
        tx.overrideSource = "user"
        mirrorPayment(tx)
        save("Marked as Credit Card Payment")
    }

    private func lockCurrentRate(_ tx: Transaction) {
        tx.multiplierLocked = true
        tx.categoryLocked = true
        tx.overrideSource = "user"
        save("Locked rate on \(tx.title)")
    }

    private func setRail(_ tx: Transaction, _ rail: PaymentRail) {
        tx.paymentRail = rail.rawValue
        tx.paymentRailLocked = true
        if let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: bankAccounts),
           let mult = account.rewardMultiplier(for: rail) {
            tx.multiplier = mult
            tx.multiplierLocked = true
        }
        tx.overrideSource = "user"
        save("Set \(rail.shortLabel) on \(tx.title)")
    }

    private func mirrorPayment(_ row: Transaction) {
        let targetId = row.transactionId
        var descriptor = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { p in
                p.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.amount = abs(row.amount)
            existing.date = row.date
            existing.cardName = row.paymentMethod
            existing.title = row.title
        } else {
            modelContext.insert(
                CreditCardPayment(
                    transactionId: row.transactionId,
                    amount: abs(row.amount),
                    date: row.date,
                    cardName: row.paymentMethod,
                    sourceAccount: row.paymentMethod,
                    title: row.title
                )
            )
        }
    }

    private func save(_ message: String) {
        do {
            try modelContext.save()
            WidgetCenter.shared.reloadAllTimelines()
            statusMessage = message
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                statusMessage = nil
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private struct ReviewQueueRow: View {
    let item: ReviewQueueItem
    let accounts: [BankAccount]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.transaction.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(item.transaction.amount, format: .currency(code: "USD"))
                    .font(.body.weight(.semibold))
            }
            HStack(spacing: 6) {
                Text(item.transaction.category)
                Text("·")
                Text(item.transaction.date, style: .date)
                Spacer()
                Text("\(item.transaction.multiplier.formatted())x")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            FlowReasons(reasons: item.reasons)
        }
        .padding(.vertical, 2)
    }
}

private struct FlowReasons: View {
    let reasons: [ReviewQueueReason]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reasons) { reason in
                Label(reason.title, systemImage: reason.systemImage)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
    }
}
