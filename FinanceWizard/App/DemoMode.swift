//
//  DemoMode.swift
//  Finance Wizard
//
//  Debug-only launch options for repeatable Simulator screenshots (scripts/sim-shot.sh).
//  `-demoData YES` opens an in-memory store seeded with made-up rows, so the App Group
//  database is never read or written. `-screen <tab>` picks the tab shown at launch.
//

#if DEBUG
import Foundation
import SwiftData

enum DemoMode {
    /// Launch arguments land in UserDefaults' volatile argument domain, so nothing persists.
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demoData") }

    /// Raw `-screen` value (see `AppTab`).
    static var launchScreen: String? { UserDefaults.standard.string(forKey: "screen") }

    static func makeSeededContainer() throws -> ModelContainer {
        let container = try SharedStore.makeContainer(inMemory: true)
        let context = ModelContext(container)
        seed(in: context)
        try context.save()
        return container
    }

    private static func seed(in context: ModelContext) {
        let checking = BankAccount(
            accountId: "demo-checking",
            itemId: "demo-item",
            name: "Everyday Checking",
            mask: "1111",
            type: "depository",
            subtype: "checking",
            institutionName: "Demo Bank",
            currentBalance: 4_218.36,
            availableBalance: 4_118.36
        )
        let savings = BankAccount(
            accountId: "demo-savings",
            itemId: "demo-item",
            name: "Rainy Day Savings",
            mask: "2222",
            type: "depository",
            subtype: "savings",
            institutionName: "Demo Bank",
            currentBalance: 12_500
        )
        let card = BankAccount(
            accountId: "demo-card",
            itemId: "demo-item",
            name: "Demo Rewards Card",
            mask: "4242",
            type: "credit",
            subtype: "credit card",
            institutionName: "Demo Bank",
            currentBalance: 1_284.17,
            creditLimit: 8_000,
            lastStatementBalance: 962.40,
            minimumPaymentAmount: 35,
            nextPaymentDueDate: day(-14),
            purchaseApr: 24.99
        )
        [checking, savings, card].forEach(context.insert)

        // (merchant, dollars, category, days ago, account)
        let purchases: [(String, Double, KnownCategory, Int, BankAccount)] = [
            ("Corner Market", 84.12, .groceries, 0, card),
            ("Blue Door Coffee", 6.75, .dining, 1, card),
            ("Northside Fuel", 41.30, .gas, 2, card),
            ("Harbor Noodle House", 32.40, .dining, 3, card),
            ("Corner Market", 61.88, .groceries, 5, card),
            ("City Transit Pass", 45.00, .transit, 7, checking),
            ("Maple Hardware", 27.19, .shopping, 9, card),
            ("Lakeside Cinema", 24.00, .entertainment, 11, card),
            ("Corner Market", 96.54, .groceries, 12, card),
            ("Oak Street Pharmacy", 18.62, .health, 14, card),
            ("Blue Door Coffee", 5.50, .dining, 15, card),
            ("Northside Fuel", 38.72, .gas, 17, card),
            ("Paper & Pine Books", 22.99, .shopping, 20, card),
            ("Corner Market", 73.05, .groceries, 24, card),
            ("Harbor Noodle House", 28.15, .dining, 27, card),
            ("Northside Fuel", 44.08, .gas, 33, card),
            ("Corner Market", 88.31, .groceries, 38, card),
            ("Trailhead Outfitters", 129.00, .shopping, 45, card),
            ("Corner Market", 67.42, .groceries, 52, card)
        ]
        for (index, purchase) in purchases.enumerated() {
            insertExpense(
                id: "demo-tx-\(index)",
                title: purchase.0,
                dollars: purchase.1,
                category: purchase.2,
                daysAgo: purchase.3,
                account: purchase.4,
                in: context
            )
        }

        // Same amount every 30 days so subscription detection has a billing cycle to find.
        let recurring: [(String, Double, KnownCategory, BankAccount)] = [
            ("Riverbend Apartments", 1_450, .housing, checking),
            ("Metro Power & Water", 112.48, .utilities, checking),
            ("Fibernet Home", 59.99, .homeInternet, checking),
            ("StreamBox", 15.99, .subscriptions, card),
            ("Tunewave Premium", 10.99, .subscriptions, card)
        ]
        for (index, bill) in recurring.enumerated() {
            for cycle in 0..<4 {
                insertExpense(
                    id: "demo-bill-\(index)-\(cycle)",
                    title: bill.0,
                    dollars: bill.1,
                    category: bill.2,
                    daysAgo: 4 + index + cycle * 30,
                    account: bill.3,
                    in: context
                )
            }
        }

        for cycle in 0..<16 {
            context.insert(Income(
                transactionId: "demo-pay-\(cycle)",
                source: "Acme Widgets Payroll",
                amount: 1_175,
                date: day(2 + cycle * 7),
                category: "Payroll",
                accountName: checking.name,
                accountMask: checking.mask,
                sourceInstitution: checking.institutionName
            ))
        }

        context.insert(BudgetPlan(
            monthlyLimit: 3_000,
            categoryLimits: [
                KnownCategory.groceries.rawValue: 500,
                KnownCategory.dining.rawValue: 150,
                KnownCategory.gas.rawValue: 160,
                KnownCategory.shopping.rawValue: 200
            ],
            expectedIncome: [
                ExpectedIncomeStream(label: "Payroll", amount: 1_175, frequency: .weekly, weekday: 6)
            ]
        ))
    }

    private static func insertExpense(
        id: String,
        title: String,
        dollars: Double,
        category: KnownCategory,
        daysAgo: Int,
        account: BankAccount,
        in context: ModelContext
    ) {
        context.insert(Transaction(
            transactionId: id,
            title: title,
            amount: -dollars,
            date: day(daysAgo),
            category: category.rawValue,
            paymentMethod: account.plaidDisplayName,
            paymentRail: account.isCredit ? "other" : "debit",
            plaidAccountId: account.accountId
        ))
    }

    /// Noon, so a timezone change cannot move a row across a day boundary.
    private static func day(_ daysAgo: Int) -> Date {
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
        return calendar.date(byAdding: .day, value: -daysAgo, to: noon) ?? noon
    }
}
#endif
