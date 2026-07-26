---
layout: default
title: Data model
---

# Data model

## SwiftData: `Transaction` (expenses)

Defined in `Shared/Transaction.swift`.

| Property | Type | Notes |
|----------|------|--------|
| `transactionId` | `String` | **Unique** — finance-sync / Plaid id |
| `title` | `String` | Merchant / vendor |
| `amount` | `Double` | **Expenses stored negative** in the app |
| `date` | `Date` | Parsed from `YYYY-MM-DD` |
| `category` | `String` | Budget category (e.g. Dining, Gas (Car)) |
| `paymentMethod` | `String` | Card / account name |
| `multiplier` | `Double` | Points rate (e.g. 5 = 5x) |

### Amount sign convention (expenses)

| Source (API/file) | In app |
|-------------------|--------|
| Expense amount `> 0` | Stored as `-amount` |
| Display “Total Spend” | Sum of `abs(amount)` over the period |
| Signed balance helpers | Sum of `amount` as stored |

## SwiftData: `Income`

Defined in `Shared/Income.swift`. **Separate model** so spend analytics never include money-in. Maps 1:1 to finance-sync `IncomeRow`.

| Property | Type | API field | Notes |
|----------|------|-----------|--------|
| `transactionId` | `String` | `transaction_id` | **Unique** Plaid/import id |
| `source` | `String` | `source` | Employer / payer display name |
| `amount` | `Double` | `amount` | **Always positive** (money in) |
| `date` | `Date` | `date` | `YYYY-MM-DD` |
| `category` | `String` | `category` | Payroll, Direct Deposit, Interest, Refund, Other Income |
| `accountName` | `String?` | `account_name` | e.g. CHASE COLLEGE |
| `accountMask` | `String?` | `account_mask` | last4 |
| `sourceInstitution` | `String?` | `source_institution` | e.g. Chase |
| `rawName` | `String?` | `raw_name` | Bank description |
| `pfc` | `String?` | `pfc` | Plaid PFC detailed |
| `pending` | `Bool` | `pending` | Default false |
| `kind` | `String` | `kind` | Always `"income"` |
| `updatedAt` | `String?` | `updated_at` | ISO timestamp |

| Rule | |
|------|---|
| Affects Total Spend? | **No** |
| In category / card charts? | **No** |
| Editable from app? | **No** (read-only) |
| Source API | `GET /api/income?month=YYYY-MM` |

## JSON DTOs (not persisted as-is)

In `ContentView.swift`:

- `ImportedTransaction` / `ExportFile` — expenses (`transactions[]`)
- `ImportedIncome` / `IncomeExportFile` — income (`income[]`, plus `total`, `categories`, …)

JSON field names use snake_case (`transaction_id`, `account_name`, `payment_method`) to match the API.

## Upsert rules

On Sync or Import (expenses):

1. Decode `ExportFile`.
2. For each row, fetch by `transactionId`.
3. **Exists** → update fields.  
4. **Missing** → insert.  
5. `modelContext.save()`.
6. `WidgetCenter.shared.reloadAllTimelines()`.

On Sync (income):

1. Decode `IncomeExportFile` (`IncomeApiResponse`).
2. For each `IncomeRow`, upsert by `transaction_id` → `transactionId`.
3. Map `source`, `account_name`, `account_mask`, etc.; amount stays positive.
4. Save + reload timelines.

Re-syncing the same month does **not** duplicate rows.

## App Group store

`Shared/SharedStore.swift`:

```text
groupContainer: .identifier("group.net.roberth.FinanceWidget")
store name: FinanceTransactions
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

`Shared/CategorySymbol.swift` maps category strings → SF Symbol names (no remote logos).
