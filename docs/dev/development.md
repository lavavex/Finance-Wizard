---
layout: default
title: Development
---

# Development

## Prerequisites

- macOS + **Xcode 26+** (iOS 26 SDK; Xcode 27 beta is fine)  
- **iOS 26** deployment target (app + widget)  
- Git  
- Optional: Plaid Sandbox keys for Sync testing  
- Optional: GitHub CLI / SSH keys for remote  

### Foundation Models (on-device AI)

The main app links Apple’s **`FoundationModels`** system framework (no extra entitlement or capability). Use it when you add AI features; nothing else is required in the project file beyond the link + iOS 26 target.

The Simulator cannot run the model. For local Ask testing, run **My Mac (Designed for iPhone)** — see [Troubleshooting](troubleshooting.md#apple-intelligence-on-the-simulator).

| Requirement | Notes |
|-------------|--------|
| **SDK / Xcode** | Xcode 26+ with iOS 26 (or newer) SDK |
| **Deployment target** | iOS **26.0** (both targets) |
| **Device** | [Apple Intelligence–compatible](https://www.apple.com/apple-intelligence/) hardware (e.g. iPhone 15 Pro+, recent M-series iPads) |
| **Settings** | **Apple Intelligence** enabled on the device/simulator that supports it |
| **Language / region** | Model availability can vary by language and region |
| **Runtime check** | Always read `SystemLanguageModel.default.availability` before using a session |

Docs: [Foundation Models](https://developer.apple.com/documentation/foundationmodels)

Availability is checked in Settings. **Ask** uses `makeAskSession` + tools. Keep `import FoundationModels` on the main target only; keep the widget free of AI unless you deliberately need it there.

Simulator: Apple Intelligence / Foundation Models support depends on host Mac + OS; prefer a supported physical device if the model reports unavailable.

Testers installing from TestFlight should use [Getting started](../user/getting-started.md), not this page.

## Building from source

1. On a Mac, open **`FinanceWizard.xcodeproj`** (git root) with **Xcode 26+**.
2. Select the **FinanceWizard** scheme (not only the widget extension).
3. Pick a simulator or a physical device running **iOS 26+**.

### Signing

1. **FinanceWizard** target → **Signing & Capabilities** → your **Team** (Personal Team is fine).
2. Repeat for **WidgetExtension** (same team).
3. Bundle IDs: app `net.roberth.FinanceWizard`, widget `net.roberth.FinanceWizard.Widget`.

### App Groups (required)

Both targets must enable:

```text
group.net.roberth.FinanceWizard
```

Entitlements: `FinanceWizard/FinanceWizard.entitlements`, `WidgetExtension.entitlements`. Without the shared group, widgets cannot see transactions the app saves.

### Shared code

| Folder | Role |
|--------|------|
| `Shared/` | SwiftData models, store, analytics (app **and** widget) |
| `FinanceWizard/` | App UI + Plaid client |
| `Widget/` | WidgetKit extension |

Folders are file-system synced — new `.swift` files join the target automatically.

## Opening & building

```bash
# From git root (Xcode 26+ / iOS 26 SDK)
open FinanceWizard.xcodeproj
```

In Xcode: scheme **FinanceWizard** (the app, not only the widget) → Run (⌘R).

Classifier changes must keep `Shared/Analytics/ClassifierRegression.swift` green:

```bash
xcodebuild -project FinanceWizard.xcodeproj -scheme FinanceWizard \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:FinanceWizardTests test
```

Or **Settings → Developer → Debug → Run classifier cases**.

### Running tests

Tests are hosted in the app, so they share its Keychain, UserDefaults, and App Group on that simulator. Use a simulator with no real data on it:

```bash
xcrun simctl create "FW Tests" "iPhone 17"
xcodebuild -project FinanceWizard.xcodeproj -scheme FinanceWizard \
  -destination 'platform=iOS Simulator,name=FW Tests' \
  -only-testing:FinanceWizardTests test
```

`BackupRestoreTests` covers restore merging, backup encryption, temporary files, and Keychain writes. Its wipe tests delete the simulator’s app data, so they are skipped unless you set `TEST_RUNNER_FW_DESTRUCTIVE_TESTS=1` for `xcodebuild`, and they still refuse to run if a bank is linked.

## Screenshots with demo data

`scripts/sim-shot.sh` needs Xcode 27.2 (release) and an iOS 27.1+ Simulator runtime (`xcodebuild -downloadPlatform iOS`). It builds the Debug app and captures each tab on iPhone 17 and iPhone Duo, creating those simulators if needed:

```bash
./scripts/sim-shot.sh                  # every tab, light mode
./scripts/sim-shot.sh budget accounts  # only these tabs
APPEARANCE=dark ./scripts/sim-shot.sh  # dark mode
SKIP_BUILD=1 ./scripts/sim-shot.sh     # reuse the last build
```

Images land in `.sim-shots/<device>/` (gitignored). iPhone Duo uses its own iOS runtime and has two displays (1398×2034 and 2007×2853). Only the active one has content, so the script captures both and keeps the one that isn't black.

The script uses these launch arguments, which also work from an Xcode scheme:

| Argument | Effect |
|----------|--------|
| `-demoData YES` | Debug only. Opens an in-memory store seeded with made-up rows (`FinanceWizard/App/DemoMode.swift`). The App Group database is not touched, and the widget still reads the App Group database. |
| `-screen <tab>` | Debug only. Opens `transactions`, `accounts`, `budget`, `subscriptions`, or `settings`. |
| `-settings.onboardingCompleted YES` | Skips Welcome for this launch. |

## Version & build numbers (local ↔ Xcode Cloud)

| Setting | Meaning |
|---------|---------|
| **MARKETING_VERSION** | User-facing version (e.g. `1.0`) → About **Version** |
| **CURRENT_PROJECT_VERSION** | Integer build → About **Build** / TestFlight |

**Xcode Cloud** stamps each archive with its own build counter, the same number you see in App Store Connect / TestFlight. The repo has no CI scripts.

**Local** builds use the value in `project.pbxproj`, which stays at `1`. Settings → About shows build 1 on a local install, and that number never reaches App Store Connect.

## Xcode project format (Xcode Cloud)

Newer local Xcodes may rewrite `project.pbxproj` to a newer **objectVersion**. An older Xcode Cloud image then fails with:

> cannot be opened because it is in a future Xcode project file format

If you see this, go to App Store Connect → your app → **Xcode Cloud** → workflow → **Environment** and pick an Xcode version at least as new as your Mac's.

**Also check the workflow project name:** it must open **`FinanceWizard.xcodeproj`**.

## Where to put code

| Change | Put it in |
|--------|-----------|
| App entry, splash, root gate | `FinanceWizard/App/` |
| Welcome / onboarding flag | `FinanceWizard/Features/Onboarding/` |
| Feature UI (transactions, accounts, budget, settings) | `FinanceWizard/Features/<Area>/` |
| App-only services (logo fetch, local helpers) | `FinanceWizard/Services/` |
| Plaid Link / sync / credentials | `FinanceWizard/Plaid/` |
| SwiftData models + domain enums | `Shared/Models/` (both targets) |
| ModelContainer / SharedStore | `Shared/Store/` |
| Analytics, search, period helpers | `Shared/Analytics/` |
| Card nicknames | `Shared/Cards/` |
| Category charts, icons, privacy UI | `Shared/UI/` |
| Institution logos | `Shared/Branding/` |
| Widget UI | `Widget/Widgets/` |
| Widget bundle + config intents | `Widget/` (root) |
| Docs wiki | `docs/user/` (testers), `docs/dev/` (contributors) |

Folders under `FinanceWizard/`, `Shared/`, and `Widget/` are **file-system synced** — new `.swift` files join the target automatically. Keep shared types in `Shared/` so app and widget stay aligned.

## Conventions used in this project

- **License:** [MIT](../../LICENSE).  
- **Comments:** short file headers + `///` for behavior and constraints. No Swift-syntax lectures. No LESSON / TYPE HERE dumps in shipping source.  
- **Docs:** every behavior change is updated in `docs/` in the same change.  
- Expenses from Plaid/API are **negated** when saved.  
- Upsert by `transactionId`, never blind-replace the whole DB on Sync.  
- Widget and app share **analytics** helpers so filters stay consistent.  

### Suggested reading order (if you’re learning the app)

0. `docs/dev/how-it-works.md` — how processes, Plaid, tabs, and widgets connect  
1. `FinanceWizard/App/FinanceWizardApp.swift` — how the app starts  
2. `FinanceWizard/App/SplashScreenView.swift` + `Features/Onboarding/` — splash → Welcome or tabs  
3. `Shared/Models/Transaction.swift` + `Shared/Store/SharedStore.swift` — data + totals  
4. `FinanceWizard/App/ContentView.swift` — tabs and main list  
5. `FinanceWizard/Plaid/PlaidSyncEngine.swift` — how bank data lands on disk  
6. Any feature screen under `FinanceWizard/Features/`  

## Git

Repo root is the folder that contains `.xcodeproj`, `FinanceWizard/`, `Shared/`, `Widget/`, and `docs/`.

**Public repo:** [github.com/lavavex/Finance-Wizard](https://github.com/lavavex/Finance-Wizard)

### Branches

| Branch | Role |
|--------|------|
| `dev` | Active development. Commit here. Open PRs here. |
| `main` | Shipped code: TestFlight, GitHub Pages. Updated by merging `dev` when ready. |

### Contributors

1. Fork on GitHub (or clone the public repo if you have write access).
2. Use **your** GitHub remote as `origin`. Add `upstream` if you forked:

```bash
git clone git@github.com:YOUR_USER/Finance-Wizard.git
cd Finance-Wizard
git remote add upstream git@github.com:lavavex/Finance-Wizard.git
```

3. Branch from **`dev`**, commit, `git push origin your-branch`, open a pull request against **`lavavex/Finance-Wizard`** targeting **`dev`**.
4. Do not put LAN git hosts, personal SSH keys, or machine Xcode paths in committed docs. Those belong in **`docs/local/`** (gitignored except `docs/local/README.md`).

Typical ignore (see `.gitignore`): `xcuserdata/`, `DerivedData/`, `.DS_Store`, `docs/local/*` (except the README), local `AGENTS.md`.

See also: [GitHub Pages](github-pages.md).

## Testing Sync (Sandbox)

1. Use Sandbox keys + First Platypus Bank (`user_good` / `pass_good`).  
2. First **Sync now** may take a few seconds while product data becomes ready.  
3. Second **Sync now** should be incremental (cursor) and return few or no new rows.  
4. **Full re-sync** clears cursors and re-pulls history.  

## Previews

SwiftUI `#Preview` uses in-memory `modelContainer` where possible so the canvas does not need the App Group.

## Leftovers (historical names, still used)

| Item | Status |
|------|--------|
| `Features/AI/` | Settings availability, Ask overlay + sheet, ledger tools. |
| `SubscriptionsView.swift` | Recurring **tab** UI; filename is historical. |
| `RecurringCalendarView.swift` | Month grid on Recurring (`UICalendarView` wrap). |
| `PayoffPlan.swift` / `PayoffPlanEditorView.swift` | My Loan / Pay Over Time / promo APR schedules. |
| `Widget/Widgets/Widget.swift` | Total Spend widget (`FinanceHomeWidget`). |

## Future extension ideas

- Category budget alerts / overspend push notifications  
- Widget “trailing 30 days” period  
- `mark-exported` if this app owns the queue  
- Shared App Group settings for default period  
