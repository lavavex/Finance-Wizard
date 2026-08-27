---
layout: default
title: Home
---

# Finance Wizard documentation

**Finance Wizard** is a personal iOS expense tracker. You connect banks with **your own Plaid keys**. Data stays on the iPhone. Home Screen widgets read the same store.

## User docs

For people installing from **TestFlight** (public beta soon).

| Page | What it covers |
|------|----------------|
| [Getting started](user/getting-started.md) | TestFlight, Welcome, Plaid keys, first Sync |
| [Using the app](user/using-the-app.md) | Tabs: Transactions, Accounts, Budget, Recurring |
| [Settings](user/settings.md) | Keys, banks, privacy, backup |
| [Widgets](user/widgets.md) | Total Spend, Category, Balances |
| [Help](user/help.md) | Link, Sync, empty list, Relink |

**[All user docs](user/index.md)**

## Developer / contributor docs

For people building, debugging, or changing the code.

| Page | What it covers |
|------|----------------|
| [Development](dev/development.md) | Xcode, signing, App Groups, GitHub PRs |
| [How it works](dev/how-it-works.md) | End-to-end map with file names |
| [Architecture](dev/architecture.md) | Targets, folders, launch tree, data flow |
| [Onboarding (implementation)](dev/onboarding.md) | Splash, gate, `settings.onboardingCompleted` |
| [Data model](dev/data-model.md) | SwiftData models, amounts, App Group |
| [Sync & API](dev/sync-and-api.md) | Plaid endpoints, mapping, webhooks |
| [Settings & Debug](dev/settings.md) | Implementation, Debug menu, build numbers |
| [Widgets (implementation)](dev/widgets.md) | Kinds, timeline, App Group |
| [Troubleshooting](dev/troubleshooting.md) | Build errors, console, Welcome flag |
| [Publishing this wiki](dev/github-pages.md) | GitHub Pages from `docs/` |

**[All developer docs](dev/index.md)**

## License / privacy

[MIT](../LICENSE). You supply Plaid keys. Bank passwords stay inside Plaid Link. Access tokens and the API secret stay on device.
