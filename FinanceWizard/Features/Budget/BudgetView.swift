//
//  BudgetView.swift
//  Finance Wizard
//
//  Monthly budget screen: overall cap, expected income, category limits, progress vs spend.
//  SwiftUI + SwiftData: @Query keeps transaction/income arrays live as the store changes.
//

import SwiftUI
import SwiftData

/// Main Budget tab UI — period filter, spend vs limits, expected income, category targets.
/// Conforms to View: must provide a `body` that describes the interface.
struct BudgetView: View {
    // @Query automatically fetches and observes SwiftData models; UI updates when data changes.
    @Query private var transactions: [Transaction]
    @Query private var incomeRows: [Income]
    // modelContext is the SwiftData context for save/insert/delete on BudgetPlan, etc.
    @Environment(\.modelContext) private var modelContext

    // @State: view-owned values that trigger a redraw when changed.
    @State private var plan: BudgetPlan?
    @State private var period: SnapshotPeriod = .month
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var monthlyDraft: String = ""
    @State private var editingCategory: String?
    @State private var categoryDraft: String = ""
    @State private var showAddCategory = false
    @State private var addCategoryName = KnownCategory.groceries.rawValue
    @State private var addCategoryAmount = ""

    @State private var showIncomeEditor = false
    @State private var editingIncome: ExpectedIncomeStream?
    /// Bumps when expected income changes so snapshot recomputes.
    /// Pure computed properties only re-run when their inputs change; this Int is a deliberate dependency.
    @State private var incomeEpoch = 0

    /// Human-readable label for the selected period (e.g. “March 2024”).
    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    /// Aggregated spend/income vs limits for the current plan and period.
    /// Optional: nil while plan is still loading.
    private var snapshot: BudgetSnapshot? {
        guard let plan else { return nil }
        // Reading incomeEpoch ties this computed property to income edits (forces recompute).
        _ = incomeEpoch
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
            // Group is an invisible container so modifiers apply whether we show list or spinner.
            Group {
                // if let plan, let snapshot unwraps both optionals only when both are non-nil.
                if let plan, let snapshot {
                    budgetList(plan: plan, snapshot: snapshot)
                } else {
                    ProgressView("Loading budget…")
                }
            }
            .navigationTitle("Budget")
            .toolbar {
                // ToolbarItem places controls in the navigation bar.
                ToolbarItem(placement: .topBarTrailing) {
                    // $period and $referenceDate are Bindings (two-way links to @State).
                    PeriodFilterMenu(
                        period: $period,
                        referenceDate: $referenceDate,
                        transactions: transactions,
                        showTitle: true
                    )
                }
            }
            // .task runs async work when the view appears (and cancels if the view goes away).
            .task {
                let loaded = BudgetStore.loadOrCreate(in: modelContext)
                plan = loaded
                monthlyDraft = formatAmount(loaded.monthlyLimit)
            }
            // sheet presents a modal when the bound Bool becomes true.
            .sheet(isPresented: $showAddCategory) {
                addCategorySheet
            }
            .sheet(isPresented: $showIncomeEditor) {
                ExpectedIncomeEditorSheet(
                    stream: editingIncome,
                    // Trailing closures: callbacks the sheet calls when the user saves/deletes/cancels.
                    onSave: { stream in
                        plan?.upsertExpectedIncome(stream)
                        try? modelContext.save()
                        incomeEpoch += 1
                        showIncomeEditor = false
                        editingIncome = nil
                    },
                    onDelete: { id in
                        plan?.removeExpectedIncome(id: id)
                        try? modelContext.save()
                        incomeEpoch += 1
                        showIncomeEditor = false
                        editingIncome = nil
                    },
                    onCancel: {
                        showIncomeEditor = false
                        editingIncome = nil
                    }
                )
            }
            // .alert shows a system alert dialog; custom Binding ties visibility to editingCategory.
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

    // @ViewBuilder lets this function return different view trees (List content) without type errors.
    @ViewBuilder
    private func budgetList(plan: BudgetPlan, snapshot: BudgetSnapshot) -> some View {
        List {
            // MARK: Overview
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    // firstTextBaseline aligns text baselines across columns of different font sizes.
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
                                // abs() turns negative remaining (over budget) into a positive display amount.
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
                        // ProgressView(value:) is a determinate bar; min caps at 100% fill for the bar.
                        ProgressView(value: min(fraction, 1))
                            .tint(snapshot.isOverTotal ? .red : .accentColor)
                        Text("\(Int((fraction * 100).rounded()))% of monthly budget")
                            .font(.caption2)
                            .foregroundStyle(snapshot.isOverTotal ? .red : .secondary)
                    }

                    // Actual + expected income
                    if snapshot.income > 0 || snapshot.expectedIncome > 0.005 {
                        VStack(alignment: .leading, spacing: 6) {
                            if snapshot.income > 0 {
                                HStack {
                                    Text("Income received")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    MoneyText(snapshot.income)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            if snapshot.expectedIncome > 0.005 {
                                HStack {
                                    Text("Expected this period")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    MoneyText(snapshot.expectedIncome)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let delta = snapshot.incomeVsExpected, snapshot.expectedIncome > 0.005 {
                                HStack {
                                    // Small epsilon (-0.005) avoids floating-point “almost zero” flicker.
                                    Text(delta >= -0.005 ? "Ahead of plan" : "Behind plan")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    MoneyText(abs(delta))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(delta >= -0.005 ? .green : .orange)
                                }
                            }
                            if let next = snapshot.nextPayday {
                                HStack {
                                    Text("Next payday")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    // FormatStyle API: .dateTime builds a localized date string.
                                    Text(next, format: .dateTime.month(.abbreviated).day().weekday(.wide))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
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

            // MARK: Expected income
            Section {
                if plan.expectedIncomeStreams.isEmpty {
                    Text("Add paycheck or other regular income to power smart budgets.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(plan.expectedIncomeStreams) { stream in
                        Button {
                            editingIncome = stream
                            showIncomeEditor = true
                        } label: {
                            expectedIncomeRow(stream)
                        }
                        // .plain avoids button styling that would look like a big blue link in a List.
                        .buttonStyle(.plain)
                    }
                    if plan.expectedMonthlyIncome > 0 {
                        HStack {
                            Text("Est. monthly total")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            MoneyText(plan.expectedMonthlyIncome)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                }

                Button {
                    // nil stream means “add new” rather than edit existing.
                    editingIncome = nil
                    showIncomeEditor = true
                } label: {
                    Label("Add expected income", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Expected income")
            } footer: {
                Text("Amount per payday, how often it hits, and which day. Used for period expectations and future dynamic budgets.")
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

            // Only show “unbudgeted” when there is meaningful spend outside limited categories.
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

    /// One row for a configured expected-income stream (label, schedule, amounts).
    private func expectedIncomeRow(_ stream: ExpectedIncomeStream) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "banknote.fill")
                .foregroundStyle(.green)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(stream.scheduleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let next = stream.nextDate() {
                    Text("Next \(next.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(stream.amount)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                MoneyText(stream.estimatedMonthly, prefix: "~", suffix: "/mo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// One category progress row: icon, spent vs limit, optional progress bar.
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
                // total: 1 means value is a 0…1-ish fraction; allow slightly over for visual overflow.
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

    /// Modal form for picking a category and monthly limit amount.
    private var addCategorySheet: some View {
        NavigationStack {
            Form {
                Picker("Category", selection: $addCategoryName) {
                    // id: \.self uses the String itself as the identity for ForEach.
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
                    // disabled when parse fails (empty/invalid amount).
                    .disabled(parseAmount(addCategoryAmount) == nil)
                }
            }
        }
        // presentationDetents controls sheet height options (.medium = half screen-ish).
        .presentationDetents([.medium])
    }

    /// Parses the monthly draft field and saves it on the plan.
    private func saveMonthlyLimit(plan: BudgetPlan) {
        plan.monthlyLimit = parseAmount(monthlyDraft)
        plan.updatedAt = Date()
        try? modelContext.save()
        monthlyDraft = formatAmount(plan.monthlyLimit)
    }

    /// Saves or clears the category limit currently being edited in the alert.
    private func saveCategoryEdit() {
        guard let plan, let cat = editingCategory else { return }
        plan.setLimit(parseAmount(categoryDraft), forCategory: cat)
        try? modelContext.save()
        editingCategory = nil
    }

    /// Turns user-typed money text into a Double, or nil if empty/invalid/negative.
    private func parseAmount(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
        // Double(cleaned) is a failable initializer — returns nil if the string isn’t a number.
        guard !cleaned.isEmpty, let v = Double(cleaned), v >= 0 else { return nil }
        return v
    }

    /// Formats an optional amount for a text field (empty string means “no limit”).
    private func formatAmount(_ value: Double?) -> String {
        guard let value, value > 0 else { return "" }
        // FormatStyle: fractionLength(0...2) allows 0–2 decimal places as needed.
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// Short USD currency string for compact row displays.
    private func moneyShort(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
    }
}

// MARK: - Expected income editor

/// Sheet for adding or editing one ExpectedIncomeStream (label, amount, schedule).
/// private means only visible inside this source file.
private struct ExpectedIncomeEditorSheet: View {
    // nil stream = create mode; non-nil = edit mode with existing values.
    let stream: ExpectedIncomeStream?
    // Function types: closures the parent passes in to handle save/delete/cancel.
    let onSave: (ExpectedIncomeStream) -> Void
    let onDelete: (String) -> Void
    let onCancel: () -> Void

    @State private var label: String = "Paycheck"
    @State private var amountText: String = ""
    @State private var frequency: ExpectedIncomeFrequency = .monthly
    /// Calendar weekday 1…7 (Sunday…Saturday) — matches Calendar.current weekday numbering.
    @State private var weekday: Int = Calendar.current.component(.weekday, from: Date())
    @State private var dayOfMonth: Int = 1

    private var isEditing: Bool { stream != nil }

    /// Validation: positive amount and non-empty label required before Save is enabled.
    private var canSave: Bool {
        let amt = parseAmount(amountText)
        guard let amt, amt > 0 else { return false }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Label", text: $label)
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("0", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                } footer: {
                    Text("Amount you receive each payday (not the monthly total).")
                }

                Section {
                    Picker("Frequency", selection: $frequency) {
                        ForEach(ExpectedIncomeFrequency.allCases) { freq in
                            Text(freq.displayName).tag(freq)
                        }
                    }
                    // Segmented control style (pill buttons) for a small set of options.
                    .pickerStyle(.segmented)

                    // switch on an enum shows different UI per frequency case.
                    switch frequency {
                    case .daily:
                        Text("Counts every calendar day.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .weekly:
                        Picker("Day of week", selection: $weekday) {
                            // Closed range 1...7 as ForEach source; id: \.self for Int identity.
                            ForEach(1...7, id: \.self) { day in
                                Text(weekdayLabel(day)).tag(day)
                            }
                        }
                    case .monthly:
                        Picker("Day of month", selection: $dayOfMonth) {
                            ForEach(1...31, id: \.self) { day in
                                Text(ordinal(day)).tag(day)
                            }
                        }
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(previewFooter)
                }

                // Only offer Remove when editing an existing stream.
                if isEditing, let id = stream?.id {
                    Section {
                        Button("Remove income", role: .destructive) {
                            onDelete(id)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit income" : "Expected income")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            // onAppear seeds form fields from the existing stream when editing.
            .onAppear {
                if let stream {
                    label = stream.label
                    amountText = stream.amount > 0
                        ? stream.amount.formatted(.number.precision(.fractionLength(0...2)))
                        : ""
                    frequency = stream.frequency
                    // ?? provides a default when the optional weekday is nil.
                    weekday = stream.weekday
                        ?? Calendar.current.component(.weekday, from: Date())
                    dayOfMonth = stream.dayOfMonth ?? 1
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Live footer preview: schedule description, estimated monthly, next payday.
    private var previewFooter: String {
        let draft = makeStream()
        let monthly = draft.estimatedMonthly
        let monthlyText = monthly.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))
        if let next = draft.nextDate() {
            let nextText = next.formatted(date: .abbreviated, time: .omitted)
            return "\(draft.scheduleDescription) · ~\(monthlyText)/mo · next \(nextText)"
        }
        return "\(draft.scheduleDescription) · ~\(monthlyText)/mo"
    }

    private func save() {
        onSave(makeStream())
    }

    /// Builds an ExpectedIncomeStream from current form state (new id if creating).
    private func makeStream() -> ExpectedIncomeStream {
        let amount = parseAmount(amountText) ?? 0
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExpectedIncomeStream(
            // Keep existing id when editing; UUID().uuidString for brand-new streams.
            id: stream?.id ?? UUID().uuidString,
            label: name.isEmpty ? "Income" : name,
            amount: amount,
            frequency: frequency,
            // Only store weekday/dayOfMonth when that frequency uses them.
            weekday: frequency == .weekly ? weekday : nil,
            dayOfMonth: frequency == .monthly ? dayOfMonth : nil
        )
    }

    private func parseAmount(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
        guard !cleaned.isEmpty, let v = Double(cleaned), v >= 0 else { return nil }
        return v
    }

    /// Localized weekday name for calendar day index 1…7.
    private func weekdayLabel(_ day: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard day >= 1, day <= symbols.count else { return "Day \(day)" }
        // Arrays are 0-based: weekday 1 (Sunday) → symbols[0].
        return symbols[day - 1]
    }

    /// English ordinal label (1st, 2nd, 3rd, 4th…) for day-of-month picker.
    private func ordinal(_ n: Int) -> String {
        let absN = abs(n)
        let mod100 = absN % 100
        // 11th, 12th, 13th are special (not 11st, etc.).
        if (11...13).contains(mod100) { return "\(n)th" }
        switch absN % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

// Preview with an in-memory model container so canvas doesn’t need a real database file.
#Preview {
    BudgetView()
        .modelContainer(
            for: [Transaction.self, Income.self, BudgetPlan.self],
            inMemory: true
        )
}
