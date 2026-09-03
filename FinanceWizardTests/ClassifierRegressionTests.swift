//
//  ClassifierRegressionTests.swift
//  Finance Wizard
//
//  Hosts Shared/Analytics/ClassifierRegression.swift. Changing classify()
//  without updating a failing case is the bug — do not delete the case.
//

import XCTest
@testable import FinanceWizard

@MainActor
final class ClassifierRegressionTests: XCTestCase {
    func testRealDescriptors() {
        let bad = ClassifierRegression.failures()
        XCTAssertTrue(bad.isEmpty, bad.joined(separator: "\n"))
    }

    func testTotalIncomeSkipsRefund() {
        XCTAssertTrue(IncomeAnalytics.isEarnings("Payroll"))
        XCTAssertTrue(IncomeAnalytics.isEarnings("Other Income"))
        XCTAssertFalse(IncomeAnalytics.isEarnings("Refund"))
        XCTAssertFalse(IncomeAnalytics.isEarnings("refund"))
    }
}
