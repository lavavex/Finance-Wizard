---
layout: default
title: Help
---

# Help

Install and setup: [Getting started](getting-started.md). Building the app? [Developer troubleshooting](../dev/troubleshooting.md).

## Plaid and Sync

### “Add your Plaid client_id and secret”

**Settings** → paste **client_id** and **secret** → pick **Sandbox** or **Production** → **Save credentials**. The secret must match that environment (Sandbox secret with Sandbox).

### Link closes immediately or never opens

- Allow the browser sheet when iOS asks.
- Save credentials again, then retry **Link bank account**.
- Sandbox only works with a Sandbox secret.

### “Link closed without linking a bank (or the session timed out)”

Finish the bank login in the browser sheet and wait for it to return to the app. Don’t swipe the sheet away while you’re still on Plaid. Sandbox: search **First Platypus Bank**, username `user_good`, password `pass_good`. Then try **Link** again.

### Link finishes but nothing shows up

Wait a few seconds and try **Link** again, or check Plaid Dashboard logs.

### Sync says no banks linked

**Settings → Link bank account**, then **Transactions → Sync → Sync now**.

### Sync works but the list is empty

- Wait a moment after the first link, then **Sync → Full re-sync**.
- Confirm the bank still appears under Settings.
- Pending (not posted) charges may not appear yet.

### Categories look wrong

Open the transaction → fix **category** → **Save** with **learn** on. Future Syncs keep that mapping.

### Bank says login expired

**Settings** → Relink that bank.

### Real-bank (Production) OAuth never returns to the app

Some banks need extra Plaid / redirect setup. Sandbox test banks usually don’t.

## Widgets

Sync in the app first, then add the widget. If it stays empty, delete it and add it again. More: [Widgets](widgets.md).

## Recurring

### How do I track Chase My Loan vs Pay Over Time vs an AmEx 0% promo?

They are different things:

- **My Loan / Pay Over Time / Apple installments** — attach the charge or installment row. Monthly amount is in the **card minimum**, due with the **statement**. Do not use **Pay off by date** for these.
- **Pay off by date** — Accounts → card → **Pay off by date**. For a promo or extra balance you want gone by a date. The form can suggest a monthly extra to finish by then.

Loan/installment **remaining** drops when a new statement posts (after Sync). Pay-off-by-date plans still have **Record this month’s payment** if you want to tick extra principal by hand.

### Total paid looks twice as high as I actually sent

The bank lists the payment on checking **and** on the card. Accounts → Total paid keeps one. Pull down to **Sync** if an older double-count is still showing.

### A travel credit or store refund showed up as income

Those are card credits, not paychecks. Sync files them as **Refund** (not Total Income). A loan disbursement into checking is **Loan**, not earnings. Payroll and other deposits to checking stay income.

### Phone or electric bill doesn’t show on Recurring

Auto-detect looks for the **same amount** on a schedule, so a bill that changes each month may be missing. Open one of those charges → **Recurring** → **Monthly** (or **Yearly**) → **Save**. The Recurring tab groups that merchant even when the amount varies. **Not recurring** on a single charge hides only that row; **Not Recurring** on the Recurring tab hides the whole vendor.

## Welcome screen

Welcome appears only on first launch. TestFlight **updates** keep your data and skip Welcome. To see Welcome again (testers): **Settings → Developer → Debug → Replay onboarding**.
