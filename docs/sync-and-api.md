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
  loop /transactions/sync with stored cursor
    added + modified → upsert expense or income into SwiftData
    removed → delete local row
  save next_cursor for that Item
Reload widget timelines
```

### Full re-sync

Same as above, but **clears cursors** first so Plaid re-sends the full transaction stream for each Item (use after schema resets or missing history).

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
| `POST /accounts/get` | Balances and credit limits |
| `POST /item/get` + `/institutions/get_by_id` | Institution id, logo, primary color |
| `POST /liabilities/get` | Credit APR, min payment, due dates, statement balance |
| `POST /item/remove` | Optional unlink on Plaid side |

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

## JSON file import

Toolbar **Import** still accepts a legacy export with a `transactions` array (finance-sync-shaped JSON) for offline backfill.

## Security notes

- Your **Plaid secret is on the device**. Fine for a personal / family tool; not suitable for a public App Store multi-tenant product.  
- Prefer **Sandbox** while developing.  
- Production requires Plaid production approval and real bank OAuth (Universal Links / redirect URI may be required for OAuth institutions).  
- Access tokens never leave the device except to `*.plaid.com` over HTTPS.
