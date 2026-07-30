---
layout: default
title: Sync & API
---

# Sync & Plaid API

Finance Wizard talks **directly to Plaid** using **your** developer `client_id` and `secret`. There is no home finance-sync server.

## Setup (once)

1. Create a free account at [dashboard.plaid.com](https://dashboard.plaid.com).  
2. Copy **client_id** and the **secret** for **Sandbox** (or Development / Production).  
3. In the app: **Settings → Plaid developer account** → paste keys → pick environment → **Save**.  
4. **Link bank account** (Sandbox: search “First Platypus Bank”, user `user_good` / pass `pass_good`).  
5. On **Transactions**, tap **Sync → Sync now**.

Secrets live in the **Keychain** on device. Do not commit them to git.

## What Sync does

Toolbar **Sync** menu:

### Sync now (incremental)

```text
For each linked Plaid Item:
  /item/get → institution + login-error status (Relink banner)
  loop /transactions/sync with stored cursor
    added + modified → upsert expense or income (with enrichment)
    pending_transaction_id → drop pending twin when posted arrives
    removed → delete local row
  /accounts/get + /liabilities/get
  /transactions/recurring/get → RecurringStream (add-on; soft-fail)
  save next_cursor for that Item
Reload widget timelines
```

Pending transactions are stored and merged into posted rows via `pending_transaction_id`. UI prefers `authorized_date` when present.

### Force bank refresh

Calls `/transactions/refresh` (optional paid add-on) before the normal cursor sync so Plaid does an on-demand bank pull. Soft-fails if the product is not enabled.

### Full re-sync

Same as Sync now, but **clears cursors** first so Plaid re-sends the full transaction stream for each Item (use after schema resets or missing history).

### Link bank account (Hosted Link)

In-app WKWebView Link is **deprecated**. Finance Wizard uses [Hosted Link](https://plaid.com/docs/link/hosted-link/) in an `ASWebAuthenticationSession`:

```text
1. POST /link/token/create with hosted_link:
     is_mobile_app: true
     completion_redirect_uri: financewizard://hosted-link-complete
2. Open response.hosted_link_url in ASWebAuthenticationSession
3. User completes Link (including bank OAuth) in the secure browser
4. Browser redirects to financewizard://hosted-link-complete → session closes
5. POST /link/token/get  → public_token
6. POST /item/public_token/exchange
7. Store access_token (Keychain) + item metadata
```

No Dashboard allowlist is required for `completion_redirect_uri` (custom scheme). Optional `redirect_uri` (https Universal Link) is only for Production app-to-app OAuth.

## Plaid endpoints used

| Endpoint | Purpose |
|----------|---------|
| `POST /link/token/create` | Link session: `transactions` + `liabilities` when supported (up to 730 days) |
| `POST /item/public_token/exchange` | public_token → access_token + item_id |
| `POST /transactions/sync` | Incremental transaction updates (cursor-based) |
| `POST /transactions/refresh` | On-demand bank pull (optional add-on; Force bank refresh) |
| `POST /transactions/recurring/get` | Subscription / payroll streams (optional add-on) |
| `POST /accounts/get` | Balances and credit limits |
| `POST /item/get` + `/institutions/get_by_id` | Institution id, login errors, logo, primary color |
| `POST /liabilities/get` | Credit APR, min payment, due dates, statement balance |
| `POST /item/remove` | Optional unlink on Plaid side |

### Webhooks

Live Worker (Cloudflare free tier + KV):

```text
https://plaid-webhooks.lavavex.workers.dev/plaid/webhook
```

- Health: `GET https://plaid-webhooks.lavavex.workers.dev/health`
- Pending events: `GET https://plaid-webhooks.lavavex.workers.dev/pending?item_id=…`

The app sends this URL as `webhook` on every `/link/token/create` (Link + Relink). You can also set the same URL in the Plaid Dashboard for team-level defaults.

**Important webhooks we handle (by code):**

| Type | Code | Meaning |
|------|------|---------|
| TRANSACTIONS | `SYNC_UPDATES_AVAILABLE` | New/changed txs — tap Sync |
| TRANSACTIONS | `RECURRING_TRANSACTIONS_UPDATE` | Recurring streams changed |
| TRANSACTIONS | `INITIAL_UPDATE` / `HISTORICAL_UPDATE` / `DEFAULT_UPDATE` / `TRANSACTIONS_REMOVED` | Legacy / extra signals |
| ITEM | `ERROR` (e.g. `ITEM_LOGIN_REQUIRED`) | Needs Relink |
| ITEM | `PENDING_EXPIRATION` / `USER_PERMISSION_REVOKED` | Needs Relink |

The Worker **stores** last event per Item in KV. The iOS app does **not** auto-sync from webhooks yet (no push path into SwiftData without your access tokens on a server). Use **Sync** in the app; `/item/get` still surfaces login errors on sync.

Host depends on Settings environment:

| Environment | Host |
|-------------|------|
| Sandbox | `https://sandbox.plaid.com` |
| Development | `https://development.plaid.com` |
| Production | `https://production.plaid.com` |

## How rows map into the app

Plaid amount convention:

| Plaid `amount` | App model |
|----------------|-----------|
| **> 0** (money out) | `Transaction` expense, stored **negative** |
| **< 0** (money in) | `Income`, stored **positive** |

- **Category** from `personal_finance_category` (mapped to Dining, Gas, …) unless a local learn rule or lock applies.  
- **Payment method** from account name + mask (e.g. `Checking ···0000`) or institution name.  
- **Transfers** (savings ↔ checking, internal moves) are **skipped** — never enter spend or income.  
- **Credit card bill payments** → `CreditCardPayment` (Accounts → Total paid) **and** a `Transaction` with category **Credit Card Payment** (list-visible, excluded from Total Spend).  
- **Credit balances / limits** come from `POST /accounts/get` on each Sync.  
- **Credit terms** (min payment, due date, last payment/statement, APRs, overdue) from `POST /liabilities/get` when the Item has Liabilities.  
- **Bank logo / brand color** from `POST /item/get` → `POST /institutions/get_by_id` (`include_optional_metadata`).  
- Pending rows are skipped by default.  
- Each Sync also cleans older expense/income rows whose titles look like transfers or card payments.  
- Banks linked **before** Liabilities was added may need a **re-link** so credit details can load.

### Local locks & learn rules

Editing a transaction **Save**s on device only:

- Sets `categoryLocked` / `multiplierLocked` so later syncs do not overwrite.  
- Optional **learn** stores a vendor rule (`VendorRulesStore`) applied on future Plaid upserts.

## File import

Toolbar **Import** menu:

| Option | Format |
|--------|--------|
| **JSON export** | Legacy finance-sync shape (`transactions[]`) |
| **Apple Card CSV** | Wallet / [card.apple.com](https://card.apple.com) CSV export |

### Apple Card CSV

Expected columns (header names are flexible): **Transaction Date**, **Description** / **Merchant**, **Amount (USD)**, optional **Category**, **Type** (`Purchase` / `Payment` / `Credit`).

| Type | Result |
|------|--------|
| Purchase | Expense on payment method **Apple Card** |
| Payment | **Credit Card Payment** (list + Total paid; not spend) |
| Credit / refund | **Income** category Refund |

Re-import updates the same rows via stable `applecard:…` ids.

## Security notes

- Your **Plaid secret is on the device**. Fine for a personal / family tool; not suitable for a public App Store multi-tenant product.  
- Prefer **Sandbox** while developing.  
- Production requires Plaid production approval and real bank OAuth (Universal Links / redirect URI may be required for OAuth institutions).  
- Access tokens never leave the device except to `*.plaid.com` over HTTPS.
