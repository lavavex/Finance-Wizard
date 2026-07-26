---
layout: default
title: Sync & API
---

# Sync & API

The app talks to **finance-sync** on your PC. Default base URL:

```text
http://openwindow.local:8787
```

Change anytime in **Settings** (no rebuild required).

## What Sync does (app menu)

Toolbar **Sync** opens a menu:

### Sync recent months (default)

```text
1. POST /api/plaid/sync
   body: {
     "includeTransactions": false,
     "unexportedOnly": false,
     "includePending": false
   }
   (no month field — full bank refresh on the PC)

2. For each of [currentMonth, previousMonth] as YYYY-MM:
     GET /api/transactions?month=YYYY-MM
     upsert expenses into SwiftData

3. For each of [currentMonth, previousMonth] as YYYY-MM:
     GET /api/income?month=YYYY-MM
     upsert income into SwiftData (separate model; not in spend)

4. Reload widget timelines
```

### Sync everything

Same Plaid step, then **unfiltered** pulls of the full portal tables:

```text
2. GET /api/transactions          (no month)
3. GET /api/income                (no month)
4. Upsert all rows + reload widgets
```

Use this after a schema reset or when you want history beyond the last two months.

### Months (recent sync only)

Computed at runtime with the device calendar:

- **Current month** — e.g. `2026-07`
- **Previous month** — e.g. `2026-06`

Shown in Settings under **Recent months**.

## Rate limits (Plaid)

The server enforces a local cooldown (e.g. 15 minutes between Plaid pulls, hourly cap). Typical response:

| HTTP | Code idea | App behavior |
|------|-----------|--------------|
| **429** | `PLAID_SYNC_COOLDOWN` / hourly / reset | **Not fatal** — still GET both months |
| **409** | Sync already in flight | **Not fatal** — still GET both months |
| **2xx** | Plaid ran | Then GET both months |
| Other error | Server/Plaid failure | Try GET months anyway; soft message if GETs work |

`GET /api/transactions` does **not** call Plaid and is not under that cooldown.

## Endpoints used by the app

### POST `/api/plaid/sync` (alias: `/api/app/sync`)

Triggers Plaid → SQLite (and Excel mirror if enabled on the server).

Optional body fields (server contract):

| Field | App sends | Meaning |
|-------|-----------|---------|
| `month` | *(omitted)* | Filter; omit = broad pull |
| `includeTransactions` | `false` | App prefers explicit GETs per month |
| `unexportedOnly` | `false` | Full month snapshots |
| `includePending` | `false` | Skip pending |
| `force` | not used | Bypass local cooldown (avoid spamming) |

### GET `/api/transactions`

Query params:

| Param | App usage |
|-------|-----------|
| `month=YYYY-MM` | Current and previous month (two requests) |
| `unexported` | Not used by default Sync |
| `includePending` | Not used by default Sync |

Response shape (simplified):

```json
{
  "ok": true,
  "count": 80,
  "transactions": [
    {
      "transaction_id": "...",
      "date": "2026-07-01",
      "vendor": "Audible",
      "category": "Subscriptions",
      "amount": 8.99,
      "payment_method": "Prime Visa",
      "multiplier": 5,
      "pending": 0,
      "exported_to_budget_at": null
    }
  ]
}
```

### GET `/api/income`

Separate **income** stream. Does **not** affect Total Spend, category charts, card breakdowns, Excel expense mirror, or budget expense export.

| Param | App usage |
|-------|-----------|
| `month=YYYY-MM` | Same current + previous months as expenses |
| `year` | Not used by default Sync |
| `includePending` | Omitted (server default: pending off) |

Response shape (finance-sync `IncomeApiResponse` / `IncomeRow`):

```json
{
  "ok": true,
  "kind": "income",
  "count": 6,
  "total": 2200.46,
  "filters": { "month": "2026-07", "year": null, "includePending": false },
  "categories": ["Payroll", "Direct Deposit", "Interest", "Refund", "Other Income"],
  "income": [
    {
      "transaction_id": "...",
      "date": "2026-07-01",
      "source": "QuikTrip",
      "category": "Payroll",
      "amount": 317.73,
      "account_name": "CHASE COLLEGE",
      "account_mask": "2667",
      "source_institution": null,
      "raw_name": "QuikTrip",
      "pfc": null,
      "pending": false,
      "kind": "income",
      "updated_at": "2026-07-26T22:27:12.461Z"
    }
  ]
}
```

| Field | Notes |
|-------|--------|
| `amount` | Always **positive** (money in) |
| `source` | Display name (employer / payer) |
| `transaction_id` | Stable Plaid/import primary key |
| `total` | Server sum for this filter |
| Categories | Payroll, Direct Deposit, Interest, Refund, Other Income |

Internal transfers excluded server-side. Income is **read-only** from the app (no classify API). Pull is **soft-failed** so expense sync still completes if income fails.

### POST `/api/transactions/{transaction_id}/classify`

Pushed when the user **Save**s category/multiplier on a transaction detail screen.

```json
{
  "category": "Coffee",
  "multiplier": 3,
  "learn": true,
  "scopePaymentMethod": false,
  "applyToMatching": false
}
```

| Field | Default in app | Meaning |
|-------|----------------|---------|
| `learn` | true | Store vendor rule for future Plaid rows |
| `scopePaymentMethod` | false | Limit rule / bulk to same card |
| `applyToMatching` | false | Also fix other matching rows on server |

Server locks the row so later Plaid syncs do not overwrite. Transaction JSON may include `category_locked`, `multiplier_locked`, `override_source`.

Also: `GET /api/categories` for the picker (falls back to a built-in list if unreachable).

### Not called by default (by design)

- `POST /api/transactions/mark-exported` — shared flag with other consumers (e.g. Mac budget export). Avoid until ownership is clear.
- Bank linking / Plaid Link — stays on the portal.

## JSON file import

**Import** on the Transactions toolbar:

1. User picks a `.json` file (same `transactions` array shape).
2. Same upsert path as Sync.
3. Useful offline or for one-off exports.

## Connectivity checklist

```bash
# From Mac on the same network as the portal:
curl -s "http://openwindow.local:8787/api/status" | head

curl -s "http://openwindow.local:8787/api/transactions?month=$(date +%Y-%m)" | head

curl -s "http://openwindow.local:8787/api/income?month=$(date +%Y-%m)" | head
```

If hostname fails, use the PC LAN IP in Settings (e.g. `http://10.0.0.135:8787`).

## Security

- No auth on the API today → **trusted LAN / VPN only**.
- Do not expose port 8787 to the public internet without auth + TLS.
