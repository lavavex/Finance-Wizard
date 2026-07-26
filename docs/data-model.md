---
layout: default
title: Data model
---

# Data model

## SwiftData: `Transaction`

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

### Amount sign convention

| Source (API/file) | In app |
|-------------------|--------|
| Expense amount `> 0` | Stored as `-amount` |
| Display “Total Spend” | Sum of `abs(amount)` over the period |
| Signed balance helpers | Sum of `amount` as stored |

## JSON DTOs (not persisted as-is)

In `ContentView.swift`:

- `ImportedTransaction` — one object inside `transactions[]`
- `ExportFile` — root with `transactions` array  

JSON field names use snake_case (`transaction_id`, `payment_method`) to match the API.

## Upsert rules

On Sync or Import:

1. Decode `ExportFile`.
2. For each row, fetch by `transactionId`.
3. **Exists** → update fields.  
4. **Missing** → insert.  
5. `modelContext.save()`.
6. `WidgetCenter.shared.reloadAllTimelines()`.

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
