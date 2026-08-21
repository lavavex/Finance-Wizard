---
layout: default
title: How it works
---

# How it works

End-to-end map of Finance Wizard: launch, data, Plaid, tabs, widgets. File names are the ones in the repo today.

Related: [Architecture](architecture.md) (folders), [Data model](data-model.md) (fields), [Sync & API](sync-and-api.md) (Plaid endpoints).

## Two processes, one store

| Process | Target | Entry |
|---------|--------|--------|
| App | `FinanceWizard` | `FinanceWizard/App/FinanceWizardApp.swift` (`@main`) |
| Widgets | `WidgetExtension` | `Widget/WidgetBundle.swift` (`@main`) |

They do **not** share memory. They share one SwiftData file via App Group `group.net.roberth.FinanceWizard`, opened by `Shared/Store/SharedStore.swift` (`makeContainer()`, store name `FinanceTransactions`).

```text
iPhone
├── Finance Wizard.app
│     FinanceWizardApp
│       ModelContainer (App Group)
│       RootWithSplash → OnboardingGate → Welcome or tabs
│       Plaid HTTPS (your keys)
└── Widget extension
      reads same ModelContainer
      no Plaid calls
```

## Launch

```text
FinanceWizardApp.init
  SharedStore.makeContainer()
  InstitutionLogoFetcher.start()          FinanceWizard/Services/InstitutionLogoFetcher.swift
  InstitutionLogoCache.seedBundledLogos() Shared/Branding/InstitutionLogoCache.swift
        │
        ▼
WindowGroup
  RootWithSplash                          FinanceWizard/App/SplashScreenView.swift
    overlay: SplashScreenView             same 256pt AppIconImage as Welcome
    under:   OnboardingGate               FinanceWizard/Features/Onboarding/OnboardingGate.swift
               │
               ├─ settings.onboardingCompleted == false
               │    OnboardingView        FinanceWizard/Features/Onboarding/OnboardingView.swift
               │    Get Started → @AppStorage true
               │
               └─ true
                    ContentView           FinanceWizard/App/ContentView.swift
```

Flag key: `OnboardingStore.storageKey` = `settings.onboardingCompleted` (`OnboardingStore.swift`). `@AppStorage` so the gate redraws. Opening a `.fwbackup` hits `onOpenURL` → `PlaidConnectionBackup` → Settings restore (`PlaidConnectionBackup.openFileNotification`).

## Tabs (`ContentView`)

Transactions is built at launch. Other tabs are **lazy** (`loadedTabs`) so cold start stays light.

| Tab | View | File |
|-----|------|------|
| Transactions | `AllTransactionsView` | `ContentView.swift` (same file) |
| Accounts | `CardsView` | `Features/Accounts/CardsView.swift` |
| Budget | `BudgetView` | `Features/Budget/BudgetView.swift` |
| Recurring | `SubscriptionsView` | `Features/Transactions/SubscriptionsView.swift` |
| Settings | `SettingsView` | `Features/Settings/SettingsView.swift` |

`screenshotPrivacy` is `@AppStorage` and pushed into the environment (`Shared/UI/ScreenshotPrivacy.swift`).

## Where money lives (SwiftData)

All `@Model` types are under `Shared/Models/` and listed in `SharedStore.schema`.

| Model | File | Role |
|-------|------|------|
| `Transaction` | `Transaction.swift` | Expenses, stored **negative** |
| `Income` | `Income.swift` | Money in, stored **positive** |
| `BankAccount` | `BankAccount.swift` | Plaid account snapshot (balances, credit) |
| `CreditCardPayment` | `CreditCardPayment.swift` | Card bill pays (not Total Spend) |
| `BudgetPlan` | `Budget.swift` | Caps, category limits, expected income |
| `RecurringStream` | `RecurringStream.swift` | Streams from Plaid recurring API (optional) |

**Sign rule:** Plaid amount `> 0` (money out) → `Transaction` negated. Plaid `< 0` (money in) → `Income` positive. Transfers are skipped. Card bill pays become `CreditCardPayment` **and** a `Transaction` with category Credit Card Payment (list only, excluded from spend).

Analytics that both app and widgets use (pure functions on arrays):

| Helper | File |
|--------|------|
| Period / sort / totals / snapshots | `Shared/Store/SharedStore.swift` (`TransactionAnalytics`, `SnapshotPeriod`) |
| Search | `Shared/Analytics/TransactionSearch.swift` |
| Review queue | `Shared/Analytics/ReviewQueueAnalytics.swift` |
| Recurring detection | `Shared/Analytics/SubscriptionAnalytics.swift` |
| Budget vs spend | `Shared/Analytics/BudgetAnalytics.swift` |
| Period indexes | `Shared/Analytics/PeriodSpendIndex.swift` |

## Plaid path

Credentials and tokens never go to a Finance Wizard server.

```text
Settings: client_id + env  → UserDefaults     PlaidCredentialsStore.swift
          secret           → Keychain         PlaidKeychain.swift
Link bank
  PlaidLinkView / PlaidLinkSheet              PlaidLinkView.swift
    POST /link/token/create  (hosted_link)
    ASWebAuthenticationSession
    bounce page pages/budgetmagi/             → financewizard://hosted-link-complete
    /link/token/get → public_token
    /item/public_token/exchange
    access_token → Keychain + metadata        PlaidItemStore.swift
Sync (toolbar or pull-to-refresh)
  PlaidSyncEngine.syncAll                     PlaidSyncEngine.swift
    HTTP via PlaidAPIClient                   PlaidAPIClient.swift
    map PFC → app category                    PlaidCategoryMapper.swift
    apply VendorRulesStore if unlocked        VendorRulesStore.swift
    upsert models in ModelContext
    InstitutionLogoCache
    WidgetCenter.reloadAllTimelines()
```

Webhook worker (`workers/plaid-webhooks/`) records Plaid events; the **app does not auto-sync** from them. User still taps Sync. Relink when `/item/get` says login expired.

## How each tab uses that data

### Transactions

`AllTransactionsView` `@Query`s `Transaction` and `Income`, filters with `TransactionAnalytics` + `PeriodFilterMenu.swift`. Rows: `TransactionRows.swift`. Tap → `TransactionDetailView.swift` (category / multiplier / rail / learn rule). Save sets locks so Sync won’t overwrite. **Needs review:** `ReviewQueueView.swift`. **Import:** JSON in `ContentView.swift`; Apple Card CSV in `Features/Import/AppleCardCSVImport.swift` (payment method Apple Card, `AppleCardAccount.swift`). Category charts: `CategorySpendView.swift` + `Shared/UI/CategorySpendChart.swift`.

### Accounts

`CardsView` builds `AccountsBoard` (`AccountsBoard.swift`) from transactions, accounts, and payments. Detail: `CardDetailView.swift` (nickname via `CardLabelStore.swift`, debit/ACH rails via `PaymentRail.swift`, rewards via `CardBenefitsStore.swift` + `CardProductCatalog.swift`). Logos: `Shared/UI/BankIcon.swift` + `InstitutionLogoCache`.

### Budget

`BudgetView` loads/creates `BudgetPlan` through `BudgetStore` in `Budget.swift`. `BudgetAnalytics` compares limits to `@Query` spend and income for the selected period.

### Recurring

`SubscriptionsView` scans local `Transaction`s with `SubscriptionAnalytics` (vendor + amount + cadence). User **Cancelled** / **Not Recurring** writes `transaction.subscriptionCadenceOverride`. Overlay GIF: `Resources/WorkingOverlay.gif` + `Shared/UI/BundleGIFView.swift`. Plaid `/transactions/recurring/get` may also fill `RecurringStream` on Sync (add-on; soft-fail).

### Settings

`SettingsView`: keys, Link/Relink/Unlink, backup (`PlaidConnectionBackup.swift`), privacy, About. **Debug:** `DebugMenuView.swift` (replay Welcome, wipes, counts). Export zip: `DebugDataExport.swift`.

## Widgets

Registered in `Widget/WidgetBundle.swift`:

| Widget | File | Data |
|--------|------|------|
| Total Spend | `Widget/Widgets/Widget.swift` (`FinanceHomeWidget`) | `SharedStore` spend snapshot; hide-cards is breakdown only |
| Category | `Widget/Widgets/CategorySpendWidget.swift` | category snapshot + `CategorySpendChartView` |
| Balances | `Widget/Widgets/BalancesWidget.swift` | depository balances |

Config intents: `Widget/AppIntent.swift`. Widgets never call Plaid; they only read the App Group store after the app syncs.

## Secrets vs prefs vs files

| Kind | Where | Examples |
|------|--------|----------|
| Secrets | Keychain | Plaid secret, Item access tokens |
| Prefs | `UserDefaults` prefixes `plaid.` / `card.` / `settings.` | client_id, env, cursors, vendor rules, nicknames, onboarding, screenshot privacy, card benefits |
| Logos | App Group files | `InstitutionLogoCache` |
| Encrypted backup | `.fwbackup` | `PlaidConnectionBackup` bags models + those prefixes + logos |

## Not wired yet (keep)

`FinanceWizard/Features/AI/` — `OnDeviceAI.swift` (Foundation Models) and `OnDeviceAIStatusView.swift`. Not in the tab bar or Settings. App icon source: `FinanceWizard/Mika.icon/` (Icon Composer).
