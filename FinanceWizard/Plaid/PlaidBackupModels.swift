//
//  PlaidBackupModels.swift
//  Finance Wizard
//
//  Codable snapshot shapes written into a .fwbackup payload — one per SwiftData model,
//  plus the credentials/item envelopes. Split out of PlaidConnectionBackup.swift so the
//  restore logic there is readable on its own.
//
//  Restore accepts only the current format version. Missing required keys fail decode.
//

import Foundation

extension PlaidConnectionBackup {
    struct Payload: Codable, Equatable, Sendable {
        var version: Int
        var createdAt: Date
        var credentials: CredentialsSnapshot
        var items: [ItemSnapshot]
        var transactions: [TransactionSnapshot]
        var income: [IncomeSnapshot]
        var bankAccounts: [BankAccountSnapshot]
        var creditCardPayments: [PaymentSnapshot]
        var budgetPlans: [BudgetPlanSnapshot]
        var payoffPlans: [PayoffPlanSnapshot]
        var cardLabels: [String: String]
        var vendorRules: [VendorRule]
        var screenshotPrivacy: Bool
        /// All UserDefaults keys with app prefixes (`plaid.`, `card.`, `settings.`).
        /// New prefs under those prefixes are included automatically.
        var preferenceDefaults: [String: Data]
        /// Institution logo files (filename → bytes) from the App Group cache.
        var logoFiles: [String: Data]
    }

    struct CredentialsSnapshot: Codable, Equatable, Sendable {
        var clientID: String
        var secret: String
        var environment: String
        var redirectURIOverride: String
    }

    struct ItemSnapshot: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var accessToken: String
        var institutionName: String
        var accountNames: [String]
        var transactionsCursor: String
        var linkedAt: Date
        var errorCode: String?
        var errorMessage: String?
        var lastStatusCheckAt: Date?
    }

    struct TransactionSnapshot: Codable, Equatable, Sendable {
        var transactionId: String
        var title: String
        var amount: Double
        var date: Date
        var category: String
        var paymentMethod: String
        var categoryLocked: Bool?
        var overrideSource: String?
        var plaidPaymentChannel: String?
        var paymentRail: String?
        var paymentRailLocked: Bool?
        var subscriptionCadenceOverride: String?
        var authorizedDate: Date?
        var pendingTransactionId: String?
        var plaidAccountId: String?
        var merchantEntityId: String?
        var merchantName: String?
        var logoURL: String?
        var website: String?
        var pfcConfidence: String?
        var isPending: Bool?
    }

    struct IncomeSnapshot: Codable, Equatable, Sendable {
        var transactionId: String
        var source: String
        var amount: Double
        var date: Date
        var category: String
        var accountName: String?
        var accountMask: String?
        var sourceInstitution: String?
        var rawName: String?
        var pfc: String?
        var pending: Bool
        var kind: String
        var updatedAt: String?
    }

    struct BankAccountSnapshot: Codable, Equatable, Sendable {
        var accountId: String
        var itemId: String
        var name: String
        var officialName: String?
        var mask: String?
        var type: String
        var subtype: String?
        var institutionName: String
        var currentBalance: Double
        var availableBalance: Double?
        var creditLimit: Double?
        var institutionId: String?
        var lastSyncedAt: Date
        var isOverdue: Bool?
        var lastPaymentAmount: Double?
        var lastPaymentDate: Date?
        var lastStatementIssueDate: Date?
        var lastStatementBalance: Double?
        var minimumPaymentAmount: Double?
        var nextPaymentDueDate: Date?
        var purchaseApr: Double?
        var cashApr: Double?
        var balanceTransferApr: Double?
        var specialApr: Double?
        var liabilitiesSyncedAt: Date?
    }

    struct PaymentSnapshot: Codable, Equatable, Sendable {
        var transactionId: String
        var amount: Double
        var date: Date
        var cardName: String
        var sourceAccount: String?
        var title: String
        var creditAccountId: String?
        var institutionName: String?
    }


    struct BudgetPlanSnapshot: Codable, Equatable, Sendable {
        var planId: String
        var monthlyLimit: Double?
        var categoryLimits: [String: Double]
        var expectedIncome: [ExpectedIncomeStream]
        var updatedAt: Date
    }

    struct PayoffPlanSnapshot: Codable, Equatable, Sendable {
        var planId: String
        var kindRaw: String
        var name: String
        var accountId: String?
        var paymentMethod: String
        var originalAmount: Double
        var remainingAmount: Double
        var monthlyPayment: Double
        var monthlyFee: Double?
        var aprPercent: Double?
        var startDate: Date
        var endDate: Date?
        var termMonths: Int?
        var linkedTransactionId: String?
        var notes: String?
        var isEnded: Bool
        var lastAppliedStatementDate: Date?
        var createdAt: Date
        var updatedAt: Date
    }

    // MARK: Plans & summaries

    /// What restore would do — shown before applying, so existing links stay predictable.
}
