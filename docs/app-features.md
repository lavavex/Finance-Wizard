---
layout: default
title: App features
---

# App features

## Tab: Transactions

Main list of expenses with filters shared conceptually with the widget.

### Header

- **Total Spend** — sum of absolute amounts for the selected **period** (expenses only; all cards).
- **Total Income** — sum of income amounts for the same period (`GET /api/income`; always positive; **not** in spend).
- **Net** — income − spend for the period (informational only).
- **Tap Total Spend** → **Categories** screen with switchable charts (default **horizontal bars**; also vertical bars and pie) plus a numeric breakdown.
- Hiding cards does **not** change spend or income totals.
- Counts of expenses and income rows in the period.

### Lists

- **Income** section — `source`, category, account, amount (read-only detail). Categories: Payroll, Direct Deposit, Interest, Refund, Other Income.
- **Expenses** section — same as before (classify / category edit on tap).

### Toolbar

| Control | Action |
|---------|--------|
| **Sync** | Menu: **Sync now** (Plaid incremental), **Full re-sync** (reset cursors), **Link bank account** |
| Pull down | Same as **Sync now** (incremental Plaid sync) |
| Search | Title, category, amount, last four, nickname |
| Calendar | Period: This week / This month / All time |
| Sort | Date, amount, name |
| Eye slash | Hide cards from the **list only** |
| **Import** | Menu: legacy JSON export, or **Apple Card CSV** from Wallet / card.apple.com |

### Tools (Transactions)

| Tool | Meaning |
|------|---------|
| **Needs review** | Unlocked rates, ambiguous debit/ACH, bill-pay lookalikes, weak categories — swipe to fix |
| **Subscriptions** | Memberships / fixed bills only (near-identical amount + schedule; excludes retail/dining/gas habits) |

### Rows

Each row shows:

- SF Symbol from **category** (`CategorySymbol`)
- Vendor title  
- Category · payment method  
- Date  
- Amount (signed) + points multiplier  

**Tap a row** → **Transaction detail** (`TransactionDetailView`):

| Field | Editable? |
|-------|-----------|
| Title, amount, date, card, id | Read-only |
| **Category** | Yes (built-in list + free text), including **Credit Card Payment** |
| **Points multiplier** | Yes |
| Learn / same card / apply matching | Local rules only |
| Points estimate | Derived (abs(amount) × multiplier) |

**Save** updates SwiftData and locks category/multiplier so later Plaid syncs do not overwrite them. With **learn**, a local vendor rule is stored for future Plaid rows.

**Credit Card Payment** is a first-class category for bill pays. Rows still appear in the transaction list (labeled “Bill pay”) but are **excluded** from Total Spend, category charts, widgets, and per-card spend. Sync maps Plaid card payments here automatically; choosing this category on detail also mirrors the row into Accounts → Total paid.

## Tab: Accounts

Hub for credit cards and checking/savings (formerly **Cards**):

| Element | Meaning |
|---------|---------|
| **Total Spend** | Purchases in the selected period (tap → category chart) |
| **Total paid** | Card bill payments (expandable list); not part of Total Spend |
| **Credit balance / limit / utilization** | From Plaid balances on Sync |
| **Min payments / next due** | From Plaid Liabilities on Sync (when supported) |
| **Credit cards** | Balance + limit; min/due; spend; utilization; Plaid logo |
| **Checking & savings** | Available balance + spend; debit vs ACH reward mults on detail |
| **Account detail** | Rename; summary with Total paid disclosure; credit terms; purchases |

Open an account → nickname it (per last four). On checking accounts, set **Debit** vs **ACH** reward multipliers (e.g. X Money 0.03 debit / 0 ACH). Transactions store a **payment rail** (inferred from Plaid + heuristics; overridable on the transaction).

Period + sort controls apply across the tab. Pull down to Sync. Transfers and card bill payments stay out of Transactions totals.

**Upcoming bills** — credit cards with a due date in the next 30 days (or overdue), min payment + utilization color.

## Tab: Benefits

Rewards & perks for **credit cards** (and card-like methods such as Apple Card):

| Element | Meaning |
|---------|---------|
| **Estimated rewards** | Period estimate from spend × each card’s earn profile |
| **Fee payback** | Annualized period rewards − annual fee (rollup + per card) |
| **Action needed** | Cards without a product pick (deep link into product menu) |
| **Card list** | Per-card estimated $ value + category / temporary boost chips |
| **Product pick** | Renames card to `[product] [last 4]`, loads rates, shows confirmation toast |
| **By category** | Period spend / rate / est. value per **reward** category (highest rate first) |
| **Reward categories** | Full editor: every standard category rate + custom boosts |
| **Temporary boosts** | Time-boxed rates (rotating 5%, promos) with optional end date |
| **Earn rates** | Points vs cash back, default rate, point value (¢), annual fee |
| **Perks** | Freeform non-earn benefits |

Transaction detail shows **general category → reward category** mapping and a **Travel earn** control (Auto / Portal / Direct) that locks the reward bucket.

### Two category systems

| System | File | Used for |
|--------|------|----------|
| **General** | `Shared/KnownCategory.swift` | Transactions list, charts, Plaid classify (`Dining`, `Gas (Car)`, `Personal Care`, …) |
| **Reward** | `Shared/RewardCategory.swift` | Benefits earn rates (`Drugstores`, `Travel (Portal)`, `Online Grocery`, …) |

Rates & product presets: `Shared/CardProductCatalog.swift` + `Shared/CardBenefitsStore.swift` (per-card overrides in UserDefaults).

A purchase’s **general** category + title map into a **reward** category (e.g. CVS under Personal Care → **Drugstores**). Cash back is entered as a **percent** (e.g. `3` = 3%).

## Tab: Settings

See [Settings](settings.md).

## Filters & sort (shared logic)

Implemented in `Shared/SharedStore.swift` as `TransactionAnalytics` + `SnapshotPeriod` + `TransactionSort`.

| Period | Meaning |
|--------|---------|
| This week | Current calendar week (device locale) |
| This month | Current calendar month |
| All time | No date lower bound |

| Sort | Meaning |
|------|---------|
| Date (newest/oldest) | By `date` |
| Amount (largest/smallest) | By `abs(amount)` |
| Name (A–Z) | By `title` |

## Icons

### Categories (transactions)
Maps **category** → SF Symbol in `Shared/CategorySymbol.swift`.

### Cards / banks
- **One row per linked account** (Plaid `account_id` / last four) so multiple Chase cards stay separate.  
- **Logo** = institution logo from Plaid on Sync (not product photography).  
- **Rename** per account on the card detail screen.

## What the app does *not* do (yet)

- Apple Card live API (CSV import is supported)  
- Budget limits / overspend alerts  
- Multi-device cloud sync (data is local + re-Sync from Plaid)  
- Hosted backend for Plaid secrets (BYO keys on device)  
