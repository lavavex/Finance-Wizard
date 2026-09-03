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

**Income** and **Expenses** are separate lists. **Total Income** is earnings (paychecks, direct deposits, interest). Merchant refunds, card credits, and loan proceeds stay in the expense list as **Refund** / **Loan** and do not inflate income. Pull down to **Sync**. Toolbar:

| Control | What it does |
|---------|----------------|
| **Sync** | Sync now, Full re-sync, Link bank account |
| Search | Title, category, amount, last four, nickname |
| Calendar | This week / This month / All time |
| Sort | Date, amount, name |
| Eye | Hide cards from the **list only** |

**Needs review** — items that still need a category or bill-pay check. Swipe to fix.

Tap a row for **Transaction** detail. You can change the **category** and **payment method**. **Save** remembers that so later Syncs don’t overwrite it. Turn on **learn** to apply the same category to future charges from that merchant.

**Recurring** on that screen: **Auto-detect**, **Yearly**, **Monthly**, **Weekly**, or **Not recurring**. Use **Monthly** or **Yearly** for bills whose amount changes, like phone and electric — the Recurring tab groups that merchant even when the dollar amount is different each time.

**Credit Card Payment** (shown as “Bill pay”) is a payment to a card, not a purchase. It stays in the list but is **not** in Total Spend, charts, or widgets. It also shows under Accounts → Total paid. Checking ACH and the card’s “Thank You” are the **same** payment — Total paid counts it once even if the bank posts them a day or two apart.

**Refund** / **Loan** / **Installment** also stay in the list but are **not** Total Spend or Total Income. Card statement credits (travel credit, merchant returns) and My Loan deposits to checking are not paychecks. Issuer **installment** billing (My Chase Plan, Amex Plan It) is the billing of a purchase already in the list — use **Pay over time…** if you want them on Recurring.

## Accounts

Credit cards plus checking and savings.

| You’ll see | Meaning |
|------------|---------|
| **Total Spend** | Purchases this period (tap for categories) |
| **Total paid** | Card bill payments (not spend) |
| **Credit balance / limit / utilization** | From your bank on Sync |
| **Min payments / next due** | When the bank reports them. **Interest saving balance** (on the card) is other balances in full plus this statement’s loan/installment payment — pay that to stay on the loan schedule without paying the loan off early. |
| **Upcoming bills** | Due in the next 30 days (or overdue). A due date more than a week old that the bank has not flagged overdue is treated as stale and dropped, so a bank that stops refreshing does not pin an old bill here forever. |

Open a card to see **all** activity by **statement period** (not the Accounts week/month filter). The card row on Accounts and the card screen always show the same cycle: **This statement** while one is open, **Last statement** when nothing has posted since the close.

Pull down to Sync.

### Loans, installments, and pay-off-by-date

On a **credit card**:

| | What it is |
|--|------------|
| **Loans & installments** | Open the **loan charge** or **installment** row. Enter remaining, remaining months, and the **statement payment**. **My Loan** also uses the **fixed APR** from the loan email (interest this statement = remaining × APR ÷ 12). **Pay Over Time** fee is payment minus remaining ÷ months. That payment is **already in the card minimum**. Chase: do not pay “Statement balance” or you pay the whole loan off at once; “Interest saving balance” includes the monthly loan payment. |
| **Pay off by date** | A plan to clear a promo (0% APR) or extra balance by a date you choose. Accounts → card → **Pay off by date**. Extra principal you intend to send with the statement payment. |

**Record this month’s payment** reduces remaining in the app. These show on **Recurring** on the card’s due date.

Open a card from Accounts to see **all** activity grouped by **statement** (close day from the bank). The Accounts week/month filter does not apply on that screen.

## Ask

Circular **Ask** button, bottom-right, above the tab bar (not a sixth tab — that would open iOS **More**). On-device chat (Apple Intelligence). It looks up **totals, balances, recurring, and recent charges** when needed. Card names match the nicknames you set in Accounts (not the bank’s “Credit Card” label). Replies stream in; you can tap a suggested follow-up. The conversation is saved on this device. Simulator cannot run the model; use a real iPhone or **My Mac (Designed for iPhone)**.

Transaction detail: **Suggest with Apple Intelligence** picks a category from the app’s list.

## Recurring

Detected subscriptions and repeating bills. Fixed-price subs need the same merchant and amount on a schedule. Phone, electric, and similar bills can **vary** — mark one charge **Monthly** or **Yearly** on Transaction detail, or the app may pick them up when the cadence is regular. A **month grid** at the top marks **next charge** days; tap a day to list those charges under the calendar. **Active** vs **Ended** (including ones you mark **Cancelled** or **Not Recurring**). Shows next charge and estimated monthly total (`~` when the amount changes). Tap a row for the charges.

**Extra bills** is subscriptions and other charges besides the card payment. **On your cards** is loans and installments that are already in the card minimum — they do not add to Extra bills. Pay-off-extra plans are extra principal you mean to send with the statement.

## Budget

A **monthly cap**, **expected income**, and **per-category limits** compared to real spend. Remaining / over updates as new charges sync. **Cards due** lists statement minimums in this period (loans/installments are already inside the min) plus any extra principal from a pay-off-by-date plan.

## Settings

[Settings](settings.md) — Plaid keys, banks, privacy, backup.

## Not included

- Apple Card (Plaid does not sync it)
- Push alerts when you go over budget (the Budget tab still shows remaining / over)
- Automatic sync to another iPhone (use backup, or Sync from Plaid on that phone)
- A Finance Wizard server that holds your Plaid secret (keys stay on the phone)
