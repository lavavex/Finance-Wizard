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
