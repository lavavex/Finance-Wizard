//
//  ReviewQueueView.swift
//  Finance Wizard
//
//  Batch-friendly list of transactions that need a human pass.
//  Teaches: @Query, @Environment modelContext, swipeActions, NavigationLink, Task, optional Binding.
//

import SwiftUI
import SwiftData
import WidgetKit // reloads home-screen widgets after local data changes

/// List of transactions flagged for review (bill-pay candidates, ambiguous rails, unlocked rates).
struct ReviewQueueView: View {
    // @Query: live arrays from SwiftData — auto-refresh when the store changes.
    @Query private var transactions: [Transaction]
    @Query private var bankAccounts: [BankAccount]
    // modelContext is the SwiftData “workspace” for insert/update/delete/save.
    // @Environment pulls it from the app’s model container (set at the app root).
    @Environment(\.modelContext) private var modelContext

    // Optional filter: nil means “show all reasons.”
    @State private var filter: ReviewQueueReason? = nil
    // Brief success / error line shown in the list after a swipe action.
    @State private var statusMessage: String?

    // Filter the full review queue when a reason is selected.
    private var items: [ReviewQueueItem] {
        let all = ReviewQueueAnalytics.items(in: transactions, accounts: bankAccounts)
        // guard let exits early if filter is nil (return unfiltered).
        guard let filter else { return all }
        return all.filter { $0.reasons.contains(filter) }
    }

    var body: some View {
        List {
            Section {
                // Optional tags: Picker can select “All” (nil) or a specific reason.
                Picker("Show", selection: $filter) {
                    // Optional.none is the same as nil for ReviewQueueReason?.
                    Text("All").tag(Optional<ReviewQueueReason>.none)
                    ForEach(ReviewQueueReason.allCases) { reason in
                        Text(reason.title).tag(Optional(reason))
                    }
                }
            }

            // if let statusMessage only builds this section when a message exists.
            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            Section {
                if items.isEmpty {
                    // ContentUnavailableView is the system empty-state layout (icon + title + message).
                    ContentUnavailableView(
                        "All clear",
                        systemImage: "checkmark.seal",
                        description: Text("Nothing needs review right now.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(items) { item in
                        // NavigationLink pushes a destination when the row is tapped.
                        NavigationLink {
                            TransactionDetailView(transaction: item.transaction)
                        } label: {
                            ReviewQueueRow(item: item, accounts: bankAccounts)
                        }
                        // swipeActions add buttons revealed by swiping a row (Mail-style).
                        // allowsFullSwipe: true means a full swipe runs the first action.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if item.reasons.contains(.billPayCandidate) {
                                Button("Bill pay") {
                                    markBillPay(item.transaction)
                                }
                                .tint(.orange) // swipe button background color
                            }
                            if item.reasons.contains(.unlockedDefaultMultiplier) {
                                Button("Lock rate") {
                                    lockCurrentRate(item.transaction)
                                }
                                .tint(.blue)
                            }
                        }
                        // Leading edge = swipe the other direction (separate action set).
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

    // MARK: - Mutations (write to the model, then save)

    /// Marks a row as credit-card bill pay and mirrors it into CreditCardPayment storage.
    private func markBillPay(_ tx: Transaction) {
        // SwiftData models are reference types — mutating properties updates the store on save.
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
        // if let with comma: both conditions must succeed (matched account + known multiplier).
        if let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: bankAccounts),
           let mult = account.rewardMultiplier(for: rail) {
            tx.multiplier = mult
            tx.multiplierLocked = true
        }
        tx.overrideSource = "user"
        save("Set \(rail.shortLabel) on \(tx.title)")
    }

    /// Upsert a CreditCardPayment that mirrors this bill-pay transaction.
    private func mirrorPayment(_ row: Transaction) {
        let targetId = row.transactionId
        // FetchDescriptor + #Predicate is how you query SwiftData by property (compile-checked).
        var descriptor = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { p in
                p.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1
        // try? turns a throwing call into an optional (nil on failure).
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.amount = abs(row.amount)
            existing.date = row.date
            existing.cardName = row.paymentMethod
            existing.title = row.title
        } else {
            // insert schedules a new model object for the next save.
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
        // do/catch handles throwing functions like modelContext.save().
        do {
            try modelContext.save()
            // Tell widgets (if any) to refresh timelines with new data.
            WidgetCenter.shared.reloadAllTimelines()
            statusMessage = message
            // Task { } starts unstructured async work from sync code.
            // sleep pauses ~1.8s, then clears the banner (try? ignores cancellation errors).
            Task {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                statusMessage = nil
            }
        } catch {
            // error is the thrown Error; localizedDescription is user-readable.
            statusMessage = error.localizedDescription
        }
    }
}

// private struct: only visible inside this file (not exported to other modules/files).
/// Compact row content for one review item (title, amount, reason chips).
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
                MoneyText(item.transaction.amount)
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

/// Horizontal “chips” listing why this transaction is in the queue.
private struct FlowReasons: View {
    let reasons: [ReviewQueueReason]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(reasons) { reason in
                Label(reason.title, systemImage: reason.systemImage)
                    .font(.caption2.weight(.medium))
                    // Chain of layout modifiers builds a pill shape.
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule()) // rounded pill outline
            }
        }
    }
}
