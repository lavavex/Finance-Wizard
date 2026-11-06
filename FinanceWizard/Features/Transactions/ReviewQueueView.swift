//
//  ReviewQueueView.swift
//  Finance Wizard
//
//  Batch-friendly list of transactions that need a human pass.
//

import SwiftUI
import SwiftData
import WidgetKit // reloads home-screen widgets after local data changes

/// List of transactions flagged for review (bill-pay candidates, ambiguous rails, unlocked rates).
struct ReviewQueueView: View {
    @Query private var transactions: [Transaction]
    @Query private var bankAccounts: [BankAccount]
    @Environment(\.modelContext) private var modelContext

    // Optional filter: nil means “show all reasons.”
    @State private var filter: ReviewQueueReason? = nil
    @State private var statusMessage: String?
    /// Model suggestions by merchant title. Nothing changes until the user applies them.
    @State private var suggestions: [String: String] = [:]
    @State private var isSuggesting = false

    private static let suggestionLimit = 20

    /// One row per merchant whose category is a guess.
    private var merchantsToSuggest: [Transaction] {
        var seen = Set<String>()
        return ReviewQueueAnalytics.items(in: transactions)
            .filter { $0.reasons.contains(.weakCategory) && !$0.transaction.isCategoryLocked }
            .map(\.transaction)
            .filter { seen.insert($0.title).inserted }
    }

    private var canSuggest: Bool {
        guard case .available = OnDeviceAI.availabilityStatus() else { return false }
        return !merchantsToSuggest.isEmpty
    }

    private var items: [ReviewQueueItem] {
        let all = ReviewQueueAnalytics.items(in: transactions)
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

            if isSuggesting || !suggestions.isEmpty {
                Section {
                    if isSuggesting {
                        ProgressView("Suggesting categories…")
                    }
                    ForEach(suggestions.keys.sorted(), id: \.self) { title in
                        LabeledContent(title, value: suggestions[title] ?? "")
                            .swipeActions {
                                Button("Skip") { suggestions[title] = nil }
                            }
                    }
                    if !isSuggesting, !suggestions.isEmpty {
                        Button("Apply \(suggestions.count) Suggestions") { applySuggestions() }
                    }
                } header: {
                    Text("Suggested categories")
                } footer: {
                    Text("Written on this device. Swipe to skip one. Applying also sets the category for future charges from that merchant.")
                }
            } else if canSuggest {
                Section {
                    Button {
                        Task { await suggestCategories() }
                    } label: {
                        Label("Suggest categories", systemImage: "apple.intelligence")
                    }
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
                            ReviewQueueRow(item: item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if item.reasons.contains(.billPayCandidate) {
                                Button("Bill pay") {
                                    markBillPay(item.transaction)
                                }
                                .tint(.orange)
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

    // MARK: - Suggestions

    private func suggestCategories() async {
        isSuggesting = true
        defer { isSuggesting = false }
        let allowed = KnownCategory.defaultNames.filter {
            !TransactionAnalytics.isExcludedFromSpendCategory($0) && !ReviewQueueAnalytics.looksWeakCategory($0)
        }
        for row in merchantsToSuggest.prefix(Self.suggestionLimit) {
            // A failure on one merchant shouldn't lose the rest.
            guard let name = try? await OnDeviceAI.suggestCategory(
                title: row.title,
                amount: row.amount,
                allowedCategories: allowed
            ) else { continue }
            if name != row.category { suggestions[row.title] = name }
        }
        if suggestions.isEmpty { statusMessage = "No better categories found." }
    }

    private func applySuggestions() {
        for row in transactions where !row.isCategoryLocked {
            guard let name = suggestions[row.title] else { continue }
            row.category = name
            row.categoryLocked = true
            row.overrideSource = "user"
        }
        for (title, name) in suggestions where !DemoMode.isActive {
            VendorRulesStore.upsert(vendor: title, paymentMethod: nil, category: name)
        }
        let count = suggestions.count
        suggestions = [:]
        save("Updated \(count) merchants")
    }

    // MARK: - Mutations (write to the model, then save)

    /// Marks a row as credit-card bill pay and mirrors it into CreditCardPayment storage.
    private func markBillPay(_ tx: Transaction) {
        tx.category = KnownCategory.creditCardPayment.rawValue
        tx.categoryLocked = true
        tx.overrideSource = "user"
        mirrorPayment(tx)
        save("Marked as Credit Card Payment")
    }

    /// Upsert a CreditCardPayment that mirrors this bill-pay transaction.
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

/// Compact row content for one review item (title, amount, reason chips).
private struct ReviewQueueRow: View {
    let item: ReviewQueueItem

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
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
    }
}
