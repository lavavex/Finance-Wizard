//
//  CardsView.swift
//  Finance Wizard
//
//  Cards hub: one row per real account (by Plaid account_id / mask), not
//  collapsed by bank brand. Logos come from Plaid only.
//

import SwiftUI
import SwiftData

// MARK: - Cards tab

struct CardsView: View {
    @Query private var transactions: [Transaction]
    @Query(sort: \BankAccount.name) private var accounts: [BankAccount]
    @Query(sort: \CreditCardPayment.date, order: .reverse) private var payments: [CreditCardPayment]

    @State private var period: SnapshotPeriod = .month
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var sort: TransactionSort = .dateNewest
    @State private var nicknameEpoch = 0

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    private var periodTransactions: [Transaction] {
        TransactionAnalytics.inPeriod(
            transactions,
            period: period,
            referenceDate: referenceDate
        )
    }

    private var creditAccounts: [BankAccount] {
        _ = nicknameEpoch
        return accounts.filter(\.isCredit)
    }

    private var periodPayments: [CreditCardPayment] {
        CreditAnalytics.payments(in: payments, period: period, referenceDate: referenceDate)
    }

    private var periodTotalSpend: Double {
        TransactionAnalytics.totalSpend(in: periodTransactions)
    }

    private var totalOwed: Double {
        creditAccounts.reduce(0) { $0 + max(0, $1.currentBalance) }
    }

    private var totalLimit: Double {
        creditAccounts.compactMap(\.creditLimit).reduce(0, +)
    }

    private var totalUtilization: Double? {
        guard totalLimit > 0 else { return nil }
        return min(max(totalOwed / totalLimit, 0), 1)
    }

    private var totalPaidInPeriod: Double {
        CreditAnalytics.totalPaid(in: periodPayments)
    }

    private var totalMinimumDue: Double {
        creditAccounts.compactMap(\.minimumPaymentAmount).reduce(0, +)
    }

    private var soonestDueDate: Date? {
        creditAccounts.compactMap(\.nextPaymentDueDate).min()
    }

    private var anyOverdue: Bool {
        creditAccounts.contains { $0.isOverdue == true }
    }

    /// One row per credit account (unique account_id), plus orphan spend methods.
    private var unifiedCardRows: [UnifiedCardRow] {
        _ = nicknameEpoch

        var claimedPaymentMethods = Set<String>()
        var rows: [UnifiedCardRow] = []

        // 1) Each Plaid credit account is its own card — never merge by brand.
        for account in creditAccounts.sorted(by: { max(0, $0.currentBalance) > max(0, $1.currentBalance) }) {
            let methods = paymentMethodsMatching(account: account)
            for m in methods { claimedPaymentMethods.insert(m) }

            let spendTxs = periodTransactions.filter {
                methods.contains(TransactionAnalytics.cardName(for: $0))
            }
            let spent = TransactionAnalytics.totalSpend(in: spendTxs)
            let primaryMethod = methods.sorted().first ?? account.plaidDisplayName

            rows.append(
                UnifiedCardRow(
                    id: account.accountId,
                    displayName: account.displayName,
                    rawPaymentMethod: primaryMethod,
                    matchingPaymentMethods: methods,
                    spent: spent,
                    transactionCount: spendTxs.count,
                    creditAccount: account,
                    paidInPeriod: paidFor(credit: account, paymentMethods: methods)
                )
            )
        }

        // 2) Spend-only methods (checking, etc.) not claimed by a credit account
        let orphanMethods = Set(periodTransactions.map { TransactionAnalytics.cardName(for: $0) })
            .subtracting(claimedPaymentMethods)
            .sorted()

        for method in orphanMethods {
            let spendTxs = periodTransactions.filter {
                TransactionAnalytics.cardName(for: $0) == method
            }
            let spent = TransactionAnalytics.totalSpend(in: spendTxs)
            guard spent > 0 || !spendTxs.isEmpty else { continue }

            // Prefer depository account if exact match
            let depository = accounts.first { account in
                !account.isCredit && paymentMethodsMatching(account: account).contains(method)
            }

            rows.append(
                UnifiedCardRow(
                    id: "method:\(method)",
                    displayName: CardLabelStore.label(
                        paymentMethod: method,
                        accountId: depository?.accountId,
                        fallback: method
                    ),
                    rawPaymentMethod: method,
                    matchingPaymentMethods: [method],
                    spent: spent,
                    transactionCount: spendTxs.count,
                    creditAccount: nil,
                    bankAccount: depository,
                    paidInPeriod: 0
                )
            )
        }

        return rows.sorted { lhs, rhs in
            let balanceL = lhs.creditAccount.map { max(0, $0.currentBalance) } ?? -1
            let balanceR = rhs.creditAccount.map { max(0, $0.currentBalance) } ?? -1
            if balanceL != balanceR { return balanceL > balanceR }
            if lhs.spent != rhs.spent { return lhs.spent > rhs.spent }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CategorySpendView(period: period, referenceDate: referenceDate)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Total Spend")
                                    .font(.headline)
                                Text(periodLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("Tap for category chart")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Text(periodTotalSpend, format: .currency(code: "USD"))
                                .font(.title3.bold())
                        }
                    }

                    if !creditAccounts.isEmpty || totalPaidInPeriod > 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Credit balance")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(totalOwed, format: .currency(code: "USD"))
                                        .font(.title3.weight(.semibold))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Limit")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(totalLimit > 0 ? totalLimit : 0, format: .currency(code: "USD"))
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let util = totalUtilization {
                                UtilizationBar(value: util, label: "Overall utilization")
                            }

                            if totalMinimumDue > 0 || soonestDueDate != nil {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Min payments")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if totalMinimumDue > 0 {
                                            Text(totalMinimumDue, format: .currency(code: "USD"))
                                                .font(.subheadline.weight(.semibold))
                                        } else {
                                            Text("—")
                                                .font(.subheadline)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(anyOverdue ? "Overdue" : "Next due")
                                            .font(.caption)
                                            .foregroundStyle(anyOverdue ? .red : .secondary)
                                        if let due = soonestDueDate {
                                            Text(due, style: .date)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(anyOverdue ? .red : .primary)
                                        } else {
                                            Text("—")
                                                .font(.subheadline)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }

                            HStack {
                                Text("Paid in \(periodLabel.lowercased())")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(totalPaidInPeriod, format: .currency(code: "USD"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.green)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Overview")
                } footer: {
                    Text("Each linked account is listed separately (by card number). Open a card to rename it. Logos and credit details come from Plaid.")
                }

                Section {
                    if unifiedCardRows.isEmpty {
                        Text("No cards in \(periodLabel.lowercased()). Sync data or pick another range.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(unifiedCardRows) { row in
                            NavigationLink {
                                CardDetailView(
                                    displayName: row.displayName,
                                    rawPaymentMethod: row.rawPaymentMethod,
                                    matchingPaymentMethods: row.matchingPaymentMethods,
                                    period: period,
                                    referenceDate: referenceDate,
                                    sort: sort,
                                    creditAccount: row.creditAccount,
                                    bankAccount: row.bankAccount ?? row.creditAccount,
                                    periodPayments: paymentsMatching(
                                        credit: row.creditAccount,
                                        paymentMethods: row.matchingPaymentMethods
                                    ),
                                    onNicknameChanged: { nicknameEpoch += 1 }
                                )
                            } label: {
                                UnifiedCardLabel(row: row)
                            }
                        }
                    }
                } header: {
                    Text("Cards")
                }

                Section {
                    if periodPayments.isEmpty {
                        Text("No card payments in \(periodLabel.lowercased()).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(periodPayments, id: \.transactionId) { payment in
                            CreditPaymentRow(
                                payment: payment,
                                institutionId: institutionId(for: payment)
                            )
                        }
                    }
                } header: {
                    Text("Payments · \(periodLabel)")
                } footer: {
                    Text("Card bill payments don’t count toward Total Spend.")
                }
            }
            .navigationTitle("Cards")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(TransactionSort.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PeriodFilterMenu(
                        period: $period,
                        referenceDate: $referenceDate,
                        transactions: transactions,
                        additionalDates: payments.map(\.date),
                        showTitle: true
                    )
                }
            }
        }
    }

    // MARK: - Strict matching (mask / exact only — never brand-wide)

    /// Payment-method strings that belong to this Plaid account.
    private func paymentMethodsMatching(account: BankAccount) -> Set<String> {
        var methods = Set<String>()
        let allMethods = Set(transactions.map { TransactionAnalytics.cardName(for: $0) })
            .union(periodTransactions.map { TransactionAnalytics.cardName(for: $0) })

        for method in allMethods {
            if methodBelongs(method, to: account) {
                methods.insert(method)
            }
        }

        // Always include the account’s own Plaid label even with no spend yet
        methods.insert(account.plaidDisplayName)
        return methods
    }

    private func methodBelongs(_ method: String, to account: BankAccount) -> Bool {
        if namesMatch(method, account.plaidDisplayName) { return true }
        if namesMatch(method, account.name) { return true }
        // Mask is the reliable disambiguator for multiple Chase cards
        if let mask = account.mask, !mask.isEmpty {
            // "Credit Card ···0820" / "Chase Freedom ...0820" / "····0820"
            if method.contains(mask) { return true }
        }
        return false
    }

    private func paidFor(credit: BankAccount, paymentMethods: Set<String>) -> Double {
        CreditAnalytics.totalPaid(
            in: paymentsMatching(credit: credit, paymentMethods: paymentMethods)
        )
    }

    private func paymentsMatching(
        credit: BankAccount?,
        paymentMethods: Set<String>
    ) -> [CreditCardPayment] {
        periodPayments.filter { payment in
            if let credit, let id = payment.creditAccountId, id == credit.accountId {
                return true
            }
            if let credit, let mask = credit.mask, !mask.isEmpty, payment.cardName.contains(mask) {
                return true
            }
            if paymentMethods.contains(payment.cardName) { return true }
            if let credit, namesMatch(payment.cardName, credit.plaidDisplayName) {
                return true
            }
            return false
        }
    }

    private func namesMatch(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func institutionId(for payment: CreditCardPayment) -> String? {
        if let id = payment.creditAccountId,
           let account = accounts.first(where: { $0.accountId == id }) {
            return account.institutionId
        }
        if let maskMatch = creditAccounts.first(where: { account in
            guard let mask = account.mask, !mask.isEmpty else { return false }
            return payment.cardName.contains(mask)
        }) {
            return maskMatch.institutionId
        }
        return accounts.first { $0.institutionName == payment.institutionName }?.institutionId
    }
}

// MARK: - Row model

private struct UnifiedCardRow: Identifiable {
    let id: String
    let displayName: String
    let rawPaymentMethod: String
    let matchingPaymentMethods: Set<String>
    let spent: Double
    let transactionCount: Int
    let creditAccount: BankAccount?
    var bankAccount: BankAccount? = nil
    let paidInPeriod: Double

    var institutionId: String? {
        creditAccount?.institutionId ?? bankAccount?.institutionId
    }

    var institutionName: String? {
        creditAccount?.institutionName ?? bankAccount?.institutionName
    }
}

private struct UnifiedCardLabel: View {
    let row: UnifiedCardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                BankIconView(
                    paymentMethod: row.rawPaymentMethod,
                    size: 40,
                    accountId: row.creditAccount?.accountId ?? row.bankAccount?.accountId,
                    displayName: row.displayName,
                    institutionId: row.institutionId,
                    institutionName: row.institutionName
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body.weight(.semibold))
                    if let account = row.creditAccount {
                        Text(account.subtitleDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let mask = row.bankAccount?.mask, !mask.isEmpty {
                        Text("···\(mask)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(row.transactionCount > 0
                             ? "\(row.transactionCount) purchases"
                             : "No purchases this period")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let account = row.creditAccount {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(max(0, account.currentBalance), format: .currency(code: "USD"))
                            .font(.body.weight(.semibold))
                        if let limit = account.creditLimit, limit > 0 {
                            Text("Limit \(limit.formatted(.currency(code: "USD")))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Balance")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(row.spent, format: .currency(code: "USD"))
                            .font(.body.weight(.semibold))
                        Text("Spend")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let util = row.creditAccount?.utilization {
                UtilizationBar(value: util, label: nil)
            }

            if let credit = row.creditAccount, credit.hasLiabilitiesDetails {
                HStack(spacing: 8) {
                    if let minPay = credit.minimumPaymentAmount {
                        Text("Min \(minPay.formatted(.currency(code: "USD")))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let due = credit.nextPaymentDueDate {
                        Text("·")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if credit.isOverdue == true {
                            Text("Overdue")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        } else {
                            Text("Due \(due.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if credit.isOverdue == true {
                        Text("Overdue")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Spacer(minLength: 0)
                }
            }

            HStack {
                Text("Spend \(row.spent.formatted(.currency(code: "USD")))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.transactionCount > 0 {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("\(row.transactionCount) purchases")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.paidInPeriod > 0 {
                    Text("Paid \(row.paidInPeriod.formatted(.currency(code: "USD")))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Card detail

struct CardDetailView: View {
    let displayName: String
    let rawPaymentMethod: String
    var matchingPaymentMethods: Set<String> = []
    let period: SnapshotPeriod
    let referenceDate: Date
    let sort: TransactionSort
    var creditAccount: BankAccount? = nil
    var bankAccount: BankAccount? = nil
    var periodPayments: [CreditCardPayment] = []
    var onNicknameChanged: (() -> Void)? = nil

    @Query private var transactions: [Transaction]
    @State private var nicknameDraft: String = ""
    @State private var didSaveNickname = false
    @State private var titleName: String = ""

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    private var methods: Set<String> {
        var set = matchingPaymentMethods
        if set.isEmpty { set.insert(rawPaymentMethod) }
        return set
    }

    private var cardRows: [Transaction] {
        let inPeriod = TransactionAnalytics.inPeriod(
            transactions,
            period: period,
            referenceDate: referenceDate
        )
        let forCard = inPeriod.filter { methods.contains(TransactionAnalytics.cardName(for: $0)) }
        return TransactionAnalytics.sorted(forCard, by: sort)
    }

    private var cardSpend: Double {
        TransactionAnalytics.totalSpend(in: cardRows)
    }

    private var paidTotal: Double {
        CreditAnalytics.totalPaid(in: periodPayments)
    }

    private var account: BankAccount? { creditAccount ?? bankAccount }

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
                if let credit = creditAccount {
                    LabeledContent("Plaid name") {
                        Text(credit.plaidDisplayName)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    if let mask = credit.mask, !mask.isEmpty {
                        LabeledContent("Last four") {
                            Text(mask)
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LabeledContent("Account") {
                        Text(rawPaymentMethod)
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
                Text("Card name")
            } footer: {
                Text("Nicknames are per account (by card number). Multiple Chase cards stay separate.")
            }

            Section {
                if let credit = creditAccount {
                    HStack {
                        Text("Balance")
                        Spacer()
                        Text(max(0, credit.currentBalance), format: .currency(code: "USD"))
                            .font(.title3.weight(.semibold))
                    }
                    if let available = credit.availableBalance {
                        HStack {
                            Text("Available credit")
                            Spacer()
                            Text(available, format: .currency(code: "USD"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let limit = credit.creditLimit, limit > 0 {
                        HStack {
                            Text("Limit")
                            Spacer()
                            Text(limit, format: .currency(code: "USD"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let util = credit.utilization {
                            UtilizationBar(value: util, label: "Utilization")
                        }
                    }
                }

                HStack {
                    Text("Spend")
                    Spacer()
                    Text(cardSpend, format: .currency(code: "USD"))
                        .foregroundStyle(.secondary)
                }
                Text("\(periodLabel) · \(cardRows.count) purchases")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Paid this period")
                    Spacer()
                    Text(paidTotal, format: .currency(code: "USD"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(paidTotal > 0 ? .green : .secondary)
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
                            Text(minPay, format: .currency(code: "USD"))
                        }
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
                                Text(lastAmt, format: .currency(code: "USD"))
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
                                Text(stmt, format: .currency(code: "USD"))
                                if let d = credit.lastStatementIssueDate {
                                    Text(d, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if let apr = credit.purchaseApr {
                        LabeledContent("Purchase APR") {
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
                    if credit.liabilitiesSyncedAt != nil {
                        Text("From Plaid Liabilities. Coverage varies by bank.")
                    } else {
                        Text("Sync after linking to load APR and due dates when the bank supports them.")
                    }
                }
            }

            if !periodPayments.isEmpty {
                Section("Payments · \(periodLabel)") {
                    ForEach(periodPayments, id: \.transactionId) { payment in
                        CreditPaymentRow(
                            payment: payment,
                            institutionId: account?.institutionId
                        )
                    }
                }
            }

            Section("Purchases") {
                if cardRows.isEmpty {
                    Text("No purchases for this card in the selected period.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cardRows) { transaction in
                        NavigationLink {
                            TransactionDetailView(transaction: transaction)
                        } label: {
                            TransactionRowView(
                                transaction: transaction,
                                institutionId: account?.institutionId,
                                institutionName: account?.institutionName
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(titleName.isEmpty ? displayName : titleName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            titleName = displayName
            nicknameDraft = displayName
        }
    }

    private func saveNickname() {
        let value = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let plaidFallback = creditAccount?.plaidDisplayName
            ?? bankAccount?.plaidDisplayName
            ?? rawPaymentMethod
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
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didSaveNickname = false
        }
    }

    private func formatAPR(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2))))%"
    }

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

// MARK: - Shared rows

struct TransactionRowView: View {
    let transaction: Transaction
    var institutionId: String? = nil
    var institutionName: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Category for the spend type; institution mark when we know the card's bank
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: CategoryStyle.symbolName(for: transaction.category))
                    .font(.title3)
                    .foregroundStyle(CategoryStyle.color(for: transaction.category))
                    .frame(width: 28, alignment: .center)
                    .accessibilityLabel(transaction.category)

                if institutionId != nil || institutionName != nil {
                    BankIconView(
                        paymentMethod: transaction.paymentMethod,
                        size: 14,
                        displayName: displayPaymentMethod,
                        institutionId: institutionId,
                        institutionName: institutionName
                    )
                    .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.title)
                    .font(.body)
                Text("\(transaction.category) · \(displayPaymentMethod)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(transaction.amount, format: .currency(code: "USD"))
                    .foregroundStyle(transaction.amount >= 0 ? .green : .primary)
                Text("\(transaction.multiplier.formatted())x")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayPaymentMethod: String {
        CardLabelStore.label(paymentMethod: transaction.paymentMethod)
    }
}

struct CreditPaymentRow: View {
    let payment: CreditCardPayment
    var institutionId: String? = nil

    private var cardLabel: String {
        if let id = payment.creditAccountId {
            return CardLabelStore.label(accountId: id, fallback: payment.cardName)
        }
        return CardLabelStore.label(paymentMethod: payment.cardName, fallback: payment.cardName)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                BankIconView(
                    paymentMethod: payment.cardName,
                    size: 36,
                    displayName: cardLabel,
                    institutionId: institutionId,
                    institutionName: payment.institutionName
                )
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                    .background(Circle().fill(Color(.systemBackground)).padding(-1))
                    .offset(x: 4, y: 4)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(cardLabel)
                    .font(.body.weight(.medium))
                Text(payment.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(payment.date, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(payment.amount, format: .currency(code: "USD"))
                .font(.body.weight(.semibold))
                .foregroundStyle(.green)
        }
    }
}

struct UtilizationBar: View {
    let value: Double
    let label: String?

    private var percent: Int {
        Int((value * 100).rounded())
    }

    private var color: Color {
        switch value {
        case ..<0.30: return .green
        case ..<0.70: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let label {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(percent)% used")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(4, geo.size.width * value))
                }
            }
            .frame(height: 8)
        }
    }
}

#Preview {
    CardsView()
        .modelContainer(
            for: [Transaction.self, BankAccount.self, CreditCardPayment.self],
            inMemory: true
        )
}
