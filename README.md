<div align="center">
  <img alt="Finance Wizard" src="FinanceWizard/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" height="128">

  <h1>Finance Wizard</h1>

  <img alt="iOS 26+" src="https://img.shields.io/badge/iOS-26+-black">
</div>

<p align="center">
  <b>Finance Wizard</b> is a personal expense tracker for iPhone.
  Connect your banks with <a href="https://dashboard.plaid.com">your own Plaid developer keys</a>,
  keep every charge on this device, and see spend, budgets, and recurring bills in a native SwiftUI app.
  Nothing is uploaded to a Finance Wizard server.
</p>

## TestFlight

Use the TestFlight build to try new features and report bugs before a public App Store release. Public beta is coming soon — the join link will live in the [getting started](docs/user/getting-started.md) guide.

<a href="docs/user/getting-started.md">
  <img width="80" height="80" alt="TestFlight" src="Resources/TestFlight.png">
</a>

## What you get

- **Transactions** — every charge and paycheck in one list. Fix categories. Sync when you want.
- **Accounts** — cards, checking, and savings: balances, utilization, bills coming due.
- **Budget** — a monthly cap and category limits against real spend.
- **Recurring** — subscriptions and repeating bills, with next-charge dates.
- **Widgets** — Total Spend, spend by category, and cash balances on the Home Screen.

Apple Card is imported from a **CSV** (Wallet / [card.apple.com](https://card.apple.com)). There is no live Apple Card API.

## Your data stays on the phone

Bank passwords are entered only in **Plaid’s** sign-in screen. Access tokens and your Plaid secret live in the iPhone Keychain. Transactions live in SwiftData on this device (widgets read the same store). Optional encrypted backup if you want a copy you control.

A free [Plaid](https://dashboard.plaid.com) account is enough to start (Sandbox uses fake test banks).

## Documentation

- [Getting started](docs/user/getting-started.md) — TestFlight, Welcome, Plaid keys, first Sync
- [Using the app](docs/user/using-the-app.md) — tabs, categories, Apple Card CSV
- [Settings](docs/user/settings.md) — keys, banks, privacy, backup
- [Widgets](docs/user/widgets.md) — Home Screen widgets
- [Help](docs/user/help.md) — Link, Sync, Relink, empty list

## Development

Thanks for taking a look. Start with the [developer docs](docs/dev/index.md) and [how it works](docs/dev/how-it-works.md). Agent rules: [`AGENTS.md`](AGENTS.md).

Not affiliated with Plaid or Apple Card — only your own Plaid keys and Apple platforms.
