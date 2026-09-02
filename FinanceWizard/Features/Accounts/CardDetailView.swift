//
//  CardDetailView.swift
//  Finance Wizard
//
//  Single account / payment-method detail: balances, bills, spend list.
//

import SwiftUI
import SwiftData

/// Detail screen for one credit card, depository account, or orphan payment method.
/// Credit cards list **all** activity grouped by statement cycle, not the Accounts date filter.
struct CardDetailView: View {
    let displayName: String
    let rawPaymentMethod: String
    // Default empty Set; parent usually passes matching methods from UnifiedCardRow.
    var matchingPaymentMethods: Set<String> = []
    var sort: TransactionSort = .dateNewest
    var creditAccount: BankAccount? = nil
    var bankAccount: BankAccount? = nil
    var onNicknameChanged: (() -> Void)? = nil

    @Query private var transactions: [Transaction]
    @Query private var payoffPlans: [PayoffPlan]
    @Query private var allPayments: [CreditCardPayment]
    @Environment(\.modelContext) private var modelContext

    @State private var nicknameDraft: String = ""
    @State private var didSaveNickname = false
    @State private var titleName: String = ""
    @State private var showAddPayoff = false
    /// FIX: the "Saved" confirmations used detached Task.sleep calls that kept running
    /// after the view was popped and then wrote to @State on a dead view. Held here so
    /// they can be cancelled on disappear and replaced instead of stacking up.
    @State private var savedNameResetTask: Task<Void, Never>?

    // Always have at least the raw method in the set used to filter purchases.
    private var methods: Set<String> {
        var set = matchingPaymentMethods
        if set.isEmpty { set.insert(rawPaymentMethod) }
        return set
    }

    private var cardRows: [Transaction] {
        transactions.filter { methods.contains(TransactionAnalytics.cardName(for: $0)) }
    }

    private var statementCloseDay: Int? {
        StatementCycle.closeDay(from: creditAccount?.lastStatementIssueDate)
    }

    private var statementGroups: [(bucket: StatementBucket, rows: [Transaction])] {
        StatementCycle.group(
            cardRows,
            closeDay: creditAccount != nil ? statementCloseDay : nil,
            lastStatement: creditAccount?.lastStatementIssueDate,
            sort: sort
        )
    }

    /// Cycle shown in Summary — shared with AccountsBoard so both screens agree.
    private var currentStatementGroup: (bucket: StatementBucket, rows: [Transaction])? {
        StatementCycle.currentGroup(in: statementGroups)
    }

    // OLD: statementGroups.first(where: { $0.bucket.isOpen })?.rows ?? statementGroups.first?.rows ?? []
    private var currentStatementRows: [Transaction] {
        currentStatementGroup?.rows ?? []
    }

    private var cardSpend: Double {
        TransactionAnalytics.totalSpend(in: currentStatementRows)
    }

    private var cardPayments: [CreditCardPayment] {
        AccountsBoard.paymentsMatching(
            credit: creditAccount,
            paymentMethods: methods,
            in: Array(allPayments)
        )
    }

    private var currentStatementPayments: [CreditCardPayment] {
        guard let current = currentStatementGroup?.bucket else {
            return cardPayments
        }
        return cardPayments.filter {
            $0.date >= current.start && $0.date <= current.end
        }
    }

    private var paidTotal: Double {
        CreditAnalytics.totalPaid(in: currentStatementPayments)
    }

    /// FIX: this returned "This statement" for any credit account with a close day, even
    /// when the rows below were the previous, already-closed cycle. Label what is actually
    /// on screen: the bucket's own title.
    /// OLD:
    /// if creditAccount != nil, statementCloseDay != nil { return "This statement" }
    /// if let open = statementGroups.first(where: { $0.bucket.isOpen }) { return open.bucket.title }
    private var summaryPeriodLabel: String {
        guard let bucket = currentStatementGroup?.bucket else { return "All activity" }
        return bucket.title
    }

    private var account: BankAccount? { creditAccount ?? bankAccount }

    private var cardPayoffPlans: [PayoffPlan] {
        payoffPlans.filter { plan in
            if let id = creditAccount?.accountId, plan.accountId == id { return true }
            if methods.contains(plan.paymentMethod) { return true }
            return plan.paymentMethod.caseInsensitiveCompare(rawPaymentMethod) == .orderedSame
        }
        .sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
            return lhs.installmentTotal > rhs.installmentTotal
        }
    }

    private var issuerPlans: [PayoffPlan] {
        cardPayoffPlans.filter { $0.kind.followsCardStatement }
    }

    private var payoffByDatePlans: [PayoffPlan] {
        cardPayoffPlans.filter { !$0.kind.followsCardStatement }
    }

    // FIX: removed `isDepositoryDetail` — it was never read, and its condition was
    // self-contradictory (`creditAccount == nil` tested twice, once redundantly).
    // OLD:
    // private var isDepositoryDetail: Bool {
    //     creditAccount == nil && (bankAccount?.isDepository == true || bankAccount != nil && creditAccount == nil)
    // }

    var body: some View {
        List {
            Section {
                InstitutionLogoHeader(
                    displayName: titleName.isEmpty ? displayName : titleName,
                    institutionId: account?.institutionId,
                    institutionName: account?.institutionName,
                    mask: account?.mask
                )
                .listRowBackground(Color.clear)
            }

            Section {
                TextField("Display name", text: $nicknameDraft)
                    .textInputAutocapitalization(.words)
                // Credit vs bank vs orphan method show different identity fields.
                if let credit = creditAccount {
                    LabeledContent("Bank name") {
                        CardText(credit.plaidDisplayName)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if let mask = credit.mask, !mask.isEmpty {
                        LabeledContent("Last four") {
                            CardText(mask)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let bank = bankAccount {
                    LabeledContent("Bank name") {
                        CardText(bank.plaidDisplayName)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if let mask = bank.mask, !mask.isEmpty {
                        LabeledContent("Last four") {
                            CardText(mask)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LabeledContent("Account") {
                        CardText(rawPaymentMethod)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Button("Save name") {
                    saveNickname()
                }
                if didSaveNickname {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            } header: {
                Text("Account name")
            }

            Section {
                if let credit = creditAccount {
                    HStack {
                        Text("Balance")
                        Spacer()
                        MoneyText(max(0, credit.currentBalance))
                            .font(.title3.weight(.semibold))
                    }
                    if let available = credit.availableBalance {
                        HStack {
                            Text("Available credit")
                            Spacer()
                            MoneyText(available)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let limit = credit.creditLimit, limit > 0 {
                        HStack {
                            Text("Limit")
                            Spacer()
                            MoneyText(limit)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let util = credit.utilization {
                            UtilizationBar(value: util, label: "Utilization")
                        }
                    }
                } else if let bank = bankAccount, bank.isDepository {
                    HStack {
                        Text("Available")
                        Spacer()
                        MoneyText(bank.availableBalance ?? bank.currentBalance)
                            .font(.title3.weight(.semibold))
                    }
                    HStack {
                        Text("Ledger balance")
                        Spacer()
                        MoneyText(bank.currentBalance)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Spend")
                    Spacer()
                    MoneyText(cardSpend)
                        .foregroundStyle(.secondary)
                }
                Text("\(summaryPeriodLabel) · \(currentStatementRows.count) transactions")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if creditAccount != nil || paidTotal > 0 || !currentStatementPayments.isEmpty {
                    TotalPaidDisclosure(
                        total: paidTotal,
                        payments: currentStatementPayments,
                        periodLabel: summaryPeriodLabel,
                        institutionId: account?.institutionId
                    )
                }
            } header: {
                Text("Summary")
            }

            if let credit = creditAccount, credit.hasLiabilitiesDetails {
                Section {
                    if credit.isOverdue == true {
                        Label("Payment overdue", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.subheadline.weight(.semibold))
                    }
                    if let minPay = credit.minimumPaymentAmount {
                        LabeledContent("Minimum payment") {
                            MoneyText(minPay)
                        }
                    }
                    LabeledContent("Interest saving balance") {
                        MoneyText(
                            PayoffPlanProgress.interestSavingBalance(
                                on: credit,
                                plans: cardPayoffPlans
                            )
                        )
                    }
                    if let due = credit.nextPaymentDueDate {
                        LabeledContent("Payment due") {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(due, style: .date)
                                if let days = credit.daysUntilDue {
                                    Text(dueSubtitle(days: days, overdue: credit.isOverdue == true))
                                        .font(.caption)
                                        .foregroundStyle(days < 0 || credit.isOverdue == true ? .red : .secondary)
                                }
                            }
                        }
                    }
                    if let lastAmt = credit.lastPaymentAmount {
                        LabeledContent("Last payment") {
                            VStack(alignment: .trailing, spacing: 2) {
                                MoneyText(lastAmt)
                                if let d = credit.lastPaymentDate {
                                    Text(d, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let stmt = credit.lastStatementBalance {
                        LabeledContent("Last statement") {
                            VStack(alignment: .trailing, spacing: 2) {
                                MoneyText(stmt)
                                if let d = credit.lastStatementIssueDate {
                                    Text(d, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    // Optional APRs — only show rows Plaid actually provided.
                    if let apr = credit.purchaseApr {
                        LabeledContent(apr == 0 ? "Purchase APR (promo)" : "Purchase APR") {
                            Text(formatAPR(apr))
                        }
                    }
                    if let apr = credit.cashApr {
                        LabeledContent("Cash APR") {
                            Text(formatAPR(apr))
                        }
                    }
                    if let apr = credit.balanceTransferApr {
                        LabeledContent("Balance transfer APR") {
                            Text(formatAPR(apr))
                        }
                    }
                    if let apr = credit.specialApr {
                        LabeledContent("Special APR") {
                            Text(formatAPR(apr))
                        }
                    }
                } header: {
                    Text("Credit details")
                } footer: {
                    if !issuerPlans.isEmpty {
                        Text("Interest saving balance is other balances in full plus this statement’s loan/installment payments — not leftover loan principal. Paying it each cycle avoids purchase interest and keeps the loan on its billing-cycle schedule. Statement balance would pay the loan off early.")
                    }
                    if credit.liabilitiesSyncedAt == nil {
                        Text("No APR/due date yet. Enable Liabilities in the Plaid Dashboard, Relink this bank (select the credit card), then Sync.")
                    }
                }
            }

            if creditAccount != nil {
                if !issuerPlans.isEmpty {
                    Section {
                        ForEach(issuerPlans, id: \.planId) { plan in
                            NavigationLink {
                                PayoffPlanEditorView(existing: plan)
                            } label: {
                                PayoffPlanRowView(
                                    plan: plan,
                                    cardDueDate: creditAccount?.nextPaymentDueDate
                                )
                            }
                        }
                    } header: {
                        Text("Loans & installments")
                    } footer: {
                        Text("Issuer plans. Each month’s amount is in the card minimum and due with the statement.")
                    }
                }
                Section {
                    ForEach(payoffByDatePlans, id: \.planId) { plan in
                        NavigationLink {
                            PayoffPlanEditorView(existing: plan)
                        } label: {
                            PayoffPlanRowView(
                                plan: plan,
                                cardDueDate: creditAccount?.nextPaymentDueDate
                            )
                        }
                    }
                    Button("Pay off by date") {
                        showAddPayoff = true
                    }
                } header: {
                    Text("Pay off by date")
                } footer: {
                    Text("A plan to clear a promo or extra balance by a date you choose. Not for My Loan or Pay Over Time.")
                }
            }

            if statementGroups.isEmpty {
                Section("Activity") {
                    Text("No transactions on this account yet.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(statementGroups, id: \.bucket.id) { group in
                    Section {
                        ForEach(group.rows) { transaction in
                            NavigationLink {
                                TransactionDetailView(transaction: transaction)
                            } label: {
                                TransactionRowView(
                                    transaction: transaction,
                                    institutionId: account?.institutionId,
                                    institutionName: account?.institutionName,
                                    showPaymentRail: bankAccount?.isDepository == true || creditAccount == nil
                                )
                            }
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.bucket.title)
                            Text(group.bucket.rangeLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(titleName.isEmpty ? displayName : titleName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddPayoff) {
            NavigationStack {
                PayoffPlanEditorView(
                    defaultKind: (creditAccount?.purchaseApr == 0 || creditAccount?.specialApr == 0)
                        ? .promoAPR : .custom,
                    defaultAccountId: creditAccount?.accountId,
                    defaultPaymentMethod: displayName,
                    defaultAmount: (creditAccount?.purchaseApr == 0 || creditAccount?.specialApr == 0)
                        ? (creditAccount?.lastStatementBalance ?? creditAccount?.currentBalance)
                        : nil,
                    defaultApr: creditAccount?.specialApr
                        ?? ((creditAccount?.purchaseApr == 0) ? 0 : nil)
                )
            }
        }
        .onAppear {
            titleName = displayName
            nicknameDraft = displayName
        }
        .onDisappear {
            savedNameResetTask?.cancel()
        }
    }

    // MARK: - Actions

    /// Persist a custom display name (or clear it if empty / same as Plaid name).
    private func saveNickname() {
        let value = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let plaidFallback = creditAccount?.plaidDisplayName
            ?? bankAccount?.plaidDisplayName
            ?? rawPaymentMethod
        // Empty or unchanged → store nil (use bank name).
        let custom: String? = (value.isEmpty || value == plaidFallback) ? nil : value
        CardLabelStore.setLabel(
            custom,
            accountId: account?.accountId,
            paymentMethod: rawPaymentMethod
        )
        titleName = custom ?? plaidFallback
        nicknameDraft = titleName
        didSaveNickname = true
        onNicknameChanged?()
        // OLD: Task { try? await Task.sleep(…); didSaveNickname = false }
        savedNameResetTask?.cancel()
        savedNameResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            didSaveNickname = false
        }
    }



    private func formatAPR(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2))))%"
    }

    /// Relative due copy: past due, today, tomorrow, or “In N days.”
    private func dueSubtitle(days: Int, overdue: Bool) -> String {
        if overdue || days < 0 {
            let past = abs(min(days, 0))
            if past == 0 { return "Due today" }
            return past == 1 ? "1 day past due" : "\(past) days past due"
        }
        if days == 0 { return "Due today" }
        if days == 1 { return "Due tomorrow" }
        return "In \(days) days"
    }
}
