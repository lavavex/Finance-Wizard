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
