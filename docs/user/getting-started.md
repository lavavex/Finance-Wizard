---
layout: default
title: Getting started
---

# Getting started

This is for **people using Finance Wizard on an iPhone**, not for building the app in Xcode. Install comes from **TestFlight** (public beta soon). To compile from source, see [Development](../dev/development.md).

Finance Wizard keeps your bank data **on this device**. You connect banks with **your own Plaid developer keys**. Bank passwords are entered only in Plaid’s sign-in screen, never stored by the app.

## What you need

- An **iPhone** running **iOS 26** or later
- An **Apple ID** (for TestFlight)
- A free **[Plaid developer account](https://dashboard.plaid.com)** if you want to link banks
  - **Sandbox** — fake test banks (good for trying the app)
  - **Production** — real banks, if Plaid has enabled Production on your account

## 1. Install from TestFlight

1. On your iPhone, install **[TestFlight](https://apps.apple.com/app/testflight/id899247664)** from the App Store if you don’t have it.
2. Open the **TestFlight link** you were sent (public link will be posted here when it is live).
3. In TestFlight, tap **Finance Wizard** → **Install** (or **Update**).
4. Open **Finance Wizard** from the Home Screen.

Beta updates install through TestFlight. Feedback (screenshots, notes) can be sent from TestFlight if you hit a bug.

## 2. First launch

1. You’ll see a short **splash** (app icon), then **Welcome**.
2. Read the three points, tap **Get Started**.
3. The tab bar appears: **Transactions**, **Accounts**, **Budget**, **Recurring**, **Settings**.

Later launches skip Welcome and go straight to the tabs.

## 3. Add your Plaid keys

Without keys, the app can’t talk to Plaid or open Link.

1. Sign up at [dashboard.plaid.com](https://dashboard.plaid.com).
2. Open **Developers → Keys**.
3. Copy **client_id** and the **secret** that matches the environment you will use (Sandbox secret with Sandbox, Production secret with Production).
4. In the app: **Settings**.
5. Under **Plaid account**, paste **client_id** and **secret**, pick **Environment**, tap **Save credentials**.

Keys stay on this iPhone (the secret is in the Keychain). They are not uploaded to a Finance Wizard server.

## 4. Link a bank and sync

1. **Settings → Link bank account** (or **Transactions → Sync → Link bank account**).
2. Finish sign-in in the system browser Plaid opens.
3. Go to **Transactions** → **Sync → Sync now** (or pull down to refresh).

**Sandbox (test banks):** search **First Platypus Bank**, username `user_good`, password `pass_good`.

After a successful sync, charges show on **Transactions**, cards and balances on **Accounts**. Pull down again anytime you want new activity.

If Link asks you to sign in again later, **Settings** → swipe the bank → **Relink**.

## 5. Find your way around

| Tab | What it’s for |
|-----|----------------|
| **Transactions** | Spend and income for a week/month, search, categories, **Sync** / **Import** |
| **Accounts** | Cards, checking/savings, utilization, bills due |
| **Budget** | Monthly cap and category limits vs real spend |
| **Recurring** | Detected subscriptions, repeating bills, and card payoff plans (My Loan, Pay Over Time, promo APR) |
| **Settings** | Plaid keys, linked banks, backup, privacy |

More detail: [Using the app](using-the-app.md).

**Apple Card:** there is no live Apple Card API. **Transactions → Import → Apple Card CSV** from Wallet / [card.apple.com](https://card.apple.com).

## 6. Home Screen widgets (optional)

After at least one Sync:

1. Home Screen → long-press → **+**
2. Search **Finance Wizard**
3. Add **Total Spend**, **Spend by Category**, and/or **Balances**
4. Long-press a widget → **Edit Widget** for week vs month (where available)

## 7. Privacy and backup

- **Settings → Hide for screenshots** — masks dollar amounts and card last-four if you share a picture of the app.
- **Settings → Backup & restore** — encrypted `.fwbackup` you can save (includes keys, banks, and data on this phone). Keep the password somewhere safe.

## If something goes wrong

| Symptom | Try |
|---------|-----|
| “Add your Plaid client_id and secret” | Save keys in Settings; secret must match **Environment** |
| Link closes immediately | Allow the browser sheet; Save credentials again |
| List empty after Sync | Wait a few seconds on first link, then **Sync → Full re-sync** |
| Login expired | Relink that bank in Settings |
| Welcome again / skip Welcome | Welcome is only the first launch. Rebuilds from TestFlight keep your data. |

More: [Help](help.md).

## Building the app yourself

Xcode, signing, and App Groups: [Development](../dev/development.md).
