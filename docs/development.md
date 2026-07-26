---
layout: default
title: Development
---

# Development

## Prerequisites

- macOS + Xcode  
- Git  
- Optional: finance-sync on LAN for Sync testing  
- Optional: GitHub CLI / SSH keys for remote  

## Opening & building

```bash
# From git root
open FinanceWidget.xcodeproj
```

In Xcode: scheme **FinanceWidget** → Run (⌘R).

## Where to put code

| Change | Put it in |
|--------|-----------|
| Screens / Sync / Settings | `FinanceWidget/` |
| Model, store, filters, symbols | `Shared/` (both targets) |
| Widget UI / intents | `Widget/` |
| Docs wiki | `docs/` |

When adding a new file under `Shared/`, ensure **Target Membership** includes **FinanceWidget** and **WidgetExtension** (folder sync usually handles this).

## Conventions used in this project

- **Plain-English comments** on non-obvious lines (learning-friendly).  
- Expenses from API are **negated** when saved.  
- Upsert by `transactionId`, never blind replace of the whole DB on Sync.  
- Widget and app share **analytics** helpers so filters stay consistent.  

## Git

Repo root is the Xcode project folder (contains `.xcodeproj`, `FinanceWidget/`, `Shared/`, `Widget/`, `docs/`).

Suggested ignore (see project `.gitignore`):

- `xcuserdata/`  
- `DerivedData/`  
- `.DS_Store`  

### SSH remote (private repo)

```bash
# After creating empty private repo on GitHub:
git remote add origin git@github.com:YOUR_USER/FinanceWidget.git
git push -u origin main
```

See also: [GitHub Pages setup](github-pages.md).

## Testing Sync without Plaid spam

1. First Sync may call Plaid.  
2. Immediate second Sync should hit **429** and still refresh months via GET.  
3. Confirm list updates and no hard error on cooldown.  

## Previews

SwiftUI `#Preview` uses in-memory `modelContainer` where possible so the canvas does not need the App Group.

## Future extension ideas

- Category budget alerts  
- Widget “trailing 30 days” period  
- `mark-exported` if this app owns the queue  
- Shared App Group settings for default period  
