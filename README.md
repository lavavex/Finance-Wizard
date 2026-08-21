<p align="center">
  <img src="FinanceWizard/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="120" height="120" alt="Finance Wizard">
</p>

<h1 align="center">Finance Wizard</h1>

<p align="center">
  <strong>Your banks. Your keys. On your iPhone.</strong>
</p>

<p align="center">
  A personal expense tracker for iOS&nbsp;26+.<br>
  Connect accounts with <em>your</em> Plaid developer keys.<br>
  Nothing is uploaded to a Finance Wizard server.
</p>

<p align="center">
  <a href="docs/user/getting-started.md"><strong>Get the TestFlight beta</strong></a>
  ·
  <a href="docs/user/index.md">User guide</a>
  ·
  <a href="docs/user/help.md">Help</a>
</p>

---

## What it does

| | |
|---|---|
| **Transactions** | Every charge and paycheck in one list. Fix categories. Sync when you want. |
| **Accounts** | Cards, checking, and savings — balances, utilization, bills coming due. |
| **Budget** | A monthly cap and category limits against real spend. |
| **Recurring** | Subscriptions and repeating bills, with next-charge dates. |
| **Widgets** | Total Spend, spend by category, and cash balances on the Home Screen. |

Apple Card is imported from a **CSV** (Wallet / card.apple.com). There is no live Apple Card feed.

## How your data stays yours

- Bank passwords are entered only in **Plaid’s** sign-in screen.
- Access tokens and your Plaid **secret** live in the iPhone Keychain.
- Transactions live in SwiftData on this device (shared with widgets).
- Optional encrypted **backup** if you want a copy you control.

You need a [Plaid developer account](https://dashboard.plaid.com) (free Sandbox is enough to try it).

## Get started

1. Install **TestFlight**, then Finance Wizard (public beta soon — link will go in the [getting started](docs/user/getting-started.md) guide).
2. Open the app → **Welcome** → **Get Started**.
3. **Settings** → paste your Plaid `client_id` and **secret** → **Save**.
4. **Link bank account** → **Transactions → Sync**.

Full walkthrough: **[Getting started](docs/user/getting-started.md)**  
Tabs and widgets: **[Using the app](docs/user/using-the-app.md)** · **[Widgets](docs/user/widgets.md)**

## Documentation

| | |
|---|---|
| **[User docs](docs/user/index.md)** | TestFlight, how to use the app, Settings, help |
| **[Developer docs](docs/dev/index.md)** | Xcode, architecture, Plaid API, contributing |

Not affiliated with Plaid or Apple Card — only your own Plaid keys and Apple platforms.
