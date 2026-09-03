---
layout: default
title: Architecture
---

# Architecture

## Targets

The app and widget share one Xcode project and the same App Group store. Tests host the app:

| Target | Product | Bundle ID | Responsibility |
|--------|---------|-----------|----------------|
| **FinanceWizard** | Finance Wizard (iOS app) | `net.roberth.FinanceWizard` | UI, Plaid Link, sync, settings |
| **WidgetExtension** | Widget extension (`.appex`) | `net.roberth.FinanceWizard.Widget` | Total Spend, Category Spend, Balances widgets |
| **FinanceWizardTests** | Unit tests (`.xctest`) | `net.roberth.FinanceWizard.tests` | Classifier descriptor table |

The app embeds the widget extension (Embed Foundation Extensions build phase). They ship together but are signed and built as separate targets.

App Group (shared store): `group.net.roberth.FinanceWizard`

## UI

Prefer **native iOS**: SwiftUI system controls, SF Symbols, system materials. If SwiftUI has no equivalent, wrap the system UIKit control (`UIViewRepresentable`) instead of a custom or third-party widget.

## Source folders

Xcode uses **folder-synced** groups for `FinanceWizard/`, `Shared/`, `Widget/`, and `FinanceWizardTests/` — new files under those trees join the target automatically.

```text
FinanceWizard/                 Main app (SwiftUI + Plaid client)
  App/                         @main, splash, RootWithSplash → OnboardingGate
  Features/
    Onboarding/                Welcome, gate, completed-flag store
    Transactions/              List tools, detail, period filter, review, Recurring
    Accounts/                  Accounts hub, card detail, payoff plans, accounts board model
    Budget/                    Monthly budget UI
    Settings/                  Settings, backup, debug export, Debug menu
    AI/                        On-device Foundation Models (Ask overlay + Settings status)
  Services/                    App-only helpers (classify API stub, logo fetch)
  Plaid/                       Credentials, Link, /transactions/sync, backup wipe
                               (classification lives in Shared/Analytics — see below)
                               PlaidSyncEngine (sync) · PlaidSyncMaintenance (prune,
                               dedupe, one-off repair) · PlaidConnectionBackup (restore)
                               · PlaidBackupModels (.fwbackup snapshot shapes)

Shared/                        Compiled into APP + WIDGET (must stay in sync)
  Models/                      SwiftData @Model + domain enums
  Store/                       SharedStore / ModelContainer
  Analytics/                   Spend, review queue, subscriptions, search,
                               PlaidCategoryMapper (classification),
                               ClassifierRegression (descriptor table)
  Cards/                       Card nicknames
  Branding/                    Institution logo cache
  UI/                          Category style/charts, bank icons, privacy

FinanceWizardTests/            Hosted unit tests (`@testable import FinanceWizard`)

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

`Features/AI/` — availability on Settings. **Ask** overlay button on `ContentView` (sheet, not a sixth tab): tool calling, streaming, prewarm, persisted thread (separate store). `suggestCategory` on transaction detail.

### Cost of the hot paths

Measured against a real 3,232-transaction / 242-payment store:

| Path | Note |
|---|---|
| `CardLabelStore` nicknames | Cached in memory. Reading UserDefaults per lookup cost 2.4 ms per 3,232-row list pass vs 0.047 ms cached; lookups happen 1–3× per row. Writes refresh the cache; restore/wipe call `resetMemoryCache()`. |
| `CreditAnalytics.deduplicated` | O(n²) — 6.5 ms at 242 payments, ~69 ms at 1,000. Callers holding the output of `payments(in:period:)` must use `sumPaid` rather than `totalPaid`, which would dedupe a second time. |
| `ReviewQueueAnalytics.count` | Counts without building or sorting `ReviewQueueItem`s. Keep it in step with `items(...)`: both use `recentSpend` + `needsReview`. |
| `cleanLegacyMisclassifiedRows` | Full-scans Transaction and Income. Gated on `legacyCleanupVersion` so it runs once per classifier change, not once per sync. Bump that constant when classification rules change. |
| `AccountsBoard.build` | Groups transactions by payment method in one pass instead of filtering all rows per card. |
| `findCreditAccount` | Takes the preloaded account array (do not fetch `BankAccount` per payment row). |

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
RootWithSplash
├── SplashScreenView          (cold start overlay; matches Welcome icon)
└── OnboardingGate
      ├── OnboardingView      (Welcome, if settings.onboardingCompleted is false)
      └── ContentView TabView
            ├── Transactions  (AllTransactionsView)
            ├── Accounts      (CardsView → CardDetailView)
            ├── Budget        (BudgetView)
            ├── Recurring     (SubscriptionsView)
            └── Settings      (SettingsView → DebugMenuView)
```

See [How it works](how-it-works.md) for the file-level map. See [Onboarding](onboarding.md).

## Persistence

| Concern | Technology |
|---------|------------|
| Transactions / income | **SwiftData** `@Model` in App Group |
| Plaid secret + access tokens | **Keychain** |
| Client id, env, cursors, vendor rules, onboarding | **UserDefaults** (`plaid.` / `card.` / `settings.` prefixes) |
| Widget config (period, hide cards) | **Widget configuration intent** |

See [Data model](data-model.md).

## No home server

Bank linking and transaction pull run **on the phone** against Plaid.

## Security notes

- Plaid **secret on device** is intentional for a personal BYO-key app; do not ship this pattern as a multi-user commercial product without a backend.  
- HTTPS only to `*.plaid.com`.  
- App Group isolates shared data to your app + extension.
