//
//  SyncAndStoreTests.swift
//  Finance Wizard
//
//  Pending → posted edits, missing balances, moving an unreadable store aside, and debug
//  export cleanup. Uses in-memory stores and throwaway folders, never the App Group.
//

import XCTest
import SwiftData
@testable import FinanceWizard

@MainActor
final class SyncAndStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try SharedStore.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    // MARK: - Pending → posted

    func testUserEditsMoveFromPendingRowToPostedRow() throws {
        context.insert(Transaction(
            transactionId: "pending",
            title: "Store",
            amount: -10,
            date: Date(),
            category: "Dining",
            paymentMethod: "Card",
            categoryLocked: true,
            overrideSource: "user",
            paymentRail: "ach",
            paymentRailLocked: true,
            subscriptionCadenceOverride: "monthly"
        ))
        context.insert(Transaction(
            transactionId: "posted",
            title: "Store",
            amount: -10,
            date: Date(),
            category: "Shopping",
            paymentMethod: "Card"
        ))

        let edits = try XCTUnwrap(PlaidSyncEngine.pendingRowEdits(transactionID: "pending", modelContext: context))
        PlaidSyncEngine.applyPendingEdits(edits, toTransactionID: "posted", modelContext: context)

        let posted = try XCTUnwrap(
            context.fetch(FetchDescriptor<Transaction>()).first { $0.transactionId == "posted" }
        )
        XCTAssertEqual(posted.category, "Dining")
        XCTAssertTrue(posted.isCategoryLocked)
        XCTAssertEqual(posted.paymentRail, "ach")
        XCTAssertTrue(posted.isPaymentRailLocked)
        XCTAssertEqual(posted.subscriptionCadenceOverride, "monthly")
        XCTAssertEqual(posted.overrideSource, "user")
    }

    func testPendingRowWithoutEditsCarriesNothing() {
        context.insert(Transaction(
            transactionId: "pending",
            title: "Store",
            amount: -10,
            date: Date(),
            category: "Shopping",
            paymentMethod: "Card"
        ))

        XCTAssertNil(PlaidSyncEngine.pendingRowEdits(transactionID: "pending", modelContext: context))
        XCTAssertNil(PlaidSyncEngine.pendingRowEdits(transactionID: "missing", modelContext: context))
    }

    func testPayoffPlanFollowsPostedRow() throws {
        let plan = PayoffPlan(
            kind: .custom,
            name: "Plan",
            accountId: nil,
            paymentMethod: "Card",
            originalAmount: 100,
            remainingAmount: 100,
            monthlyPayment: 10,
            linkedTransactionId: "pending"
        )
        context.insert(plan)

        PlaidSyncEngine.relinkPayoffPlans(from: "pending", to: "posted", modelContext: context)

        XCTAssertEqual(plan.linkedTransactionId, "posted")
    }

    // MARK: - Balances

    func testMissingBalanceKeepsLastKnownValue() throws {
        let item = PlaidLinkedItem(
            id: "item",
            accessToken: "token",
            institutionName: "Bank",
            accountNames: [],
            transactionsCursor: "",
            linkedAt: Date()
        )
        context.insert(BankAccount(
            accountId: "known",
            itemId: "item",
            name: "Card",
            type: "credit",
            institutionName: "Bank",
            currentBalance: 500
        ))
        let details = try JSONDecoder().decode([PlaidAccountDetail].self, from: Data("""
        [
          {"account_id": "known", "name": "Card", "type": "credit", "balances": {"current": null}},
          {"account_id": "new", "name": "Checking", "type": "depository", "balances": {"current": null, "available": 40}}
        ]
        """.utf8))

        _ = PlaidSyncEngine.upsertAccounts(details, item: item, institutionId: nil, modelContext: context)

        let balances = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<BankAccount>()).map { ($0.accountId, $0.currentBalance) }
        )
        XCTAssertEqual(balances["known"], 500)
        XCTAssertEqual(balances["new"], 40)
    }

    // MARK: - Cleanup

    func testRoutineCleanupKeepsTwoRealDepositsWithTheSameDetails() throws {
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        for id in ["first", "second"] {
            context.insert(Income(
                transactionId: id,
                source: "Venmo",
                amount: 20,
                date: day,
                category: KnownCategory.personToPerson.rawValue,
                accountMask: "1111"
            ))
        }
        try context.save()

        PlaidSyncEngine.cleanupStaleBankAccounts(modelContext: context)

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Income>()), 2)
    }

    // MARK: - Card payments from a bank that hides the payee

    private func bankAndCardRows(_ rows: [(title: String, amount: Double, day: Int, account: String, category: String)]) -> [Transaction] {
        rows.enumerated().map { index, row in
            Transaction(
                transactionId: "row-\(index)",
                title: row.title,
                amount: -row.amount,
                date: Date(timeIntervalSince1970: 1_790_000_000 + Double(row.day) * 86_400),
                category: row.category,
                paymentMethod: row.account,
                plaidAccountId: row.account
            )
        }
    }

    private func paired(_ rows: [Transaction]) -> [String] {
        PlaidSyncEngine.vaguePaymentsMatchingCardPayments(in: rows, creditAccountIds: ["card"]).map(\.transactionId)
    }

    func testVaguePaymentMatchingACardPaymentIsThatPayment() {
        let payment = KnownCategory.creditCardPayment.rawValue
        let rows = bankAndCardRows([
            ("MOBILE PAYMENT - THANK YOU", 100, 6, "card", payment),
            ("ACH PMT", 100, 10, "checking", "Miscellaneous"),
            ("PAYMENT", 177.09, 10, "checking", "Miscellaneous"),
            ("Corner Cafe", 100, 7, "checking", "Dining"),
        ])
        XCTAssertEqual(paired(rows), ["row-1"])
    }

    func testOneCardPaymentExplainsOnlyOneBankRow() {
        let payment = KnownCategory.creditCardPayment.rawValue
        // The card payment already has its bank row, so the vague one is something else.
        let alreadyKnown = bankAndCardRows([
            ("Payment Thank You-Mobile", 100, 6, "card", payment),
            ("EXAMPLE CARD ACH PMT", 100, 6, "checking", payment),
            ("ACH PMT", 100, 8, "checking", "Miscellaneous"),
        ])
        XCTAssertEqual(paired(alreadyKnown), [])

        let twoVague = bankAndCardRows([
            ("Payment Thank You-Mobile", 100, 6, "card", payment),
            ("ACH PMT", 100, 7, "checking", "Miscellaneous"),
            ("ACH PMT", 100, 8, "checking", "Miscellaneous"),
        ])
        XCTAssertEqual(paired(twoVague), ["row-1"])
    }

    func testVaguePaymentFarFromTheCardPaymentOrLockedByTheUserStaysSpending() {
        let payment = KnownCategory.creditCardPayment.rawValue
        let rows = bankAndCardRows([
            ("Payment Thank You-Mobile", 100, 1, "card", payment),
            ("ACH PMT", 100, 20, "checking", "Miscellaneous"),
            ("Payment Thank You-Mobile", 60, 20, "card", payment),
            ("PAYMENT", 60, 21, "checking", "Utilities"),
        ])
        rows[3].categoryLocked = true
        XCTAssertEqual(paired(rows), [])
    }

    func testPairingRefilesTheBankRowWithoutASecondPaymentRecord() throws {
        context.insert(BankAccount(
            accountId: "card", itemId: "item", name: "Example Card", mask: "1111", type: "credit",
            institutionName: "Example Bank", currentBalance: 500
        ))
        for row in bankAndCardRows([
            ("MOBILE PAYMENT - THANK YOU", 100, 6, "card", KnownCategory.creditCardPayment.rawValue),
            ("ACH PMT", 100, 10, "checking", "Miscellaneous"),
        ]) {
            context.insert(row)
        }
        try context.save()

        XCTAssertEqual(PlaidSyncEngine.pairVaguePaymentsWithCards(modelContext: context), 1)
        XCTAssertEqual(PlaidSyncEngine.pairVaguePaymentsWithCards(modelContext: context), 0)

        let bank = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first { $0.title == "ACH PMT" })
        XCTAssertEqual(bank.category, KnownCategory.creditCardPayment.rawValue)
        XCTAssertTrue(bank.isCategoryLocked)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CreditCardPayment>()), 0)
    }

    // MARK: - Paychecks known only by a payroll code

    private func paycheck(_ source: String, raw: String?, pfc: String? = "INCOME_SALARY") -> Income {
        Income(
            transactionId: UUID().uuidString, source: source, amount: 600,
            date: Date(timeIntervalSince1970: 1_790_000_000), category: "Payroll", rawName: raw, pfc: pfc
        )
    }

    func testPaycheckTakesTheEmployerNamedOnAnotherBanksLine() throws {
        context.insert(paycheck("Example Market", raw: "EXAMPLE MARKET CORP PAYROLLEXM PPD ID: 1234567890"))
        context.insert(paycheck("PAYROLLEXM", raw: "PAYROLLEXM"))
        context.insert(paycheck("EXM CORPORATION PAYROLLEXM PPD ID: 1234567890", raw: "EXM CORPORATION PAYROLLEXM PPD ID: 1234567890"))
        context.insert(paycheck("OTHERCODE99", raw: "OTHERCODE99"))
        context.insert(paycheck("PAYROLLEXM", raw: "PAYROLLEXM", pfc: "TRANSFER_IN_DEPOSIT"))
        try context.save()

        XCTAssertEqual(PlaidSyncEngine.nameIncomeByPayrollCode(modelContext: context), 2)

        let sources = try context.fetch(FetchDescriptor<Income>()).map(\.source).sorted()
        XCTAssertEqual(sources, ["Example Market", "Example Market", "Example Market", "OTHERCODE99", "PAYROLLEXM"])
    }

    func testCodeSharedByTwoEmployersNamesNobody() {
        let employers = PlaidSyncEngine.employersByPayrollCode([
            ("Example Market", "EXAMPLE MARKET SHAREDCODE"),
            ("Example Diner", "EXAMPLE DINER SHAREDCODE DIRECTDEP"),
        ])
        XCTAssertNil(employers["SHAREDCODE"])
        XCTAssertNil(employers["DIRECTDEP"])
        XCTAssertEqual(employers["EXAMPLE"], nil)
    }

    // MARK: - Unreadable store

    func testMoveStoreAsideKeepsFilesAndReplacesOlderCopy() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let store = "\(SharedStore.storeName).store"
        for name in [store, "\(store)-wal", "AskChat.store"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }

        XCTAssertTrue(try SharedStore.moveStoreAside(in: folder))

        let recovered = folder.appendingPathComponent("Recovered store")
        XCTAssertEqual(try Data(contentsOf: recovered.appendingPathComponent(store)), Data(store.utf8))
        XCTAssertTrue(manager.fileExists(atPath: recovered.appendingPathComponent("\(store)-wal").path))
        XCTAssertFalse(manager.fileExists(atPath: folder.appendingPathComponent(store).path))
        XCTAssertTrue(manager.fileExists(atPath: folder.appendingPathComponent("AskChat.store").path))

        try Data("newer".utf8).write(to: folder.appendingPathComponent(store))
        XCTAssertTrue(try SharedStore.moveStoreAside(in: folder))
        XCTAssertEqual(try Data(contentsOf: recovered.appendingPathComponent(store)), Data("newer".utf8))
        XCTAssertFalse(manager.fileExists(atPath: recovered.appendingPathComponent("\(store)-wal").path))
    }

    func testMoveStoreAsideReportsWhenThereIsNothingToMove() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }

        XCTAssertFalse(try SharedStore.moveStoreAside(in: folder))
    }

    // MARK: - Debug export

    func testDebugExportCleanupRemovesOnlyExportFiles() throws {
        let temp = FileManager.default.temporaryDirectory
        let export = temp.appendingPathComponent("FinanceWizard-debug-\(UUID().uuidString)", isDirectory: true)
        let zip = temp.appendingPathComponent("FinanceWizard-debug-\(UUID().uuidString).zip")
        let other = temp.appendingPathComponent("other-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: zip)
        try Data("x".utf8).write(to: other)

        DebugDataExporter.discardTemporaryFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }
}
