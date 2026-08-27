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

| Requirement | Notes |
|-------------|--------|
| **SDK / Xcode** | Xcode 26+ with iOS 26 (or newer) SDK |
| **Deployment target** | iOS **26.0** (both targets) |
| **Device** | [Apple Intelligence–compatible](https://www.apple.com/apple-intelligence/) hardware (e.g. iPhone 15 Pro+, recent M-series iPads) |
| **Settings** | **Apple Intelligence** enabled on the device/simulator that supports it |
| **Language / region** | Model availability can vary by language and region |
| **Runtime check** | Always read `SystemLanguageModel.default.availability` before using a session |

Docs: [Foundation Models](https://developer.apple.com/documentation/foundationmodels)

**Not wired yet:** no app feature code imports or calls the model. When you implement, start from the main target only (`import FoundationModels`); keep widget free of AI unless you deliberately need it there.

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

## Version & build numbers (local ↔ Xcode Cloud)

| Setting | Meaning |
|---------|---------|
| **MARKETING_VERSION** | User-facing version (e.g. `1.0`) → About **Version** |
| **CURRENT_PROJECT_VERSION** | Integer build → About **Build** / TestFlight |

**Xcode Cloud** runs `ci_scripts/ci_pre_xcodebuild.sh`, which sets:

```text
CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER
```

so every Cloud archive’s build matches the Cloud build counter (same number you see in App Store Connect / TestFlight).

**Local** uses whatever is in `project.pbxproj`. After a Cloud build lands, align your Mac:

```bash
./scripts/set-build-number.sh <CI_BUILD_NUMBER>
```

Then Clean + Run so **Settings → About** matches the Cloud install. Do not hand-edit a lower number than the last Cloud build (App Store Connect rejects non‑increasing builds).

## Xcode project format (Xcode Cloud)

Newer local Xcodes (26/27) may rewrite `project.pbxproj` to **objectVersion 110+**. Older Xcode Cloud images then fail with:

> cannot be opened because it is in a future Xcode project file format (110)

There is **no permanent lock inside the `.xcodeproj`** that stops Xcode from rewriting the file when you save. Use one (or both) of these:

### A. Auto-downgrade on Xcode Cloud (in this repo)

| Script | When |
|--------|------|
| `ci_scripts/ci_post_clone.sh` | After clone |
| `ci_scripts/ci_pre_xcodebuild.sh` | Before `xcodebuild` |
| `scripts/lock-xcode-project-format.sh` | Forces `objectVersion = 77` |

Cloud runs the `ci_scripts/*` hooks automatically when present.

### B. Optional local pre-commit hook

```bash
git config core.hooksPath .githooks
```

Commits then re-lock the project format before they land.

### C. Or upgrade Xcode Cloud to match your Mac

App Store Connect → your app → **Xcode Cloud** → workflow → **Environment** → pick an Xcode version that understands format 110 (same generation as your local Xcode 27). Then you can leave format 110 as-is.

**Also check the workflow project name:** it must open **`FinanceWizard.xcodeproj`** (not the old `FinanceWidget.xcodeproj`).

## Where to put code

| Change | Put it in |
|--------|-----------|
| App entry, splash, root gate | `FinanceWizard/App/` |
| Welcome / onboarding flag | `FinanceWizard/Features/Onboarding/` |
| Feature UI (transactions, accounts, budget, settings, import) | `FinanceWizard/Features/<Area>/` |
| App-only services (logo fetch, local helpers) | `FinanceWizard/Services/` |
| Plaid Link / sync / credentials | `FinanceWizard/Plaid/` |
| SwiftData models + domain enums | `Shared/Models/` (both targets) |
| ModelContainer / SharedStore | `Shared/Store/` |
| Analytics, search, period helpers | `Shared/Analytics/` |
| Card catalog / benefits / nicknames | `Shared/Cards/` |
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
| `Features/AI/` | Next feature. Not in the tab bar or Settings yet. |
| `SubscriptionsView.swift` | Recurring **tab** UI; filename is historical. |
| `Widget/Widgets/Widget.swift` | Total Spend widget (`FinanceHomeWidget`). |

## Future extension ideas

- Category budget alerts / overspend push notifications  
- Widget “trailing 30 days” period  
- `mark-exported` if this app owns the queue  
- Shared App Group settings for default period  
