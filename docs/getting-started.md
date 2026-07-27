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
4. Bundle IDs (separate from any older FinanceWidget install):
   - App: `net.roberth.FinanceWizard`
   - Widget: `net.roberth.FinanceWizard.Widget`

These IDs make **Finance Wizard** a distinct app from a previous **FinanceWidget** build on the same device. If you change them, update App Group capability consistency (next section).

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

## 4. Local network / HTTP (for Sync)

The default server is plain **HTTP** on the LAN (`http://openwindow.local:8787`).

1. Confirm **Info** / `Info.plist` allows local networking / ATS exceptions for local HTTP (already set up during development with `NSAllowsLocalNetworking` / arbitrary loads as needed).
2. **Privacy – Local Network Usage Description** should explain why the app talks to the PC.
3. On first Sync, iOS may prompt for **Local Network** access — allow it.

## 5. Shared code membership

These folders are compiled into **both** app and widget:

| Folder | Role |
|--------|------|
| `Shared/` | `Transaction`, `SharedStore`, analytics, category SF Symbols |

App-only: `FinanceWizard/`  
Widget-only: `Widget/`

In Xcode, select a file → **File inspector** → **Target Membership** to verify.

## 6. First run checklist

1. **Build and run** the **Finance Wizard** app (⌘R; scheme **FinanceWizard**).
2. Open the **Settings** tab.
3. Set **Sync server** if not using the default host, tap **Save server URL**.
4. Confirm **Months pulled** shows the current and previous `YYYY-MM` values.
5. Ensure **finance-sync** is running on the PC (port **8787**).
6. On **Transactions**, tap **Sync**.
7. List should fill; **By Card** should list payment methods.
8. Add the **Total Spend** widget from the Home Screen gallery (long-press home → **+** → find the app).

## 7. Optional: JSON file import

Toolbar **Import** still accepts a finance-sync-style JSON export (`transactions` array) if the server is offline.

## 8. Widget preview

- Prefer running the **app** scheme so data is written to the App Group, then add the widget.
- Or run the **WidgetExtension** scheme for layout debugging (data may be empty without a prior app Sync).

## Next

- [Architecture](architecture.md) — how pieces fit  
- [Sync & API](sync-and-api.md) — what Sync does on the wire  
