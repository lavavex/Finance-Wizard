//
//  OnDeviceAITools.swift
//  Finance Wizard
//
//  Foundation Models tools. Fetches happen on the main actor when the model asks,
//  not in SwiftUI body. Results stay short because the on-device context window is small.
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

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year().locale(Locale(identifier: "en_US")))
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

    let container: ModelContainer

    init(modelContext: ModelContext) { container = modelContext.container }

    @Generable
    struct Arguments {
        @Guide(description: "0 = this calendar month, -1 = last month, down to -12")
        var monthOffset: Int
    }

    func call(arguments: Arguments) async throws -> MoneySnapshotResult {
        await MainActor.run {
            let modelContext = container.mainContext
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
            // Same totals as the app: spend after refunds, and each bill pay counted once.
            let cardPayments = (try? modelContext.fetch(
                FetchDescriptor<CreditCardPayment>(
                    predicate: #Predicate { $0.date >= start && $0.date < end }
                )
            )) ?? []
            let spendTotal = TransactionAnalytics.totalSpend(in: spendInMonth)
            let cardPaymentTotal = CreditAnalytics.totalPaid(in: cardPayments)
            let incomeTotal = IncomeAnalytics.totalEarned(in: incomeInMonth)
            let net = incomeTotal - spendTotal

            var byCategory: [String: Double] = [:]
            for row in consumption {
                byCategory[row.category, default: 0] += abs(row.amount)
            }
            let top = byCategory.sorted { $0.value > $1.value }.prefix(5).map {
                MoneyCategorySlice(name: $0.key, amountUSD: AskLedger.rounded($0.value))
            }

            let topName = top.first?.name
            let headline: String
            if net >= 0 {
                headline = "\(label): income \(LedgerToolSupport.money(incomeTotal)) minus spend \(LedgerToolSupport.money(spendTotal)) leaves \(LedgerToolSupport.money(net)) ahead. Spending did not exceed income. Card payments of \(LedgerToolSupport.money(cardPaymentTotal)) are transfers, not extra spending."
            } else {
                headline = "\(label): spend \(LedgerToolSupport.money(spendTotal)) minus income \(LedgerToolSupport.money(incomeTotal)) leaves \(LedgerToolSupport.money(abs(net))) behind. \(topName.map { "Largest category: \($0)." } ?? "") Card payments of \(LedgerToolSupport.money(cardPaymentTotal)) are transfers, not extra spending."
            }
            return MoneySnapshotResult(
                monthLabel: label,
                incomeUSD: AskLedger.rounded(incomeTotal),
                spendUSD: AskLedger.rounded(spendTotal),
                cardPaymentsUSD: AskLedger.rounded(cardPaymentTotal),
                netUSD: AskLedger.rounded(net),
                topCategories: Array(top),
                note: "Spend is after refunds. Top categories are before refunds.",
                headline: headline
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
}

/// Linked account balances (cash and credit).
struct AccountBalancesTool: Tool {
    let name = "getAccountBalances"
    let description = "Current balances for linked bank and credit accounts. Use when the question is about cash on hand, what is owed, or account balances."

    let container: ModelContainer

    init(modelContext: ModelContext) { container = modelContext.container }

    @Generable
    struct Arguments {
        @Guide(description: "Pass 0; this tool takes no real arguments")
        var unused: Int
    }

    func call(arguments: Arguments) async throws -> AccountBalanceList {
        await MainActor.run {
            let modelContext = container.mainContext
            let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
            let rows = accounts.map { account in
                AccountBalanceRow(
                    name: account.displayName,
                    kind: account.type,
                    institution: account.institutionName,
                    currentUSD: AskLedger.rounded(account.currentBalance),
                    availableUSD: AskLedger.rounded(account.availableBalance ?? account.currentBalance)
                )
            }
            return AccountBalanceList(
                accounts: rows,
                totalOwedAllCardsUSD: AskLedger.rounded(accounts.filter(\.isCredit).reduce(0) { $0 + $1.currentBalance }),
                totalCheckingAndSavingsUSD: AskLedger.rounded(
                    accounts.filter { $0.subtype == "checking" || $0.subtype == "savings" }
                        .reduce(0) { $0 + $1.currentBalance }
                )
            )
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
    /// Totals, since the model can't reliably add a list of balances.
    var totalOwedAllCardsUSD: Double
    var totalCheckingAndSavingsUSD: Double
}

/// Detected recurring charges (capped).
struct RecurringChargesTool: Tool {
    let name = "getRecurringCharges"
    let description = "Detected subscriptions, repeating bills, and card payoff plans (My Loan, Pay Over Time, promo APR) with estimated monthly cost. Use for questions about Netflix, bills, loans, or upcoming recurring charges."

    let container: ModelContainer

    init(modelContext: ModelContext) { container = modelContext.container }

    @Generable
    struct Arguments {
        @Guide(description: "Pass 0; this tool takes no real arguments")
        var unused: Int
    }

    func call(arguments: Arguments) async throws -> RecurringChargeList {
        await MainActor.run {
            let modelContext = container.mainContext
            // Uncapped: detection looks back 400 days, and a yearly charge can be that old.
            let rows = (try? modelContext.fetch(FetchDescriptor<Transaction>())) ?? []
            let snaps = SubscriptionAnalytics.snapshots(from: rows)
            let detected = SubscriptionAnalytics.detect(snapshots: snaps)
            // A bill that skipped its date isn't an upcoming cost until it charges again.
            let groups = detected.filter { !SubscriptionAnalytics.isOverdue($0) }
            let lapsed = detected.filter { SubscriptionAnalytics.isOverdue($0) }
            let monthlyTotal = groups.reduce(0.0) { $0 + $1.estimatedMonthly }
            var items = groups.prefix(8).map {
                RecurringChargeRow(
                    vendor: $0.displayVendor,
                    typicalAmountUSD: AskLedger.rounded($0.typicalAmount),
                    cadence: $0.cadence.displayName,
                    estimatedMonthlyUSD: AskLedger.rounded($0.estimatedMonthly)
                )
            }
            let payoffs = ((try? modelContext.fetch(FetchDescriptor<PayoffPlan>())) ?? [])
                .filter(\.isActive)
            var extraPrincipal = 0.0
            for plan in payoffs.prefix(4) {
                let onCard = plan.kind.followsCardStatement
                if !onCard { extraPrincipal += plan.monthlyPayment }
                items.append(
                    RecurringChargeRow(
                        vendor: "\(plan.kind.displayName): \(plan.name)",
                        typicalAmountUSD: AskLedger.rounded(plan.installmentTotal),
                        cadence: onCard ? "On card statement (in minimum)" : "Extra principal",
                        estimatedMonthlyUSD: onCard ? 0 : AskLedger.rounded(plan.monthlyPayment)
                    )
                )
            }
            let total = AskLedger.rounded(monthlyTotal + extraPrincipal)
            var headline = "Recurring charges cost about \(AskLedger.money(total)) a month across \(groups.count) charges."
            if !lapsed.isEmpty {
                let names = lapsed.prefix(4).map {
                    "\($0.displayVendor) (\(AskLedger.money($0.typicalAmount)), last \(MoneyInsights.shortDay($0.lastDate)))"
                }
                headline += " Not counted, because they haven't charged lately: \(names.joined(separator: ", "))."
            }
            return RecurringChargeList(
                headline: headline,
                estimatedMonthlyUSD: total,
                charges: Array(items)
            )
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
    var headline: String
    var estimatedMonthlyUSD: Double
    var charges: [RecurringChargeRow]
}

@Generable
struct MoneyPlanSection {
    var title: String
    var lines: [String]
}

@Generable
struct MoneyPlanResult {
    var headline: String
    var sections: [MoneyPlanSection]
}

/// Totals for a merchant, category, or date range. The app does the math, not the model.
struct SpendingQueryTool: Tool {
    let name = "getSpending"
    let description = "Exact spending total. Leave out merchant and category for all spending. Set toMonth only when the user asks about several months."

    let container: ModelContainer

    init(modelContext: ModelContext) { container = modelContext.container }

    @Generable
    struct Arguments {
        @Guide(description: "Store or business the user named")
        var merchant: String?
        @Guide(description: "Spending category the user named")
        var category: String?
        @Guide(description: "The month as YYYY-MM")
        var fromMonth: String
        @Guide(description: "Last month of a multi-month range as YYYY-MM")
        var toMonth: String?
    }

    func call(arguments: Arguments) async throws -> SpendingResult {
        await MainActor.run {
            let modelContext = container.mainContext
            let range = AskLedger.monthRange(from: arguments.fromMonth, to: arguments.toMonth ?? "")
            let result = AskLedger.spending(
                merchant: arguments.merchant ?? "",
                category: arguments.category ?? "",
                range: range,
                in: modelContext
            )
            return SpendingResult(
                headline: result.headline,
                totalUSD: result.total,
                chargeCount: result.chargeCount,
                largestCharges: result.largest.map {
                    SpendingCharge(title: $0.title, amountUSD: $0.amount, date: LedgerToolSupport.day($0.date))
                },
                topMerchants: result.topMerchants.map {
                    MoneyCategorySlice(name: $0.name, amountUSD: $0.amount)
                }
            )
        }
    }
}

@Generable
struct SpendingCharge {
    var title: String
    var amountUSD: Double
    var date: String
}

@Generable
struct SpendingResult {
    var headline: String
    var totalUSD: Double
    var chargeCount: Int
    var largestCharges: [SpendingCharge]
    var topMerchants: [MoneyCategorySlice]
}

/// Progress against the monthly budget.
struct BudgetStatusTool: Tool {
    let name = "getBudgetStatus"
    let description = "This month's spending against the budget: amount left, and categories over or near their limits."

    let container: ModelContainer

    init(modelContext: ModelContext) { container = modelContext.container }

    @Generable
    struct Arguments {
        @Guide(description: "Pass 0; this tool takes no real arguments")
        var unused: Int
    }

    func call(arguments: Arguments) async throws -> BudgetStatusResult {
        await MainActor.run {
            let modelContext = container.mainContext
            let status = AskLedger.budgetStatus(in: modelContext)
            let row = { (item: AskLedger.BudgetStatus.Category) in
                BudgetCategoryRow(name: item.name, spentUSD: item.spent, limitUSD: item.limit)
            }
            return BudgetStatusResult(
                headline: status.headline,
                overLimit: status.overLimit.map(row),
                closestToLimit: status.closestToLimit.map(row)
            )
        }
    }
}

@Generable
struct BudgetCategoryRow {
    var name: String
    var spentUSD: Double
    var limitUSD: Double
}

@Generable
struct BudgetStatusResult {
    var headline: String
    var overLimit: [BudgetCategoryRow]
    var closestToLimit: [BudgetCategoryRow]
}

/// Card due dates and minimum payments.
struct UpcomingPaymentsTool: Tool {
    let name = "getUpcomingPayments"
    let description = "Credit card due dates and minimum payments. Use for what's due, when, and how much."

    let container: ModelContainer

    init(modelContext: ModelContext) { container = modelContext.container }

    @Generable
    struct Arguments {
        @Guide(description: "Pass 0; this tool takes no real arguments")
        var unused: Int
    }

    func call(arguments: Arguments) async throws -> UpcomingPaymentsResult {
        await MainActor.run {
            let modelContext = container.mainContext
            let upcoming = AskLedger.upcomingPayments(in: modelContext)
            return UpcomingPaymentsResult(
                headline: upcoming.headline,
                cards: upcoming.cards.map {
                    UpcomingPaymentRow(
                        name: $0.name,
                        minimumDueUSD: $0.minimumDue ?? 0,
                        balanceUSD: $0.balance,
                        dueDate: LedgerToolSupport.day($0.dueDate),
                        isOverdue: $0.isOverdue
                    )
                }
            )
        }
    }
}

@Generable
struct UpcomingPaymentRow {
    var name: String
    var minimumDueUSD: Double
    var balanceUSD: Double
    var dueDate: String
    var isOverdue: Bool
}

@Generable
struct UpcomingPaymentsResult {
    var headline: String
    var cards: [UpcomingPaymentRow]
}

/// Finds specific charges. Totals come from getSpending.
struct SearchTransactionsTool: Tool {
    let name = "searchTransactions"
    let description = "List individual charges by merchant, title, or category. Use to show specific charges, not for totals."

    let container: ModelContainer

    init(modelContext: ModelContext) { container = modelContext.container }

    @Generable
    struct Arguments {
        @Guide(description: "Merchant, category, or keyword")
        var query: String
        @Guide(description: "Max rows to return, from 1 to 8")
        var limit: Int
    }

    func call(arguments: Arguments) async throws -> TransactionSearchList {
        await MainActor.run {
            let modelContext = container.mainContext
            let accounts = (try? modelContext.fetch(FetchDescriptor<BankAccount>())) ?? []
            let limit = min(8, max(1, arguments.limit))
            let descriptor = FetchDescriptor<Transaction>(
                sortBy: [SortDescriptor(\.date, order: .reverse)]
            )
            // Match across history, then cap the results: an older charge must still be findable.
            let rows = (try? modelContext.fetch(descriptor)) ?? []
            let matches = TransactionSearch.filter(rows, query: arguments.query, accounts: accounts)
            let items = matches.prefix(limit).map { row in
                let account = BankAccount.matching(paymentMethod: row.paymentMethod, in: accounts)
                let cardLabel = CardLabelStore.label(
                    paymentMethod: row.paymentMethod,
                    accountId: account?.accountId,
                    fallback: row.paymentMethod
                )
                return TransactionSearchRow(
                    date: LedgerToolSupport.day(row.displayDate),
                    title: row.title,
                    category: row.category,
                    amountUSD: AskLedger.rounded(abs(row.amount)),
                    cardLabel: cardLabel
                )
            }
            return TransactionSearchList(
                query: arguments.query,
                matchCount: matches.count,
                rows: Array(items)
            )
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
}

@Generable
struct TransactionSearchList {
    var query: String
    var matchCount: Int
    var rows: [TransactionSearchRow]
}
