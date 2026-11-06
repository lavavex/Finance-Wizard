//
//  MoneyInsightViews.swift
//  Finance Wizard
//
//  Screens for MoneyInsights: "Why?" explanations, the monthly recap, and AI search results.
//

import SwiftData
import SwiftUI

/// Facts first, with an on-device summary above them when the model is available.
struct MoneyInsightView: View {
    let title: String
    let insight: MoneyInsight
    var followUpQuestion: String?

    @State private var summary: String?
    @State private var isSummarizing = false
    @State private var showAsk = false

    var body: some View {
        List {
            if isSummarizing || summary != nil {
                Section {
                    if let summary {
                        Text(summary)
                    } else {
                        ProgressView()
                    }
                } header: {
                    Label("Summary", systemImage: "apple.intelligence")
                } footer: {
                    Text("Written on this device from the numbers below.")
                }
            }

            Section {
                Text(insight.headline)
                    .font(.body.weight(.medium))
            }

            ForEach(insight.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.lines, id: \.self) { line in
                        Text(line)
                    }
                }
            }

            if followUpQuestion != nil {
                Section {
                    Button("Ask a follow-up") { showAsk = true }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAsk) {
            OnDeviceAIChatView(initialQuestion: followUpQuestion)
        }
        .task(id: insight.headline) {
            summary = nil
            guard case .available = OnDeviceAI.availabilityStatus() else { return }
            isSummarizing = true
            summary = try? await OnDeviceAI.summarize(insight)
            isSummarizing = false
        }
    }
}

/// Reads history here, so opening a transaction doesn't load every row.
struct ExplainChargeView: View {
    let transaction: Transaction
    @Query private var transactions: [Transaction]

    var body: some View {
        MoneyInsightView(
            title: "This charge",
            insight: MoneyInsights.charge(transaction, among: transactions),
            followUpQuestion: "Tell me about my charges from \(transaction.title)."
        )
    }
}

/// One month at a time, starting with the last full month.
struct MonthlyRecapView: View {
    @Query private var transactions: [Transaction]
    @Query private var income: [Income]
    @Query private var plans: [BudgetPlan]
    @State private var month: Date

    init(month: Date = Calendar.current.date(byAdding: .month, value: -1, to: TransactionAnalytics.monthStart(for: Date())) ?? Date()) {
        _month = State(initialValue: month)
    }

    private var label: String {
        month.formatted(.dateTime.month(.wide).year())
    }

    private var canGoForward: Bool {
        month < TransactionAnalytics.monthStart(for: Date())
    }

    private var insight: MoneyInsight {
        let plan = plans.first { $0.planId == BudgetStore.defaultPlanId } ?? plans.first
        let budget = plan.map {
            BudgetAnalytics.snapshot(plan: $0, transactions: transactions, referenceDate: month)
        }
        return MoneyInsights.monthlyRecap(transactions, income: income, budget: budget, month: month)
    }

    var body: some View {
        MoneyInsightView(
            title: label,
            insight: insight,
            followUpQuestion: "What stands out about my money in \(label)?"
        )
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Previous month", systemImage: "chevron.left") { move(by: -1) }
                Button("Next month", systemImage: "chevron.right") { move(by: 1) }
                    .disabled(!canGoForward)
            }
        }
    }

    private func move(by months: Int) {
        month = Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
    }
}

/// The real rows matching a plain-English search, so nothing here is written by the model.
struct AITransactionSearchView: View {
    let query: String

    @Query private var transactions: [Transaction]
    @State private var filter: TransactionSearchFilter?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let filter {
                let rows = filter.matches(in: transactions)
                Section {
                    LabeledContent("Searched for", value: filter.summary)
                    LabeledContent("Total") {
                        MoneyText(rows.reduce(0) { $0 + abs($1.amount) })
                    }
                } footer: {
                    Text("\(rows.count) transactions")
                }
                Section {
                    ForEach(rows) { row in
                        NavigationLink {
                            TransactionDetailView(transaction: row)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                        .lineLimit(1)
                                    Text(row.date, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                MoneyText(row.amount)
                            }
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("Search failed", systemImage: "magnifyingglass", description: Text(errorMessage))
                    .listRowBackground(Color.clear)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(query)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                filter = try await OnDeviceAI.searchFilter(for: query)
            } catch {
                errorMessage = AskConversation.message(for: error)
            }
        }
    }
}
