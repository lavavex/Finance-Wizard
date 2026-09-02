//
//  AccountsBoard.swift
//  Finance Wizard
//
//  One-pass accounts tab model + list rows (credit / checking / orphan spend).
//

import SwiftUI
import SwiftData

// MARK: - One-pass accounts board (tab switch / body must not re-scan)

/// Snapshot of everything the Accounts tab needs for one period.
/// Built once (or when inputs change), then the UI only reads these precomputed fields.
/// Not a View — pure data so heavy work stays out of SwiftUI’s body.
struct AccountsBoard {
    var periodTotalSpend: Double = 0
    var totalOwed: Double = 0
    var totalLimit: Double = 0
    // Optional because utilization is undefined when totalLimit is 0.
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

    /// Single pass over accounts + transactions + payments → fully populated board.
    static func build(
        accounts: [BankAccount],
        transactions: [Transaction],
        payments: [CreditCardPayment],
        period: SnapshotPeriod,
        referenceDate: Date,
        payoffPlans: [PayoffPlan] = []
    ) -> AccountsBoard {
        var board = AccountsBoard()
        let creditAccounts = accounts.filter(\.isCredit)
        let depositoryAccounts = accounts.filter(\.isDepository)
        let index = PeriodSpendIndex.build(
            transactions: transactions,
            period: period,
            referenceDate: referenceDate
        )
        board.periodTotalSpend = index.totalSpend
        board.periodPayments = CreditAnalytics.payments(
            in: payments,
            period: period,
            referenceDate: referenceDate
        )
        // PERF: `payments(in:period:)` already returned a deduplicated list; totalPaid()
        // deduplicated it a second time. Dedup is O(n²) (~6.5 ms at 242 payments, ~69 ms at
        // 1,000), so the repeat was pure waste — just sum what we already have.
        // OLD: board.totalPaidInPeriod = CreditAnalytics.totalPaid(in: board.periodPayments)
        board.totalPaidInPeriod = CreditAnalytics.sumPaid(board.periodPayments)

        board.totalOwed = creditAccounts.reduce(0) { $0 + max(0, $1.currentBalance) }
        board.totalLimit = creditAccounts.compactMap(\.creditLimit).reduce(0, +)
        if board.totalLimit > 0 {
            board.totalUtilization = min(max(board.totalOwed / board.totalLimit, 0), 1)
        }
        board.totalMinimumDue = creditAccounts.compactMap(\.minimumPaymentAmount).reduce(0, +)
        board.anyOverdue = creditAccounts.contains { $0.isOverdue == true }

        // Upcoming bills: overdue or due within 30 days.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let horizon = cal.date(byAdding: .day, value: 30, to: today)
        // FIX: the filter had no lower bound, so a due date the bank stopped refreshing
        // (a Plaid item in an error state) stayed pinned in Upcoming bills and drove
        // "Next due" forever. A date more than a week past, with no overdue flag to back
        // it up, is stale data rather than a real bill.
        let staleBefore = cal.date(byAdding: .day, value: -7, to: today) ?? today
        func isLiveDueDate(_ account: BankAccount) -> Bool {
            guard let due = account.nextPaymentDueDate else { return false }
            let day = cal.startOfDay(for: due)
            if account.isOverdue == true { return true }
            guard let horizon else { return false }
            return day >= staleBefore && day <= horizon
        }
        // OLD: board.soonestDueDate = creditAccounts.compactMap(\.nextPaymentDueDate).min()
        board.soonestDueDate = creditAccounts
            .filter(isLiveDueDate)
            .compactMap(\.nextPaymentDueDate)
            .min()
        board.upcomingBills = creditAccounts
            .filter(isLiveDueDate)
            .sorted {
                // Missing dates sort last.
                ($0.nextPaymentDueDate ?? .distantFuture) < ($1.nextPaymentDueDate ?? .distantFuture)
            }

        // PERF: the credit loop below used to run `transactions.filter { … }` per card, so a
        // 5-card wallet walked all 3,232 rows five times and recomputed cardName(for:) each
        // time. Group once here and look each card's rows up by payment method instead.
        var rowsByMethod: [String: [Transaction]] = [:]
        for tx in transactions {
            rowsByMethod[TransactionAnalytics.cardName(for: tx), default: []].append(tx)
        }

        let pool = index.allKnownMethods
        // claimed tracks payment-method strings already assigned to a credit/depository row
        // so “orphan spend” only shows methods nothing else owns.
        var claimed = Set<String>()

        // Credit rows — highest balance first
        for account in creditAccounts.sorted(by: {
            max(0, $0.currentBalance) > max(0, $1.currentBalance)
        }) {
            let methods = account.matchingPaymentMethods(in: pool)
            for m in methods { claimed.insert(m) }
            let primary = methods.sorted().first ?? account.plaidDisplayName
            // OLD: let cardTxs = transactions.filter { methods.contains(TransactionAnalytics.cardName(for: $0)) }
            let cardTxs = methods.flatMap { rowsByMethod[$0] ?? [] }
            let closeDay = StatementCycle.closeDay(from: account.lastStatementIssueDate)
            // Pass the issuer's last statement date so "open" means "not yet billed"
            // rather than "ends on or after today" — matches CardDetailView.
            let statementGroups = StatementCycle.group(
                cardTxs,
                closeDay: closeDay,
                lastStatement: account.lastStatementIssueDate
            )
            // OLD: let currentStatement = statementGroups.first(where: { $0.bucket.isOpen })
            let currentStatement = StatementCycle.currentGroup(in: statementGroups)
            let statementRows = currentStatement?.rows ?? []
            let statementPayments: [CreditCardPayment] = {
                let matched = paymentsMatching(
                    credit: account,
                    paymentMethods: methods,
                    in: payments
                )
                guard let bucket = currentStatement?.bucket else { return matched }
                return matched.filter { $0.date >= bucket.start && $0.date <= bucket.end }
            }()
            let paid = CreditAnalytics.totalPaid(in: statementPayments)
            board.creditRows.append(
                UnifiedCardRow(
                    id: account.accountId,
                    displayName: account.displayName,
                    rawPaymentMethod: primary,
                    matchingPaymentMethods: methods,
                    spent: TransactionAnalytics.totalSpend(in: statementRows),
                    transactionCount: statementRows.count,
                    creditAccount: account,
                    bankAccount: account,
                    paidInPeriod: paid,
                    installmentIncludedInMin: PayoffPlanProgress.installmentIncludedInMin(
                        on: account,
                        plans: payoffPlans
                    ),
                    extraPrincipalThisStatement: PayoffPlanProgress.extraPrincipalThisStatement(
                        on: account,
                        plans: payoffPlans
                    ),
                    // OLD: spendIsThisStatement: true,
                    statementSpendLabel: currentStatement.map {
                        $0.bucket.isOpen ? "This statement " : "Last statement "
                    } ?? "Spend ",
                    interestSavingBalance: PayoffPlanProgress.interestSavingBalance(
                        on: account,
                        plans: payoffPlans
                    )
                )
            )
        }

        // Depository rows (checking/savings) — highest available balance first
        for account in depositoryAccounts.sorted(by: {
            ($0.availableBalance ?? $0.currentBalance) > ($1.availableBalance ?? $1.currentBalance)
        }) {
            let methods = account.matchingPaymentMethods(in: pool)
            // Only count spend not already claimed by a credit card row.
            let own = methods.subtracting(claimed)
            for m in methods { claimed.insert(m) }
            let totals = index.totals(for: own)
            let primary = methods.sorted().first ?? account.plaidDisplayName
            board.depositoryRows.append(
                UnifiedCardRow(
                    id: account.accountId,
                    displayName: account.displayName,
                    rawPaymentMethod: primary,
                    matchingPaymentMethods: methods,
                    spent: totals.spend,
                    transactionCount: totals.count,
                    creditAccount: nil,
                    bankAccount: account,
                    paidInPeriod: 0
                )
            )
        }

        // Orphan spend methods — purchase methods with no linked BankAccount (except Apple Card handling)
        let orphanMethods = index.spendByMethod.keys
            .filter { !claimed.contains($0) }
            .filter { !AppleCardAccount.isAppleCard(paymentMethod: $0) }
            .sorted()
        for method in orphanMethods {
            let entry = index.spendByMethod[method] ?? .init(spend: 0, count: 0)
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

    /// Filter period payments that belong to a given credit account / payment-method set.
    static func paymentsMatching(
        credit: BankAccount?,
        paymentMethods: Set<String>,
        in periodPayments: [CreditCardPayment]
    ) -> [CreditCardPayment] {
        periodPayments.filter { payment in
            // Match by linked account id, card mask, payment-method string, or display name.
            if let credit, let id = payment.creditAccountId, id == credit.accountId {
                return true
            }
            // FIX: bare substring match on a 4-digit mask could claim another card's
            // payment. Same standalone-group rule as BankAccount.matchesPaymentMethod.
            // OLD: if let credit, let mask = credit.mask, !mask.isEmpty, payment.cardName.contains(mask) {
            if let credit, let mask = credit.mask, !mask.isEmpty,
               BankAccount.containsStandaloneMask(payment.cardName, mask: mask) {
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

/// Compact row for a credit account with a due date (or overdue).
struct UpcomingBillRow: View {
    let account: BankAccount
    var installmentIncluded: Double = 0
    var interestSavingBalance: Double? = nil

    // Color escalates as due date nears or utilization is high.
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
                // Prefer minimum payment; fall back to full balance.
                if let min = account.minimumPaymentAmount {
                    MoneyText(min)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(urgencyColor)
                } else {
                    MoneyText(max(0, account.currentBalance))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(urgencyColor)
                }
                if installmentIncluded > 0.005 {
                    Text("Incl. \(installmentIncluded.formatted(.currency(code: "USD"))) installment")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let isb = interestSavingBalance, isb > 0.005 {
                    MoneyText(isb, prefix: "Int. saving ")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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

/// Expandable “Total paid” row listing credit-card bill payments in the period.
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
                // Explicit id: CreditCardPayment may not be Identifiable in this ForEach.
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

/// One account (or orphan method) ready to display and navigate to CardDetailView.
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
    var installmentIncludedInMin: Double = 0
    var extraPrincipalThisStatement: Double = 0
    /// FIX: replaced the `spendIsThisStatement` flag, which hard-coded the "This statement"
    /// prefix even when the row was actually showing the last closed cycle.
    /// OLD: var spendIsThisStatement: Bool = false
    var statementSpendLabel: String = "Spend "
    var interestSavingBalance: Double? = nil

    // Prefer credit, else depository, for logo lookups.
    var institutionId: String? {
        creditAccount?.institutionId ?? bankAccount?.institutionId
    }

    var institutionName: String? {
        creditAccount?.institutionName ?? bankAccount?.institutionName
    }
}

/// Visual label for a UnifiedCardRow (used as NavigationLink content on Accounts).
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
                // Trailing metrics: credit balance, checking available, or spend.
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

            // Min payment + due date when Plaid liabilities details exist.
            if let credit = row.creditAccount, credit.hasLiabilitiesDetails {
                HStack(spacing: 8) {
                    if let minPay = credit.minimumPaymentAmount {
                        VStack(alignment: .leading, spacing: 1) {
                            MoneyText(minPay, prefix: "Min ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if row.installmentIncludedInMin > 0.005 {
                                Text("includes \(row.installmentIncludedInMin.formatted(.currency(code: "USD"))) loan/installment")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            if let isb = row.interestSavingBalance, isb > 0.005 {
                                MoneyText(isb, prefix: "Int. saving ")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
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
                MoneyText(row.spent, prefix: row.statementSpendLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if row.transactionCount > 0 {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("\(row.transactionCount)")
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
