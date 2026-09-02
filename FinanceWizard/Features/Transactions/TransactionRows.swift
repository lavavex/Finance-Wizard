//
//  TransactionRows.swift
//  Finance Wizard
//
//  Shared list rows used by Transactions and Accounts tabs.
//

import SwiftUI

/// One row showing a transaction: category icon, title, card, date, amount, rewards.
/// Reused in multiple lists so layout stays consistent app-wide.
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
                    // Nudge the badge toward the corner of the category icon.
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
                HStack(spacing: 4) {
                    Text(transaction.displayDate, style: .date)
                    // isPending is optional Bool — compare to true, not truthy.
                    if transaction.isPending == true {
                        Text("· Pending")
                            .foregroundStyle(.orange)
                    }
                }
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
                if TransactionAnalytics.isCreditCardPaymentCategory(transaction.category) {
                    Text("Bill pay")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CategoryStyle.creditPayment)
                } else if transaction.category.caseInsensitiveCompare(TransactionAnalytics.loanCategory) == .orderedSame {
                    Text("Loan")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CategoryStyle.services)
                } else if transaction.category.caseInsensitiveCompare(TransactionAnalytics.refundCategory) == .orderedSame {
                    Text("Refund")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                } else if transaction.category.caseInsensitiveCompare(TransactionAnalytics.installmentCategory) == .orderedSame {
                    Text("Installment")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(CategoryStyle.services)
                } else {
                    Text(transaction.category)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var displayPaymentMethod: String {
        CardLabelStore.label(paymentMethod: transaction.paymentMethod)
    }

    // Color for debit vs ACH vs other rails (helps depository account rows).
    private var railColor: Color {
        switch transaction.effectivePaymentRail {
        case .debit: return .mint
        case .ach: return .orange
        case .other: return .secondary
        }
    }
}

/// Row for a credit-card bill payment (money paid toward a card balance).
struct CreditPaymentRow: View {
    let payment: CreditCardPayment
    var institutionId: String? = nil

    // Prefer account-id label, then fall back to payment method name.
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
                    // Circle background clips a hole so the badge sits cleanly on the logo.
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

/// Thin progress bar for credit utilization (0.0 … 1.0 fraction used of limit).
struct UtilizationBar: View {
    let value: Double
    let label: String?

    private var percent: Int {
        Int((value * 100).rounded())
    }

    // Green under 30%, orange under 70%, else red.
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
                    // min 4pt so a tiny balance still shows
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(4, geo.size.width * value))
                }
            }
            .frame(height: 8) // GeometryReader expands greedily — pin its height.
        }
    }
}
