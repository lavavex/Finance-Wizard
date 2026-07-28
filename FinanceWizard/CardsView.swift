//
//  CardsView.swift
//  Finance Wizard
//
//  Accounts hub: credit cards + checking/savings, Plaid logos, credit
//  liabilities, and collapsible bill payments under spend.
//

import SwiftUI
import SwiftData

// MARK: - Accounts tab (formerly Cards)

struct CardsView: View {
    @Query private var transactions: [Transaction]
    @Query(sort: \BankAccount.name) private var accounts: [BankAccount]
    @Query(sort: \CreditCardPayment.date, order: .reverse) private var payments: [CreditCardPayment]
    @Environment(\.modelContext) private var modelContext

    @State private var period: SnapshotPeriod = .month
    @State private var referenceDate: Date = TransactionAnalytics.monthStart(for: Date())
    @State private var sort: TransactionSort = .dateNewest
    @State private var nicknameEpoch = 0
    @State private var isSyncing = false
    @State private var syncBanner: String?

    /// Prebuilt board — body only reads this, never re-walks all transactions per section.
    @State private var board = AccountsBoard()
    @State private var isBuildingBoard = true

    private var periodLabel: String {
        period.filterLabel(referenceDate: referenceDate)
    }

    private var creditAccounts: [BankAccount] {
        _ = nicknameEpoch
        return accounts.filter(\.isCredit)
    }

    private var refreshToken: String {
        "\(period.rawValue)|\(referenceDate.timeIntervalSince1970)|\(transactions.count)|\(accounts.count)|\(payments.count)|\(nicknameEpoch)"
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
                            if isBuildingBoard && board.creditRows.isEmpty && board.depositoryRows.isEmpty {
                                ProgressView()
                            } else {
                                MoneyText(board.periodTotalSpend)
                                    .font(.title3.bold())
                            }
                        }
                    }

                    TotalPaidDisclosure(
                        total: board.totalPaidInPeriod,
                        payments: board.periodPayments,
                        periodLabel: periodLabel,
                        institutionId: nil,
                        resolveInstitutionId: { institutionId(for: $0) }
                    )

                    if !creditAccounts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Credit balance")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    MoneyText(board.totalOwed)
                                        .font(.title3.weight(.semibold))
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("Limit")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    MoneyText(board.totalLimit > 0 ? board.totalLimit : 0)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let util = board.totalUtilization {
                                UtilizationBar(value: util, label: "Overall utilization")
                            }

                            if board.totalMinimumDue > 0 || board.soonestDueDate != nil {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Min payments")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if board.totalMinimumDue > 0 {
                                            MoneyText(board.totalMinimumDue)
                                                .font(.subheadline.weight(.semibold))
                                        } else {
                                            Text("—")
                                                .font(.subheadline)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(board.anyOverdue ? "Overdue" : "Next due")
                                            .font(.caption)
                                            .foregroundStyle(board.anyOverdue ? .red : .secondary)
                                        if let due = board.soonestDueDate {
                                            Text(due, style: .date)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(board.anyOverdue ? .red : .primary)
                                        } else {
                                            Text("—")
                                                .font(.subheadline)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Overview")
                }

                if let syncBanner {
                    Section {
                        Text(syncBanner)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // MARK: Upcoming bills (next 30 days)
                if !board.upcomingBills.isEmpty {
                    Section {
                        ForEach(board.upcomingBills, id: \.accountId) { account in
                            UpcomingBillRow(account: account)
                        }
                    } header: {
                        Text("Upcoming bills")
                    }
                }

                // MARK: Credit cards
                Section {
                    if isBuildingBoard && board.creditRows.isEmpty {
                        HStack {
                            ProgressView()
                            Text("Loading accounts…")
                                .foregroundStyle(.secondary)
                        }
                    } else if board.creditRows.isEmpty {
                        ContentUnavailableView(
                            "No credit cards",
                            systemImage: "creditcard",
                            description: Text("Link a bank in Settings, then Sync on Transactions.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(board.creditRows) { row in
                            accountNavigationLink(row: row)
                        }
                    }
                } header: {
                    Text("Credit cards")
                }

                // MARK: Checking / savings
                Section {
                    if board.depositoryRows.isEmpty {
                        Text("No checking or savings accounts linked yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(board.depositoryRows) { row in
                            accountNavigationLink(row: row)
                        }
                    }
                } header: {
                    Text("Checking & savings")
                }

                if !board.otherSpendRows.isEmpty {
                    Section {
                        ForEach(board.otherSpendRows) { row in
                            accountNavigationLink(row: row)
                        }
                    } header: {
                        Text("Other spend")
                    }
                }
            }
            .navigationTitle("Accounts")
            .refreshable {
                await syncFromPlaid()
            }
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
            .task(id: refreshToken) {
                AppleCardAccount.ensureIfNeeded(in: modelContext, transactions: transactions)
                InstitutionLogoCache.prefetch(accounts: accounts)
                rebuildBoard()
            }
        }
    }

    @MainActor
    private func rebuildBoard() {
        isBuildingBoard = board.creditRows.isEmpty && board.depositoryRows.isEmpty
        let period = self.period
        let referenceDate = self.referenceDate
        let accounts = self.accounts
        let transactions = self.transactions
        let payments = self.payments
        _ = nicknameEpoch

        Task { @MainActor in
            await Task.yield()
            board = AccountsBoard.build(
                accounts: accounts,
                transactions: transactions,
                payments: payments,
                period: period,
                referenceDate: referenceDate
            )
            isBuildingBoard = false
        }
    }

    private func syncFromPlaid() async {
        guard !isSyncing else { return }
        await MainActor.run {
            isSyncing = true
            syncBanner = "Syncing with Plaid…"
        }
        do {
            let report = try await PlaidSyncEngine.syncAll(
                modelContext: modelContext,
                resetCursors: false,
                includePending: false
            )
            await MainActor.run {
                syncBanner = report.summary
                isSyncing = false
                nicknameEpoch += 1
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { syncBanner = nil }
        } catch {
            await MainActor.run {
                syncBanner = error.localizedDescription
                isSyncing = false
            }
        }
    }

    @ViewBuilder
    private func accountNavigationLink(row: UnifiedCardRow) -> some View {
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
                periodPayments: AccountsBoard.paymentsMatching(
                    credit: row.creditAccount,
                    paymentMethods: row.matchingPaymentMethods,
                    in: board.periodPayments
                ),
                onNicknameChanged: { nicknameEpoch += 1 }
            )
        } label: {
            UnifiedCardLabel(row: row)
        }
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

// MARK: - One-pass accounts board (tab switch / body must not re-scan)

private struct AccountsBoard {
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

private struct UpcomingBillRow: View {
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

// MARK: - Account detail

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
    @Environment(\.modelContext) private var modelContext

    @State private var nicknameDraft: String = ""
    @State private var didSaveNickname = false
    @State private var titleName: String = ""
    @State private var debitMultText: String = ""
    @State private var achMultText: String = ""
    @State private var didSaveRewards = false

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

    private var isDepositoryDetail: Bool {
        creditAccount == nil && (bankAccount?.isDepository == true || bankAccount != nil && creditAccount == nil)
    }

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
                Text("\(periodLabel) · \(cardRows.count) purchases")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Bill payments under spend — expandable list
                if creditAccount != nil || paidTotal > 0 || !periodPayments.isEmpty {
                    TotalPaidDisclosure(
                        total: paidTotal,
                        payments: periodPayments,
                        periodLabel: periodLabel,
                        institutionId: account?.institutionId
                    )
                }
            } header: {
                Text("Summary")
            }

            if let bank = bankAccount, bank.isDepository || creditAccount == nil && bankAccount != nil {
                if bank.isDepository {
                    Section {
                        HStack {
                            Text("Debit card rewards")
                            Spacer()
                            TextField("e.g. 0.03", text: $debitMultText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                            Text("×")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("ACH rewards")
                            Spacer()
                            TextField("e.g. 0", text: $achMultText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                            Text("×")
                                .foregroundStyle(.secondary)
                        }
                        Button("Save rewards") {
                            saveRewardMultipliers()
                        }
                        if didSaveRewards {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    } header: {
                        Text("Debit vs ACH rewards")
                    } footer: {
                        Text("Cash back can differ for card purchases vs bank transfers. Edit a transaction if the type is wrong.")
                    }
                }
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
                    if credit.liabilitiesSyncedAt == nil {
                        Text("Sync after linking to load APR and due dates when available.")
                    }
                }
            }

            Section("Purchases") {
                if cardRows.isEmpty {
                    Text("No purchases for this account in the selected period.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(cardRows) { transaction in
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
                }
            }
        }
        .navigationTitle(titleName.isEmpty ? displayName : titleName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            titleName = displayName
            nicknameDraft = displayName
            if let bank = bankAccount {
                debitMultText = formatOptionalMult(bank.debitRewardMultiplier)
                achMultText = formatOptionalMult(bank.achRewardMultiplier)
            }
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

    private func saveRewardMultipliers() {
        guard let bank = bankAccount else { return }
        bank.debitRewardMultiplier = parseOptionalMult(debitMultText)
        bank.achRewardMultiplier = parseOptionalMult(achMultText)
        try? modelContext.save()
        didSaveRewards = true
        onNicknameChanged?()
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didSaveRewards = false
        }
    }

    private func formatOptionalMult(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...4)))
    }

    private func parseOptionalMult(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        if trimmed.isEmpty { return nil }
        return Double(trimmed)
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
    var showPaymentRail: Bool = false

    @Environment(\.screenshotPrivacy) private var screenshotPrivacy

    var body: some View {
        HStack(spacing: 12) {
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
                HStack(spacing: 4) {
                    Text(
                        "\(transaction.category) · \(ScreenshotPrivacy.cardText(displayPaymentMethod, privacy: screenshotPrivacy))"
                    )
                    if showPaymentRail {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(transaction.effectivePaymentRail.shortLabel)
                            .foregroundStyle(railColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(transaction.date, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                MoneyText(transaction.amount)
                    .foregroundStyle(
                        TransactionAnalytics.isExcludedFromSpend(transaction)
                            ? Color.secondary
                            : (transaction.amount >= 0 ? .green : .primary)
                    )
                if TransactionAnalytics.isExcludedFromSpend(transaction) {
                    Text("Bill pay")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CategoryStyle.creditPayment)
                } else if transaction.multiplier > 0 {
                    Text("\(transaction.multiplier.formatted())x")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No rewards")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var displayPaymentMethod: String {
        CardLabelStore.label(paymentMethod: transaction.paymentMethod)
    }

    private var railColor: Color {
        switch transaction.effectivePaymentRail {
        case .debit: return .blue
        case .ach: return .orange
        case .other: return .secondary
        }
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
                CardText(cardLabel)
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
            MoneyText(payment.amount)
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
