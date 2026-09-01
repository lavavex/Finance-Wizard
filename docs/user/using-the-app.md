---
layout: default
title: Using the app
---

# Using the app

Install and first Sync: [Getting started](getting-started.md).

## First launch

Splash (app icon) → **Welcome** → **Get Started** → tabs. Later launches skip Welcome.

## Transactions

Your charges and income for the selected period.

- **Total Spend** — purchases this week / month / all time (all cards). Tap for category charts (bars or pie).
- **Total Income** — money in for the same period (not part of spend).
- **Net** — income minus spend.
- Hiding a card from the list does **not** change the totals.

**Income** and **Expenses** are separate lists. Pull down to **Sync**. Toolbar:

| Control | What it does |
|---------|----------------|
| **Sync** | Sync now, Full re-sync, Link bank account |
| Search | Title, category, amount, last four, nickname |
| Calendar | This week / This month / All time |
| Sort | Date, amount, name |
| Eye | Hide cards from the **list only** |
| **Import** | JSON export, or **Apple Card CSV** from Wallet / [card.apple.com](https://card.apple.com) |

**Needs review** — items that still need a category, rate, or bill-pay check. Swipe to fix.

Tap a row for **Transaction** detail. You can change **category** and **points multiplier**. **Save** remembers that so later Syncs don’t overwrite it. Turn on **learn** to apply the same category to future charges from that merchant.

**Recurring** on that screen: **Auto-detect**, **Yearly**, **Monthly**, **Weekly**, or **Not recurring**. Use **Monthly** or **Yearly** for bills whose amount changes, like phone and electric — the Recurring tab groups that merchant even when the dollar amount is different each time.

**Credit Card Payment** (shown as “Bill pay”) is a payment to a card, not a purchase. It stays in the list but is **not** in Total Spend, charts, or widgets. It also shows under Accounts → Total paid. Checking ACH and the card’s “Thank You” are the **same** payment — Total paid counts it once even if the bank posts them a day or two apart.

**Refund** / **Loan** / **Installment** also stay in the list but are **not** Total Spend or Total Income. Card statement credits (travel credit, merchant returns) and My Loan deposits to checking are not paychecks. Apple Card **Monthly Installments** are the billing of a purchase already in the list — use **Pay over time…** if you want them on Recurring.

## Accounts

Credit cards plus checking and savings.

| You’ll see | Meaning |
|------------|---------|
| **Total Spend** | Purchases this period (tap for categories) |
| **Total paid** | Card bill payments (not spend) |
| **Credit balance / limit / utilization** | From your bank on Sync |
| **Min payments / next due** | When the bank reports them |
| **Upcoming bills** | Due in the next 30 days (or overdue) |

Open an account to rename it. On checking, you can set **Debit** vs **ACH** reward rates. Pull down to Sync.

### Payoff plans (My Loan, Pay Over Time, promo APR)

On a **credit card**, **Payoff plans** tracks balances you are paying down on a schedule. These are **not** the same product:

| Type | What it is |
|------|------------|
| **My Loan** | Lump sum from the card’s credit line (Chase My Loan). Chase posts it as a **charge** on the card (e.g. “My Chase Loan TO 2667”). Open that charge → **My Loan…**, or add a plan on the card and **Choose loan charge**. Then set the fixed payment, APR, and term. |
| **Pay Over Time** | A **purchase** split into installments (Chase Pay Over Time, Amex Plan It). Monthly payment plus an optional plan fee. Add from the **transaction**, or from the card. |
| **Promo APR** | A slice of the card balance at 0% (or special APR) until a date — e.g. AmEx intro APR. If the card’s purchase APR is **0%**, **Add payoff plan** starts as Promo APR with the statement balance. Set remaining to the **promo** balance if it is not the whole card. |
| **Balance payoff** | Any other scheduled payoff on that card. |

**Record this month’s payment** reduces remaining by the monthly payment. Plans also appear on the **Recurring** tab (calendar + estimated monthly). They do **not** change Total Spend; they are a schedule on top of the card balance.

### Rewards on a card

On a credit card you can pick a **product** (so rates match the real card), edit earn rates and boosts, and see estimated rewards vs annual fee. Transaction detail can lock **travel earn** (Auto / Portal / Direct).

There are two kinds of categories: **spend** categories (Dining, Gas, …) and **reward** categories (Drugstores, Travel portal, …). The app maps a purchase into a reward bucket for estimates.

## Ask

Circular **Ask** button, bottom-right, above the tab bar (not a sixth tab — that would open iOS **More**). On-device chat (Apple Intelligence). It looks up **totals, balances, recurring, and recent charges** when needed. Card names match the nicknames you set in Accounts (not the bank’s “Credit Card” label). Replies stream in; you can tap a suggested follow-up. The conversation is saved on this device. Simulator cannot run the model; use a real iPhone or **My Mac (Designed for iPhone)**.

Transaction detail: **Suggest with Apple Intelligence** picks a category from the app’s list.

## Recurring

Detected subscriptions and repeating bills. Fixed-price subs need the same merchant and amount on a schedule. Phone, electric, and similar bills can **vary** — mark one charge **Monthly** or **Yearly** on Transaction detail, or the app may pick them up when the cadence is regular. A **month grid** at the top marks **next charge** days; tap a day to list those charges under the calendar. **Active** vs **Ended** (including ones you mark **Cancelled** or **Not Recurring**). Shows next charge and estimated monthly total (`~` when the amount changes). Tap a row for the charges.

**Payoff plans** (My Loan, Pay Over Time, promo APR) are listed here too and count toward Est. Monthly. Add **Pay Over Time** from a purchase, **My Loan** from the My Chase Loan charge (or the card).

## Budget

A **monthly cap**, **expected income**, and **per-category limits** compared to real spend. Remaining / over updates as new charges sync.

## Settings

[Settings](settings.md) — Plaid keys, banks, privacy, backup.

## What the app does not do yet

- Live Apple Card feed (CSV import only)
- Push alerts when you go over budget (the Budget tab still shows remaining / over)
- Syncing the same data to another iPhone automatically (use backup, or Sync from Plaid again)
- A Finance Wizard server that holds your Plaid secret (keys stay on the phone)
