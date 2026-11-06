//
//  AskEvalTests.swift
//  Finance Wizard
//
//  Runs AskEval where tests can reach the on-device model, such as a device with
//  Apple Intelligence. Opt in with TEST_RUNNER_FW_ASK_EVAL=1.
//

import XCTest
import FoundationModels
@testable import FinanceWizard

@MainActor
final class AskEvalTests: XCTestCase {
    func testScoreOnDeviceAsk() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["FW_ASK_EVAL"] == "1",
            "Set TEST_RUNNER_FW_ASK_EVAL=1 on a device with Apple Intelligence."
        )
        guard case .available = SystemLanguageModel.default.availability else {
            throw XCTSkip("Apple Intelligence isn't available here.")
        }
        try await AskEval.run()
    }
}
