---
layout: default
title: Settings
---

# Settings

## Sync server

| Field | Description |
|-------|-------------|
| Text field | Base URL of finance-sync, **no path** |
| **Save server URL** | Writes to `UserDefaults` (`serverBaseURL`) |
| **Reset to default** | `http://openwindow.local:8787` |

Rules when saving:

- Trim whitespace  
- Strip trailing `/`  
- Empty → default  

Examples:

```text
http://openwindow.local:8787
http://10.0.0.135:8787
http://127.0.0.1:8787
```

(Simulator on the same Mac can often use hostname or `127.0.0.1` if the portal binds appropriately.)

## Sync behavior (read-only info)

| Label | Meaning |
|-------|---------|
| **Months pulled** | Current + previous `YYYY-MM` (live) |
| **Active URL** | Normalized URL Sync will call |

There is **no** hardcoded month in the app. Sync also pulls **income** for those months (`GET /api/income`); income is never part of Total Spend.

## Implementation

| Piece | Location |
|-------|----------|
| Keys / helpers | `FinanceWizard/AppSettings.swift` |
| UI | `FinanceWizard/SettingsView.swift` |
| Persistence | `@AppStorage` / `UserDefaults` |

Settings are **device-local** (not in the App Group, not synced to the widget config).
