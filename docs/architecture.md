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

Xcode uses **folder-synced** groups for `FinanceWizard/`, `Shared/`, and `Widget/` — new files under those trees join the target automatically.

```text
FinanceWizard/                 Main app (SwiftUI + Plaid client)
  App/                         @main, root ContentView, splash, app settings
  Features/
    Transactions/              List tools, detail, period filter, review, subs
    Accounts/                  Cards hub, card detail, accounts board model
    Budget/                    Monthly budget UI
    Settings/                  Settings + debug export
    Import/                    Apple Card CSV
  Services/                    App-only helpers (classify API stub, logo fetch)
  Plaid/                       Credentials, Link, /transactions/sync

Shared/                        Compiled into APP + WIDGET (must stay in sync)
  Models/                      SwiftData @Model + domain enums
  Store/                       SharedStore / ModelContainer
  Analytics/                   Spend, review queue, subscriptions, search
  Cards/                       Product catalog, benefits, nicknames
  Branding/                    Institution logo cache
  UI/                          Category style/charts, bank icons, privacy

Widget/                        WidgetKit extension
  WidgetBundle.swift           Entry + registered widgets
  AppIntent.swift              Configuration intents
  Widgets/                     Total Spend, Balances, Category Spend

docs/                          GitHub Pages documentation
```

### On-device AI (Foundation Models)

| | |
|---|---|
| **Framework** | `FoundationModels` (linked on **FinanceWizard** only) |
| **Min OS** | iOS **26** |
| **Where data stays** | Inference is on-device (Apple Intelligence); still prefer minimal transaction context in prompts |
| **Capability / entitlement** | None beyond what the system already requires for Apple Intelligence |

Feature code is not required for the app to build; use the framework when you add AI UI.

### Why `Shared/`?

SwiftData `@Model` types and `ModelConfiguration(groupContainer:)` must match **exactly** in app and widget. Compiling the same files into both targets avoids drift.

## Runtime data flow

```text
User saves Plaid client_id + secret (Keychain)
    │
    ▼
Link bank → /link/token/create (hosted_link) → ASWebAuthenticationSession
    → /link/token/get → /item/public_token/exchange
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
├── Cards          (CardsView → CardDetailView)
│     period spend by card, credit utilization, payments
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
