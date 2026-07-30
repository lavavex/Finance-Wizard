//
//  BudgetView.swift
//  Finance Wizard
//
//  Monthly budget: overall cap, category limits, progress vs spend.
//

import SwiftUI
import SwiftData

struct BudgetView: View {
    @Query private var transactions: [Transaction]
    @Query private var incomeRows: [Income]
    @Environment(\.modelContext) private var modelContext

    @State private var plan: BudgetPlan?
    @State private var period: SnapshotPeriod = .month
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var monthlyDraft: String = ""
    @State private var editingCategory: String?
    @State private var categoryDraft: String = ""
    @State private var showAddCategory = false
    @State private var addCategoryName = KnownCategory.groceries.rawValue
    @State private var addCategoryAmount = ""

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    private var snapshot: BudgetSnapshot? {
        guard let plan else { return nil }
        return BudgetAnalytics.snapshot(
            plan: plan,
            transactions: transactions,
            incomeRows: incomeRows,
            period: period,
            referenceDate: referenceDate
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan, let snapshot {
                    budgetList(plan: plan, snapshot: snapshot)
                } else {
                    ProgressView("Loading budget…")
                }
            }
            .navigationTitle("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PeriodFilterMenu(
                        period: $period,
                        referenceDate: $referenceDate,
                        transactions: transactions,
                        showTitle: true
                    )
                }
            }
            .task {
                let loaded = BudgetStore.loadOrCreate(in: modelContext)
                plan = loaded
                monthlyDraft = formatAmount(loaded.monthlyLimit)
            }
            .sheet(isPresented: $showAddCategory) {
                addCategorySheet
            }
            .alert(
                "Category limit",
                isPresented: Binding(
                    get: { editingCategory != nil },
                    set: { if !$0 { editingCategory = nil } }
                )
            ) {
                TextField("Amount", text: $categoryDraft)
                    .keyboardType(.decimalPad)
                Button("Save") { saveCategoryEdit() }
                Button("Remove limit", role: .destructive) {
                    if let cat = editingCategory {
                        plan?.setLimit(nil, forCategory: cat)
                        try? modelContext.save()
                    }
                    editingCategory = nil
                }
                Button("Cancel", role: .cancel) { editingCategory = nil }
            } message: {
                if let cat = editingCategory {
                    Text("Monthly limit for \(cat)")
                }
            }
        }
    }

    @ViewBuilder
    private func budgetList(plan: BudgetPlan, snapshot: BudgetSnapshot) -> some View {
        List {
            // MARK: Overview
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MoneyText(snapshot.totalSpent)
                                .font(.title2.weight(.bold))
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(periodLabel)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if let remaining = snapshot.totalRemaining {
                                Text(snapshot.isOverTotal ? "Over" : "Left")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                MoneyText(abs(remaining))
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(snapshot.isOverTotal ? .red : .green)
                            } else {
                                Text("No total limit")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    if let fraction = snapshot.totalFraction {
                        ProgressView(value: min(fraction, 1))
                            .tint(snapshot.isOverTotal ? .red : .accentColor)
                        Text("\(Int((fraction * 100).rounded()))% of monthly budget")
                            .font(.caption2)
                            .foregroundStyle(snapshot.isOverTotal ? .red : .secondary)
                    }

                    if snapshot.income > 0 {
                        HStack {
                            Text("Income this period")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            MoneyText(snapshot.income)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }

                    Text("\(snapshot.transactionCount) expenses")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("This period")
            }

            // MARK: Overall limit
            Section {
                HStack {
                    Text("Monthly budget")
                    Spacer()
                    TextField("Optional", text: $monthlyDraft)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                        .onChange(of: monthlyDraft) { _, _ in
                            // live parse without forced save spam
                        }
                    Text("USD")
                        .foregroundStyle(.secondary)
                }
                Button("Save monthly budget") {
                    saveMonthlyLimit(plan: plan)
                }
                .fontWeight(.semibold)
            } header: {
                Text("Overall")
            } footer: {
                Text("Optional total spend target for the month. Category limits below are independent.")
            }

            // MARK: Categories
            Section {
                if snapshot.categories.isEmpty {
                    Text("No spend yet this period. Add category limits to track specific areas.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.categories) { row in
                        Button {
                            editingCategory = row.category
                            categoryDraft = formatAmount(row.limit)
                        } label: {
                            categoryRow(row)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button {
                    showAddCategory = true
                } label: {
                    Label("Add category limit", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Categories")
            } footer: {
                Text("Tap a category to set or clear its monthly limit. Over-budget categories show in red.")
            }

            if snapshot.unbudgetedSpend > 0.5,
               snapshot.categories.contains(where: { $0.limit != nil }) {
                Section {
                    HStack {
                        Text("Unbudgeted spend")
                        Spacer()
                        MoneyText(snapshot.unbudgetedSpend)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Spend in categories without a limit.")
                }
            }
        }
    }

    private func categoryRow(_ row: BudgetCategoryProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: CategoryStyle.symbolName(for: row.category))
                    .foregroundStyle(CategoryStyle.color(for: row.category))
                    .frame(width: 22)
                Text(row.category)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                if let limit = row.limit {
                    Text("\(moneyShort(row.spent)) / \(moneyShort(limit))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(row.isOver ? .red : .primary)
                } else {
                    MoneyText(row.spent)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let fraction = row.fraction {
                ProgressView(value: min(max(fraction, 0), 1.5), total: 1)
                    .tint(row.isOver ? .red : CategoryStyle.color(for: row.category))
                HStack {
                    if row.isOver, let rem = row.remaining {
                        Text("Over by \(moneyShort(abs(rem)))")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if let rem = row.remaining {
                        Text("\(moneyShort(rem)) left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if row.transactionCount > 0 {
                        Text("\(row.transactionCount) txns")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text("No limit · tap to set")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var addCategorySheet: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $addCategoryName) {
                    ForEach(KnownCategory.budgetPickerNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                if let cat = KnownCategory.match(for: addCategoryName) {
                    Text(cat.budgetHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Monthly limit")
                    Spacer()
                    TextField("0", text: $addCategoryAmount)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 120)
                }
            }
            .navigationTitle("Category limit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showAddCategory = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let plan else { return }
                        let amount = parseAmount(addCategoryAmount)
                        plan.setLimit(amount, forCategory: addCategoryName)
                        try? modelContext.save()
                        addCategoryAmount = ""
                        showAddCategory = false
                    }
                    .disabled(parseAmount(addCategoryAmount) == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func saveMonthlyLimit(plan: BudgetPlan) {
        plan.monthlyLimit = parseAmount(monthlyDraft)
        plan.updatedAt = Date()
        try? modelContext.save()
        monthlyDraft = formatAmount(plan.monthlyLimit)
    }

    private func saveCategoryEdit() {
        guard let plan, let cat = editingCategory else { return }
        plan.setLimit(parseAmount(categoryDraft), forCategory: cat)
        try? modelContext.save()
        editingCategory = nil
    }

    private func parseAmount(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
        guard !cleaned.isEmpty, let v = Double(cleaned), v >= 0 else { return nil }
        return v
    }

    private func formatAmount(_ value: Double?) -> String {
        guard let value, value > 0 else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func moneyShort(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }
}

#Preview {
    BudgetView()
        .modelContainer(
            for: [Transaction.self, Income.self, BudgetPlan.self],
            inMemory: true
        )
}
