---
layout: default
title: Development
---

# Development

## Prerequisites

- macOS + Xcode  
- Git  
- Optional: Plaid Sandbox keys for Sync testing  
- Optional: GitHub CLI / SSH keys for remote  

## Opening & building

```bash
# From git root
open FinanceWizard.xcodeproj
```

In Xcode: scheme **FinanceWizard** (Finance Wizard app) → Run (⌘R).

## Version & build numbers (local ↔ Xcode Cloud)

| Setting | Meaning |
|---------|---------|
| **MARKETING_VERSION** | User-facing version (e.g. `0.1`) → About **Version** |
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
| Screens / Sync / Settings | `FinanceWizard/` |
| Model, store, filters, symbols | `Shared/` (both targets) |
| Widget UI / intents | `Widget/` |
| Docs wiki | `docs/` |

When adding a new file under `Shared/`, ensure **Target Membership** includes **FinanceWizard** and **WidgetExtension** (folder sync usually handles this).

## Conventions used in this project

- **Plain-English comments** on non-obvious lines (learning-friendly).  
- Expenses from API are **negated** when saved.  
- Upsert by `transactionId`, never blind replace of the whole DB on Sync.  
- Widget and app share **analytics** helpers so filters stay consistent.  

## Git

Repo root is the Xcode project folder (contains `.xcodeproj`, `FinanceWizard/`, `Shared/`, `Widget/`, `docs/`).  
GitHub remote for this project: `Finance-Wizard`.

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

See also: [GitHub Pages setup](github-pages.md).

## Testing Sync (Sandbox)

1. Use Sandbox keys + First Platypus Bank (`user_good` / `pass_good`).  
2. First **Sync now** may take a few seconds while product data becomes ready.  
3. Second **Sync now** should be incremental (cursor) and return few or no new rows.  
4. **Full re-sync** clears cursors and re-pulls history.  

## Previews

SwiftUI `#Preview` uses in-memory `modelContainer` where possible so the canvas does not need the App Group.

## Future extension ideas

- Category budget alerts  
- Widget “trailing 30 days” period  
- `mark-exported` if this app owns the queue  
- Shared App Group settings for default period  
