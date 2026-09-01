//
//  OnDeviceAITools.swift
//  Finance Wizard
//
//  Foundation Models tools. Fetches happen on the main actor when the model asks,
//  not in SwiftUI body. Caps keep the on-device context window small.
//

import Foundation
import FoundationModels
import SwiftData

private enum LedgerToolSupport {
    static let money: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    static func money(_ value: Double) -> String {
        money.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func monthInterval(offset: Int, calendar: Calendar = .current, now: Date = .now) -> DateInterval {
        let clamped = min(0, max(-12, offset))
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let start = calendar.date(byAdding: .month, value: clamped, to: startOfThisMonth) ?? startOfThisMonth
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    static func monthLabel(offset: Int, calendar: Calendar = .current, now: Date = .now) -> String {
        let interval = monthInterval(offset: offset, calendar: calendar, now: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: interval.start)
    }
}

/// Income, spend, net, and top categories for one calendar month.
struct MoneySnapshotTool: Tool {
    let name = "getMoneySnapshot"
    let description = "Totals for a calendar month: income, spend, net (income minus spend), and top spend categories. Use for overall money questions such as whether spending exceeds income or why the user feels broke. monthOffset 0 is this month, -1 is last month."

    let modelContext: ModelContext

    @Generable
    struct Arguments {
        @Guide(description: "0 = this calendar month, -1 = last month, down to -12")
        var monthOffset: Int
    }

    func call(arguments: Arguments) async throws -> MoneySnapshotResult {
        try await MainActor.run {
            let offset = arguments.monthOffset
            let interval = LedgerToolSupport.monthInterval(offset: offset)
            let label = LedgerToolSupport.monthLabel(offset: offset)

            let start = interval.start
            let end = interval.end
            let spendInMonth = (try? modelContext.fetch(
                FetchDescriptor<Transaction>(
                    predicate: #Predicate { $0.date >= start && $0.date < end }
                )
            )) ?? []
            let incomeInMonth = (try? modelContext.fetch(
                FetchDescriptor<Income>(
                    predicate: #Predicate { $0.date >= start && $0.date < end }
                )
            )) ?? []
            let consumption = spendInMonth.filter { !TransactionAnalytics.isExcludedFromSpendCategory($0.category) }
            let cardPayments = spendInMonth.filter { TransactionAnalytics.isExcludedFromSpendCategory($0.category) }
            let spendTotal = consumption.reduce(0.0) { $0 + abs($1.amount) }
            let cardPaymentTotal = cardPayments.reduce(0.0) { $0 + abs($1.amount) }
            let incomeTotal = incomeInMonth.reduce(0.0) { $0 + $1.amount }
            let net = incomeTotal - spendTotal

            var byCategory: [String: Double] = [:]
            for row in consumption {
                byCategory[row.category, default: 0] += abs(row.amount)
            }
            let top = byCategory.sorted { $0.value > $1.value }.prefix(5).map {
                MoneyCategorySlice(name: $0.key, amountUSD: $0.value)
            }

            let topName = top.first?.name
            let headline: String
            if net >= 0 {
                headline = "\(label): income \(LedgerToolSupport.money(incomeTotal)) minus spend \(LedgerToolSupport.money(spendTotal)) leaves \(LedgerToolSupport.money(net)) ahead. Spending did not exceed income. Card payments of \(LedgerToolSupport.money(cardPaymentTotal)) are transfers, not extra spending."
            } else {
                headline = "\(label): spend \(LedgerToolSupport.money(spendTotal)) minus income \(LedgerToolSupport.money(incomeTotal)) leaves \(LedgerToolSupport.money(abs(net))) behind. \(topName.map { "Largest category: \($0)." } ?? "") Card payments of \(LedgerToolSupport.money(cardPaymentTotal)) are transfers, not extra spending."
            }
            var followUps = ["Compare to last month", "What are my account balances?"]
            if let topName {
                followUps.insert("Break down \(topName) this month", at: 0)
            } else {
                followUps.append("What recurring charges do I have?")
            }

            return MoneySnapshotResult(
                monthLabel: label,
                incomeUSD: incomeTotal,
                spendUSD: spendTotal,
                cardPaymentsUSD: cardPaymentTotal,
                netUSD: net,
                topCategories: Array(top),
                note: "Spend excludes credit card payments (those are transfers, not new spending).",
                headline: headline,
                suggestedFollowUps: followUps
            )
        }
    }
}

@Generable
struct MoneyCategorySlice {
    var name: String
    var amountUSD: Double
}

@Generable
struct MoneySnapshotResult {
    var monthLabel: String
    var incomeUSD: Double
    var spendUSD: Double
    var cardPaymentsUSD: Double
    var netUSD: Double
    var topCategories: [MoneyCategorySlice]
    var note: String
    var headline: String
    var suggestedFollowUps: [String]
}

/// Linked account balances (cash and credit).
struct AccountBalancesTool: Tool {
    let name = "getAccountBalances"
    let description = "Current balances for linked bank and credit accounts. Use when the question is about cash on hand, what is owed, or account balances."

    let modelContext: ModelContext

    @Generable
    struct Arguments {
        @Guide(description: "Pass 0; this tool takes no real arguments")
        var unused: Int
    }

    func call(arguments: Arguments) async throws -> AccountBalanceList {
        try await MainActor.run {
            let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
            let rows = accounts.map { account in
                AccountBalanceRow(
                    name: account.displayName,
                    kind: account.type,
                    institution: account.institutionName,
                    currentUSD: account.currentBalance,
                    availableUSD: account.availableBalance ?? account.currentBalance
                )
            }
            return AccountBalanceList(accounts: rows)
        }
    }
}

@Generable
struct AccountBalanceRow {
    var name: String
    var kind: String
    var institution: String
    var currentUSD: Double
    var availableUSD: Double
}

@Generable
struct AccountBalanceList {
    var accounts: [AccountBalanceRow]
}

/// Detected recurring charges (capped).
struct RecurringChargesTool: Tool {
    let name = "getRecurringCharges"
    let description = "Detected subscriptions, repeating bills, and card payoff plans (My Loan, Pay Over Time, promo APR) with estimated monthly cost. Use for questions about Netflix, bills, loans, or upcoming recurring charges."

    let modelContext: ModelContext

    @Generable
    struct Arguments {
        @Guide(description: "Pass 0; this tool takes no real arguments")
        var unused: Int
    }

    func call(arguments: Arguments) async throws -> RecurringChargeList {
        try await MainActor.run {
            var descriptor = FetchDescriptor<Transaction>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 400
            let rows = (try? modelContext.fetch(descriptor)) ?? []
            let snaps = SubscriptionAnalytics.snapshots(from: rows)
            let groups = SubscriptionAnalytics.detect(snapshots: snaps)
            let active = Array(groups.prefix(20))
            var items = active.map {
                RecurringChargeRow(
                    vendor: $0.displayVendor,
                    typicalAmountUSD: $0.typicalAmount,
                    cadence: $0.cadence.displayName,
                    estimatedMonthlyUSD: $0.estimatedMonthly
                )
            }
            let payoffs = ((try? modelContext.fetch(FetchDescriptor<PayoffPlan>())) ?? [])
                .filter(\.isActive)
            for plan in payoffs.prefix(20) {
                items.append(
                    RecurringChargeRow(
                        vendor: "\(plan.kind.displayName): \(plan.name)",
                        typicalAmountUSD: plan.installmentTotal,
                        cadence: "Monthly",
                        estimatedMonthlyUSD: plan.installmentTotal
                    )
                )
            }
            let monthly = items.reduce(0.0) { $0 + $1.estimatedMonthlyUSD }
            return RecurringChargeList(estimatedMonthlyUSD: monthly, charges: items)
        }
    }
}

@Generable
struct RecurringChargeRow {
    var vendor: String
    var typicalAmountUSD: Double
    var cadence: String
    var estimatedMonthlyUSD: Double
}

@Generable
struct RecurringChargeList {
    var estimatedMonthlyUSD: Double
    var charges: [RecurringChargeRow]
}

/// Keyword search over recent expenses (capped).
struct SearchTransactionsTool: Tool {
    let name = "searchTransactions"
    let description = "Search recent expenses by merchant name, title, or category. Use for a specific store or charge, not for overall totals."

    let modelContext: ModelContext

    @Generable
    struct Arguments {
        @Guide(description: "Merchant, category, or keyword")
        var query: String
        @Guide(description: "Max rows to return, from 1 to 20")
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> TransactionSearchList {
        try await MainActor.run {
            let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
            let limit = min(20, max(1, arguments.limit))
            var descriptor = FetchDescriptor<Transaction>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            descriptor.fetchLimit = 120
            let rows = (try? modelContext.fetch(descriptor)) ?? []
            let matches = TransactionSearch.filter(rows, query: arguments.query, accounts: accounts).prefix(limit)
            let day = DateFormatter()
            day.dateStyle = .medium
            day.timeStyle = .none
            let items = matches.map { row in
                let account = BankAccount.matching(paymentMethod: row.paymentMethod, in: accounts)
                let cardLabel = CardLabelStore.label(
                    paymentMethod: row.paymentMethod,
                    accountId: account?.accountId,
                    fallback: row.paymentMethod
                )
                return TransactionSearchRow(
                    date: day.string(from: row.displayDate),
                    title: row.title,
                    category: row.category,
                    amountUSD: abs(row.amount),
                    cardLabel: cardLabel,
                    transactionId: row.transactionId
                )
            }
            return TransactionSearchList(query: arguments.query, rows: Array(items))
        }
    }
}

struct TopTransactionsTool: Tool {
    let name = "getTopTransactions"
    let description = "Search for biggest/largest single charges; not category totals; not a named merchant"
    let modelContext: ModelContext
    
    @Generable
    struct Arguments {
        @Guide(description: "0 = this calendar month, -1 = last month, down to -12")
        var monthOffset: Int
        @Guide(description: "Max Number of transactions/rows to return, from 1 to 20")
        var limit: Int
    }
    
    func call(arguments: Arguments) async throws -> TopTransactionList {
        try await MainActor.run {
            return TopTransactionList(monthLabel: "month", rows: [])
        }
    }
}

@Generable
struct TransactionSearchRow {
    var date: String
    var title: String
    var category: String
    var amountUSD: Double
    var cardLabel: String
    var transactionId: String
}

@Generable
struct TransactionSearchList {
    var query: String
    var rows: [TransactionSearchRow]
}

@Generable
struct TopTransactionList {
    var monthLabel: String
    var rows: [TransactionSearchRow]
}
