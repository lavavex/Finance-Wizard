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

## Opening & building

```bash
# From git root
# Prefer Xcode that ships the iOS 26+ SDK (beta is OK)
open -a Xcode-beta FinanceWizard.xcodeproj
# or: open FinanceWizard.xcodeproj
```

In Xcode: scheme **FinanceWizard** (Finance Wizard app) → Run (⌘R).

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
| Docs wiki | `docs/` |

Folders under `FinanceWizard/`, `Shared/`, and `Widget/` are **file-system synced** — new `.swift` files join the target automatically. Keep shared types in `Shared/` so app and widget stay aligned.

## Conventions used in this project

- **Comments:** short file headers + `///` for behavior and constraints. No Swift-syntax lectures. No LESSON / TYPE HERE dumps in shipping source. See `AGENTS.md`.  
- **Docs:** every behavior change is updated in `docs/` in the same change (again `AGENTS.md`).  
- Expenses from Plaid/API are **negated** when saved.  
- Upsert by `transactionId`, never blind-replace the whole DB on Sync.  
- Widget and app share **analytics** helpers so filters stay consistent.  

### Suggested reading order (if you’re learning the app)

1. `FinanceWizard/App/FinanceWizardApp.swift` — how the app starts  
2. `FinanceWizard/App/SplashScreenView.swift` + `Features/Onboarding/` — splash → Welcome or tabs  
3. `Shared/Models/Transaction.swift` + `Shared/Store/SharedStore.swift` — data + totals  
4. `FinanceWizard/App/ContentView.swift` — tabs and main list  
5. `FinanceWizard/Plaid/PlaidSyncEngine.swift` — how bank data lands on disk  
6. Any feature screen under `FinanceWizard/Features/`  

## Git

Repo root is the Xcode project folder (contains `.xcodeproj`, `FinanceWizard/`, `Shared/`, `Widget/`, `docs/`).

| Remote | URL |
|--------|-----|
| **origin** (fetch) | `git@github.com:lavavex/Finance-Wizard.git` |
| **origin** (push) | GitHub **and** Gitea (`git@gitea:roberth/Finance-Wizard.git`) |
| **gitea** | `git@gitea:roberth/Finance-Wizard.git` |

`gitea` is an SSH host alias in `~/.ssh/config` → `git@10.10.0.34` (port 22), key `~/.ssh/id_ed25519`. Add that public key under Gitea **Settings → SSH / GPG Keys**.

`git push origin main` updates both hosts. `git push gitea main` is Gitea only. `git pull` still comes from GitHub.

Create the empty repo on Gitea first (`roberth/Finance-Wizard`, no README) if it does not exist.

Suggested ignore (see project `.gitignore`):

- `xcuserdata/`  
- `DerivedData/`  
- `.DS_Store`  

### SSH remote (private repo)

```bash
# After creating empty private repo on GitHub:
git remote add origin git@github.com:YOUR_USER/Finance-Wizard.git
git push -u origin main
```

See also: [GitHub Pages setup](github-pages.md). Agent rules for this repo: [`AGENTS.md`](../AGENTS.md) (always update docs; run `xcodebuild` when you write Swift).

## Testing Sync (Sandbox)

1. Use Sandbox keys + First Platypus Bank (`user_good` / `pass_good`).  
2. First **Sync now** may take a few seconds while product data becomes ready.  
3. Second **Sync now** should be incremental (cursor) and return few or no new rows.  
4. **Full re-sync** clears cursors and re-pulls history.  

## Previews

SwiftUI `#Preview` uses in-memory `modelContainer` where possible so the canvas does not need the App Group.

## Future extension ideas

- Category budget alerts / overspend push notifications  
- Widget “trailing 30 days” period  
- `mark-exported` if this app owns the queue  
- Shared App Group settings for default period  
