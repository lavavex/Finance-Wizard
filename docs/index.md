---
layout: default
title: Home
---

# Finance Wizard documentation

**Finance Wizard** is a personal iOS expense tracker. You bring **your own Plaid developer keys**, link banks with Hosted Link, keep data in **SwiftData** (App Group), and put spend / balances on the Home Screen.

This site is the project wiki.

## Contents

| Page | What it covers |
|------|----------------|
| [Getting started](getting-started.md) | Xcode, signing, App Groups, Plaid keys, first Sync |
| [Onboarding](onboarding.md) | Splash, Welcome, completed flag, Debug replay |
| [Architecture](architecture.md) | Targets, folders, launch tree, data flow |
| [Data model](data-model.md) | SwiftData models, amounts, App Group store |
| [Sync & API](sync-and-api.md) | Plaid Link, `/transactions/sync`, mapping |
| [App features](app-features.md) | Tabs: Transactions, Accounts, Budget, Recurring, Settings |
| [Widget](widget.md) | Total Spend, Category Spend, Balances |
| [Settings](settings.md) | Plaid, backup, Debug menu |
| [Development](development.md) | Shared code, git, comments, agent rules |
| [Troubleshooting](troubleshooting.md) | Build, Plaid, Welcome, store |
| [Publishing this wiki](github-pages.md) | `docs/` → GitHub Pages |

## Quick mental model

```text
Launch → splash (app icon) → Welcome (first run) or tabs
                │
                ▼
┌─────────────────┐     Hosted Link + /transactions/sync    ┌──────────┐
│  Finance Wizard │ ──────────────────────────────────────► │ Plaid    │
│  iOS app        │                                         │ (BYO keys)│
└────────┬────────┘ ◄────────────────────────────────────── └────┬─────┘
         │ SwiftData App Group                                   │ banks
         ▼                                                       ▼
┌─────────────────┐                               ┌──────────────┐
│  Widgets        │ same store                    │ Linked accts │
└─────────────────┘                               └──────────────┘
```

## Requirements

- **Xcode 26+**, deployment **iOS 26**
- **Apple Developer team** (Personal Team is fine)
- **Plaid developer account** (Sandbox: [dashboard.plaid.com](https://dashboard.plaid.com))
- App Group on app + widget: `group.net.roberth.FinanceWizard`

## Repo layout

```text
Finance Wizard/              git root
  FinanceWizard/             app UI, Plaid/, Features/, App/
  Shared/                    SwiftData + analytics (app + widget)
  Widget/                    WidgetKit extension
  docs/                      this wiki
  AGENTS.md                  rules for coding agents
  FinanceWizard.xcodeproj
```

## License / privacy

Personal project. You supply Plaid keys. Bank passwords stay inside Plaid Link. Access tokens and the API secret stay on device.
