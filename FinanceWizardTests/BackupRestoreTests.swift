//
//  BackupRestoreTests.swift
//  Finance Wizard
//
//  Restore merge rules, backup encryption, temporary files, and Keychain writes.
//  Hosted in the app: only the wipe tests touch global state, and they are opt-in.
//

import XCTest
import SwiftData
@testable import FinanceWizard

@MainActor
final class BackupRestoreTests: XCTestCase {
    private typealias Backup = PlaidConnectionBackup

    private let linkedItem = "item-linked"
    private let newItem = "item-new"
    private let linkedAccount = "account-linked"
    private let newAccount = "account-new"

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try SharedStore.makeContainer(inMemory: true)
        context = ModelContext(container)
    }

    // MARK: - Safe merge

    func testSafeMergeLeavesNewerRowsForLinkedBankAlone() throws {
        context.insert(Transaction(
            transactionId: "tx",
            title: "Posted",
            amount: -50,
            date: day(2),
            category: "Dining",
            paymentMethod: "Card",
            plaidAccountId: linkedAccount
        ))
        context.insert(Income(transactionId: "pay", source: "Current", amount: 200, date: day(2), category: "Payroll"))
        context.insert(CreditCardPayment(transactionId: "cc", amount: 75, date: day(2), cardName: "Current", title: "Current"))
        context.insert(BankAccount(
            accountId: linkedAccount,
            itemId: linkedItem,
            name: "Current",
            mask: "1111",
            type: "credit",
            institutionName: "Linked Bank",
            currentBalance: 999,
            lastSyncedAt: day(1)
        ))
        try context.save()

        var payload = emptyPayload()
        payload.items = [item(linkedItem, institution: "Linked Bank")]
        payload.bankAccounts = [account(linkedAccount, item: linkedItem, institution: "Linked Bank", mask: "1111", syncedAt: day(0))]
        payload.transactions = [transaction("tx", account: linkedAccount, amount: -40, title: "Pending")]
        payload.income = [income("pay", mask: "1111", amount: 1)]
        payload.creditCardPayments = [cardPayment("cc", account: linkedAccount, institution: "Linked Bank", amount: 1)]

        let counts = try merge(payload, policy: .safeMerge, protecting: [linkedItem])

        XCTAssertEqual(counts.transactions + counts.income + counts.payments + counts.bankAccounts, 0)
        let tx = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(tx.amount, -50)
        XCTAssertEqual(tx.title, "Posted")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Income>()).first?.amount, 200)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CreditCardPayment>()).first?.amount, 75)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BankAccount>()).first?.currentBalance, 999)
    }

    func testSafeMergeDoesNotBringBackRowsTheLinkedBankRemoved() throws {
        var payload = emptyPayload()
        payload.items = [item(linkedItem, institution: "Linked Bank")]
        payload.bankAccounts = [account(linkedAccount, item: linkedItem, institution: "Linked Bank", mask: "1111")]
        payload.transactions = [transaction("removed", account: linkedAccount)]
        payload.income = [income("removed-income", mask: "1111")]
        payload.creditCardPayments = [cardPayment("removed-payment", account: linkedAccount, institution: "Linked Bank")]

        try merge(payload, policy: .safeMerge, protecting: [linkedItem])

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Income>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CreditCardPayment>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BankAccount>()), 0)
    }

    func testSafeMergeAddsRowsForBankNotOnThisDevice() throws {
        var payload = emptyPayload()
        payload.items = [item(linkedItem, institution: "Linked Bank"), item(newItem, institution: "New Bank")]
        payload.bankAccounts = [
            account(linkedAccount, item: linkedItem, institution: "Linked Bank", mask: "1111"),
            account(newAccount, item: newItem, institution: "New Bank", mask: "2222")
        ]
        payload.transactions = [
            transaction("linked-tx", account: linkedAccount),
            transaction("new-tx", account: newAccount)
        ]
        payload.income = [income("new-income", mask: "2222")]
        payload.creditCardPayments = [cardPayment("new-payment", account: newAccount, institution: "New Bank")]

        let counts = try merge(payload, policy: .safeMerge, protecting: [linkedItem])

        XCTAssertEqual(counts.transactions, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).map(\.transactionId), ["new-tx"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<BankAccount>()).map(\.accountId), [newAccount])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Income>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CreditCardPayment>()), 1)
    }

    func testSafeMergeTellsTwoLoginsAtOneBankApartByLastFour() throws {
        var payload = emptyPayload()
        payload.items = [item(linkedItem, institution: "Same Bank"), item(newItem, institution: "Same Bank")]
        payload.bankAccounts = [
            account(linkedAccount, item: linkedItem, institution: "Same Bank", mask: "1111"),
            account(newAccount, item: newItem, institution: "Same Bank", mask: "2222")
        ]
        payload.income = [
            income("linked-income", mask: "1111"),
            income("new-income", mask: "2222")
        ]

        try merge(payload, policy: .safeMerge, protecting: [linkedItem])

        XCTAssertEqual(try context.fetch(FetchDescriptor<Income>()).map(\.transactionId), ["new-income"])
    }

    func testSafeMergeMatchesOlderRowsWithoutAccountIDsByLabel() throws {
        var payload = emptyPayload()
        payload.items = [item(linkedItem, institution: "Linked Bank")]
        payload.bankAccounts = [account(linkedAccount, item: linkedItem, institution: "Linked Bank", mask: "1111")]
        payload.transactions = [
            transaction("no-id", account: nil, paymentMethod: "Backup account ···1111"),
            transaction("bank-label", account: nil, paymentMethod: "Linked Bank")
        ]
        var payment = cardPayment("no-id-payment", account: linkedAccount, institution: "Linked Bank")
        payment.creditAccountId = nil
        payload.creditCardPayments = [payment]

        try merge(payload, policy: .safeMerge, protecting: [linkedItem])

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Transaction>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CreditCardPayment>()), 0)
    }

    func testSafeMergeKeepsImportedRowsThatMatchNoBank() throws {
        var payload = emptyPayload()
        payload.items = [item(linkedItem, institution: "Linked Bank")]
        payload.bankAccounts = [account(linkedAccount, item: linkedItem, institution: "Linked Bank", mask: "1111")]
        payload.transactions = [transaction("imported", account: nil, paymentMethod: "Apple Card")]

        try merge(payload, policy: .safeMerge, protecting: [linkedItem])

        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).map(\.transactionId), ["imported"])
    }

    func testPlansTakeBackupCopyOnlyWhenNewer() throws {
        context.insert(BudgetPlan(planId: "newer-here", monthlyLimit: 100, updatedAt: day(1)))
        context.insert(BudgetPlan(planId: "newer-in-backup", monthlyLimit: 100, updatedAt: day(5)))
        try context.save()

        var payload = emptyPayload()
        payload.budgetPlans = [
            budgetPlan("newer-here", limit: 1, updatedAt: day(5)),
            budgetPlan("newer-in-backup", limit: 1, updatedAt: day(1))
        ]

        try merge(payload, policy: .safeMerge, protecting: [])

        let limits = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<BudgetPlan>()).map { ($0.planId, $0.monthlyLimit) }
        )
        XCTAssertEqual(limits["newer-here"], 100)
        XCTAssertEqual(limits["newer-in-backup"], 1)
    }

    // MARK: - Replace connections

    func testReplaceConnectionsLetsBackupWinButKeepsCategoryLock() throws {
        context.insert(Transaction(
            transactionId: "locked",
            title: "My title",
            amount: -50,
            date: day(1),
            category: "Dining",
            paymentMethod: "Card",
            categoryLocked: true,
            plaidAccountId: linkedAccount
        ))
        try context.save()

        var payload = emptyPayload()
        payload.items = [item(linkedItem, institution: "Linked Bank")]
        payload.bankAccounts = [account(linkedAccount, item: linkedItem, institution: "Linked Bank", mask: "1111")]
        payload.transactions = [transaction("locked", account: linkedAccount, amount: -40, title: "Bank title")]

        let counts = try merge(payload, policy: .replaceConnections, protecting: [])

        XCTAssertEqual(counts.transactions, 1)
        let tx = try XCTUnwrap(context.fetch(FetchDescriptor<Transaction>()).first)
        XCTAssertEqual(tx.amount, -40)
        XCTAssertEqual(tx.title, "My title")
        XCTAssertEqual(tx.category, "Dining")
    }

    // MARK: - Encryption

    func testEncryptedBackupRoundTrips() throws {
        var payload = emptyPayload()
        payload.credentials.secret = "test-secret"
        payload.transactions = [transaction("tx", account: linkedAccount)]

        let data = try Backup.encrypt(payload: payload, password: "correct horse")

        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-secret"))
        XCTAssertEqual(try Backup.decrypt(envelopeData: data, password: "correct horse"), payload)
    }

    func testWrongPasswordIsRejected() throws {
        let data = try Backup.encrypt(payload: emptyPayload(), password: "correct horse")

        XCTAssertThrowsError(try Backup.decrypt(envelopeData: data, password: "wrong horse")) { error in
            XCTAssertEqual(error.localizedDescription, Backup.BackupError.wrongPassword.localizedDescription)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let data = try Backup.encrypt(payload: emptyPayload(), password: "correct horse")
        var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var bytes = try XCTUnwrap(Data(base64Encoded: envelope["ciphertext"] as! String))
        bytes[0] ^= 0xFF
        envelope["ciphertext"] = bytes.base64EncodedString()
        let tampered = try JSONSerialization.data(withJSONObject: envelope)

        XCTAssertThrowsError(try Backup.decrypt(envelopeData: tampered, password: "correct horse")) { error in
            XCTAssertEqual(error.localizedDescription, Backup.BackupError.invalidFile.localizedDescription)
        }
    }

    func testUnexpectedIterationCountsAreRejectedWithoutRunningThem() throws {
        let data = try Backup.encrypt(payload: emptyPayload(), password: "correct horse")
        // Past UInt32.max, large enough to stall, too low, and invalid.
        for iterations in [5_000_000_000, 4_000_000_000, 1, 0, -1] {
            var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            envelope["iterations"] = iterations
            let crafted = try JSONSerialization.data(withJSONObject: envelope)

            XCTAssertThrowsError(try Backup.decrypt(envelopeData: crafted, password: "correct horse")) { error in
                XCTAssertEqual(error.localizedDescription, Backup.BackupError.invalidFile.localizedDescription)
            }
        }
    }

    // MARK: - Temporary files

    func testDiscardDeletesOnlyAppMadeBackupCopies() throws {
        let temp = FileManager.default.temporaryDirectory
        let incoming = temp.appendingPathComponent("incoming-\(UUID().uuidString)-a.fwbackup")
        let unrelated = temp.appendingPathComponent("unrelated-\(UUID().uuidString).fwbackup")
        let folder = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let picked = folder.appendingPathComponent("incoming-picked.fwbackup")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: unrelated)
            try? FileManager.default.removeItem(at: folder)
        }
        for url in [incoming, unrelated, picked] {
            try Data("x".utf8).write(to: url)
        }

        Backup.discardTemporaryFile(incoming)
        Backup.discardTemporaryFile(unrelated)
        Backup.discardTemporaryFile(picked)
        Backup.discardTemporaryFile(nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path))
    }

    func testPurgeClearsLeftoverCopiesOnly() throws {
        let temp = FileManager.default.temporaryDirectory
        let incoming = temp.appendingPathComponent("incoming-\(UUID().uuidString)-a.fwbackup")
        let export = temp.appendingPathComponent("FinanceWizard-backup-\(UUID().uuidString).fwbackup")
        let other = temp.appendingPathComponent("incoming-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: other) }
        for url in [incoming, export, other] {
            try Data("x".utf8).write(to: url)
        }

        Backup.purgeTemporaryFiles()

        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: - Keychain

    func testKeychainSetReplacesExistingValue() throws {
        let account = "test.\(UUID().uuidString)"
        defer { PlaidKeychain.delete(account: account) }

        try PlaidKeychain.set("first", account: account)
        try PlaidKeychain.set("second", account: account)

        XCTAssertEqual(PlaidKeychain.get(account: account), "second")
    }

    // MARK: - Rollback

    func testRollbackReturnsWorkResultWithoutUndoing() throws {
        var undone = false
        let value = try Backup.runWithRollback({ 7 }, undo: { undone = true })

        XCTAssertEqual(value, 7)
        XCTAssertFalse(undone)
    }

    func testFailedWorkRunsUndoAndSaysDataWasPutBack() {
        var undone = false
        XCTAssertThrowsError(
            try Backup.runWithRollback({ throw Backup.BackupError.invalidFile }, undo: { undone = true }) as Int
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("previous data was put back"))
        }
        XCTAssertTrue(undone)
    }

    func testFailedUndoSaysDataWasNotPutBack() {
        XCTAssertThrowsError(
            try Backup.runWithRollback(
                { throw Backup.BackupError.invalidFile },
                undo: { throw Backup.BackupError.emptyPayload }
            ) as Int
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not be put back"))
        }
    }

    // MARK: - Wipe then restore (deletes this simulator's app data; opt-in)

    func testFailedWipeRestorePutsPreviousDataBack() throws {
        try requireDisposableSimulator()
        defer { PlaidItemStore.removeAll() }
        try seedPreviousData()

        var payload = emptyPayload()
        payload.items = [item(newItem, institution: "New Bank")]
        payload.transactions = [transaction("backup-tx", account: newAccount)]

        XCTAssertThrowsError(
            try Backup.apply(
                payload: payload,
                policy: .wipeThenRestore,
                modelContext: context,
                beforeCommit: { throw Backup.BackupError.invalidFile }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("previous data was put back"))
        }

        XCTAssertEqual(PlaidItemStore.loadItems().map(\.id), [linkedItem])
        XCTAssertEqual(PlaidItemStore.loadItems().first?.accessToken, "token-previous")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).map(\.transactionId), ["previous-tx"])
    }

    func testWipeRestoreReplacesPreviousData() throws {
        try requireDisposableSimulator()
        defer { PlaidItemStore.removeAll() }
        try seedPreviousData()

        var payload = emptyPayload()
        payload.items = [item(newItem, institution: "New Bank")]
        payload.transactions = [transaction("backup-tx", account: newAccount)]

        try Backup.apply(payload: payload, policy: .wipeThenRestore, modelContext: context)

        XCTAssertEqual(PlaidItemStore.loadItems().map(\.id), [newItem])
        XCTAssertEqual(try context.fetch(FetchDescriptor<Transaction>()).map(\.transactionId), ["backup-tx"])
    }

    // MARK: - Helpers

    private func requireDisposableSimulator() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FW_DESTRUCTIVE_TESTS"] == "1",
            "Deletes app data. Set TEST_RUNNER_FW_DESTRUCTIVE_TESTS=1 on a simulator with no real data."
        )
        guard !PlaidItemStore.hasLinkedItems, PlaidCredentialsStore.secret.isEmpty else {
            throw XCTSkip("A bank or API key is on this simulator, so it may hold real data.")
        }
    }

    private func seedPreviousData() throws {
        try PlaidItemStore.upsert(PlaidLinkedItem(
            id: linkedItem,
            accessToken: "token-previous",
            institutionName: "Linked Bank",
            accountNames: [],
            transactionsCursor: "cursor-previous",
            linkedAt: day(30)
        ))
        context.insert(Transaction(
            transactionId: "previous-tx",
            title: "Previous",
            amount: -1,
            date: day(1),
            category: "Dining",
            paymentMethod: "Card"
        ))
        try context.save()
    }

    @discardableResult
    private func merge(
        _ payload: Backup.Payload,
        policy: Backup.RestorePolicy,
        protecting items: Set<String>
    ) throws -> Backup.AppDataCounts {
        let counts = try Backup.mergeAppData(
            payload,
            policy: policy,
            protectedItemIDs: items,
            modelContext: context
        )
        try context.save()
        return counts
    }

    private func emptyPayload() -> Backup.Payload {
        Backup.Payload(
            version: Backup.formatVersion,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            credentials: Backup.CredentialsSnapshot(
                clientID: "",
                secret: "",
                environment: "sandbox",
                redirectURIOverride: ""
            ),
            items: [],
            transactions: [],
            income: [],
            bankAccounts: [],
            creditCardPayments: [],
            budgetPlans: [],
            payoffPlans: [],
            cardLabels: [:],
            vendorRules: [],
            screenshotPrivacy: false,
            preferenceDefaults: [:],
            logoFiles: [:]
        )
    }

    private func item(_ id: String, institution: String) -> Backup.ItemSnapshot {
        Backup.ItemSnapshot(
            id: id,
            accessToken: "token-\(id)",
            institutionName: institution,
            accountNames: [],
            transactionsCursor: "cursor-\(id)",
            linkedAt: day(30)
        )
    }

    private func account(
        _ id: String,
        item: String,
        institution: String,
        mask: String,
        syncedAt: Date? = nil
    ) -> Backup.BankAccountSnapshot {
        Backup.BankAccountSnapshot(
            accountId: id,
            itemId: item,
            name: "Backup account",
            mask: mask,
            type: "credit",
            institutionName: institution,
            currentBalance: 1,
            lastSyncedAt: syncedAt ?? day(10)
        )
    }

    private func transaction(
        _ id: String,
        account: String?,
        amount: Double = -1,
        title: String = "Backup",
        paymentMethod: String = "Card"
    ) -> Backup.TransactionSnapshot {
        Backup.TransactionSnapshot(
            transactionId: id,
            title: title,
            amount: amount,
            date: Date(timeIntervalSince1970: 1_790_000_000),
            category: "Shopping",
            paymentMethod: paymentMethod,
            plaidAccountId: account
        )
    }

    /// Same shape sync writes: `sourceInstitution` holds the account name, not the bank.
    private func income(_ id: String, mask: String, amount: Double = 1) -> Backup.IncomeSnapshot {
        Backup.IncomeSnapshot(
            transactionId: id,
            source: "Backup",
            amount: amount,
            date: day(10),
            category: "Payroll",
            accountName: "Backup account",
            accountMask: mask,
            sourceInstitution: "Backup account",
            pending: false,
            kind: "income"
        )
    }

    private func cardPayment(
        _ id: String,
        account: String,
        institution: String,
        amount: Double = 1
    ) -> Backup.PaymentSnapshot {
        Backup.PaymentSnapshot(
            transactionId: id,
            amount: amount,
            date: day(10),
            cardName: "Backup",
            title: "Backup",
            creditAccountId: account,
            institutionName: institution
        )
    }

    private func budgetPlan(_ id: String, limit: Double, updatedAt: Date) -> Backup.BudgetPlanSnapshot {
        Backup.BudgetPlanSnapshot(
            planId: id,
            monthlyLimit: limit,
            categoryLimits: [:],
            expectedIncome: [],
            updatedAt: updatedAt
        )
    }

    private func day(_ daysAgo: Int) -> Date {
        Date().addingTimeInterval(-Double(daysAgo) * 86_400)
    }
}
