//
//  PayoffPlanEditorView.swift
//  Finance Wizard
//
//  Create or edit a My Loan / Pay Over Time / promo APR / custom payoff plan.
//

import SwiftUI
import SwiftData

/// Form for one payoff plan. Pass `existing` to edit; omit it to insert a new row.
struct PayoffPlanEditorView: View {
    var existing: PayoffPlan? = nil
    var defaultKind: PayoffPlanKind = .custom
    var defaultName: String = ""
    var defaultAccountId: String? = nil
    var defaultPaymentMethod: String = ""
    var defaultAmount: Double? = nil
    var defaultLinkedTransactionId: String? = nil
    var defaultApr: Double? = nil
    var defaultEndDate: Date? = nil
    var onSaved: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var accounts: [BankAccount]

    @State private var kind: PayoffPlanKind = .custom
    @State private var name: String = ""
    @State private var selectedAccountId: String = ""
    @State private var originalText: String = ""
    @State private var remainingText: String = ""
    @State private var monthlyText: String = ""
    @State private var feeText: String = ""
    @State private var aprText: String = ""
    @State private var startDate: Date = Date()
    @State private var hasEndDate = false
    @State private var endDate: Date = Date()
    @State private var termText: String = ""
    @State private var notes: String = ""
    @State private var saveError: String?

    private var creditAccounts: [BankAccount] {
        accounts.filter(\.isCredit).sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var selectedAccount: BankAccount? {
        creditAccounts.first { $0.accountId == selectedAccountId }
    }

    private var paymentMethodLabel: String {
        selectedAccount?.displayName ?? defaultPaymentMethod
    }

    var body: some View {
        Form {
            Section {
                Picker("Type", selection: $kind) {
                    ForEach(PayoffPlanKind.allCases) { value in
                        Text(value.displayName).tag(value)
                    }
                }
                Text(kind.shortHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Plan")
            }

            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                if !creditAccounts.isEmpty {
                    Picker("Card", selection: $selectedAccountId) {
                        Text("None").tag("")
                        ForEach(creditAccounts, id: \.accountId) { account in
                            Text(account.displayName).tag(account.accountId)
                        }
                    }
                } else if !defaultPaymentMethod.isEmpty {
                    LabeledContent("Card", value: defaultPaymentMethod)
                }
            }

            Section {
                moneyField("Original amount", text: $originalText)
                moneyField("Remaining", text: $remainingText)
                moneyField("Monthly payment", text: $monthlyText)
                if kind == .payOverTime {
                    moneyField("Monthly fee", text: $feeText)
                }
                if kind == .myLoan || kind == .promoAPR {
                    HStack {
                        Text(kind == .promoAPR ? "Promo APR %" : "APR %")
                        Spacer()
                        TextField("0", text: $aprText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                }
            } header: {
                Text("Amounts")
            } footer: {
                amountsFooter
            }

            Section {
                DatePicker("First payment", selection: $startDate, displayedComponents: .date)
                Toggle("End / promo date", isOn: $hasEndDate)
                if hasEndDate {
                    DatePicker(
                        kind == .promoAPR ? "Promo ends" : "Last payment",
                        selection: $endDate,
                        displayedComponents: .date
                    )
                }
                HStack {
                    Text("Term (months)")
                    Spacer()
                    TextField("optional", text: $termText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
                if hasEndDate, let suggested = suggestedMonthly {
                    Button("Use \(suggested.formatted(.currency(code: "USD"))) / mo to finish by this date") {
                        monthlyText = formatMoney(suggested)
                    }
                }
                if let warning = paceWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Schedule")
            }

            Section {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }

            if existing != nil {
                Section {
                    Button("Record this month’s payment") {
                        recordPayment()
                    }
                    Button("Mark paid off") {
                        markPaidOff()
                    }
                }
                Section {
                    Button("Delete plan", role: .destructive) {
                        deletePlan()
                    }
                }
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .navigationTitle(existing == nil ? "New payoff plan" : "Payoff plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if existing == nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .onAppear { loadDraft() }
        .onChange(of: kind) { _, newKind in
            if newKind == .promoAPR, aprText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                aprText = "0"
            }
        }
    }

    @ViewBuilder
    private var amountsFooter: some View {
        switch kind {
        case .payOverTime:
            Text("The fee is added to each month’s bill and does not reduce remaining.")
        case .promoAPR:
            Text("Set remaining to the promo balance (not the whole card). Monthly payment should clear it before the promo ends.")
        case .myLoan:
            Text("Use the loan’s fixed payment and APR from Chase — not a Pay Over Time purchase plan.")
        case .custom:
            EmptyView()
        }
    }

    @ViewBuilder
    private func moneyField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 140)
        }
    }

    private var suggestedMonthly: Double? {
        guard hasEndDate, let remaining = parseAmount(remainingText), remaining > 0 else {
            return nil
        }
        let cal = Calendar.current
        let months = cal.dateComponents(
            [.month],
            from: cal.startOfDay(for: Date()),
            to: cal.startOfDay(for: endDate)
        ).month ?? 0
        let count = endDate < Date() ? 0 : max(1, months)
        guard count > 0 else { return nil }
        return remaining / Double(count)
    }

    private var paceWarning: String? {
        guard hasEndDate,
              let remaining = parseAmount(remainingText), remaining > 0,
              let monthly = parseAmount(monthlyText), monthly > 0 else {
            return nil
        }
        let months = Int(ceil(remaining / monthly))
        guard let projected = Calendar.current.date(byAdding: .month, value: months, to: Date()) else {
            return nil
        }
        if Calendar.current.startOfDay(for: projected) > Calendar.current.startOfDay(for: endDate) {
            return "At this payment, payoff is after the end date (\(projected.formatted(date: .abbreviated, time: .omitted)))."
        }
        return nil
    }

    private func loadDraft() {
        if let plan = existing {
            kind = plan.kind
            name = plan.name
            selectedAccountId = plan.accountId ?? ""
            originalText = formatMoney(plan.originalAmount)
            remainingText = formatMoney(plan.remainingAmount)
            monthlyText = formatMoney(plan.monthlyPayment)
            feeText = plan.monthlyFee.map(formatMoney) ?? ""
            aprText = plan.aprPercent.map { formatNumber($0) } ?? (plan.kind == .promoAPR ? "0" : "")
            startDate = plan.startDate
            if let end = plan.endDate {
                hasEndDate = true
                endDate = end
            }
            termText = plan.termMonths.map(String.init) ?? ""
            notes = plan.notes ?? ""
            return
        }
        kind = defaultKind
        name = defaultName
        selectedAccountId = defaultAccountId ?? ""
        if let amount = defaultAmount {
            originalText = formatMoney(amount)
            remainingText = formatMoney(amount)
        }
        if defaultKind == .promoAPR {
            aprText = defaultApr.map { formatNumber($0) } ?? "0"
        } else if let apr = defaultApr {
            aprText = formatNumber(apr)
        }
        if let end = defaultEndDate {
            hasEndDate = true
            endDate = end
        }
    }

    private func save() {
        saveError = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            saveError = "Name can’t be empty."
            return
        }
        guard let original = parseAmount(originalText), original > 0 else {
            saveError = "Original amount must be greater than 0."
            return
        }
        guard let remaining = parseAmount(remainingText), remaining >= 0 else {
            saveError = "Remaining must be a number 0 or greater."
            return
        }
        guard let monthly = parseAmount(monthlyText), monthly > 0 else {
            saveError = "Monthly payment must be greater than 0."
            return
        }
        let fee = parseOptionalAmount(feeText)
        let apr = parseOptionalAmount(aprText)
        let term = Int(termText.trimmingCharacters(in: .whitespacesAndNewlines))

        let accountId = selectedAccountId.isEmpty ? defaultAccountId : selectedAccountId
        let method = paymentMethodLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let ended = remaining <= 0.005

        if let plan = existing {
            plan.kind = kind
            plan.name = trimmedName
            plan.accountId = accountId
            plan.paymentMethod = method
            plan.originalAmount = original
            plan.remainingAmount = ended ? 0 : remaining
            plan.monthlyPayment = monthly
            plan.monthlyFee = kind == .payOverTime ? fee : nil
            plan.aprPercent = apr
            plan.startDate = startDate
            plan.endDate = hasEndDate ? endDate : nil
            plan.termMonths = term
            plan.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            plan.isEnded = ended
            plan.updatedAt = Date()
        } else {
            let plan = PayoffPlan(
                kind: kind,
                name: trimmedName,
                accountId: accountId,
                paymentMethod: method,
                originalAmount: original,
                remainingAmount: ended ? 0 : remaining,
                monthlyPayment: monthly,
                monthlyFee: kind == .payOverTime ? fee : nil,
                aprPercent: apr ?? (kind == .promoAPR ? 0 : nil),
                startDate: startDate,
                endDate: hasEndDate ? endDate : nil,
                termMonths: term,
                linkedTransactionId: defaultLinkedTransactionId,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                isEnded: ended
            )
            modelContext.insert(plan)
        }
        do {
            try modelContext.save()
            onSaved?()
            if existing == nil { dismiss() }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func recordPayment() {
        guard let plan = existing else { return }
        plan.recordPayment()
        remainingText = formatMoney(plan.remainingAmount)
        try? modelContext.save()
        if plan.isEnded { dismiss() }
    }

    private func markPaidOff() {
        guard let plan = existing else { return }
        plan.markPaidOff()
        remainingText = "0"
        try? modelContext.save()
        dismiss()
    }

    private func deletePlan() {
        guard let plan = existing else { return }
        modelContext.delete(plan)
        try? modelContext.save()
        dismiss()
    }

    private func parseAmount(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "$", with: "")
        guard let value = Double(trimmed) else { return nil }
        return value
    }

    private func parseOptionalAmount(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return parseAmount(trimmed)
    }

    private func formatMoney(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }

    private func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return value.formatted()
    }
}

/// Compact row for Recurring and card detail lists.
struct PayoffPlanRowView: View {
    let plan: PayoffPlan

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: plan.kind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(plan.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(plan.installmentTotal)
                    .font(.body.weight(.semibold))
                MoneyText(plan.remainingAmount, prefix: "", suffix: " left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = [plan.kind.displayName]
        if let next = plan.nextPaymentDate(), next > Date() {
            parts.append("next \(next.formatted(date: .abbreviated, time: .omitted))")
        } else if plan.isEnded {
            parts.append("paid off")
        } else if let end = plan.endDate {
            parts.append("ends \(end.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#Preview {
    NavigationStack {
        PayoffPlanEditorView(
            defaultKind: .payOverTime,
            defaultName: "Couch",
            defaultPaymentMethod: "Chase",
            defaultAmount: 1200
        )
    }
}
