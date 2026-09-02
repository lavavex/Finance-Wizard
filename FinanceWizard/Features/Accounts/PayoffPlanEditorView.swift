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
    @Query private var transactions: [Transaction]

    @State private var kind: PayoffPlanKind = .custom
    @State private var name: String = ""
    @State private var selectedAccountId: String = ""
    @State private var originalText: String = ""
    @State private var remainingText: String = ""
    @State private var monthlyText: String = ""
    // FIX: `feeText` was written and read but had no field anywhere in the Form, so
    // monthlyFee was always nil for custom/promo plans. Issuer plans derive the fee from
    // payment − principal, so no manual entry is needed at all. `hasEndDate` was likewise
    // set in loadDraft but never gated anything — save() always wrote endDate for
    // schedule-driven kinds. Both removed.
    // OLD:
    // @State private var feeText: String = ""
    // @State private var hasEndDate = false
    @State private var aprText: String = ""
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date()
    @State private var termText: String = ""
    @State private var notes: String = ""
    @State private var linkedTransactionId: String?
    @State private var showTransactionPicker = false
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

    private var linkedTransaction: Transaction? {
        guard let id = linkedTransactionId else { return nil }
        return transactions.first { $0.transactionId == id }
    }

    /// FIX: an existing plan's kind was fixed forever (`[existing.kind]`), so a plan created
    /// as the wrong product had to be deleted and rebuilt. The two issuer products differ only
    /// in how the monthly amount splits — My Loan is APR-based, Pay Over Time is a flat plan
    /// fee — so switching between them is a legitimate correction.
    /// OLD: if let existing { return [existing.kind] }
    private var availableKinds: [PayoffPlanKind] {
        if let existing {
            return existing.kind.followsCardStatement ? [.myLoan, .payOverTime] : [existing.kind]
        }
        if defaultKind.followsCardStatement { return [defaultKind] }
        return [.promoAPR, .custom]
    }

    private var showsKindPicker: Bool { availableKinds.count > 1 }

    private var showsTransactionPicker: Bool {
        kind.followsCardStatement
    }

    private var showsSchedule: Bool {
        !kind.followsCardStatement
    }

    private var editorTitle: String {
        if existing != nil { return kind.displayName }
        if kind.followsCardStatement {
            return kind == .myLoan ? "Loan on this card" : "Installment"
        }
        return "Pay off by date"
    }

    private var pickerTransactions: [Transaction] {
        let onCard = transactions.filter { matchesSelectedCard($0) }
        if kind == .myLoan {
            let loans = onCard.filter { PayoffPlanRecognition.looksLikeLoanDisbursement(title: $0.title) }
                .sorted { $0.date > $1.date }
            let rest = onCard.filter { !PayoffPlanRecognition.looksLikeLoanDisbursement(title: $0.title) }
                .sorted {
                    if abs($0.amount) == abs($1.amount) { return $0.date > $1.date }
                    return abs($0.amount) > abs($1.amount)
                }
            return Array((loans + rest).prefix(80))
        }
        return Array(
            onCard
                .filter { !TransactionAnalytics.isCreditCardPaymentCategory($0.category) }
                .sorted { $0.date > $1.date }
                .prefix(80)
        )
    }

    var body: some View {
        Form {
            Section {
                if showsKindPicker {
                    Picker("Type", selection: $kind) {
                        ForEach(availableKinds) { value in
                            Text(value.displayName).tag(value)
                        }
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

            if showsTransactionPicker {
                Section {
                    if let tx = linkedTransaction {
                        Button {
                            showTransactionPicker = true
                        } label: {
                            TransactionRowView(transaction: tx)
                        }
                        .buttonStyle(.plain)
                        Button("Clear transaction", role: .destructive) {
                            linkedTransactionId = nil
                        }
                    } else {
                        Button(kind == .myLoan ? "Choose loan charge" : "Choose purchase") {
                            showTransactionPicker = true
                        }
                    }
                } header: {
                    Text(kind == .myLoan ? "Loan charge" : "Purchase")
                } footer: {
                    Text(kind == .myLoan
                         ? "The loan posts as a charge on the card (for example “My Loan TO 1234”). Pick that row."
                         : "The purchase this Pay Over Time plan is paying off.")
                }
            }

            Section {
                moneyField("Original amount", text: $originalText)
                moneyField("Remaining", text: $remainingText)
                moneyField("Monthly payment", text: $monthlyText)
                if kind.followsCardStatement {
                    HStack {
                        Text("Remaining months")
                        Spacer()
                        TextField("required", text: $termText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                    }
                    if kind == .myLoan {
                        HStack {
                            Text("APR %")
                            Spacer()
                            TextField("from email", text: $aprText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                        }
                    }
                    if let breakdown = issuerBreakdown {
                        LabeledContent("Principal this statement") {
                            MoneyText(breakdown.principal)
                        }
                        LabeledContent(kind == .payOverTime ? "Monthly fee" : "Interest this statement") {
                            MoneyText(breakdown.fee)
                                .foregroundStyle(breakdown.fee < -0.005 ? .red : .secondary)
                        }
                        if kind == .myLoan, aprText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let apr = breakdown.apr {
                            LabeledContent("Implied APR") {
                                Text("\(apr.formatted(.number.precision(.fractionLength(0...2))))%")
                            }
                        }
                    }
                }
                if kind == .promoAPR {
                    HStack {
                        Text("Promo APR %")
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

            if kind.followsCardStatement {
                Section {
                    if let due = selectedAccount?.nextPaymentDueDate {
                        LabeledContent("Due with card") {
                            Text(due, style: .date)
                        }
                    } else {
                        Text("Due on the same day as this card’s statement payment. It is included in the minimum due.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Card statement")
                } footer: {
                    Text("The issuer adds this installment to the minimum at statement close. There is no separate due date.")
                }
            } else {
                Section {
                    DatePicker(
                        kind == .promoAPR ? "Promo ends" : "Pay off by",
                        selection: $endDate,
                        displayedComponents: .date
                    )
                    if let suggested = suggestedMonthly {
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
                    Text("Pay off by")
                } footer: {
                    Text("Extra principal you plan to send with the card payment each statement. Due date follows the card.")
                }
            }

            Section {
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
            }

            if existing != nil {
                Section {
                    if !kind.followsCardStatement {
                        Button("Record this month’s payment") {
                            recordPayment()
                        }
                    }
                    Button("Mark paid off") {
                        markPaidOff()
                    }
                } footer: {
                    if kind.followsCardStatement {
                        Text("Remaining drops when the next statement closes (after Sync).")
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
        .navigationTitle(editorTitle)
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
            // Switching an existing plan to My Loan needs an APR; seed it from the payment,
            // remaining and term so the split is sensible before the user types the real rate.
            if newKind == .myLoan, aprText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let remaining = parseAmount(remainingText),
               let payment = parseAmount(monthlyText),
               let months = Int(termText.trimmingCharacters(in: .whitespacesAndNewlines)),
               let implied = PayoffPlanMath.impliedAPR(
                    payment: payment, remaining: remaining, months: months
               ) {
                aprText = formatNumber((implied * 100).rounded() / 100)
            }
        }
        .sheet(isPresented: $showTransactionPicker) {
            NavigationStack {
                List {
                    if pickerTransactions.isEmpty {
                        Text("No charges on this card yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(pickerTransactions, id: \.transactionId) { tx in
                            Button {
                                applyLinkedTransaction(tx)
                                showTransactionPicker = false
                            } label: {
                                TransactionRowView(transaction: tx)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .navigationTitle(kind == .myLoan ? "Loan charge" : "Purchase")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showTransactionPicker = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var amountsFooter: some View {
        switch kind {
        case .payOverTime:
            Text("Monthly payment is what hits the statement. Fee is the rest after remaining ÷ months (principal). Fee is not principal.")
        case .promoAPR:
            Text("Set remaining to the promo balance (not the whole card). Monthly payment should clear it before the promo ends.")
        case .myLoan:
            Text("From the loan email: amount, fixed APR, billing cycles, and monthly payment. Interest this statement is remaining × APR ÷ 12. Principal is the rest of the payment. The minimum due includes this payment.")
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

    private var issuerBreakdown: (principal: Double, fee: Double, apr: Double?)? {
        guard kind.followsCardStatement,
              let remaining = parseAmount(remainingText), remaining > 0,
              let payment = parseAmount(monthlyText), payment > 0,
              let months = Int(termText.trimmingCharacters(in: .whitespacesAndNewlines)),
              months > 0
        else { return nil }
        if kind == .myLoan {
            let enteredAPR = parseOptionalAmount(aprText)
            let apr = enteredAPR
                ?? PayoffPlanMath.impliedAPR(payment: payment, remaining: remaining, months: months)
            let interest = PayoffPlanMath.amortizingInterest(remaining: remaining, aprPercent: apr) ?? 0
            return (payment - interest, interest, apr)
        }
        guard let principal = PayoffPlanMath.evenPrincipal(remaining: remaining, months: months),
              let fee = PayoffPlanMath.impliedFee(payment: payment, remaining: remaining, months: months)
        else { return nil }
        return (principal, fee, nil)
    }

    /// FIX: both of these divided remaining by the payment and ignored the promo APR, so on
    /// a non-zero APR the suggested payment left a balance when the promo expired and the
    /// pace warning stayed silent. Both now amortise at the entered APR (0% is unchanged).
    /// OLD: return remaining / Double(count)
    private var suggestedMonthly: Double? {
        guard showsSchedule, let remaining = parseAmount(remainingText), remaining > 0 else {
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
        return PayoffPlanMath.levelPayment(
            remaining: remaining,
            months: count,
            aprPercent: parseOptionalAmount(aprText)
        )
    }

    /// OLD: let months = Int(ceil(remaining / monthly))
    private var paceWarning: String? {
        guard showsSchedule,
              let remaining = parseAmount(remainingText), remaining > 0,
              let monthly = parseAmount(monthlyText), monthly > 0 else {
            return nil
        }
        let apr = parseOptionalAmount(aprText)
        guard let months = PayoffPlanMath.monthsToPayOff(
            remaining: remaining,
            payment: monthly,
            aprPercent: apr
        ) else {
            // Payment does not even cover one month of interest at this APR.
            return "At this payment the balance never clears — it is below the monthly interest."
        }
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
            // OLD: feeText = plan.monthlyFee.map(formatMoney) ?? ""
            aprText = plan.aprPercent.map { formatNumber($0) } ?? (plan.kind == .promoAPR ? "0" : "")
            startDate = plan.startDate
            if let end = plan.endDate {
                endDate = end
            }
            termText = plan.termMonths.map(String.init) ?? ""
            notes = plan.notes ?? ""
            linkedTransactionId = plan.linkedTransactionId
            return
        }
        kind = defaultKind
        name = defaultKind == .myLoan && !defaultName.isEmpty
            ? PayoffPlanRecognition.displayName(fromTitle: defaultName)
            : defaultName
        selectedAccountId = defaultAccountId ?? ""
        linkedTransactionId = defaultLinkedTransactionId
        if let amount = defaultAmount {
            originalText = formatMoney(amount)
            remainingText = formatMoney(amount)
        }
        if defaultKind == .promoAPR {
            aprText = defaultApr.map { formatNumber($0) } ?? "0"
        } else if let apr = defaultApr {
            aprText = formatNumber(apr)
        }
        // OLD: hasEndDate = !defaultKind.followsCardStatement
        if let end = defaultEndDate {
            endDate = end
        } else if !defaultKind.followsCardStatement {
            endDate = Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
        }
    }

    private func save() {
        saveError = nil
        var trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            trimmedName = kind.displayName
        }
        if showsSchedule, endDate < Calendar.current.startOfDay(for: Date()) {
            saveError = "Pay-off date must be in the future."
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
        let term = Int(termText.trimmingCharacters(in: .whitespacesAndNewlines))
        if kind.followsCardStatement {
            guard let months = term, months > 0 else {
                saveError = "Remaining months is required so fee and principal can be calculated."
                return
            }
            if let fee = PayoffPlanMath.impliedFee(payment: monthly, remaining: remaining, months: months),
               fee < -0.05 {
                saveError = "Monthly payment is less than remaining ÷ months. Check remaining, months, or payment."
                return
            }
        }
        // OLD: guard kind.followsCardStatement else { return parseOptionalAmount(feeText) }
        let fee: Double? = {
            guard kind.followsCardStatement else { return nil }
            return PayoffPlanMath.impliedFee(payment: monthly, remaining: remaining, months: term)
        }()
        let apr: Double? = {
            if kind == .promoAPR { return parseOptionalAmount(aprText) ?? 0 }
            if kind == .myLoan {
                return parseOptionalAmount(aprText)
                    ?? PayoffPlanMath.impliedAPR(payment: monthly, remaining: remaining, months: term)
            }
            return nil
        }()

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
            plan.monthlyFee = kind.followsCardStatement ? fee : nil
            plan.aprPercent = apr
            // FIX: editing re-stamped startDate with whatever the card's due date happened
            // to be at that moment. For a promo / custom plan startDate drives the whole
            // schedule (nextMonthly walks from it), so every save nudged the schedule
            // forward. An edit must not move a date the plan already has.
            // OLD: plan.startDate = selectedAccount?.nextPaymentDueDate ?? startDate
            plan.startDate = startDate
            plan.endDate = kind.followsCardStatement ? nil : endDate
            plan.termMonths = term
            plan.linkedTransactionId = linkedTransactionId
            plan.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            plan.isEnded = ended
            plan.updatedAt = Date()
            if kind.followsCardStatement, plan.lastAppliedStatementDate == nil {
                plan.lastAppliedStatementDate = selectedAccount?.lastStatementIssueDate
            }
        } else {
            let plan = PayoffPlan(
                kind: kind,
                name: trimmedName,
                accountId: accountId,
                paymentMethod: method,
                originalAmount: original,
                remainingAmount: ended ? 0 : remaining,
                monthlyPayment: monthly,
                monthlyFee: kind.followsCardStatement ? fee : nil,
                aprPercent: apr ?? (kind == .promoAPR ? 0 : nil),
                // A brand-new plan still seeds from the card's due date — the form has no
                // start-date field, and "due with the card" is the right default. Only the
                // edit path above changed, so an existing schedule stops drifting.
                startDate: selectedAccount?.nextPaymentDueDate ?? startDate,
                endDate: kind.followsCardStatement ? nil : endDate,
                termMonths: term,
                linkedTransactionId: linkedTransactionId,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                isEnded: ended,
                lastAppliedStatementDate: kind.followsCardStatement
                    ? selectedAccount?.lastStatementIssueDate : nil
            )
            modelContext.insert(plan)
        }
        if kind == .myLoan, let tx = linkedTransaction {
            adoptMyLoanCharge(tx)
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

    private func matchesSelectedCard(_ tx: Transaction) -> Bool {
        if let account = selectedAccount {
            return account.matchesPaymentMethod(tx.paymentMethod)
        }
        let method = paymentMethodLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if method.isEmpty { return true }
        if tx.paymentMethod.caseInsensitiveCompare(method) == .orderedSame { return true }
        if !defaultPaymentMethod.isEmpty,
           tx.paymentMethod.caseInsensitiveCompare(defaultPaymentMethod) == .orderedSame {
            return true
        }
        return false
    }

    private func applyLinkedTransaction(_ tx: Transaction) {
        linkedTransactionId = tx.transactionId
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || name == defaultName {
            name = PayoffPlanRecognition.displayName(fromTitle: tx.title)
        }
        let amount = abs(tx.amount)
        if originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            originalText = formatMoney(amount)
        }
        if remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remainingText = formatMoney(amount)
        }
        startDate = tx.date
        if let account = BankAccount.matching(paymentMethod: tx.paymentMethod, in: Array(accounts)) {
            selectedAccountId = account.accountId
        }
        if kind == .myLoan {
            originalText = formatMoney(amount)
            if remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                remainingText = formatMoney(amount)
            }
        }
    }

    /// My Loan is not a card bill payment — drop Total paid + recategorize as Loan.
    private func adoptMyLoanCharge(_ tx: Transaction) {
        tx.category = KnownCategory.loan.rawValue
        tx.categoryLocked = true
        tx.overrideSource = "my-loan"
        let targetId = tx.transactionId
        var descriptor = FetchDescriptor<CreditCardPayment>(
            predicate: #Predicate<CreditCardPayment> { row in
                row.transactionId == targetId
            }
        )
        descriptor.fetchLimit = 1
        if let payment = try? modelContext.fetch(descriptor).first {
            modelContext.delete(payment)
        }
    }

    /// FIX: this replaced "," with "." to accept European decimals, which destroyed US
    /// thousands separators — "4,000" parsed as $4.00, "$4,000" as $4.00 and "4,000.00" as
    /// nil. Entering a loan with a comma silently created a $4 plan. Decide what the comma
    /// means from the string itself: a group separator when digits follow in threes or a
    /// "." is also present, otherwise a decimal mark.
    private func parseAmount(_ raw: String) -> Double? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
        guard !t.isEmpty else { return nil }
        if t.contains(",") {
            if t.contains(".") {
                // "4,000.00" — comma groups, dot decides the decimal.
                t = t.replacingOccurrences(of: ",", with: "")
            } else {
                // "4,000" groups; "4,5" is a decimal comma.
                let parts = t.split(separator: ",", omittingEmptySubsequences: false)
                let grouped = parts.count > 1
                    && parts.dropFirst().allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
                t = t.replacingOccurrences(of: ",", with: grouped ? "" : ".")
            }
        }
        return Double(t)
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
    var cardDueDate: Date? = nil

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
        if let next = plan.nextPaymentDate(cardDueDate: cardDueDate), next > Date() {
            parts.append("due \(next.formatted(date: .abbreviated, time: .omitted))")
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
