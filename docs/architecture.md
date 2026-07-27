---
layout: default
title: Architecture
---

# Architecture

## Targets

Two separate products share one Xcode project and the same App Group store:

| Target | Product | Bundle ID | Responsibility |
|--------|---------|-----------|----------------|
| **FinanceWizard** | Finance Wizard (iOS app) | `net.roberth.FinanceWizard` | UI, Plaid Link, sync, settings |
| **WidgetExtension** | Widget extension (`.appex`) | `net.roberth.FinanceWizard.Widget` | Home Screen **Total Spend** (and category) widgets |

The app embeds the widget extension (Embed Foundation Extensions build phase). They ship together but are signed and built as separate targets.

App Group (shared store): `group.net.roberth.FinanceWizard`

## Source folders

```text
FinanceWizard/          Main app (SwiftUI + Plaid client)
  Plaid/                Credentials, Link, /transactions/sync
Shared/                 Model + store + filters (BOTH targets)
Widget/                 WidgetKit UI + configuration intents
docs/                   This documentation (GitHub Pages)
```

### Why `Shared/`?

SwiftData `@Model` types and `ModelConfiguration(groupContainer:)` must match **exactly** in app and widget. Compiling the same files into both targets avoids drift.

## Runtime data flow

```text
User saves Plaid client_id + secret (Keychain)
    │
    ▼
Link bank → /link/token/create → Plaid Link → /item/public_token/exchange
    │
    ▼
access_token stored on device (per Item)
    │
    ▼
User taps Sync
    │
    ▼
/transactions/sync (cursor) for each Item  ──► Plaid API (HTTPS)
    │
    ▼
Upsert expenses + income into SwiftData (App Group)
    │
    ▼
@Query refreshes app UI
WidgetCenter.reloadAllTimelines()
    │
    ▼
Widget reads SharedStore.loadSnapshot(...)
```

## UI structure (app)

```text
TabView
├── Transactions   (AllTransactionsView)
│     filters: period, sort, hide cards (list only)
│     toolbar: Sync (Plaid), Import, filters
├── By Card        (CardsView → CardDetailView)
│     period + sort; per-card totals and rows
└── Settings       (SettingsView)
      Plaid keys, environment, linked banks
```

## Persistence

| Concern | Technology |
|---------|------------|
| Transactions / income | **SwiftData** `@Model` in App Group |
| Plaid secret + access tokens | **Keychain** |
| Client id, env, cursors, vendor rules | **UserDefaults** |
| Widget config (period, hide cards) | **Widget configuration intent** |

See [Data model](data-model.md).

## No home server

Bank linking and transaction pull run **on the phone** against Plaid. There is no finance-sync PC portal in this architecture.

## Security notes

- Plaid **secret on device** is intentional for a personal BYO-key app; do not ship this pattern as a multi-user commercial product without a backend.  
- HTTPS only to `*.plaid.com`.  
- App Group isolates shared data to your app + extension.
