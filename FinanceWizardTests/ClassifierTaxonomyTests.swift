//
//  ClassifierTaxonomyTests.swift
//  Finance Wizard
//
//  Runs Plaid's published personal finance categories through the mapper, plus payroll
//  relabeling, which needs more than one row.
//  https://plaid.com/documents/transactions-personal-finance-category-taxonomy.csv
//

import XCTest
import SwiftData
@testable import FinanceWizard

@MainActor
final class ClassifierTaxonomyTests: XCTestCase {
    /// Every outbound detailed category, with what it must become when no other rule applies.
    private static let spendCategories: [String: KnownCategory] = [
        "LOAN_PAYMENTS_CAR_PAYMENT": .miscellaneous,
        "LOAN_PAYMENTS_PERSONAL_LOAN_PAYMENT": .miscellaneous,
        "LOAN_PAYMENTS_MORTGAGE_PAYMENT": .housing,
        "LOAN_PAYMENTS_STUDENT_LOAN_PAYMENT": .education,
        "LOAN_PAYMENTS_OTHER_PAYMENT": .miscellaneous,
        "BANK_FEES_ATM_FEES": .fees,
        "BANK_FEES_FOREIGN_TRANSACTION_FEES": .fees,
        "BANK_FEES_INSUFFICIENT_FUNDS": .fees,
        "BANK_FEES_INTEREST_CHARGE": .fees,
        "BANK_FEES_OVERDRAFT_FEES": .fees,
        "BANK_FEES_OTHER_BANK_FEES": .fees,
        "ENTERTAINMENT_CASINOS_AND_GAMBLING": .entertainment,
        "ENTERTAINMENT_MUSIC_AND_AUDIO": .entertainment,
        "ENTERTAINMENT_SPORTING_EVENTS_AMUSEMENT_PARKS_AND_MUSEUMS": .entertainment,
        "ENTERTAINMENT_TV_AND_MOVIES": .entertainment,
        "ENTERTAINMENT_VIDEO_GAMES": .entertainment,
        "ENTERTAINMENT_OTHER_ENTERTAINMENT": .entertainment,
        "FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR": .dining,
        "FOOD_AND_DRINK_COFFEE": .dining,
        "FOOD_AND_DRINK_FAST_FOOD": .dining,
        "FOOD_AND_DRINK_GROCERIES": .groceries,
        "FOOD_AND_DRINK_RESTAURANT": .dining,
        "FOOD_AND_DRINK_VENDING_MACHINES": .dining,
        "FOOD_AND_DRINK_OTHER_FOOD_AND_DRINK": .dining,
        "GENERAL_MERCHANDISE_BOOKSTORES_AND_NEWSSTANDS": .shopping,
        "GENERAL_MERCHANDISE_CLOTHING_AND_ACCESSORIES": .shopping,
        "GENERAL_MERCHANDISE_CONVENIENCE_STORES": .shopping,
        "GENERAL_MERCHANDISE_DEPARTMENT_STORES": .shopping,
        "GENERAL_MERCHANDISE_DISCOUNT_STORES": .shopping,
        "GENERAL_MERCHANDISE_ELECTRONICS": .shopping,
        "GENERAL_MERCHANDISE_GIFTS_AND_NOVELTIES": .giftsDonations,
        "GENERAL_MERCHANDISE_OFFICE_SUPPLIES": .shopping,
        "GENERAL_MERCHANDISE_ONLINE_MARKETPLACES": .shopping,
        "GENERAL_MERCHANDISE_PET_SUPPLIES": .pets,
        "GENERAL_MERCHANDISE_SPORTING_GOODS": .entertainment,
        "GENERAL_MERCHANDISE_SUPERSTORES": .shopping,
        "GENERAL_MERCHANDISE_TOBACCO_AND_VAPE": .shopping,
        "GENERAL_MERCHANDISE_OTHER_GENERAL_MERCHANDISE": .shopping,
        "HOME_IMPROVEMENT_FURNITURE": .homeImprovement,
        "HOME_IMPROVEMENT_HARDWARE": .homeImprovement,
        "HOME_IMPROVEMENT_REPAIR_AND_MAINTENANCE": .homeImprovement,
        "HOME_IMPROVEMENT_SECURITY": .homeImprovement,
        "HOME_IMPROVEMENT_OTHER_HOME_IMPROVEMENT": .homeImprovement,
        "MEDICAL_DENTAL_CARE": .health,
        "MEDICAL_EYE_CARE": .health,
        "MEDICAL_NURSING_CARE": .health,
        "MEDICAL_PHARMACIES_AND_SUPPLEMENTS": .health,
        "MEDICAL_PRIMARY_CARE": .health,
        "MEDICAL_VETERINARY_SERVICES": .pets,
        "MEDICAL_OTHER_MEDICAL": .health,
        "PERSONAL_CARE_GYMS_AND_FITNESS_CENTERS": .personalCare,
        "PERSONAL_CARE_HAIR_AND_BEAUTY": .personalCare,
        "PERSONAL_CARE_LAUNDRY_AND_DRY_CLEANING": .personalCare,
        "PERSONAL_CARE_OTHER_PERSONAL_CARE": .personalCare,
        "GENERAL_SERVICES_ACCOUNTING_AND_FINANCIAL_PLANNING": .shopping,
        "GENERAL_SERVICES_AUTOMOTIVE": .shopping,
        "GENERAL_SERVICES_CHILDCARE": .shopping,
        "GENERAL_SERVICES_CONSULTING_AND_LEGAL": .shopping,
        "GENERAL_SERVICES_EDUCATION": .education,
        "GENERAL_SERVICES_INSURANCE": .insurance,
        "GENERAL_SERVICES_POSTAGE_AND_SHIPPING": .shopping,
        "GENERAL_SERVICES_STORAGE": .shopping,
        "GENERAL_SERVICES_OTHER_GENERAL_SERVICES": .shopping,
        "GOVERNMENT_AND_NON_PROFIT_DONATIONS": .giftsDonations,
        "GOVERNMENT_AND_NON_PROFIT_GOVERNMENT_DEPARTMENTS_AND_AGENCIES": .miscellaneous,
        "GOVERNMENT_AND_NON_PROFIT_TAX_PAYMENT": .miscellaneous,
        "GOVERNMENT_AND_NON_PROFIT_OTHER_GOVERNMENT_AND_NON_PROFIT": .miscellaneous,
        "TRANSPORTATION_BIKES_AND_SCOOTERS": .transit,
        "TRANSPORTATION_GAS": .gas,
        "TRANSPORTATION_PARKING": .transit,
        "TRANSPORTATION_PUBLIC_TRANSIT": .transit,
        "TRANSPORTATION_TAXIS_AND_RIDE_SHARES": .transit,
        "TRANSPORTATION_TOLLS": .transit,
        "TRANSPORTATION_OTHER_TRANSPORTATION": .transit,
        "TRAVEL_FLIGHTS": .travel,
        "TRAVEL_LODGING": .travel,
        "TRAVEL_RENTAL_CARS": .travel,
        "TRAVEL_OTHER_TRAVEL": .travel,
        "RENT_AND_UTILITIES_GAS_AND_ELECTRICITY": .utilities,
        "RENT_AND_UTILITIES_INTERNET_AND_CABLE": .homeInternet,
        "RENT_AND_UTILITIES_RENT": .housing,
        "RENT_AND_UTILITIES_SEWAGE_AND_WASTE_MANAGEMENT": .utilities,
        "RENT_AND_UTILITIES_TELEPHONE": .homeInternet,
        "RENT_AND_UTILITIES_WATER": .utilities,
        "RENT_AND_UTILITIES_OTHER_UTILITIES": .utilities
    ]

    func testEverySpendCategoryInPlaidsListMapsCorrectly() {
        for (detailed, expected) in Self.spendCategories {
            let primary = Self.primary(of: detailed)
            let pfc = PlaidPFC(primary: primary, detailed: detailed, confidence_level: nil)
            XCTAssertEqual(
                PlaidCategoryMapper.expenseCategory(from: pfc, title: "Example Merchant"),
                expected.rawValue,
                detailed
            )
            XCTAssertEqual(
                PlaidCategoryMapper.classify(
                    amount: 10,
                    pfc: pfc,
                    title: "Example Merchant",
                    accountType: "credit",
                    accountSubtype: "credit card"
                ),
                .spending,
                detailed
            )
        }
    }

    func testPlainTransfersStayOutOfSpendAndIncome() {
        for detailed in [
            "TRANSFER_OUT_SAVINGS", "TRANSFER_OUT_ACCOUNT_TRANSFER", "TRANSFER_OUT_WITHDRAWAL",
            "TRANSFER_IN_SAVINGS", "TRANSFER_IN_ACCOUNT_TRANSFER"
        ] {
            let pfc = PlaidPFC(primary: Self.primary(of: detailed), detailed: detailed, confidence_level: nil)
            XCTAssertEqual(
                PlaidCategoryMapper.classify(
                    amount: detailed.hasPrefix("TRANSFER_OUT") ? 50 : -50,
                    pfc: pfc,
                    title: "Example Bank Move",
                    accountType: "depository",
                    accountSubtype: "checking"
                ),
                .transfer,
                detailed
            )
        }
    }

    func testBalanceTransferAndPersonToPersonSpendTotals() {
        XCTAssertTrue(TransactionAnalytics.isExcludedFromSpendCategory(KnownCategory.balanceTransfer.rawValue))
        XCTAssertFalse(TransactionAnalytics.isExcludedFromSpendCategory(KnownCategory.personToPerson.rawValue))
        XCTAssertFalse(IncomeAnalytics.isEarnings(KnownCategory.personToPerson.rawValue))
    }

    func testNewCategoriesAreRecognized() {
        XCTAssertEqual(KnownCategory.canonicalName(for: "insurance"), KnownCategory.insurance.rawValue)
        XCTAssertEqual(KnownCategory.canonicalName(for: "auto insurance"), KnownCategory.carInsurance.rawValue)
        XCTAssertEqual(KnownCategory.canonicalName(for: "Balance Transfer"), KnownCategory.balanceTransfer.rawValue)
    }

    func testRepairPassKeepsPersonToPersonRows() {
        XCTAssertFalse(PlaidCategoryMapper.looksLikeNonSpendTitle("Zelle transfer from a friend"))
        XCTAssertTrue(PlaidCategoryMapper.looksLikeNonSpendTitle("Online transfer to savings"))
    }

    func testInsuranceBillWithChangingAmountIsRecurring() throws {
        let context = try makeContext()
        let calendar = Calendar.current
        for (index, amount) in [120.0, 131.5, 118.25, 140.0].enumerated() {
            context.insert(Transaction(
                transactionId: "insurance-\(index)",
                title: "Example Insurer",
                amount: -amount,
                date: try XCTUnwrap(calendar.date(byAdding: .day, value: -30 * index, to: Date())),
                category: KnownCategory.insurance.rawValue,
                paymentMethod: "Card"
            ))
        }

        let rows = try context.fetch(FetchDescriptor<Transaction>())

        XCTAssertEqual(SubscriptionAnalytics.detect(in: rows).first?.cadence, .monthly)
    }

    // MARK: - Payroll

    func testPaycheckSizedDepositsFromAKnownPayrollSourceBecomePayroll() throws {
        let context = try makeContext()
        insertIncome("salary", source: "Example Employer", amount: 800, category: "Payroll", pfc: "INCOME_SALARY", in: context)
        insertIncome("mistagged", source: "example employer ", amount: 760, category: "Other Income", pfc: "TRANSPORTATION_GAS", in: context)
        insertIncome("store-refund", source: "Example Employer", amount: 12, category: "Other Income", pfc: "GENERAL_MERCHANDISE_CONVENIENCE_STORES", in: context)
        insertIncome("contractor", source: "Example Employer", amount: 700, category: "Other Income", pfc: "INCOME_CONTRACTOR", in: context)
        insertIncome("elsewhere", source: "Another Source", amount: 900, category: "Other Income", pfc: "OTHER_OTHER", in: context)

        XCTAssertEqual(PlaidSyncEngine.relabelPayrollDeposits(modelContext: context), 1)

        let categories = Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<Income>()).map { ($0.transactionId, $0.category) }
        )
        XCTAssertEqual(categories["mistagged"], "Payroll")
        XCTAssertEqual(categories["store-refund"], "Other Income")
        XCTAssertEqual(categories["contractor"], "Other Income")
        XCTAssertEqual(categories["elsewhere"], "Other Income")
    }

    // MARK: - Helpers

    private var containers: [ModelContainer] = []

    private func makeContext() throws -> ModelContext {
        let container = try SharedStore.makeContainer(inMemory: true)
        containers.append(container)
        return ModelContext(container)
    }

    private func insertIncome(
        _ id: String,
        source: String,
        amount: Double,
        category: String,
        pfc: String,
        in context: ModelContext
    ) {
        context.insert(Income(
            transactionId: id,
            source: source,
            amount: amount,
            date: Date(timeIntervalSince1970: 1_790_000_000),
            category: category,
            pfc: pfc
        ))
    }

    private static func primary(of detailed: String) -> String {
        let primaries = [
            "LOAN_PAYMENTS", "BANK_FEES", "ENTERTAINMENT", "FOOD_AND_DRINK", "GENERAL_MERCHANDISE",
            "HOME_IMPROVEMENT", "MEDICAL", "PERSONAL_CARE", "GENERAL_SERVICES",
            "GOVERNMENT_AND_NON_PROFIT", "TRANSPORTATION", "TRAVEL", "RENT_AND_UTILITIES",
            "TRANSFER_OUT", "TRANSFER_IN"
        ]
        return primaries.first { detailed.hasPrefix($0) } ?? ""
    }
}
