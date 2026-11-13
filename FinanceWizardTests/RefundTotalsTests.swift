//
//  RefundTotalsTests.swift
//  Finance Wizard
//
//  Refunds reduce Total Spend, card totals, and Budget's Spent, but not category rows.
//

import XCTest
import SwiftData
@testable import FinanceWizard

@MainActor
final class RefundTotalsTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let today = Date()

    override func setUpWithError() throws {
        container = try SharedStore.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    func testTotalSpendSubtractsRefundsAndIgnoresOtherExcludedRows() throws {
        let rows = try insert([
            ("Shopping", -100, "Card A"),
            ("Dining", -50, "Card A"),
            ("Refund", 30, "Card A"),
            ("Credit Card Payment", -500, "Card A"),
            ("Loan", 900, "Card A")
        ])

        XCTAssertEqual(TransactionAnalytics.totalSpend(in: rows), 120, accuracy: 0.001)
    }

    func testRefundsLargerThanSpendingStopAtZero() throws {
        let rows = try insert([("Shopping", -20, "Card A"), ("Refund", 75, "Card A")])

        XCTAssertEqual(TransactionAnalytics.totalSpend(in: rows), 0)
    }

    func testPeriodIndexKeepsGrossAndNetAndNetsEachCard() throws {
        let rows = try insert([
            ("Shopping", -100, "Card A"),
            ("Refund", 40, "Card A"),
            ("Dining", -60, "Card B"),
            ("Refund", 5, "Card C")
        ])

        let index = PeriodSpendIndex.build(transactions: rows, period: .month, referenceDate: today)

        XCTAssertEqual(index.grossSpend, 160, accuracy: 0.001)
        XCTAssertEqual(index.refundTotal, 45, accuracy: 0.001)
        XCTAssertEqual(index.totalSpend, 115, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(index.spendByMethod["Card A"]).spend, 60, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(index.spendByMethod["Card B"]).spend, 60, accuracy: 0.001)
        XCTAssertNil(index.spendByMethod["Card C"])
    }

    func testChartsShowNetTotalWithSlicesBeforeRefunds() throws {
        let rows = try insert([("Shopping", -100, "Card A"), ("Refund", 25, "Card A")])

        let snapshot = TransactionAnalytics.makeCategorySnapshot(from: rows, period: .month, referenceDate: today)

        XCTAssertEqual(snapshot.totalSpend, 75, accuracy: 0.001)
        XCTAssertEqual(snapshot.refunds, 25, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(snapshot.categories.first).spent, 100, accuracy: 0.001)
    }

    func testWidgetCardsAreNetOfTheirOwnRefunds() throws {
        let rows = try insert([
            ("Shopping", -100, "Card A"),
            ("Refund", 25, "Card A"),
            ("Dining", -60, "Card B")
        ])

        let snapshot = TransactionAnalytics.makeSnapshot(from: rows, period: .month)
        let cards = Dictionary(uniqueKeysWithValues: snapshot.cards.map { ($0.cardName, $0.spent) })

        XCTAssertEqual(snapshot.totalSpend, 135, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cards["Card A"]), 75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(cards["Card B"]), 60, accuracy: 0.001)
    }

    func testBudgetSpentIsNetAndCategoriesAndUnbudgetedAreNot() throws {
        let rows = try insert([
            ("Shopping", -100, "Card A"),
            ("Dining", -40, "Card A"),
            ("Refund", 30, "Card A")
        ])
        let plan = BudgetPlan(monthlyLimit: 500, categoryLimits: ["Shopping": 200])

        let snapshot = BudgetAnalytics.snapshot(plan: plan, transactions: rows, referenceDate: today)

        XCTAssertEqual(snapshot.totalSpent, 110, accuracy: 0.001)
        XCTAssertEqual(snapshot.refunds, 30, accuracy: 0.001)
        XCTAssertEqual(snapshot.unbudgetedSpend, 40, accuracy: 0.001)
        XCTAssertEqual(snapshot.categories.first { $0.category == "Shopping" }?.spent, 100)
        XCTAssertEqual(try XCTUnwrap(snapshot.totalRemaining), 390, accuracy: 0.001)
    }

    func testAskUsesTheSameTotalsAsTheApp() async throws {
        let rows = try insert([("Shopping", -100, "Card A"), ("Refund", 30, "Card A")])
        context.insert(CreditCardPayment(
            transactionId: "checking-side",
            amount: 500,
            date: today,
            cardName: "CREDIT CARD ···1234",
            sourceAccount: "CHECKING ···9999",
            title: "Payment to Example card ending in 1234",
            creditAccountId: "card-account"
        ))
        context.insert(CreditCardPayment(
            transactionId: "card-side",
            amount: 500,
            date: today,
            cardName: "CREDIT CARD ···1234",
            title: "Payment Thank You-Mobile",
            creditAccountId: "card-account"
        ))
        try context.save()

        let result = try await MoneySnapshotTool(modelContext: context)
            .call(arguments: .init(monthOffset: 0))

        XCTAssertEqual(result.spendUSD, TransactionAnalytics.totalSpend(in: rows), accuracy: 0.001)
        XCTAssertEqual(result.spendUSD, 70, accuracy: 0.001)
        XCTAssertEqual(result.cardPaymentsUSD, 500, accuracy: 0.001)
    }

    private func insert(_ rows: [(category: String, amount: Double, method: String)]) throws -> [Transaction] {
        for (index, row) in rows.enumerated() {
            context.insert(Transaction(
                transactionId: "row-\(index)",
                title: "Example \(index)",
                amount: row.amount,
                date: today,
                category: row.category,
                paymentMethod: row.method
            ))
        }
        try context.save()
        return try context.fetch(FetchDescriptor<Transaction>())
    }
}
