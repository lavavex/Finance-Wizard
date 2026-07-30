//
//  AccountsBoard.swift
//  Finance Wizard
//
//  One-pass accounts tab model + list rows (credit / checking / orphan spend).
//

import SwiftUI
import SwiftData

// MARK: - One-pass accounts board (tab switch / body must not re-scan)

struct AccountsBoard {
    var periodTotalSpend: Double = 0
    var totalOwed: Double = 0
    var totalLimit: Double = 0
    var totalUtilization: Double? = nil
    var totalPaidInPeriod: Double = 0
    var totalMinimumDue: Double = 0
    var soonestDueDate: Date? = nil
    var anyOverdue: Bool = false
    var periodPayments: [CreditCardPayment] = []
    var upcomingBills: [BankAccount] = []
    var creditRows: [UnifiedCardRow] = []
    var depositoryRows: [UnifiedCardRow] = []
    var otherSpendRows: [UnifiedCardRow] = []

    static func build(
        accounts: [BankAccount],
        transactions: [Transaction],
        payments: [CreditCardPayment],
        period: SnapshotPeriod,
        referenceDate: Date
    ) -> AccountsBoard {
        var board = AccountsBoard()
        let creditAccounts = accounts.filter(\.isCredit)
        let depositoryAccounts = accounts.filter(\.isDepository)
        let periodTxs = TransactionAnalytics.inPeriod(
            transactions,
            period: period,
            referenceDate: referenceDate
        )
        let spendTxs = TransactionAnalytics.spendOnly(periodTxs)
        board.periodTotalSpend = TransactionAnalytics.totalSpend(in: periodTxs)
        board.periodPayments = CreditAnalytics.payments(
            in: payments,
            period: period,
            referenceDate: referenceDate
        )
        board.totalPaidInPeriod = CreditAnalytics.totalPaid(in: board.periodPayments)

        board.totalOwed = creditAccounts.reduce(0) { $0 + max(0, $1.currentBalance) }
        board.totalLimit = creditAccounts.compactMap(\.creditLimit).reduce(0, +)
        if board.totalLimit > 0 {
            board.totalUtilization = min(max(board.totalOwed / board.totalLimit, 0), 1)
        }
        board.totalMinimumDue = creditAccounts.compactMap(\.minimumPaymentAmount).reduce(0, +)
        board.soonestDueDate = creditAccounts.compactMap(\.nextPaymentDueDate).min()
        board.anyOverdue = creditAccounts.contains { $0.isOverdue == true }

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizon = cal.date(byAdding: .day, value: 30, to: today)
        board.upcomingBills = creditAccounts
            .filter { account in
                guard let due = account.nextPaymentDueDate else { return false }
                let day = cal.startOfDay(for: due)
                if account.isOverdue == true { return true }
                guard let horizon else { return false }
                return day <= horizon
            }
            .sorted {
                ($0.nextPaymentDueDate ?? .distantFuture) < ($1.nextPaymentDueDate ?? .distantFuture)
            }

        // Index spend once: method → (spend, count)
        var spendByMethod: [String: (spend: Double, count: Int)] = [:]
        var allMethods = Set<String>()
        for tx in transactions {
            allMethods.insert(TransactionAnalytics.cardName(for: tx))
        }
        for tx in spendTxs {
            let method = TransactionAnalytics.cardName(for: tx)
            allMethods.insert(method)
            var entry = spendByMethod[method] ?? (0, 0)
            entry.spend += abs(tx.amount)
            entry.count += 1
            spendByMethod[method] = entry
        }

        var claimed = Set<String>()

        // Credit rows
        for account in creditAccounts.sorted(by: {
            max(0, $0.currentBalance) > max(0, $1.currentBalance)
        }) {
            let methods = methods(for: account, pool: allMethods)
            for m in methods { claimed.insert(m) }
            let spent = methods.reduce(0.0) { $0 + (spendByMethod[$1]?.spend ?? 0) }
            let count = methods.reduce(0) { $0 + (spendByMethod[$1]?.count ?? 0) }
            let primary = methods.sorted().first ?? account.plaidDisplayName
            let paid = CreditAnalytics.totalPaid(
                in: paymentsMatching(
                    credit: account,
                    paymentMethods: methods,
                    in: board.periodPayments
                )
            )
            board.creditRows.append(
                UnifiedCardRow(
                    id: account.accountId,
                    displayName: account.displayName,
                    rawPaymentMethod: primary,
                    matchingPaymentMethods: methods,
                    spent: spent,
                    transactionCount: count,
                    creditAccount: account,
                    bankAccount: account,
                    paidInPeriod: paid
                )
            )
        }

        // Depository rows
        for account in depositoryAccounts.sorted(by: {
            ($0.availableBalance ?? $0.currentBalance) > ($1.availableBalance ?? $1.currentBalance)
        }) {
            let methods = methods(for: account, pool: allMethods)
            let own = methods.subtracting(claimed)
            for m in methods { claimed.insert(m) }
            let spent = own.reduce(0.0) { $0 + (spendByMethod[$1]?.spend ?? 0) }
            let count = own.reduce(0) { $0 + (spendByMethod[$1]?.count ?? 0) }
            let primary = methods.sorted().first ?? account.plaidDisplayName
            board.depositoryRows.append(
                UnifiedCardRow(
                    id: account.accountId,
                    displayName: account.displayName,
                    rawPaymentMethod: primary,
                    matchingPaymentMethods: methods,
                    spent: spent,
                    transactionCount: count,
                    creditAccount: nil,
                    bankAccount: account,
                    paidInPeriod: 0
                )
            )
        }

        // Orphan spend methods
        let orphanMethods = spendByMethod.keys
            .filter { !claimed.contains($0) }
            .filter { !AppleCardAccount.isAppleCard(paymentMethod: $0) }
            .sorted()
        for method in orphanMethods {
            let entry = spendByMethod[method] ?? (0, 0)
            guard entry.spend > 0 || entry.count > 0 else { continue }
            board.otherSpendRows.append(
                UnifiedCardRow(
                    id: "method:\(method)",
                    displayName: CardLabelStore.label(paymentMethod: method, fallback: method),
                    rawPaymentMethod: method,
                    matchingPaymentMethods: [method],
                    spent: entry.spend,
                    transactionCount: entry.count,
                    creditAccount: nil,
                    bankAccount: nil,
                    paidInPeriod: 0
                )
            )
        }

        return board
    }

    private static func methods(for account: BankAccount, pool: Set<String>) -> Set<String> {
        var methods = Set<String>()
        for method in pool where account.matchesPaymentMethod(method) {
            methods.insert(method)
        }
        methods.insert(account.plaidDisplayName)
        return methods
    }

    static func paymentsMatching(
        credit: BankAccount?,
        paymentMethods: Set<String>,
        in periodPayments: [CreditCardPayment]
    ) -> [CreditCardPayment] {
        periodPayments.filter { payment in
            if let credit, let id = payment.creditAccountId, id == credit.accountId {
                return true
            }
            if let credit, let mask = credit.mask, !mask.isEmpty, payment.cardName.contains(mask) {
                return true
            }
            if paymentMethods.contains(payment.cardName) { return true }
            if let credit {
                let a = payment.cardName.trimmingCharacters(in: .whitespacesAndNewlines)
                let b = credit.plaidDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if a.caseInsensitiveCompare(b) == .orderedSame { return true }
            }
            return false
        }
    }
}

// MARK: - Upcoming bill strip

struct UpcomingBillRow: View {
    let account: BankAccount

    private var urgencyColor: Color {
        if account.isOverdue == true { return .red }
        if let days = account.daysUntilDue {
            if days <= 3 { return .red }
            if days <= 7 { return .orange }
            if let util = account.utilization, util >= 0.7 { return .orange }
        }
        return .primary
    }

    var body: some View {
        HStack(spacing: 12) {
            BankIconView(
                paymentMethod: account.plaidDisplayName,
                size: 36,
                accountId: account.accountId,
                displayName: account.displayName,
                institutionId: account.institutionId,
                institutionName: account.institutionName
            )
            VStack(alignment: .leading, spacing: 2) {
                CardText(account.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let util = account.utilization {
                    Text("\(Int((util * 100).rounded()))% utilization")
                        .font(.caption2)
                        .foregroundStyle(util >= 0.7 ? .orange : .secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let min = account.minimumPaymentAmount {
                    MoneyText(min)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(urgencyColor)
                } else {
                    MoneyText(max(0, account.currentBalance))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(urgencyColor)
                }
                if let due = account.nextPaymentDueDate {
                    if account.isOverdue == true {
                        Text("Overdue")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    } else if let days = account.daysUntilDue {
                        Text(days == 0 ? "Due today" : "Due in \(days)d")
                            .font(.caption2)
                            .foregroundStyle(urgencyColor == .primary ? .secondary : urgencyColor)
                    } else {
                        Text(due, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Total paid disclosure

struct TotalPaidDisclosure: View {
    let total: Double
    let payments: [CreditCardPayment]
    let periodLabel: String
    var institutionId: String?
    var resolveInstitutionId: ((CreditCardPayment) -> String?)? = nil

    var body: some View {
        DisclosureGroup {
            if payments.isEmpty {
                Text("No card bill payments in \(periodLabel.lowercased()).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(payments, id: \.transactionId) { payment in
                    CreditPaymentRow(
                        payment: payment,
                        institutionId: resolveInstitutionId?(payment) ?? institutionId
                    )
                    .padding(.vertical, 2)
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total paid")
                        .font(.subheadline.weight(.semibold))
                    Text(periodLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MoneyText(total)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(total > 0 ? .green : .secondary)
            }
        }
    }
}

// MARK: - Row model

struct UnifiedCardRow: Identifiable {
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

struct UnifiedCardLabel: View {
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
                    CardText(row.displayName)
                        .font(.body.weight(.semibold))
                    if let account = row.creditAccount ?? row.bankAccount {
                        CardText(account.subtitleDetail)
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
                if let account = row.creditAccount {
                    VStack(alignment: .trailing, spacing: 2) {
                        MoneyText(max(0, account.currentBalance))
                            .font(.body.weight(.semibold))
                        if let limit = account.creditLimit, limit > 0 {
                            MoneyText(limit, prefix: "Limit ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Balance")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else if let account = row.bankAccount, account.isDepository {
                    VStack(alignment: .trailing, spacing: 2) {
                        MoneyText(account.availableBalance ?? account.currentBalance)
                            .font(.body.weight(.semibold))
                        Text("Available")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        MoneyText(row.spent)
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
                        MoneyText(minPay, prefix: "Min ")
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
                MoneyText(row.spent, prefix: "Spend ")
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
                    MoneyText(row.paidInPeriod, prefix: "Paid ")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
