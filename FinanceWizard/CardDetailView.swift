//
//  CardDetailView.swift
//  Finance Wizard
//
//  Single account / payment-method detail: balances, bills, spend list.
//

import SwiftUI
import SwiftData

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
