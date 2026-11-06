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
