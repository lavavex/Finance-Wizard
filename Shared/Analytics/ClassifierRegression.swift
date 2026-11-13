//
//  ClassifierRegression.swift
//  Finance Wizard
//
//  Real-descriptor table for PlaidCategoryMapper.classify. Any change to that
//  function must keep every case green — branch order is load-bearing.
//

import Foundation

/// One Plaid-shaped row and the flow / labels it must produce.
struct ClassifierCase: Sendable {
    let name: String
    let title: String
    /// Plaid sign: positive = money out, negative = money in.
    let amount: Double
    let accountType: String
    let primary: String?
    let detailed: String?
    let flow: PlaidFlowKind
    /// When `flow` is `.spending`, the expense category that must be assigned.
    let expenseCategory: String?
    /// When `flow` is `.income`, the income category that must be assigned.
    let incomeCategory: String?

    init(
        _ name: String,
        title: String,
        amount: Double,
        accountType: String,
        primary: String? = nil,
        detailed: String? = nil,
        flow: PlaidFlowKind,
        expenseCategory: String? = nil,
        incomeCategory: String? = nil
    ) {
        self.name = name
        self.title = title
        self.amount = amount
        self.accountType = accountType
        self.primary = primary
        self.detailed = detailed
        self.flow = flow
        self.expenseCategory = expenseCategory
        self.incomeCategory = incomeCategory
    }
}

/// Descriptor table + evaluator. The cases are the contract; `failures()` is the check.
enum ClassifierRegression {
    static let cases: [ClassifierCase] = [
        // Bill-pay titles outrank a LOAN_DISBURSEMENTS PFC (that tag is on the card side
        // of ordinary payments). Getting this wrong deleted 107 payment rows.
        ClassifierCase(
            "payment-thank-you-card",
            title: "Payment Thank You - Web",
            amount: -187.40,
            accountType: "credit",
            primary: "LOAN_DISBURSEMENTS",
            detailed: "LOAN_DISBURSEMENTS_CREDIT_CARD_ADVANCE",
            flow: .creditPayment
        ),
        ClassifierCase(
            "payment-thank-you-mixed-case",
            title: "PAYMENT THANK YOU",
            amount: -50,
            accountType: "credit",
            flow: .creditPayment
        ),
        ClassifierCase(
            "chase-credit-crd-autopay",
            title: "CHASE CREDIT CRD AUTOPAY",
            amount: 187.40,
            accountType: "depository",
            flow: .creditPayment
        ),
        ClassifierCase(
            "epay",
            title: "EPAY",
            amount: 200,
            accountType: "depository",
            flow: .creditPayment
        ),

        // Weak needles (autopay) on a merchant bill must stay spend.
        ClassifierCase(
            "verizon-autopay",
            title: "VERIZON *AUTOPAY",
            amount: 89.43,
            accountType: "depository",
            flow: .spending
        ),
        ClassifierCase(
            "t-mobile-autopay",
            title: "T-MOBILE AUTOPAY",
            amount: 70,
            accountType: "depository",
            flow: .spending
        ),
        ClassifierCase(
            "geico-autopay",
            title: "GEICO AUTOPAY",
            amount: 124.11,
            accountType: "depository",
            flow: .spending
        ),

        // Card-line loan: charge is Loan spend-excluded; checking deposit is not earnings.
        ClassifierCase(
            "my-chase-loan-charge",
            title: "MY CHASE LOAN TO 2667",
            amount: 4000,
            accountType: "credit",
            flow: .spending,
            expenseCategory: KnownCategory.loan.rawValue
        ),
        ClassifierCase(
            "my-chase-loan-deposit",
            title: "MY CHASE LOAN TO 2667",
            amount: -4000,
            accountType: "depository",
            flow: .adjustment
        ),

        // Financing fees are a new cost; installment billing is the original purchase re-billed.
        ClassifierCase(
            "plan-fee",
            title: "PLAN FEE - AMAZON",
            amount: 8.99,
            accountType: "credit",
            flow: .spending,
            expenseCategory: KnownCategory.fees.rawValue
        ),
        ClassifierCase(
            "annual-membership-fee",
            title: "ANNUAL MEMBERSHIP FEE",
            amount: 550,
            accountType: "credit",
            flow: .spending,
            expenseCategory: KnownCategory.fees.rawValue
        ),
        ClassifierCase(
            "plan-it",
            title: "Plan It - Best Buy",
            amount: 41.66,
            accountType: "credit",
            flow: .spending,
            expenseCategory: KnownCategory.installment.rawValue
        ),
        ClassifierCase(
            "my-chase-plan",
            title: "MY CHASE PLAN",
            amount: 35,
            accountType: "credit",
            flow: .spending,
            expenseCategory: KnownCategory.installment.rawValue
        ),

        // In-store swipe Plaid tags CREDIT_CARD_PAYMENT is still spend, not bill pay.
        ClassifierCase(
            "best-buy-swipe-mis-tagged",
            title: "BEST BUY",
            amount: 412.18,
            accountType: "credit",
            primary: "LOAN_PAYMENTS",
            detailed: "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT",
            flow: .spending
        ),

        // Card-side money-in that is not a payment.
        ClassifierCase(
            "dining-credit",
            title: "DINING CREDIT",
            amount: -25,
            accountType: "credit",
            flow: .adjustment
        ),
        ClassifierCase(
            "best-buy-return-card",
            title: "BEST BUY RETURN",
            amount: -80,
            accountType: "credit",
            flow: .adjustment
        ),
        ClassifierCase(
            "stubhub-credit",
            title: "STUBHUB CREDIT",
            amount: -40,
            accountType: "credit",
            flow: .adjustment
        ),

        // Checking-side merchant refunds / reimbursements are not Total Income.
        ClassifierCase(
            "amazon-refund-checking",
            title: "AMAZON REFUND",
            amount: -32.10,
            accountType: "depository",
            flow: .adjustment
        ),
        ClassifierCase(
            "expense-reimbursement",
            title: "EXPENSE REIMBURSEMENT",
            amount: -150,
            accountType: "depository",
            flow: .adjustment
        ),

        // Tax refunds *are* earnings.
        ClassifierCase(
            "irs-tax-refund",
            title: "IRS TREAS 310 TAX REF",
            amount: -800,
            accountType: "depository",
            detailed: "INCOME_TAX_REFUND",
            flow: .income,
            incomeCategory: "Other Income"
        ),

        // Plaid's real names. These contain words other rules look for: "RENT", "GAS_".
        ClassifierCase(
            "gas-station-plaid-name",
            title: "NEIGHBORHOOD FUEL",
            amount: 40,
            accountType: "credit",
            primary: "TRANSPORTATION",
            detailed: "TRANSPORTATION_GAS",
            flow: .spending,
            expenseCategory: KnownCategory.gas.rawValue
        ),
        ClassifierCase(
            "electric-bill-is-not-fuel",
            title: "CITY POWER AND GAS",
            amount: 90,
            accountType: "depository",
            primary: "RENT_AND_UTILITIES",
            detailed: "RENT_AND_UTILITIES_GAS_AND_ELECTRICITY",
            flow: .spending,
            expenseCategory: KnownCategory.utilities.rawValue
        ),
        ClassifierCase(
            "water-bill-is-not-rent",
            title: "CITY WATER DEPT",
            amount: 60,
            accountType: "depository",
            primary: "RENT_AND_UTILITIES",
            detailed: "RENT_AND_UTILITIES_WATER",
            flow: .spending,
            expenseCategory: KnownCategory.utilities.rawValue
        ),
        ClassifierCase(
            "rental-car-is-not-rent",
            title: "AIRPORT CAR RENTAL",
            amount: 210,
            accountType: "credit",
            primary: "TRAVEL",
            detailed: "TRAVEL_RENTAL_CARS",
            flow: .spending,
            expenseCategory: KnownCategory.travel.rawValue
        ),

        // Balance transfers move debt. The fee is still a real cost.
        ClassifierCase(
            "balance-transfer-reference",
            title: "BT 123456789 - EXAMPLE CARD SERVICES",
            amount: 1500,
            accountType: "credit",
            primary: "TRANSFER_OUT",
            detailed: "TRANSFER_OUT_ACCOUNT_TRANSFER",
            flow: .spending,
            expenseCategory: KnownCategory.balanceTransfer.rawValue
        ),
        ClassifierCase(
            "balance-transfer-fee-stays-spend",
            title: "BALANCE TRANSFER FEE",
            amount: 45,
            accountType: "credit",
            primary: "BANK_FEES",
            detailed: "BANK_FEES_OTHER_BANK_FEES",
            flow: .spending,
            expenseCategory: KnownCategory.fees.rawValue
        ),

        // Person-to-person stays visible. Own-account moves stay out.
        ClassifierCase(
            "zelle-sent",
            title: "ZELLE PAYMENT TO A FRIEND",
            amount: 75,
            accountType: "depository",
            primary: "TRANSFER_OUT",
            detailed: "TRANSFER_OUT_ACCOUNT_TRANSFER",
            flow: .spending,
            expenseCategory: KnownCategory.personToPerson.rawValue
        ),
        ClassifierCase(
            "venmo-received",
            title: "VENMO CASHOUT",
            amount: -75,
            accountType: "depository",
            primary: "TRANSFER_IN",
            detailed: "TRANSFER_IN_ACCOUNT_TRANSFER",
            flow: .income,
            incomeCategory: KnownCategory.personToPerson.rawValue
        ),
        ClassifierCase(
            "own-savings-transfer-stays-hidden",
            title: "ONLINE TRANSFER TO SAVINGS",
            amount: 200,
            accountType: "depository",
            primary: "TRANSFER_OUT",
            detailed: "TRANSFER_OUT_SAVINGS",
            flow: .transfer
        ),
        ClassifierCase(
            "paypal-merchant-keeps-merchant-category",
            title: "PAYPAL EXAMPLE STORE",
            amount: 30,
            accountType: "credit",
            primary: "GENERAL_MERCHANDISE",
            detailed: "GENERAL_MERCHANDISE_ONLINE_MARKETPLACES",
            flow: .spending,
            expenseCategory: KnownCategory.shopping.rawValue
        ),
        ClassifierCase(
            "similar-word-is-not-zelle",
            title: "GAZELLE SPORTS",
            amount: 80,
            accountType: "credit",
            primary: "GENERAL_MERCHANDISE",
            detailed: "GENERAL_MERCHANDISE_SPORTING_GOODS",
            flow: .spending,
            expenseCategory: KnownCategory.entertainment.rawValue
        ),

        // Card rewards are income.
        ClassifierCase(
            "cash-redemption-is-income",
            title: "Cash Redemption",
            amount: -25,
            accountType: "depository",
            primary: "OTHER",
            detailed: "OTHER_OTHER",
            flow: .income,
            incomeCategory: "Rewards"
        ),
        ClassifierCase(
            "card-cashback-is-income",
            title: "Example Card Cashback Reward",
            amount: -5,
            accountType: "credit",
            primary: "TRANSFER_IN",
            detailed: "TRANSFER_IN_ACCOUNT_TRANSFER",
            flow: .income,
            incomeCategory: "Rewards"
        ),
        ClassifierCase(
            "benefit-credit-stays-a-refund",
            title: "TRAVEL CREDIT $300/YEAR",
            amount: -300,
            accountType: "credit",
            primary: "OTHER",
            detailed: "OTHER_OTHER",
            flow: .adjustment
        ),

        // Deposits are new money. Bank-to-bank moves aren't.
        ClassifierCase(
            "check-deposit-is-income",
            title: "Mobile Check Deposit",
            amount: -200,
            accountType: "depository",
            primary: "TRANSFER_IN",
            detailed: "TRANSFER_IN_DEPOSIT",
            flow: .income,
            incomeCategory: "Deposit"
        ),
        ClassifierCase(
            "plaid-tagged-deposit-is-income",
            title: "Deposit",
            amount: -60,
            accountType: "depository",
            primary: "TRANSFER_IN",
            detailed: "TRANSFER_IN_DEPOSIT",
            flow: .income,
            incomeCategory: "Deposit"
        ),
        ClassifierCase(
            "ach-deposit-transfer-stays-a-transfer",
            title: "Ach Deposit Internet Transfer From Account",
            amount: -500,
            accountType: "depository",
            primary: "TRANSFER_IN",
            detailed: "TRANSFER_IN_DEPOSIT",
            flow: .transfer
        ),

        ClassifierCase(
            "adp-payroll",
            title: "ADP PAYROLL ACME CORP",
            amount: -2500,
            accountType: "depository",
            primary: "INCOME",
            detailed: "INCOME_WAGES",
            flow: .income,
            incomeCategory: "Payroll"
        ),
        ClassifierCase(
            "dir-dep",
            title: "DIR DEP ACME INC",
            amount: -2500,
            accountType: "depository",
            flow: .income,
            incomeCategory: "Direct Deposit"
        ),
        ClassifierCase(
            "interest-earned",
            title: "INTEREST PAYMENT",
            amount: -1.23,
            accountType: "depository",
            primary: "INCOME",
            detailed: "INCOME_INTEREST_EARNED",
            flow: .income,
            incomeCategory: "Interest"
        ),

        ClassifierCase(
            "transfer-from-savings",
            title: "Online Transfer from Sav",
            amount: -500,
            accountType: "depository",
            flow: .transfer
        ),
    ]

    /// Human-readable failures; empty means the table is green.
    static func failures() -> [String] {
        var out: [String] = []
        for item in cases {
            let pfc: PlaidPFC? = {
                if item.primary == nil, item.detailed == nil { return nil }
                return PlaidPFC(primary: item.primary, detailed: item.detailed, confidence_level: nil)
            }()
            let got = PlaidCategoryMapper.classify(
                amount: item.amount,
                pfc: pfc,
                title: item.title,
                accountType: item.accountType,
                accountSubtype: nil
            )
            if got != item.flow {
                out.append("\(item.name): flow \(got.rawValue) (want \(item.flow.rawValue))")
                continue
            }
            if item.flow == .spending, let want = item.expenseCategory {
                let cat = PlaidCategoryMapper.expenseCategory(from: pfc, title: item.title)
                if cat != want {
                    out.append("\(item.name): expense \(cat) (want \(want))")
                }
            }
            if item.flow == .income, let want = item.incomeCategory {
                let cat = PlaidCategoryMapper.incomeCategory(from: pfc, name: item.title)
                if cat != want {
                    out.append("\(item.name): income \(cat) (want \(want))")
                }
            }
        }
        return out
    }
}
