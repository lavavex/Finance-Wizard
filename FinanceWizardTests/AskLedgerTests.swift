//
//  AskLedgerTests.swift
//  Finance Wizard
//
//  The numbers Ask gives the model, the check on what the model says back, and its session recap.
//  None of this needs Apple Intelligence.
//

import XCTest
import SwiftData
import FoundationModels
@testable import FinanceWizard

@MainActor
final class AskLedgerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let calendar = Calendar.current
    private let now = DateComponents(calendar: .current, year: 2026, month: 11, day: 15, hour: 12).date!

    override func setUpWithError() throws {
        container = try SharedStore.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    // MARK: - Date ranges

    func testMonthRangeParsesNumbersNamesAndBlanks() {
        let thisMonth = AskLedger.monthRange(from: "", to: "", now: now, calendar: calendar)
        XCTAssertEqual(thisMonth.label, "November 2026")

        let march = AskLedger.monthRange(from: "2026-03", to: "", now: now, calendar: calendar)
        XCTAssertEqual(march.label, "March 2026")
        XCTAssertEqual(calendar.component(.month, from: march.end), 4)

        XCTAssertEqual(AskLedger.monthRange(from: "March", to: "", now: now, calendar: calendar).label, "March 2026")
        XCTAssertEqual(AskLedger.monthRange(from: "December", to: "", now: now, calendar: calendar).label, "December 2025")
        XCTAssertEqual(AskLedger.monthRange(from: "gibberish", to: "", now: now, calendar: calendar).label, "November 2026")
    }

    func testMonthRangeCoversSeveralMonthsInEitherOrder() {
        let range = AskLedger.monthRange(from: "2026-06", to: "2026-03", now: now, calendar: calendar)
        XCTAssertEqual(range.label, "March 2026 through June 2026")
        XCTAssertEqual(calendar.component(.month, from: range.end), 7)
    }

    // MARK: - Spending

    func testMerchantTotalIsExactAndNetOfItsRefunds() throws {
        insert("Example Market", -60.10, "Groceries", day: 3)
        insert("EXAMPLE-MARKET #12", -39.90, "Groceries", day: 5)
        insert("Example Market", 10, "Refund", day: 6)
        insert("Other Store", -500, "Shopping", day: 7)
        insert("Example Market", -999, "Groceries", day: 3, month: 10)

        let result = AskLedger.spending(merchant: "example market", category: "", range: november, in: context)

        XCTAssertEqual(result.total, 90)
        XCTAssertEqual(result.refunds, 10)
        XCTAssertEqual(result.chargeCount, 2)
        XCTAssertEqual(result.largest.first?.amount, 60.10)
        XCTAssertTrue(result.headline.contains("$90.00"), result.headline)
    }

    func testBillPaysAndOtherExcludedRowsAreNotSpending() throws {
        insert("Example Market", -50, "Groceries", day: 3)
        insert("Payment Thank You", -900, "Credit Card Payment", day: 4)
        insert("Example Plan", -100, "Installment", day: 4)

        let result = AskLedger.spending(merchant: "", category: "", range: november, in: context)

        XCTAssertEqual(result.total, 50)
        XCTAssertEqual(result.topMerchants.map(\.name), ["Example Market"])
    }

    func testCategoryUsesCanonicalNamesAndStaysBeforeRefunds() throws {
        insert("Example Bistro", -40, "Dining", day: 3)
        insert("Example Store", -70, "Shopping", day: 3)
        insert("Example Store", 20, "Refund", day: 4)

        let result = AskLedger.spending(merchant: "", category: "restaurants", range: november, in: context)

        XCTAssertEqual(result.total, 40)
        XCTAssertEqual(result.refunds, 0)
    }

    func testNoMatchSaysSoInsteadOfZeroDollars() {
        let result = AskLedger.spending(merchant: "Nowhere", category: "", range: november, in: context)

        XCTAssertEqual(result.chargeCount, 0)
        XCTAssertEqual(result.headline, "No charges at Nowhere in November 2026.")
    }

    // MARK: - Budget and payments

    func testBudgetHeadlineComputesWhatIsLeft() throws {
        insert("Example Store", -700, "Shopping", day: 3)
        insert("Example Bistro", -40, "Dining", day: 3)
        context.insert(BudgetPlan(monthlyLimit: 1000, categoryLimits: ["Shopping": 500, "Dining": 100]))
        try context.save()

        let status = AskLedger.budgetStatus(now: now, in: context)

        XCTAssertEqual(status.remaining, 260)
        XCTAssertTrue(status.headline.contains("$260.00 left"), status.headline)
        XCTAssertEqual(status.overLimit.map(\.name), ["Shopping"])
        XCTAssertEqual(status.closestToLimit.map(\.name), ["Dining"])
    }

    func testNoBudgetIsStatedPlainly() {
        XCTAssertTrue(AskLedger.budgetStatus(now: now, in: context).headline.hasPrefix("No budget is set"))
    }

    func testUpcomingPaymentsSortByDueDateAndSkipPastOnes() throws {
        for (id, day, minimum) in [("later", 25, 40.0), ("sooner", 20, 25.0), ("past", 2, 99.0)] {
            context.insert(BankAccount(
                accountId: id,
                itemId: "item",
                name: id,
                type: "credit",
                institutionName: "Example",
                currentBalance: 500,
                minimumPaymentAmount: minimum,
                nextPaymentDueDate: date(day: day)
            ))
        }
        try context.save()

        let upcoming = AskLedger.upcomingPayments(now: now, in: context)

        XCTAssertEqual(upcoming.cards.map(\.name), ["sooner", "later"])
        XCTAssertEqual(upcoming.totalMinimum, 65)
    }

    // MARK: - Tools

    // The on-device model fills unused fields with words like these instead of leaving them out.
    func testFillerWordsDoNotFilterSpending() {
        for filler in ["all", "ANY", " merchant ", "category", "none", "n/a"] {
            let filters = AskLedger.spendingFilters(merchant: filler, category: filler)
            XCTAssertEqual(filters.merchant, "", filler)
            XCTAssertEqual(filters.category, "", filler)
        }
        let named = AskLedger.spendingFilters(merchant: "Example Market", category: "merchant")
        XCTAssertEqual(named.merchant, "Example Market")
        XCTAssertEqual(named.category, "")
    }

    func testCategoryInTheWrongFieldStillFiltersByCategory() {
        let doubled = AskLedger.spendingFilters(merchant: "Dining", category: "Dining")
        XCTAssertEqual(doubled.merchant, "")
        XCTAssertEqual(doubled.category, "Dining")

        let swapped = AskLedger.spendingFilters(merchant: "dining", category: "")
        XCTAssertEqual(swapped.merchant, "")
        XCTAssertEqual(swapped.category, "Dining")

        let custom = AskLedger.spendingFilters(merchant: "pet stuff", category: "", categoriesInUse: ["Pet Stuff"])
        XCTAssertEqual(custom.merchant, "")
        XCTAssertEqual(custom.category, "Pet Stuff")

        let merchantInCategory = AskLedger.spendingFilters(merchant: "", category: "Example Market")
        XCTAssertEqual(merchantInCategory.merchant, "Example Market")
        XCTAssertEqual(merchantInCategory.category, "")
    }

    func testInstructionsNameThisMonthAndLastMonth() {
        let january = DateComponents(calendar: .current, year: 2027, month: 1, day: 15, hour: 12).date!
        let instructions = OnDeviceAI.askInstructions(today: january)
        XCTAssertTrue(instructions.contains("This month is 2027-01."))
        XCTAssertTrue(instructions.contains("Last month is 2026-12."))
    }

    func testToolAnswersWithoutTheModel() async throws {
        insert("Example Market", -25, "Groceries", day: Calendar.current.component(.day, from: Date()), month: nil)
        try context.save()

        let result = try await SpendingQueryTool(modelContext: context).call(
            arguments: .init(merchant: "Example Market", category: "", fromMonth: "", toMonth: "")
        )

        XCTAssertEqual(result.totalUSD, 25)
        XCTAssertEqual(result.chargeCount, 1)
    }

    func testOnlyRangeWordingAsksForSeveralMonths() {
        for single in ["How much did I spend on Dining last month?", "dining total this month?", "What did Example Fuel cost me in October"] {
            XCTAssertFalse(AskLedger.asksForSeveralMonths(single), single)
        }
        for range in [
            "What did I spend in total from August through October?", "Spending since August", "Dining in the last 3 months",
            "How much this year?", "August and September spending", "Compare to last month",
        ] {
            XCTAssertTrue(AskLedger.asksForSeveralMonths(range), range)
        }
    }

    func testEveryToolIsRegisteredAndNamedInTheInstructions() {
        let instructions = OnDeviceAI.askInstructions()
        for tool in OnDeviceAI.askTools(modelContext: context) {
            XCTAssertTrue(instructions.contains(tool.name), tool.name)
        }
    }

    // MARK: - Checking answers

    func testAmountsFromToolsPassAndInventedOnesFail() {
        let facts = [#"{"totalUSD":1770.76,"note":"after 3.23 in refunds"}"#]

        XCTAssertEqual(AskAnswerCheck.unverifiedAmounts(in: "You spent $1,770.76.", facts: facts), [])
        XCTAssertEqual(AskAnswerCheck.unverifiedAmounts(in: "About $1,771 so far.", facts: facts), [])
        XCTAssertEqual(AskAnswerCheck.unverifiedAmounts(in: "Refunds were $3.23.", facts: facts), [])
        XCTAssertEqual(AskAnswerCheck.unverifiedAmounts(in: "You spent $2,000.50.", facts: facts), [2000.50])
        XCTAssertEqual(AskAnswerCheck.unverifiedAmounts(in: "You spent $45.", facts: []), [45])
    }

    func testAnswersWithoutAmountsAndAmountsTheUserTypedPass() {
        XCTAssertEqual(AskAnswerCheck.unverifiedAmounts(in: "Dining is your biggest category.", facts: []), [])
        XCTAssertEqual(AskAnswerCheck.unverifiedAmounts(in: "Yes, $50 is a lot.", facts: ["Is $50 a lot?"]), [])
    }

    // MARK: - Conversation

    func testRecapKeepsRecentQuestionsAndLeavesOutAnswers() {
        let long = String(repeating: "x", count: 1000)
        let history = (0..<8).map { AskChatTurn(isUser: $0 % 2 == 0, text: "turn \($0) \(long)") }

        let recap = AskConversation.recap(of: history)

        XCTAssertFalse(recap.contains("turn 0 "))
        XCTAssertTrue(recap.contains("turn 2 "))
        XCTAssertFalse(recap.contains("turn 3 "), "An old amount in the recap gets repeated as if it were new.")
        XCTAssertLessThan(recap.count, 600)
    }

    func testFollowUpWordingIsRecognized() {
        XCTAssertTrue(AskConversation.isFollowUp("And last month?"))
        XCTAssertTrue(AskConversation.isFollowUp("  what about groceries?"))
        XCTAssertFalse(AskConversation.isFollowUp("How much did I spend this month?"))
        XCTAssertFalse(AskConversation.isFollowUp("Android subscriptions?"))
    }

    func testFollowUpsMatchWhatWasAnswered() {
        XCTAssertEqual(
            AskConversation.followUps(afterTools: ["getSpending"]),
            ["Compare to last month", "Show the largest charges"]
        )
        XCTAssertEqual(AskConversation.followUps(afterTools: []).count, 3)
    }

    func testFailuresBecomePlainMessages() {
        struct Unknown: Error {}
        XCTAssertTrue(AskConversation.message(for: Unknown()).contains("Apple Intelligence"))
    }

    // MARK: - Helpers

    private var november: AskLedger.MonthRange {
        AskLedger.monthRange(from: "2026-11", to: "", now: now, calendar: calendar)
    }

    private func date(day: Int, month: Int = 11) -> Date {
        DateComponents(calendar: calendar, year: 2026, month: month, day: day, hour: 12).date!
    }

    private func insert(_ title: String, _ amount: Double, _ category: String, day: Int, month: Int? = 11) {
        let when = month.map { date(day: day, month: $0) } ?? Date()
        context.insert(Transaction(
            transactionId: UUID().uuidString,
            title: title,
            amount: amount,
            date: when,
            category: category,
            paymentMethod: "Card"
        ))
    }
}
