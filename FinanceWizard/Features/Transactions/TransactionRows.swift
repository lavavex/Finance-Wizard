//
//  TransactionRows.swift
//  Finance Wizard
//
//  Shared list rows used by Transactions and Accounts tabs.
//  Teaches: View composition, @Environment, optional params, GeometryReader, ZStack.
//

import SwiftUI

/// One row showing a transaction: category icon, title, card, date, amount, rewards.
/// Reused in multiple lists so layout stays consistent app-wide.
struct TransactionRowView: View {
    // Inputs from the parent. `let` = required, read-only for this view’s lifetime.
    let transaction: Transaction
    // Optional parameters with defaults — callers only pass them when needed.
    var institutionId: String? = nil
    var institutionName: String? = nil
    var showPaymentRail: Bool = false

    // @Environment reads a value SwiftUI injects down the view tree (here: privacy mode for screenshots).
    // The key path \.screenshotPrivacy is a custom environment value defined elsewhere in the app.
    @Environment(\.screenshotPrivacy) private var screenshotPrivacy

    var body: some View {
        // HStack: main row layout left → right (icon | details | amount).
        HStack(spacing: 12) {
            // ZStack stacks views on top of each other (category icon + small bank badge).
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: CategoryStyle.symbolName(for: transaction.category))
                    .font(.title3)
                    .foregroundStyle(CategoryStyle.color(for: transaction.category))
                    .frame(width: 28, alignment: .center)
                    .accessibilityLabel(transaction.category)

                // Optional chaining: only show bank icon when we have institution info.
                if institutionId != nil || institutionName != nil {
                    BankIconView(
                        paymentMethod: transaction.paymentMethod,
                        size: 14,
                        displayName: displayPaymentMethod,
                        institutionId: institutionId,
                        institutionName: institutionName
                    )
                    // offset nudges the badge toward the corner of the category icon.
                    .offset(x: 4, y: 4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.title)
                    .font(.body)
                HStack(spacing: 4) {
                    // String interpolation builds text from multiple pieces.
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
                    // Text(date, style: .date) uses a built-in relative/locale-aware date style.
                    Text(transaction.displayDate, style: .date)
                    // == true is careful with optional Bool? (isPending may be nil).
                    if transaction.isPending == true {
                        Text("· Pending")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer() // pushes the amount column to the trailing edge
            VStack(alignment: .trailing, spacing: 4) {
                MoneyText(transaction.amount)
                    // Ternary: condition ? ifTrue : ifFalse — pick color by amount / exclusion.
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
                    // else if chains exclusive branches (only one label shows).
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

    // Friendly card name from a store (nicknames, etc.).
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
        // if let unwraps an optional safely — only enters the block when non-nil.
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
                // Green down-arrow badge signals “payment received / paid.”
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
                    // lineLimit(1) truncates long titles with …
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
    // Optional label above the bar (nil = no left label).
    let label: String?

    private var percent: Int {
        // Convert 0…1 fraction to whole percent for display.
        Int((value * 100).rounded())
    }

    // Pattern matching on ranges: green under 30%, orange under 70%, else red.
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
                // if let label { } unwraps optional for display.
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
            // GeometryReader reports the parent’s size so the fill width can be a fraction of full width.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track (empty bar background)
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    // Fill: width = full width × utilization (min 4pt so a tiny balance still shows)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: max(4, geo.size.width * value))
                }
            }
            .frame(height: 8) // GeometryReader expands greedily — pin its height.
        }
    }
}
