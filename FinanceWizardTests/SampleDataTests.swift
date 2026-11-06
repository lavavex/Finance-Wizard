//
//  SampleDataTests.swift
//  Finance Wizard
//
//  "Try with sample data" must stay away from real data, and App Store builds hide developer tools.
//

import XCTest
import StoreKit
import SwiftData
@testable import FinanceWizard

@MainActor
final class SampleDataTests: XCTestCase {
    override func tearDown() {
        DemoMode.isSampleActive = false
        AskStore.useSampleChat(false)
    }

    func testSampleStoreHasRowsAndIsInMemory() throws {
        let container = try DemoMode.makeSeededContainer()
        XCTAssertTrue(container.configurations.allSatisfy(\.isStoredInMemoryOnly))
        XCTAssertFalse(try ModelContext(container).fetch(FetchDescriptor<FinanceWizard.Transaction>()).isEmpty)
    }

    func testSyncBackupAndWipeAreBlocked() async throws {
        DemoMode.isSampleActive = true
        let context = ModelContext(try DemoMode.makeSeededContainer())

        do {
            _ = try await PlaidSyncEngine.syncAll(modelContext: context)
            XCTFail("Sync should be blocked")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("sample data"), error.localizedDescription)
        }
        XCTAssertThrowsError(try PlaidConnectionBackup.wipeLocalAppData(modelContext: context))
        XCTAssertFalse(try context.fetch(FetchDescriptor<FinanceWizard.Transaction>()).isEmpty, "Wipe must not have run")
        XCTAssertThrowsError(try PlaidConnectionBackup.exportEncryptedFile(password: "long enough", modelContext: context))
        XCTAssertThrowsError(try PlaidConnectionBackup.decryptPayload(
            from: URL(fileURLWithPath: "/nonexistent.fwbackup"),
            password: "long enough"
        ))
    }

    func testSampleChatIsSeparateFromSavedChat() throws {
        let saved = AskStore.container
        AskStore.useSampleChat(true)
        XCTAssertFalse(AskStore.container === saved)
        XCTAssertTrue(AskStore.container.configurations.allSatisfy(\.isStoredInMemoryOnly))
        AskStore.useSampleChat(false)
        XCTAssertTrue(AskStore.container === saved)
    }

    func testDeveloperToolsAreHiddenInAppStoreBuilds() {
        XCTAssertFalse(DeveloperTools.isAvailable(in: .production))
        XCTAssertFalse(DeveloperTools.isAvailable(in: nil))
        XCTAssertTrue(DeveloperTools.isAvailable(in: .sandbox))
        XCTAssertTrue(DeveloperTools.isAvailable(in: .xcode))
    }
}
