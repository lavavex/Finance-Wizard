//
//  CardPaymentTests.swift
//  Finance Wizard
//
//  Total paid: one bill pay can appear on both the checking account and the card.
//

import XCTest
import SwiftData
@testable import FinanceWizard

@MainActor
final class CardPaymentTests: XCTestCase {
    func testPayingACardFromCheckingCountsOnce() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        context.insert(CreditCardPayment(
            transactionId: "checking-side",
            amount: 500,
            date: day,
            cardName: "CREDIT CARD ···1234",
            sourceAccount: "CHECKING ···9999",
            title: "Payment to Example card ending in 1234",
            creditAccountId: "card-account"
        ))
        context.insert(CreditCardPayment(
            transactionId: "card-side",
            amount: 500,
            date: day.addingTimeInterval(86_400),
            cardName: "CREDIT CARD ···1234",
            title: "Payment Thank You-Mobile",
            creditAccountId: "card-account"
        ))

        let rows = try context.fetch(FetchDescriptor<CreditCardPayment>())
        let unique = CreditAnalytics.deduplicated(rows)

        XCTAssertEqual(unique.map(\.transactionId), ["card-side"])
        XCTAssertEqual(CreditAnalytics.sumPaid(unique), 500)
    }

    func testTwoRealPaymentsOfTheSameAmountBothCount() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        for (id, offset) in [("first", 0.0), ("second", 86_400.0)] {
            context.insert(CreditCardPayment(
                transactionId: id,
                amount: 200,
                date: day.addingTimeInterval(offset),
                cardName: "CREDIT CARD ···1234",
                title: "Payment Thank You-Mobile",
                creditAccountId: "card-account"
            ))
        }

        let rows = try context.fetch(FetchDescriptor<CreditCardPayment>())

        XCTAssertEqual(CreditAnalytics.sumPaid(CreditAnalytics.deduplicated(rows)), 400)
    }

    func testEqualPaymentsToDifferentCardsBothCount() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        context.insert(CreditCardPayment(
            transactionId: "checking-side",
            amount: 300,
            date: day,
            cardName: "CREDIT CARD ···1111",
            sourceAccount: "CHECKING ···9999",
            title: "Payment to Example card ending in 1111",
            creditAccountId: "card-one"
        ))
        context.insert(CreditCardPayment(
            transactionId: "other-card",
            amount: 300,
            date: day,
            cardName: "CREDIT CARD ···2222",
            title: "Payment Thank You-Mobile",
            creditAccountId: "card-two"
        ))

        let rows = try context.fetch(FetchDescriptor<CreditCardPayment>())

        XCTAssertEqual(CreditAnalytics.sumPaid(CreditAnalytics.deduplicated(rows)), 600)
    }

    func testPaymentsFromTwoCheckingAccountsToOneCardBothCount() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        for (id, source) in [("one", "CHECKING ···1111"), ("two", "CHECKING ···2222")] {
            context.insert(CreditCardPayment(
                transactionId: id,
                amount: 100,
                date: day,
                cardName: "CREDIT CARD ···1234",
                sourceAccount: source,
                title: "Payment to Example card ending in 1234",
                creditAccountId: "card-account"
            ))
        }

        let rows = try context.fetch(FetchDescriptor<CreditCardPayment>())

        XCTAssertEqual(CreditAnalytics.sumPaid(CreditAnalytics.deduplicated(rows)), 200)
    }

    func testPaymentNamingAnIssuerMergesWithThatIssuersCard() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        context.insert(CreditCardPayment(
            transactionId: "checking-side",
            amount: 250,
            date: day,
            cardName: "Amex",
            sourceAccount: "CHECKING ···9999",
            title: "AMERICAN EXPRESS ACH PMT",
            institutionName: "Example Bank"
        ))
        context.insert(CreditCardPayment(
            transactionId: "card-side",
            amount: 250,
            date: day,
            cardName: "CREDIT CARD ···1234",
            title: "MOBILE PAYMENT - THANK YOU",
            creditAccountId: "card-account",
            institutionName: "American Express"
        ))

        let rows = try context.fetch(FetchDescriptor<CreditCardPayment>())

        XCTAssertEqual(CreditAnalytics.sumPaid(CreditAnalytics.deduplicated(rows)), 250)
    }

    /// A card that can't be linked has no card-side row, so its payment must stand alone.
    func testPaymentToUnlinkedCardDoesNotMergeWithAnotherIssuer() throws {
        let context = try makeContext()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        context.insert(CreditCardPayment(
            transactionId: "unlinked-card",
            amount: 400,
            date: day,
            cardName: "CHECKING ···9999",
            sourceAccount: "CHECKING ···9999",
            title: "Apple Card",
            institutionName: "Chase"
        ))
        context.insert(CreditCardPayment(
            transactionId: "linked-card",
            amount: 400,
            date: day,
            cardName: "CREDIT CARD ···1234",
            title: "Payment Thank You-Mobile",
            creditAccountId: "card-account",
            institutionName: "Chase"
        ))

        let rows = try context.fetch(FetchDescriptor<CreditCardPayment>())

        XCTAssertEqual(CreditAnalytics.sumPaid(CreditAnalytics.deduplicated(rows)), 800)
    }

    private var containers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let container = try SharedStore.makeContainer(inMemory: true)
        containers.append(container)
        return ModelContext(container)
    }
}
