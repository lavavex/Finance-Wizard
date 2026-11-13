//
//  MoneyInsightsTests.swift
//  Finance Wizard
//
//  The facts behind "Why?", the monthly recap, and AI search. None of this needs a model.
//

import XCTest
import SwiftData
@testable import FinanceWizard

@MainActor
final class MoneyInsightsTests: XCTestCase {
    private let calendar = Calendar.current

    private func date(_ month: Int, _ day: Int = 10, year: Int = 2026) -> Date {
        DateComponents(calendar: calendar, year: year, month: month, day: day, hour: 12).date!
    }

    private func row(_ title: String, _ amount: Double, month: Int, day: Int = 10, category: String = "Dining") -> Transaction {
        Transaction(
            transactionId: UUID().uuidString,
            title: title,
            amount: -amount,
            date: date(month, day),
            category: category,
            paymentMethod: "Example Card"
        )
    }

    func testSpendingExplainsTheChangeFromLastMonth() {
        let insight = MoneyInsights.spending([
            row("Corner Cafe", 100, month: 9),
            row("Corner Cafe", 160, month: 10),
            row("Example Fuel", 40, month: 10, category: "Gas"),
        ], month: date(10))

        XCTAssertTrue(insight.headline.contains("$200.00"), insight.headline)
        XCTAssertTrue(insight.headline.contains("$100.00 more than September 2026"), insight.headline)
        let categories = try? XCTUnwrap(insight.sections.first { $0.title == "Biggest category changes" })
        XCTAssertEqual(categories?.lines.first, "Dining up $60.00, $100.00 to $160.00")
    }

    func testSpendingCanFocusOnOneCategory() {
        let insight = MoneyInsights.spending([
            row("Corner Cafe", 30, month: 10),
            row("Example Fuel", 40, month: 10, category: "Gas"),
        ], month: date(10), category: "Gas")

        XCTAssertTrue(insight.headline.contains("$40.00 on Gas"), insight.headline)
        XCTAssertFalse(insight.facts.joined().contains("Corner Cafe"))
    }

    func testCardPaymentsStayOutOfExplanations() {
        let insight = MoneyInsights.spending([
            row("Example Card Payment", 900, month: 10, category: KnownCategory.creditCardPayment.rawValue),
            row("Corner Cafe", 30, month: 10),
        ], month: date(10))

        XCTAssertFalse(insight.facts.joined().contains("Example Card Payment"))
        XCTAssertTrue(insight.headline.contains("$30.00"))
    }

    func testChargeComparesWithEarlierCharges() {
        let current = row("Corner Cafe", 30, month: 10)
        let insight = MoneyInsights.charge(current, among: [
            current,
            row("Corner Cafe", 20, month: 8),
            row("Corner Cafe", 10, month: 9),
            row("Later Only", 500, month: 11),
        ])
        XCTAssertTrue(insight.headline.contains("$15.00 above your average of $15.00"), insight.headline)
        XCTAssertTrue(insight.facts.joined().contains("3 charges in total, $60.00 overall"))
    }

    func testFirstChargeSaysSo() {
        let current = row("New Place", 12, month: 10)
        XCTAssertTrue(MoneyInsights.charge(current, among: [current]).headline.contains("first charge"))
    }

    func testPriceChangeNeedsASteadyHistory() {
        let rows = [
            row("Example Stream", 10, month: 7),
            row("Example Stream", 10, month: 8),
            row("Example Stream", 10, month: 9),
            row("Example Stream", 13, month: 10),
            row("Varying Bill", 50, month: 7),
            row("Varying Bill", 60, month: 8),
            row("Varying Bill", 55, month: 9),
            row("Varying Bill", 70, month: 10),
        ]
        XCTAssertEqual(
            MoneyInsights.priceChanges(rows, month: date(10)),
            ["Example Stream: $10.00 to $13.00"]
        )
    }

    func testRecapCoversIncomeAndNewMerchants() {
        let recap = MoneyInsights.monthlyRecap(
            [row("Old Place", 50, month: 9), row("Old Place", 50, month: 10), row("New Place", 25, month: 10)],
            income: [
                Income(
                    transactionId: "pay", source: "Example Employer", amount: 500, date: date(10),
                    category: "Payroll", accountName: nil, accountMask: nil, sourceInstitution: nil,
                    rawName: nil, pfc: nil, pending: false, kind: "income"
                ),
            ],
            month: date(10)
        )
        XCTAssertEqual(recap.headline, "In October 2026 you earned $500.00 and spent $75.00.")
        XCTAssertTrue(recap.facts.contains("Overview: Left over: $425.00"), "\(recap.facts)")
        XCTAssertTrue(recap.facts.contains("New this month: New Place, $25.00"), "\(recap.facts)")
    }

    private func recurring(_ rows: [Transaction]) -> [SubscriptionCandidate] {
        SubscriptionAnalytics.detect(in: rows, now: date(11, 6))
    }

    func testBillUsesItsNewestPriceAfterAPlanChange() {
        let found = recurring([
            row("ACME", 90, month: 7, category: "Home Internet"),
            row("ACME", 90, month: 8, category: "Home Internet"),
            row("ACME", 125, month: 9, category: "Home Internet"),
            row("ACME", 125, month: 10, category: "Home Internet"),
        ])
        XCTAssertEqual(found.map(\.estimatedMonthly), [125])
    }

    func testRenamedBillStaysOneBill() {
        let found = recurring([
            row("ACME", 90, month: 8, category: "Home Internet"),
            row("ACME", 90, month: 9, category: "Home Internet"),
            row("ACME Internet", 125, month: 10, category: "Home Internet"),
        ])
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.estimatedMonthly, 125)
    }

    func testSimilarNamesInOtherCategoriesStaySeparate() {
        let found = recurring([
            row("Example Shop", 12, month: 8, category: "Subscriptions"),
            row("Example Shop", 12, month: 9, category: "Subscriptions"),
            row("Example Shop", 12, month: 10, category: "Subscriptions"),
            row("Example Shop Reader", 5, month: 8, category: "Entertainment"),
            row("Example Shop Reader", 5, month: 9, category: "Entertainment"),
            row("Example Shop Reader", 5, month: 10, category: "Entertainment"),
        ])
        XCTAssertEqual(Set(found.map(\.estimatedMonthly)), [12, 5])
    }

    func testTwoIdenticalPaymentsAMonthApartCountAsABill() {
        let rent = recurring([
            row("WEB PAYMENT", 900, month: 9, day: 3, category: "Miscellaneous"),
            row("WEB PAYMENT", 900, month: 10, day: 3, category: "Miscellaneous"),
        ])
        XCTAssertEqual(rent.map(\.estimatedMonthly), [900])

        let override = recurring([
            row("Example Landlord", 900, month: 9, day: 3, category: "Housing"),
            row("Example Landlord", 900, month: 10, day: 3, category: "Housing"),
        ])
        XCTAssertEqual(override.map(\.estimatedMonthly), [900])
    }

    func testTwoDifferentRepairsAreNotABill() {
        XCTAssertTrue(recurring([
            row("Example Plumber", 200, month: 9, day: 3, category: "Housing"),
            row("Example Plumber", 340, month: 10, day: 3, category: "Housing"),
        ]).isEmpty)
    }

    // MARK: - Plans the app works out for Ask

    private func paycheck(_ source: String, _ amount: Double, month: Int) -> Income {
        Income(
            transactionId: UUID().uuidString, source: source, amount: amount, date: date(month),
            category: "Payroll", accountName: nil, accountMask: nil, sourceInstitution: nil,
            rawName: nil, pfc: nil, pending: false, kind: "income"
        )
    }

    private func card(_ name: String, owes: Double, apr: Double?, minimum: Double? = nil, dueDay: Int? = nil) -> BankAccount {
        BankAccount(
            accountId: name, itemId: "item", name: name, type: "credit",
            subtype: "credit card", institutionName: "Example Bank", currentBalance: owes,
            minimumPaymentAmount: minimum, nextPaymentDueDate: dueDay.map { date(11, $0) }, purchaseApr: apr
        )
    }

    private func lines(_ plan: MoneyInsight, under title: String) -> [String] {
        plan.sections.first { $0.title.hasPrefix(title) }?.lines ?? []
    }

    func testBudgetScalesSpendingToWhatIsLeftAfterBills() {
        var rows: [Transaction] = []
        var pay: [Income] = []
        for month in 8...10 {
            rows.append(row("Example Power", 100, month: month, category: "Utilities"))
            // Amounts that vary, so neither reads as a fixed bill.
            rows.append(row("Corner Cafe", 600 + Double(month - 9) * 50, month: month, day: 3))
            rows.append(row("Example Shop", 400 + Double(month - 9) * 50, month: month, day: 5, category: "Shopping"))
            pay.append(paycheck("Example Employer", 1000, month: month))
        }
        let plan = AskPlan.budget(
            rows, income: pay, accounts: [card("Example Card", owes: 500, apr: 20, minimum: 100)], plans: [], now: date(11, 6)
        )

        XCTAssertTrue(plan.headline.contains("about $1,000.00 a month"), plan.headline)
        XCTAssertTrue(plan.headline.contains("take $200.00, leaving $800.00"), plan.headline)
        XCTAssertTrue(plan.headline.contains("come down by $200.00"), plan.headline)
        XCTAssertEqual(lines(plan, under: AskPlan.budgetTitle), [
            "Dining: $480.00, down from $600.00",
            "Shopping: $320.00, down from $400.00",
        ])
        XCTAssertTrue(lines(plan, under: "Bills and card minimums, $200.00").contains("Example Card minimum: $100.00"), "\(plan.facts)")
    }

    func testBudgetCanUseOneEmployersIncome() {
        let pay = (8...10).flatMap { [paycheck("Example Employer", 900, month: $0), paycheck("Side Work", 300, month: $0)] }

        let one = AskPlan.budget([], income: pay, accounts: [], plans: [], incomeSource: "example employer", now: date(11, 6))
        XCTAssertTrue(one.headline.contains("$900.00 a month from Example Employer"), one.headline)

        XCTAssertEqual(AskPlan.incomeSource(namedIn: "Make a budget on what I bring in from example employer?", among: pay), "Example Employer")
        XCTAssertEqual(AskPlan.incomeSource(namedIn: "Help me make a budget", among: pay), "")
    }

    func testBudgetLeavesOutLapsedBillsAndAsksAboutUnnamedPayments() {
        let rows = [
            row("Example Power", 80, month: 7, category: "Utilities"),
            row("Example Power", 80, month: 8, category: "Utilities"),
            row("Example Phone", 50, month: 9, category: "Home Internet"),
            row("Example Phone", 50, month: 10, category: "Home Internet"),
            row("PAYMENT", 177, month: 11, day: 4, category: "Miscellaneous"),
        ]
        let plan = AskPlan.budget(rows, income: [paycheck("Example Employer", 900, month: 10)], accounts: [], plans: [], now: date(11, 6))

        XCTAssertEqual(lines(plan, under: "Bills and card minimums"), ["Example Phone: $50.00"])
        XCTAssertTrue(lines(plan, under: "Not counted").contains { $0.hasPrefix("Example Power: $80.00") }, "\(plan.facts)")
        XCTAssertEqual(lines(plan, under: "Payments the bank didn't name"), ["PAYMENT: $177.00 on Nov 4"])
    }

    func testBudgetKeepsNeedsWholeAndLeavesOutOneTimeDeposits() {
        var rows: [Transaction] = []
        var pay: [Income] = []
        for month in 8...10 {
            rows.append(row("Example Grocer", 300 + Double(month - 9) * 30, month: month, category: "Groceries"))
            rows.append(row("Example Shop", 600 + Double(month - 9) * 30, month: month, day: 5, category: "Shopping"))
            pay.append(paycheck("Example Employer", 500, month: month))
        }
        pay.append(paycheck("Loan Payout", 3000, month: 10))
        let plan = AskPlan.budget(rows, income: pay, accounts: [], plans: [], now: date(11, 6))

        XCTAssertTrue(plan.headline.contains("about $500.00 a month."), plan.headline)
        XCTAssertEqual(lines(plan, under: AskPlan.budgetTitle), [
            "Groceries: $300.00, your usual",
            "Shopping: $200.00, down from $600.00",
        ])
        XCTAssertEqual(lines(plan, under: "One-time deposits"), ["Loan Payout: $3,000.00 on Oct 10"])
    }

    func testBudgetLimitsIncludeBillsAndLeaveOutCancelledOnes() {
        var rows: [Transaction] = []
        var pay: [Income] = []
        for month in 8...10 {
            rows.append(row("Example Rent", 500, month: month, day: 1, category: "Housing"))
            rows.append(row("Example Stream", 20, month: month, day: 2, category: "Subscriptions"))
            rows.append(row("Example Shop", 600 + Double(month - 9) * 30, month: month, day: 5, category: "Shopping"))
            pay.append(paycheck("Example Employer", 1000, month: month))
        }
        let limits = AskPlan.budgetLimits(rows, income: pay, accounts: [], plans: [], now: date(11, 6))
        // $1,000 in, $520 of bills, so shopping gets the $480 left, and each bill sits in its category.
        XCTAssertEqual(limits, ["Housing": 500, "Subscriptions": 20, "Shopping": 480])

        for row in rows where row.title == "Example Stream" { row.subscriptionCadenceOverride = "cancelled" }
        let plan = AskPlan.budget(rows, income: pay, accounts: [], plans: [], now: date(11, 6))
        XCTAssertEqual(lines(plan, under: "Bills and card minimums"), ["Example Rent: $500.00"])

        XCTAssertEqual(AskPlan.budgetLimits([], income: [], accounts: [], plans: [], now: date(11, 6)), [:])
    }

    func testBudgetSaysSoWhenThereIsNoIncomeOrNothingLeft() {
        let none = AskPlan.budget([], income: [], accounts: [], plans: [], now: date(11, 6))
        XCTAssertTrue(none.headline.contains("can't build a budget"), none.headline)

        let short = AskPlan.budget(
            [], income: [paycheck("Example Employer", 100, month: 10)],
            accounts: [card("Example Card", owes: 500, apr: 20, minimum: 150)], plans: [], now: date(11, 6)
        )
        XCTAssertTrue(short.headline.contains("$50.00 more than that"), short.headline)
    }

    func testPayoffPutsTheHighestRateFirstAndFlagsAPassedDueDate() {
        let plan = AskPlan.payoff(accounts: [
            card("Low Rate", owes: 2000, apr: 10, minimum: 40, dueDay: 20),
            card("No Interest", owes: 300, apr: 0, minimum: 25, dueDay: 2),
            card("High Rate", owes: 1200, apr: 24, minimum: 35, dueDay: 15),
        ], plans: [], now: date(11, 6))

        XCTAssertEqual(lines(plan, under: AskPlan.payoffTitle).map { String($0.prefix(12)) }, ["1. High Rate", "2. Low Rate:", "3. No Intere"])
        XCTAssertTrue(plan.headline.contains("owe $3,500.00 and cost about $40.67 a month"), plan.headline)
        XCTAssertTrue(plan.headline.contains("$100.00 in total, then put anything extra on High Rate"), plan.headline)
        XCTAssertEqual(lines(plan, under: "Minimums coming due").first, "High Rate: minimum $35.00, due Nov 15")
        XCTAssertTrue(lines(plan, under: "Check these").contains { $0.hasPrefix("No Interest: its due date of Nov 2 has passed") })
    }

    func testPayoffWithoutRatesStartsWithTheSmallestBalance() {
        let plan = AskPlan.payoff(accounts: [card("Big", owes: 900, apr: nil), card("Small", owes: 100, apr: nil)], plans: [])
        XCTAssertTrue(plan.headline.contains("on Small, the smallest balance"), plan.headline)

        XCTAssertTrue(AskPlan.payoff(accounts: [], plans: []).headline.contains("None of your linked cards"))
    }

    func testPlanGoesIntoTheChatAsHeadlineThenSections() {
        let plan = MoneyInsight(headline: "Headline.", sections: [.init(title: "Title", lines: ["one", "two"])])
        XCTAssertEqual(AskPlan.chatText(plan), "Headline.\n\nTitle\n- one\n- two")
    }

    func testPayerNameNeedsAConfidentCounterparty() throws {
        func decode(_ counterparty: String, merchant: String = "null") throws -> PlaidTransaction {
            let json = """
            {"account_id":"a","amount":-500,"date":"2026-11-03","name":"PAYROLLXYZ","merchant_name":\(merchant),
             "transaction_id":"t","counterparties":[\(counterparty)]}
            """
            return try JSONDecoder().decode(PlaidTransaction.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"name":"Example Employer","type":"merchant","confidence_level":"HIGH"}"#).payerName, "Example Employer")
        XCTAssertNil(try decode(#"{"name":"Example Employer","type":"merchant","confidence_level":"LOW"}"#).payerName)
        XCTAssertNil(try decode(#"{"name":"Example Bank","type":"financial_institution","confidence_level":"HIGH"}"#).payerName)
        XCTAssertNil(try decode(#"{"name":"Example Employer","type":"merchant","confidence_level":"HIGH"}"#, merchant: "\"Named\"").payerName)
    }

    func testSearchFilterCombinesConditions() {
        let rows = [
            row("Example Market", 80, month: 8, category: "Groceries"),
            row("Example Market", 20, month: 8, category: "Groceries"),
            row("Example Market", 90, month: 9, category: "Groceries"),
            row("Corner Cafe", 80, month: 8),
        ]
        let filter = TransactionSearchFilter(merchant: "example market", minAmount: 50, fromMonth: "2026-08")

        XCTAssertEqual(filter.matches(in: rows).map(\.amount), [-80])
        XCTAssertEqual(filter.summary, "example market · over $50.00 · August 2026")
    }

    func testSearchDropsFiltersTheQueryDoesNotSupport() {
        let invented = TransactionSearchFilter(
            merchant: "Amazon", category: "Shopping", minAmount: 50, fromMonth: "2026-08"
        ).supported(by: "Amazon over $50 in August")
        XCTAssertEqual(invented.merchant, "amazon")
        XCTAssertEqual(invented.category, "")
        XCTAssertEqual(invented.minAmount, 50)
        XCTAssertEqual(invented.fromMonth, "2026-08")

        let noTime = TransactionSearchFilter(merchant: "Amazon", minAmount: 0, fromMonth: "2026-10")
            .supported(by: "everything from Amazon")
        XCTAssertNil(noTime.minAmount)
        XCTAssertEqual(noTime.fromMonth, "")
    }

    func testSearchFindsTheCategoryInTheQuery() {
        let spoken = TransactionSearchFilter(merchant: "gas charges", maxAmount: 20)
            .supported(by: "gas charges under 20 dollars")
        XCTAssertEqual(spoken.merchant, "")
        XCTAssertEqual(spoken.category, KnownCategory.canonicalName(for: "gas"))

        XCTAssertEqual(
            TransactionSearchFilter(category: "gas charges").supported(by: "gas charges under 20 dollars").category,
            "gas"
        )

        let missed = TransactionSearchFilter(fromMonth: "2026-06").supported(by: "subscriptions in June")
        XCTAssertEqual(missed.category, KnownCategory.canonicalName(for: "subscriptions"))
    }

    func testSearchFilterIgnoresFillerWords() {
        let rows = [row("Corner Cafe", 80, month: 8)]
        XCTAssertEqual(TransactionSearchFilter(merchant: "all", category: "any").matches(in: rows).count, 1)
    }
}
