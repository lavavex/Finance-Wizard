---
layout: default
title: Data model
---

# Data model

## SwiftData: `Transaction` (expenses)

Defined in `Shared/Models/Transaction.swift`.

| Property | Type | Notes |
|----------|------|--------|
| `transactionId` | `String` | **Unique** — Plaid `transaction_id` |
| `title` | `String` | Merchant / vendor |
| `amount` | `Double` | **Expenses stored negative** in the app |
| `date` | `Date` | Parsed from `YYYY-MM-DD` |
| `category` | `String` | Budget category (e.g. Dining, Gas (Car)). **Loan** / **Refund** / **Installment** / **Credit Card Payment** are excluded from Total Spend. |
| `paymentMethod` | `String` | Card / account name |
| `subscriptionCadenceOverride` | `String?` | Recurring: `nil` = auto; `"yearly"` / `"monthly"` / `"weekly"` = treat that vendor as recurring (amount may vary); `"cancelled"` / `"none"` (Not Recurring); cleared in Debug |

### Amount sign convention (expenses)

| Source (API/file) | In app |
|-------------------|--------|
| Expense amount `> 0` | Stored as `-amount` |
| Display “Total Spend” | Sum of `abs(amount)` over the period |
| Signed balance helpers | Sum of `amount` as stored |

## SwiftData: `Income`

Defined in `Shared/Models/Income.swift`. **Separate model** so spend analytics never include money-in. Populated when Plaid `amount < 0` (money in).

| Property | Type | Notes |
|----------|------|--------|
| `transactionId` | `String` | **Unique** Plaid `transaction_id` |
| `source` | `String` | Employer / payer / merchant display name |
| `amount` | `Double` | **Always positive** (money in) |
| `date` | `Date` | `YYYY-MM-DD` |
| `category` | `String` | Payroll, Direct Deposit, Interest, Refund, Other Income |
| `accountName` | `String?` | Account display name |
| `accountMask` | `String?` | last4 |
| `sourceInstitution` | `String?` | Institution / account label |
| `rawName` | `String?` | Bank description |
| `pfc` | `String?` | Plaid PFC detailed |
| `pending` | `Bool` | Default false |
| `kind` | `String` | Always `"income"` |
| `updatedAt` | `String?` | Optional timestamp |

| Rule | |
|------|---|
| Affects Total Spend? | **No** |
| In category / card charts? | **No** |
| Editable from app? | **No** (read-only) |
| Source | Plaid `/transactions/sync` (negative amounts) |

## JSON DTOs (not persisted as-is)

In `FinanceWizard/App/ContentView.swift`:

- `ImportedTransaction` / `ExportFile` — expenses (`transactions[]`)
- `ImportedIncome` / `IncomeExportFile` — income (`income[]`, plus `total`, `categories`, …)

JSON field names use snake_case (`transaction_id`, `account_name`, `payment_method`) to match the API.

## Upsert rules

On **Plaid Sync** (`PlaidSyncEngine`):

1. For each linked Item, page through `/transactions/sync`.  
2. Expenses (`amount ≥ 0`) → upsert `Transaction` (stored negative); honor category locks.  
3. Income (`amount < 0`) → upsert `Income` (stored positive).  
4. Removed ids → delete local rows.  
5. Persist cursor; `modelContext.save()`; reload widgets.

On **JSON Import** (optional offline file):

1. Decode `ExportFile` / optional income payload.  
2. Upsert by `transactionId` the same way as before.

Re-syncing does **not** duplicate rows when Plaid ids are stable.

## SwiftData: `BankAccount`

Plaid account snapshot (`Shared/Models/BankAccount.swift`). Used for credit utilization.

| Property | Notes |
|----------|--------|
| `accountId` | Unique Plaid account id |
| `creditLimit` / balances | From `/accounts/get` |
| Liabilities fields | Min payment, due date, last payment/statement, APRs, overdue (`/liabilities/get`) |
| `institutionId` | For Plaid logo cache |
| `type` | `credit`, `depository`, … |
| `currentBalance` | Owed amount for credit |
| `creditLimit` | Limit when reported |
| `utilization` | computed: balance ÷ limit |

## SwiftData: `CreditCardPayment`

Card bill payments only (`Shared/Models/CreditCardPayment.swift`). Never counted in Total Spend.

| Property | Notes |
|----------|--------|
| `transactionId` | Unique |
| `amount` | Positive dollars paid |
| `cardName` | Display label for the card |
| `sourceAccount` | Optional funding account |

## SwiftData: `BudgetPlan` / `RecurringStream` / `PayoffPlan`

| Model | File | Role |
|-------|------|------|
| `BudgetPlan` | `Shared/Models/Budget.swift` | Monthly cap, category limits, expected income (Budget tab; Debug can reset) |
| `RecurringStream` | `Shared/Models/RecurringStream.swift` | Stored recurring groups used with live detection on the Recurring tab |
| `PayoffPlan` | `Shared/Models/PayoffPlan.swift` | User-declared My Loan / Pay Over Time / promo APR / custom payoff on a card |

`PayoffPlan.kindRaw`: `myLoan` | `payOverTime` | `promoAPR` | `custom`. Remaining is user-updated (**Record payment** subtracts `monthlyPayment`; `monthlyFee` does not). Shown on Recurring like a bill. `linkedTransactionId` is the Pay Over Time purchase **or** the My Loan card charge.

`monthlyPayment` is the **full amount billed each statement**, interest / plan fee included — not the principal portion. `recordPayment()` takes interest out of it before reducing `remainingAmount`.

Payoff projections are amortised, not `remaining ÷ payment`: `PayoffPlanMath.monthsToPayOff(remaining:payment:aprPercent:)` returns `nil` when the payment does not cover one month of interest (the balance never clears), and `levelPayment(remaining:months:aprPercent:)` sizes a payment that finishes on time at a given APR. Both fall back to the plain division at 0%.

`startDate` is only overwritten with the card’s `nextPaymentDueDate` for issuer kinds (`followsCardStatement`). Promo / custom plans keep the date the user chose, because `nextPaymentDate` walks their schedule from it.

## App Group store

`Shared/Store/SharedStore.swift`:

```text
groupContainer: .identifier("group.net.roberth.FinanceWizard")
store name: FinanceTransactions
schema: Transaction, Income, BankAccount, CreditCardPayment, BudgetPlan, RecurringStream, PayoffPlan
```

Both app and widget call `SharedStore.makeContainer()`.

## Analytics helpers

`TransactionAnalytics` (same file as SharedStore) is pure logic over `[Transaction]`:

| Helper | Purpose |
|--------|---------|
| `inPeriod` | Filter by week / month / all time |
| `excludingCards` | Hide cards from a list/breakdown |
| `filter` | Period + hide + sort |
| `cardSummaries` | Per-card spend totals |
| `makeSnapshot` | Widget/app summary (total vs breakdown) |
| `totalSpend` | Sum of absolute amounts |
| `paymentMethods` | Unique card names |

### Snapshot semantics (important)

| Field | Includes hidden cards? |
|-------|-------------------------|
| **Total Spend** / period totals | **Yes** — full period |
| **Per-card list** | **No** — respects hide list |

Hiding a card never changes Total Spend.

## Category SF Symbols

`Shared/UI/CategoryStyle.swift` (`CategorySymbol`) maps category strings → SF Symbol names (no remote logos).
