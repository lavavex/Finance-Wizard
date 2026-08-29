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

**Credit Card Payment** (shown as “Bill pay”) is a payment to a card, not a purchase. It stays in the list but is **not** in Total Spend, charts, or widgets. It also shows under Accounts → Total paid.

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

### Rewards on a card

On a credit card you can pick a **product** (so rates match the real card), edit earn rates and boosts, and see estimated rewards vs annual fee. Transaction detail can lock **travel earn** (Auto / Portal / Direct).

There are two kinds of categories: **spend** categories (Dining, Gas, …) and **reward** categories (Drugstores, Travel portal, …). The app maps a purchase into a reward bucket for estimates.

## Recurring

Detected subscriptions and repeating bills (same merchant + amount on a schedule). A **month grid** at the top marks **next charge** days; tap a day to list those charges under the calendar. **Active** vs **Ended** (including ones you mark **Cancelled** or **Not Recurring**). Shows next charge and estimated monthly total. Tap a row for the charges.

## Budget

A **monthly cap**, **expected income**, and **per-category limits** compared to real spend. Remaining / over updates as new charges sync.

## Settings

[Settings](settings.md) — Plaid keys, banks, privacy, backup.

## What the app does not do yet

- Live Apple Card feed (CSV import only)
- Push alerts when you go over budget (the Budget tab still shows remaining / over)
- Syncing the same data to another iPhone automatically (use backup, or Sync from Plaid again)
- A Finance Wizard server that holds your Plaid secret (keys stay on the phone)
