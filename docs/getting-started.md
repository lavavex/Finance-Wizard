---
layout: default
title: Getting started
---

# Getting started

## 1. Open the project

1. On a Mac, open **`FinanceWizard.xcodeproj`** (inside the git root).
2. Wait for indexing to finish.
3. Select the **FinanceWizard** scheme (the Finance Wizard app; not only the widget extension).
4. Pick a simulator or a physical device.

## 2. Signing

1. Select the **FinanceWizard** target (Finance Wizard app) → **Signing & Capabilities**.
2. Choose your **Team** (Personal Team works for development).
3. Repeat for **WidgetExtension** (must sign with the same team).
4. Bundle IDs:
   - App: `net.roberth.FinanceWizard`
   - Widget: `net.roberth.FinanceWizard.Widget`

## 3. App Groups (required)

Both targets must share:

```text
group.net.roberth.FinanceWizard
```

Check:

- **FinanceWizard** target → Signing & Capabilities → **App Groups**
- **WidgetExtension** target → same group checked

Entitlements files:

- `FinanceWizard/FinanceWizard.entitlements`
- `WidgetExtension.entitlements`

Without the shared group, the widget cannot see transactions the app saves.

## 4. Shared code membership

| Folder | Role |
|--------|------|
| `Shared/` | `Transaction`, `SharedStore`, analytics, category SF Symbols |
| `FinanceWizard/` | App UI + Plaid client |
| `Widget/` | WidgetKit extension |

## 5. Plaid developer keys

1. Sign up at [dashboard.plaid.com](https://dashboard.plaid.com).  
2. Open **Developers → Keys**.  
3. Copy **client_id** and the **Sandbox secret**.  
4. Run the app → **Settings** → paste keys → Environment **Sandbox** → **Save credentials**.

## 6. First run checklist

1. **Build and run** the **Finance Wizard** app (⌘R; scheme **FinanceWizard**).  
2. **Settings → Link bank account**.  
   - Sandbox institution: **First Platypus Bank**  
   - Username `user_good`, password `pass_good`  
3. On **Transactions**, open **Sync → Sync now**.  
4. List should fill; **By Card** should list payment methods.  
5. Add the **Total Spend** widget from the Home Screen gallery.

## 7. Optional: JSON file import

Toolbar **Import** still accepts a JSON file with a `transactions` array (legacy export shape) if you need offline data.

## 8. Widget preview

- Prefer running the **app** scheme so data is written to the App Group, then add the widget.  
- Or run the **WidgetExtension** scheme for layout debugging (data may be empty without a prior app Sync).

## Next

- [Architecture](architecture.md) — how pieces fit  
- [Sync & API](sync-and-api.md) — Plaid endpoints and mapping  
