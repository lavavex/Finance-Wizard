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
| Calendar | Period: This week / This month / All time |
| Sort | Date, amount, name |
| Eye slash | Hide cards from the **list only** |
| **Import** | Pick optional JSON export from Files |

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
| **Category** | Yes (built-in list + free text) |
| **Points multiplier** | Yes |
| Learn / same card / apply matching | Local rules only |
| Points estimate | Derived (abs(amount) × multiplier) |

**Save** updates SwiftData and locks category/multiplier so later Plaid syncs do not overwrite them. With **learn**, a local vendor rule is stored for future Plaid rows.

## Tab: Cards

Single hub for payment methods and credit tracking:

| Element | Meaning |
|---------|---------|
| **Total Spend** | Purchases in the selected period (tap → category chart) |
| **Credit balance / limit / utilization** | From Plaid balances on Sync |
| **Paid this period** | Card bill payments (excluded from Total Spend) |
| **Cards list** | Primary: balance + limit; secondary: spend + paid; utilization bar |
| **Payments list** | Bill payments for the period |
| **Card detail** | Rename card (e.g. “Chase Freedom”), balance/limit, payments, purchases |

Open a card → **Card name** field to nickname it (stored on device). Clear and save to restore the Plaid label (“Credit Card ···0820”).

Period + sort controls apply across the tab. Transfers and card bill payments stay out of Transactions totals.

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
Card faces use:

1. **Plaid bank logo + brand color** (`/institutions/get_by_id` optional metadata) — cached on Sync.  
2. **Product-colored plastic face** from your nickname or **Card art** pick (Freedom blue, Sapphire navy, …).

| Example nickname / art pick | Look |
|-----------------------------|------|
| Chase Freedom / Unlimited / Flex | Blue face + Chase logo when Plaid provides it |
| Sapphire Preferred / Reserve | Navy / black face |
| Amex Gold / Platinum / Blue Cash | Gold / silver / blue |

**Not** scraped product photos from Chase.com (copyright). Apps that show Freedom/Sapphire photography typically license those assets or use a paid enrichment partner.

## What the app does *not* do (yet)

- Apple Card direct API / CSV import  
- Budget limits / overspend alerts  
- Multi-device cloud sync (data is local + re-Sync from Plaid)  
- Hosted backend for Plaid secrets (BYO keys on device)  
