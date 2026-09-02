//
//  IncomeViews.swift
//  Finance Wizard
//
//  Income list row and detail screen. Split out of ContentView.swift.
//

import SwiftUI
import SwiftData

// MARK: - Income list row + detail (read-only — no classify API for income)

/// One income line in the Transactions list (icon, source, category, amount).
struct IncomeRowView: View {
    let income: Income
    var institutionId: String? = nil
    var institutionName: String? = nil
    var accountLabel: String? = nil

    @Environment(\.screenshotPrivacy) private var screenshotPrivacy

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: CategoryStyle.symbolName(for: income.category))
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 28, alignment: .center)
                    .accessibilityLabel(income.category)
                if institutionId != nil || institutionName != nil || !income.iconKey.isEmpty {
                    BankIconView(
                        paymentMethod: income.iconKey,
                        size: 14,
                        institutionId: institutionId,
                        institutionName: institutionName ?? income.sourceInstitution
                    )
                    .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(income.source)
                    .font(.body)
                Text(
                    "\(income.category) · \(ScreenshotPrivacy.cardText(accountLabel ?? income.accountDisplay, privacy: screenshotPrivacy))"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(income.date, style: .date)
                    if income.pending {
                        Text("Pending")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(income.amount)
                .foregroundStyle(.green)
        }
    }
}

/// Read-only detail screen for a single income row (Form of labeled fields).
struct IncomeDetailView: View {
    let income: Income
    var bankAccounts: [BankAccount] = []

    /// Linked BankAccount for logos when names/masks match.
    private var linkedAccount: BankAccount? {
        bankAccounts.first { account in
            if let mask = income.accountMask, let am = account.mask, mask == am { return true }
            if let name = income.accountName, account.matchesPaymentMethod(name) { return true }
            return false
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: CategoryStyle.symbolName(for: income.category))
                        .font(.largeTitle)
                        .foregroundStyle(.green)
                        .frame(width: 44)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(income.source)
                            .font(.title3.weight(.semibold))
                        MoneyText(income.amount)
                            .font(.title2.bold())
                            .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Details") {
                LabeledContent("Date") {
                    Text(income.date, style: .date)
                }
                LabeledContent("Category") {
                    Text(income.category)
                }
                if let accountName = income.accountName, !accountName.isEmpty {
                    LabeledContent("Account") {
                        HStack(spacing: 8) {
                            BankIconView(
                                paymentMethod: income.iconKey,
                                size: 24,
                                institutionId: linkedAccount?.institutionId,
                                institutionName: linkedAccount?.institutionName ?? income.sourceInstitution
                            )
                            VStack(alignment: .trailing, spacing: 2) {
                                CardText(accountName)
                                if let mask = income.accountMask, !mask.isEmpty {
                                    CardText("···\(mask)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .multilineTextAlignment(.trailing)
                        }
                    }
                } else if let institution = income.sourceInstitution, !institution.isEmpty {
                    LabeledContent("Institution") {
                        HStack(spacing: 8) {
                            BankIconView(
                                paymentMethod: institution,
                                size: 24,
                                institutionId: linkedAccount?.institutionId,
                                institutionName: linkedAccount?.institutionName ?? institution
                            )
                            Text(institution)
                        }
                    }
                }
                if income.pending {
                    LabeledContent("Status") {
                        Text("Pending")
                            .foregroundStyle(.orange)
                    }
                }
                // Only show bank description when it differs from the friendly source.
                if let rawName = income.rawName, !rawName.isEmpty, rawName != income.source {
                    LabeledContent("Bank description") {
                        Text(rawName)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let pfc = income.pfc, !pfc.isEmpty {
                    LabeledContent("Bank category") {
                        Text(pfc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("ID") {
                    Text(income.transactionId)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

        }
        .navigationTitle("Income")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Transaction.self, Income.self], inMemory: true)
}
