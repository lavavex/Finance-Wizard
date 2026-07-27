---
layout: default
title: Home
---

# Finance Wizard documentation

**Finance Wizard** is a personal iOS app for tracking expenses: sync from a home **finance-sync** server (Plaid → SQLite → JSON API), store data in **SwiftData** (App Group), browse by card, and show **Total Spend** on a Home Screen widget.

This site is the project wiki: everything needed to build, run, configure, and extend the app.

## Contents

| Page | What it covers |
|------|----------------|
| [Getting started](getting-started.md) | Xcode open, signing, App Groups, first run, Sync |
| [Architecture](architecture.md) | Targets, folders, data flow diagram |
| [Data model](data-model.md) | `Transaction`, upserts, App Group store |
| [Sync & API](sync-and-api.md) | Plaid sync, months pulled, rate limits, endpoints |
| [App features](app-features.md) | Tabs, filters, By Card, SF Symbols |
| [Widget](widget.md) | Total Spend widget, config, hide cards |
| [Settings](settings.md) | Server URL, defaults |
| [Development](development.md) | Shared code, git, conventions |
| [Troubleshooting](troubleshooting.md) | Common build / network / store issues |
| [Publishing this wiki](github-pages.md) | How to turn this `docs/` folder into GitHub Pages |

## Quick mental model

```text
┌─────────────────┐     POST /api/plaid/sync      ┌──────────────────┐
│  Finance Wizard │ ────────────────────────────► │  finance-sync    │
│  iOS app        │ ◄── GET /api/transactions ─── │  (home PC :8787) │
└────────┬────────┘     (current + prev month)    └────────┬─────────┘
         │                                                 │
         │ SwiftData (App Group)                           │ Plaid
         ▼                                                 ▼
┌─────────────────┐                               ┌──────────────────┐
│  Widget         │ reads same store              │  Banks / cards   │
│  Total Spend    │                               └──────────────────┘
└─────────────────┘
```

## Requirements

- **Xcode** (project targets recent iOS; open the `.xcodeproj` on a Mac)
- **Apple Developer team** (Personal Team is fine for device/simulator signing)
- **finance-sync** portal on the LAN (default `http://openwindow.local:8787`) for Sync
- Same **App Group** on app + widget: `group.net.roberth.FinanceWizard`

## Repo layout (source)

```text
Finance Wizard/                ← git root (local folder name)
  FinanceWizard/               ← main app sources
  Shared/                      ← SwiftData model + analytics (app + widget)
  Widget/                      ← WidgetKit extension
  WidgetExtension.entitlements
  FinanceWizard.xcodeproj
  docs/                        ← this GitHub Pages site
```

## License / privacy

Personal project. No bank credentials live in the app—Plaid linking stays on the PC portal. The iOS app only talks to your trusted LAN API over HTTP (enable local networking / ATS as documented in Getting started).
