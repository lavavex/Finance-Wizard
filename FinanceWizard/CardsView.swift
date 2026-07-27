//
//  CardsView.swift
//  Finance Wizard
//
//  Cards hub: period spend by payment method, credit utilization, and card payments.
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
        accounts.filter(\.isCredit)
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
        var rows: [UnifiedCardRow] = cardSummaries.map { summary in
            let credit = matchCreditAccount(toPaymentMethod: summary.cardName)
            return UnifiedCardRow(
                id: summary.cardName,
                displayName: summary.cardName,
                spent: summary.spent,
                transactionCount: summary.transactionCount,
                creditAccount: credit,
                paidInPeriod: paidFor(paymentMethod: summary.cardName, credit: credit)
            )
        }

        // Credit accounts with balance/limit but no matching spend row yet
        let knownNames = Set(rows.map(\.displayName))
        for account in creditAccounts {
            let already = rows.contains { row in
                if let c = row.creditAccount { return c.accountId == account.accountId }
                return namesMatch(row.displayName, account.displayName)
                    || namesMatch(row.displayName, account.name)
            }
            if already { continue }
            // Avoid duplicate display names
            if knownNames.contains(account.displayName) { continue }
            rows.append(
                UnifiedCardRow(
                    id: account.accountId,
                    displayName: account.displayName,
                    spent: 0,
                    transactionCount: 0,
                    creditAccount: account,
                    paidInPeriod: paidFor(paymentMethod: account.displayName, credit: account)
                )
            )
        }

        return rows.sorted {
            // Credit cards with balance first by spend, then alpha
            if $0.spent != $1.spent { return $0.spent > $1.spent }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
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
                    if creditAccounts.isEmpty {
                        Text("Link credit cards and Sync to see balances, limits, and utilization.")
                    } else {
                        Text("Spend is purchases this period. Credit balance / limit come from Plaid on Sync. Bill payments don’t count as spend.")
                    }
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
                                    cardName: row.displayName,
                                    period: period,
                                    referenceDate: referenceDate,
                                    sort: sort,
                                    creditAccount: row.creditAccount,
                                    periodPayments: paymentsMatching(
                                        paymentMethod: row.displayName,
                                        credit: row.creditAccount
                                    )
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

    private func matchCreditAccount(toPaymentMethod name: String) -> BankAccount? {
        creditAccounts.first { account in
            namesMatch(name, account.displayName)
                || namesMatch(name, account.name)
                || name.localizedCaseInsensitiveContains(account.name)
                || account.name.localizedCaseInsensitiveContains(name)
                || fuzzyBrandMatch(name, account.name)
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
    let displayName: String
    let spent: Double
    let transactionCount: Int
    let creditAccount: BankAccount?
    let paidInPeriod: Double
}

private struct UnifiedCardLabel: View {
    let row: UnifiedCardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                BankIconView(paymentMethod: row.displayName, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.displayName)
                        .font(.body.weight(.medium))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.spent, format: .currency(code: "USD"))
                        .font(.body.weight(.semibold))
                    if row.paidInPeriod > 0 {
                        Text("Paid \(row.paidInPeriod.formatted(.currency(code: "USD")))")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }

            if let account = row.creditAccount {
                if let util = account.utilization {
                    UtilizationBar(value: util, label: nil)
                } else if let limit = account.creditLimit, limit > 0 {
                    Text("Balance \(max(0, account.currentBalance).formatted(.currency(code: "USD"))) of \(limit.formatted(.currency(code: "USD")))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if account.currentBalance > 0 {
                    Text("Balance \(account.currentBalance.formatted(.currency(code: "USD")))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts: [String] = []
        if row.transactionCount > 0 {
            parts.append("\(row.transactionCount) purchases")
        }
        if let account = row.creditAccount {
            parts.append("Balance \(max(0, account.currentBalance).formatted(.currency(code: "USD")))")
        } else if row.transactionCount == 0 {
            parts.append("No purchases this period")
        }
        return parts.isEmpty ? "Card" : parts.joined(separator: " · ")
    }
}

// MARK: - Card detail

struct CardDetailView: View {
    let cardName: String
    let period: SnapshotPeriod
    let referenceDate: Date
    let sort: TransactionSort
    var creditAccount: BankAccount? = nil
    var periodPayments: [CreditCardPayment] = []

    @Query private var transactions: [Transaction]

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    private var cardRows: [Transaction] {
        let inPeriod = TransactionAnalytics.inPeriod(
            transactions,
            period: period,
            referenceDate: referenceDate
        )
        let forCard = inPeriod.filter {
            TransactionAnalytics.cardName(for: $0) == cardName
        }
        return TransactionAnalytics.sorted(forCard, by: sort)
    }

    private var cardSpend: Double {
        TransactionAnalytics.totalSpend(in: cardRows)
    }

    private var paidTotal: Double {
        CreditAnalytics.totalPaid(in: periodPayments)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Spend")
                    Spacer()
                    Text(cardSpend, format: .currency(code: "USD"))
                        .font(.headline)
                }
                Text("\(periodLabel) · \(cardRows.count) purchases")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let account = creditAccount {
                    HStack {
                        Text("Balance")
                        Spacer()
                        Text(max(0, account.currentBalance), format: .currency(code: "USD"))
                            .font(.body.weight(.semibold))
                    }
                    if let limit = account.creditLimit, limit > 0 {
                        HStack {
                            Text("Limit")
                            Spacer()
                            Text(limit, format: .currency(code: "USD"))
                                .foregroundStyle(.secondary)
                        }
                        if let util = account.utilization {
                            UtilizationBar(value: util, label: "Utilization")
                        }
                    }
                }

                if paidTotal > 0 {
                    HStack {
                        Text("Paid this period")
                        Spacer()
                        Text(paidTotal, format: .currency(code: "USD"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }
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
        .navigationTitle(cardName)
        .navigationBarTitleDisplayMode(.inline)
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
                Text("\(transaction.category) · \(transaction.paymentMethod)")
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
}

// MARK: - Shared credit UI pieces

struct CreditPaymentRow: View {
    let payment: CreditCardPayment

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(payment.cardName)
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
