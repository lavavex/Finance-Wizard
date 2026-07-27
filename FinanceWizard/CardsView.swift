//
//  CardsView.swift
//  Finance Wizard
//
//  Cards hub: period spend by payment method, credit utilization, and card payments.
//  User nicknames (e.g. "Chase Freedom") live in CardLabelStore.
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
    /// Bumped when the user renames a card so labels re-resolve.
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

    private var cardSummaries: [CardSpendSummary] {
        TransactionAnalytics.cardSummaries(from: periodTransactions, cardLimit: nil)
    }

    private var periodTotalSpend: Double {
        TransactionAnalytics.totalSpend(in: periodTransactions)
    }

    private var creditAccounts: [BankAccount] {
        // nicknameEpoch forces recompute after rename
        _ = nicknameEpoch
        return accounts.filter(\.isCredit)
    }

    private var periodPayments: [CreditCardPayment] {
        CreditAnalytics.payments(in: payments, period: period, referenceDate: referenceDate)
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

    /// Payment-method rows from spend, plus credit accounts that had no spend this period.
    private var unifiedCardRows: [UnifiedCardRow] {
        _ = nicknameEpoch
        var rows: [UnifiedCardRow] = cardSummaries.map { summary in
            let credit = matchCreditAccount(toPaymentMethod: summary.cardName)
            let display = resolveDisplayName(
                paymentMethod: summary.cardName,
                credit: credit
            )
            return UnifiedCardRow(
                id: summary.cardName,
                displayName: display,
                rawPaymentMethod: summary.cardName,
                spent: summary.spent,
                transactionCount: summary.transactionCount,
                creditAccount: credit,
                paidInPeriod: paidFor(paymentMethod: summary.cardName, credit: credit)
            )
        }

        let matchedAccountIds = Set(rows.compactMap(\.creditAccount?.accountId))
        for account in creditAccounts {
            if matchedAccountIds.contains(account.accountId) { continue }
            let already = rows.contains { row in
                namesMatch(row.rawPaymentMethod, account.plaidDisplayName)
                    || namesMatch(row.rawPaymentMethod, account.name)
                    || namesMatch(row.displayName, account.displayName)
            }
            if already { continue }
            rows.append(
                UnifiedCardRow(
                    id: account.accountId,
                    displayName: account.displayName,
                    rawPaymentMethod: account.plaidDisplayName,
                    spent: 0,
                    transactionCount: 0,
                    creditAccount: account,
                    paidInPeriod: paidFor(paymentMethod: account.plaidDisplayName, credit: account)
                )
            )
        }

        return rows.sorted { lhs, rhs in
            // Prefer higher balance (credit) then spend
            // (use named params — nested $0/$1 with .map confuses the compiler)
            let balanceL = lhs.creditAccount.map { account in max(0, account.currentBalance) } ?? -1
            let balanceR = rhs.creditAccount.map { account in max(0, account.currentBalance) } ?? -1
            if balanceL != balanceR { return balanceL > balanceR }
            if lhs.spent != rhs.spent { return lhs.spent > rhs.spent }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: Overview
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
                    Text("Open a card to rename it (e.g. “Chase Freedom”). Balance / limit come from Plaid; bill payments don’t count as spend.")
                }

                // MARK: Cards
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
                                    period: period,
                                    referenceDate: referenceDate,
                                    sort: sort,
                                    creditAccount: row.creditAccount,
                                    periodPayments: paymentsMatching(
                                        paymentMethod: row.rawPaymentMethod,
                                        credit: row.creditAccount
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

                // MARK: Payments
                Section {
                    if periodPayments.isEmpty {
                        Text("No card payments in \(periodLabel.lowercased()).")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(periodPayments, id: \.transactionId) { payment in
                            CreditPaymentRow(payment: payment)
                        }
                    }
                } header: {
                    Text("Payments · \(periodLabel)")
                } footer: {
                    Text("Paying a card bill is tracked here so it doesn’t inflate Total Spend or Income.")
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

    // MARK: Matching helpers

    private func resolveDisplayName(paymentMethod: String, credit: BankAccount?) -> String {
        if let credit {
            return CardLabelStore.label(
                accountId: credit.accountId,
                fallback: CardLabelStore.label(paymentMethod: paymentMethod, fallback: credit.displayName)
            )
        }
        return CardLabelStore.label(paymentMethod: paymentMethod, fallback: paymentMethod)
    }

    private func matchCreditAccount(toPaymentMethod name: String) -> BankAccount? {
        creditAccounts.first { account in
            namesMatch(name, account.plaidDisplayName)
                || namesMatch(name, account.name)
                || namesMatch(name, account.displayName)
                || name.localizedCaseInsensitiveContains(account.name)
                || account.name.localizedCaseInsensitiveContains(name)
                || fuzzyBrandMatch(name, account.name)
                || (account.mask.map { name.contains($0) } ?? false)
        }
    }

    private func paidFor(paymentMethod: String, credit: BankAccount?) -> Double {
        CreditAnalytics.totalPaid(
            in: paymentsMatching(paymentMethod: paymentMethod, credit: credit)
        )
    }

    private func paymentsMatching(
        paymentMethod: String,
        credit: BankAccount?
    ) -> [CreditCardPayment] {
        periodPayments.filter { payment in
            if let credit, let id = payment.creditAccountId, id == credit.accountId {
                return true
            }
            return namesMatch(payment.cardName, paymentMethod)
                || payment.cardName.localizedCaseInsensitiveContains(paymentMethod)
                || paymentMethod.localizedCaseInsensitiveContains(payment.cardName)
                || fuzzyBrandMatch(payment.cardName, paymentMethod)
        }
    }

    private func namesMatch(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(b.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func fuzzyBrandMatch(_ a: String, _ b: String) -> Bool {
        let al = a.lowercased()
        let bl = b.lowercased()
        let brands = ["chase", "amex", "american express", "citi", "capital one", "discover", "apple card", "prime"]
        for brand in brands {
            if al.contains(brand) && bl.contains(brand) { return true }
        }
        return false
    }
}

// MARK: - Unified row model

private struct UnifiedCardRow: Identifiable {
    let id: String
    /// User-facing name (nickname or Plaid label)
    let displayName: String
    /// Original payment-method / Plaid string used to filter transactions
    let rawPaymentMethod: String
    let spent: Double
    let transactionCount: Int
    let creditAccount: BankAccount?
    let paidInPeriod: Double
}

private struct UnifiedCardLabel: View {
    let row: UnifiedCardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                BankIconView(
                    paymentMethod: row.rawPaymentMethod,
                    size: 40,
                    accountId: row.creditAccount?.accountId,
                    displayName: row.displayName,
                    institutionId: row.creditAccount?.institutionId,
                    institutionName: row.creditAccount?.institutionName
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body.weight(.semibold))
                    if let account = row.creditAccount {
                        Text(account.subtitleDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(row.transactionCount > 0
                             ? "\(row.transactionCount) purchases"
                             : "No purchases this period")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                // Primary metrics: Balance + Limit for credit; Spend for non-credit
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

            // Secondary: spend + paid
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

// MARK: - Card detail (+ rename)

struct CardDetailView: View {
    let displayName: String
    /// Transaction.paymentMethod string (Plaid-style), not the nickname
    let rawPaymentMethod: String
    let period: SnapshotPeriod
    let referenceDate: Date
    let sort: TransactionSort
    var creditAccount: BankAccount? = nil
    var periodPayments: [CreditCardPayment] = []
    var onNicknameChanged: (() -> Void)? = nil

    @Query private var transactions: [Transaction]
    @State private var nicknameDraft: String = ""
    @State private var selectedProduct: CardProduct = .generic
    @State private var didSaveNickname = false
    @State private var titleName: String = ""

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    private var cardRows: [Transaction] {
        let inPeriod = TransactionAnalytics.inPeriod(
            transactions,
            period: period,
            referenceDate: referenceDate
        )
        let forCard = inPeriod.filter { tx in
            let name = TransactionAnalytics.cardName(for: tx)
            if name == rawPaymentMethod { return true }
            if let credit = creditAccount {
                return name == credit.plaidDisplayName || name == credit.name
            }
            return false
        }
        return TransactionAnalytics.sorted(forCard, by: sort)
    }

    private var cardSpend: Double {
        TransactionAnalytics.totalSpend(in: cardRows)
    }

    private var paidTotal: Double {
        CreditAnalytics.totalPaid(in: periodPayments)
    }

    private var faceName: String {
        let n = titleName.isEmpty ? displayName : titleName
        return n
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    CardFaceView(
                        product: selectedProduct,
                        displayName: faceName,
                        width: 280,
                        institutionId: creditAccount?.institutionId,
                        institutionName: creditAccount?.institutionName,
                        mask: creditAccount?.mask
                    )
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                TextField("Display name", text: $nicknameDraft)
                    .textInputAutocapitalization(.words)
                    .onChange(of: nicknameDraft) { _, newValue in
                        // Live preview: infer art from typed name unless user forced a pick
                        let inferred = CardProduct.resolve(from: newValue)
                        if inferred != .generic {
                            selectedProduct = inferred
                        }
                    }

                Picker("Card art", selection: $selectedProduct) {
                    ForEach(CardProduct.pickerCases) { product in
                        HStack {
                            CardProductTile(product: product, size: 28)
                            Text(product.displayName)
                        }
                        .tag(product)
                    }
                }

                if let credit = creditAccount {
                    LabeledContent("Plaid name") {
                        Text(credit.plaidDisplayName)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    LabeledContent("Account") {
                        Text(rawPaymentMethod)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Button("Save name & art") {
                    saveNickname()
                }
                if didSaveNickname {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            } header: {
                Text("Card identity")
            } footer: {
                Text("On Sync we load the bank logo from Plaid (official path). Full product photos from Chase.com can’t be bundled without a license — pick a product name for matching colors + the Plaid logo on a plastic-style face.")
            }

            Section {
                if let account = creditAccount {
                    HStack {
                        Text("Balance")
                        Spacer()
                        Text(max(0, account.currentBalance), format: .currency(code: "USD"))
                            .font(.title3.weight(.semibold))
                    }
                    if let limit = account.creditLimit, limit > 0 {
                        HStack {
                            Text("Limit")
                            Spacer()
                            Text(limit, format: .currency(code: "USD"))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let util = account.utilization {
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

            if !periodPayments.isEmpty {
                Section("Payments · \(periodLabel)") {
                    ForEach(periodPayments, id: \.transactionId) { payment in
                        CreditPaymentRow(payment: payment)
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
                            TransactionRowView(transaction: transaction)
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
            selectedProduct = CardLabelStore.product(
                accountId: creditAccount?.accountId,
                paymentMethod: rawPaymentMethod,
                displayName: displayName
            )
        }
    }

    private func saveNickname() {
        let value = nicknameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let plaidFallback = creditAccount?.plaidDisplayName ?? rawPaymentMethod
        let custom: String? = (value.isEmpty || value == plaidFallback) ? nil : value
        CardLabelStore.setLabel(
            custom,
            accountId: creditAccount?.accountId,
            paymentMethod: rawPaymentMethod
        )
        // Persist product art (explicit pick or inferred from name)
        let productToSave: CardProduct = {
            if selectedProduct != .generic { return selectedProduct }
            if let custom { return CardProduct.resolve(from: custom) }
            return .generic
        }()
        CardLabelStore.setProduct(
            productToSave == .generic ? nil : productToSave,
            accountId: creditAccount?.accountId,
            paymentMethod: rawPaymentMethod
        )
        if productToSave != .generic {
            selectedProduct = productToSave
        }
        titleName = custom ?? plaidFallback
        nicknameDraft = titleName
        didSaveNickname = true
        onNicknameChanged?()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didSaveNickname = false
        }
    }
}

// Shared row UI used on All Transactions and card detail
struct TransactionRowView: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: CategoryStyle.symbolName(for: transaction.category))
                .font(.title3)
                .foregroundStyle(CategoryStyle.color(for: transaction.category))
                .frame(width: 28, alignment: .center)
                .accessibilityLabel(transaction.category)

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

// MARK: - Shared credit UI pieces

struct CreditPaymentRow: View {
    let payment: CreditCardPayment

    private var cardLabel: String {
        if let id = payment.creditAccountId {
            return CardLabelStore.label(accountId: id, fallback: payment.cardName)
        }
        return CardLabelStore.label(paymentMethod: payment.cardName, fallback: payment.cardName)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
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
