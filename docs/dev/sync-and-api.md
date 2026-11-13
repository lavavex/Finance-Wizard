---
layout: default
title: Sync & API
---

# Sync & Plaid API

Budget Magi talks **directly to Plaid** using **your** developer `client_id` and `secret`. There is no Budget Magi server in the path.

## Setup (once)

1. Create a free account at [dashboard.plaid.com](https://dashboard.plaid.com).  
2. Copy **client_id** and the **secret** for **Sandbox** or **Production**.  
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

Budget Magi uses [Hosted Link](https://plaid.com/docs/link/hosted-link/) in an `ASWebAuthenticationSession`:

```text
1. POST /link/token/create with hosted_link:
     is_mobile_app: true  (always — this is an ASWebAuthenticationSession)
     completion_redirect_uri: financewizard://hosted-link-complete
2. Open response.hosted_link_url in ASWebAuthenticationSession
3. User completes Link (including bank OAuth) in the secure browser
4. Browser redirects to financewizard://hosted-link-complete → session closes
5. Poll POST /link/token/get until public_token (keeps going while the sheet is open)
6. POST /item/public_token/exchange
7. Store access_token (Keychain) + item metadata
```

No Dashboard allowlist is required for `completion_redirect_uri` (custom scheme).

`redirect_uri` defaults to **`https://budgetmagi.pages.dev/`** (must be allowlisted in the Plaid Dashboard). Settings can override for a Universal Link.

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

The app sends this URL as `webhook` on `/link/token/create`:

```text
https://plaid-webhooks.lavavex.workers.dev/plaid/webhook
```

The Worker (`workers/plaid-webhooks/`) answers `200` and discards each webhook. It logs and stores nothing, and `GET /health` is its only other route. The app doesn’t depend on webhooks: Hosted Link finishes by polling `/link/token/get`, `/item/get` reports login errors, and **Sync** pulls the data.

Hosted Link’s `redirect_uri` is a separate requirement: OAuth banks need the `budgetmagi.pages.dev` page in `pages/budgetmagi/`.

Host depends on Settings environment:

| Environment | Host |
|-------------|------|
| Sandbox | `https://sandbox.plaid.com` |
| Production | `https://production.plaid.com` |

Plaid environments in the app are **Sandbox** and **Production**. A stored `development` value maps to Sandbox.

## How rows map into the app

Plaid amount convention:

| Plaid `amount` | App model |
|----------------|-----------|
| **> 0** (money out) | `Transaction` expense, stored **negative** |
| **< 0** (money in) | `Income`, stored **positive** |

- **Category** from `personal_finance_category` (mapped to Dining, Gas, …) unless a local learn rule or lock applies.  
- **Payment method** from account name + mask (e.g. `Checking ···0000`) or institution name.  
- **Transfers** (savings ↔ checking, internal moves) are **skipped** — never enter spend or income.  
- **Clean-up** treats a bank as linked if its metadata exists, so a failed Keychain read can't remove accounts. Duplicate income is removed only on the first complete Sync after a bank is linked again as a new Item, because identical deposits can be real.  
- **Person to Person** rows (Zelle, Venmo, Cash App, Square Cash, PayPal, Apple Cash) are kept. Money sent counts as spend in the **Person to Person** category. Money received is listed under Income but isn't part of Total Income.  
- **Balance transfers** on a card are filed as **Balance Transfer**, excluded from spend. Their fees stay in **Fees**.  
- **Payroll:** after each Sync, a paycheck-sized deposit from a source Plaid has tagged as salary or wages elsewhere is labeled **Payroll**, because Plaid can tag an employer that's also a merchant as a purchase.  
- **Learned rules** (`VendorRulesStore`) map a vendor, and optionally a card, to a category. A rule can also cover one exact amount of a vendor, which is how a bare PAYMENT line keeps separate categories for separate bills. An amount rule wins over a general one.  
- **Payroll codes:** `Income.rawName` keeps Plaid's `original_description`. `nameIncomeByPayrollCode` gives a paycheck known only by its bank line the employer name from another paycheck whose bank line shares a long token with it, when that token belongs to one employer.  
- Expense categories follow Plaid’s published names, and `ClassifierTaxonomyTests` checks every spend category in that list. A category fix reaches existing rows on **Full re-sync**, which keeps categories you locked.  
- **Credit card bill payments** → `CreditCardPayment` (Accounts → Total paid) **and** a `Transaction` with category **Credit Card Payment** (list-visible, excluded from Total Spend).  
- **Bank lines that hide the payee:** `pairVaguePaymentsWithCards` runs after every Sync. A depository row titled only PAYMENT, ACH PMT or similar becomes a Credit Card Payment when a linked card has a payment row of the same amount from five days before to two days after, and no other bank row already claims it. It adds no `CreditCardPayment`, since the card's own row is the record. Category locks are respected.  
- **Credit balances / limits** come from `POST /accounts/get` on each Sync.  
- **Credit terms** (min payment, due date, last payment/statement, APRs, overdue) from `POST /liabilities/get` when the Item has Liabilities.  
- **Bank logo / brand color** from `POST /item/get` → `POST /institutions/get_by_id` (`include_optional_metadata`).  
- Pending rows are skipped by default.  
- Each Sync also drops expense/income rows whose titles look like transfers or card payments.  
- Relink if credit details (min payment, due date, APRs) are missing — Link requests Liabilities.

### Local locks & learn rules

Editing a transaction **Save**s on device only:

- Sets `categoryLocked` so later syncs do not overwrite.  
- Optional **learn** stores a vendor rule (`VendorRulesStore`) applied on future Plaid upserts.

## Backup

Settings **Backup & restore** writes an encrypted `.fwbackup` of this phone (keys, banks, SwiftData, prefs, logos). Restore accepts only the current backup format version and its exact PBKDF2 cost; other files are rejected.

| Policy | Banks already on the device | Other banks | Budget and payoff plans |
|--------|-----------------------------|-------------|-------------------------|
| **Safe merge** | Token, cursor, and rows are untouched. Backup rows are skipped, because the live cursor is past them and Sync would not repair them. | Token, cursor, and missing rows are added. | Newer `updatedAt` wins |
| **Replace connections** | Backup token and cursor win, and existing rows take the backup’s values (category and rail locks stay). Sync replays from the restored cursor. | Same | Newer `updatedAt` wins |
| **Wipe device, then restore** | Local data is deleted first. If the restore fails, the previous data is put back from an in-memory copy. | Same | Backup’s copy |

Rows are matched to a bank by Plaid account id, then account label (`Name ···1234`), then institution name. A row that matches no bank, such as an imported card, can’t be re-downloaded, so safe merge adds it if it’s missing.

The app deletes its temporary `.fwbackup` copies and debug exports after a restore or share, and at launch.

## Security notes

- Your **Plaid secret is on the device**. Fine for a personal / family tool; not suitable for a public App Store multi-tenant product.  
- Prefer **Sandbox** while developing.  
- Production requires Plaid production approval and real bank OAuth (Universal Links / redirect URI may be required for OAuth institutions).  
- Access tokens never leave the device except to `*.plaid.com` over HTTPS.
