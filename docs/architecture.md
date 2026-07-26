---
layout: default
title: Architecture
---

# Architecture

## Targets

| Target | Product | Responsibility |
|--------|---------|----------------|
| **FinanceWidget** | iOS app | UI, Sync, import, settings, filters |
| **WidgetExtension** | `.appex` | Home Screen **Total Spend** widget |

The app embeds the widget extension (Embed Foundation Extensions build phase).

## Source folders

```text
FinanceWidget/          Main app (SwiftUI screens, sync, settings)
Shared/                 Model + store + filters (BOTH targets)
Widget/                 WidgetKit UI + configuration intents
docs/                   This documentation (GitHub Pages)
```

### Why `Shared/`?

SwiftData `@Model` types and `ModelConfiguration(groupContainer:)` must match **exactly** in app and widget. Compiling the same files into both targets avoids drift.

## Runtime data flow

```text
User taps Sync
    │
    ▼
POST {server}/api/plaid/sync     ──► PC pulls Plaid → SQLite
    │                                 (429/409 → continue anyway)
    ▼
GET  {server}/api/transactions?month=CURRENT
GET  {server}/api/transactions?month=PREVIOUS
    │
    ▼
Upsert by transactionId into SwiftData (App Group)
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
│     toolbar: Sync, Import
├── By Card        (CardsView → CardDetailView)
│     period + sort; per-card totals and rows
└── Settings       (SettingsView)
      server URL, months info
```

## Persistence

| Concern | Technology |
|---------|------------|
| Transactions | **SwiftData** `@Model` |
| Store location | **App Group** container via `ModelConfiguration(groupContainer:)` |
| App settings (server URL) | **UserDefaults** / `@AppStorage` |
| Widget config (period, hide cards) | **Widget configuration intent** (per widget instance) |

See [Data model](data-model.md).

## Server dependency (finance-sync)

The iOS app is a **client**. Bank linking, Plaid credentials, and SQLite live on the PC portal.

| On the PC | On the phone |
|-----------|----------------|
| Plaid Link / tokens | No bank passwords |
| Rate limits for Plaid | Handles 429 by still GETting JSON |
| Port 8787 HTTP API | Configurable base URL in Settings |

Details: [Sync & API](sync-and-api.md).

## Security notes

- Default API is **HTTP on LAN** — not for public internet without TLS + auth.
- No API key in the current contract (trusted network only).
- App Group isolates shared data to your app + extension, not other apps.
