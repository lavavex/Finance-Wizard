---
layout: default
title: Home
---

# Finance Wizard documentation

**Finance Wizard** is a personal iOS expense tracker: connect **your own Plaid developer account**, link banks with Plaid Link, store data in **SwiftData** (App Group), browse by card, and show **Total Spend** on a Home Screen widget.

This site is the project wiki: everything needed to build, run, configure, and extend the app.

## Contents

| Page | What it covers |
|------|----------------|
| [Getting started](getting-started.md) | Xcode open, signing, App Groups, Plaid keys, first Sync |
| [Architecture](architecture.md) | Targets, folders, data flow diagram |
| [Data model](data-model.md) | `Transaction`, `Income`, upserts, App Group store |
| [Sync & API](sync-and-api.md) | Plaid Link, `/transactions/sync`, mapping |
| [App features](app-features.md) | Tabs, filters, Cards hub, SF Symbols |
| [Widget](widget.md) | Total Spend widget, config, hide cards |
| [Settings](settings.md) | Plaid credentials, linked banks |
| [Development](development.md) | Shared code, git, conventions |
| [Troubleshooting](troubleshooting.md) | Common build / Plaid / store issues |
| [Publishing this wiki](github-pages.md) | How to turn this `docs/` folder into GitHub Pages |

## Quick mental model

```text
┌─────────────────┐     /link/token/create        ┌──────────────────┐
│  Finance Wizard │ ────────────────────────────► │  Plaid API       │
│  iOS app        │     /transactions/sync        │  (your keys)     │
└────────┬────────┘ ◄──────────────────────────── └────────┬─────────┘
         │                                                 │
         │ SwiftData (App Group)                           │ Banks
         ▼                                                 ▼
┌─────────────────┐                               ┌──────────────────┐
│  Widget         │ reads same store              │  Linked accounts │
│  Total Spend    │                               └──────────────────┘
└─────────────────┘
```

## Requirements

- **Xcode 26+** (deployment target **iOS 26**; open the `.xcodeproj` on a Mac)
- **Apple Developer team** (Personal Team is fine for device/simulator signing)
- **Plaid developer account** (free Sandbox keys at [dashboard.plaid.com](https://dashboard.plaid.com))
- Same **App Group** on app + widget: `group.net.roberth.FinanceWizard`

## Repo layout (source)

```text
Finance Wizard/                ← git root (local folder name)
  FinanceWizard/               ← main app sources + Plaid/
  Shared/                      ← SwiftData model + analytics (app + widget)
  Widget/                      ← WidgetKit extension
  WidgetExtension.entitlements
  FinanceWizard.xcodeproj
  docs/                        ← this GitHub Pages site
```

## License / privacy

Personal project. You supply your own Plaid keys; bank passwords are entered only inside Plaid Link and never stored by the app. Access tokens and secrets stay on device.
