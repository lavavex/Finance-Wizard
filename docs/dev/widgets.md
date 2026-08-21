---
layout: default
title: Widgets
---

# Widgets (implementation)

How testers add widgets: [User widgets](../user/widgets.md).

The extension registers **three** widgets (`Widget/WidgetBundle.swift`). All read SwiftData via the App Group (`SharedStore`).

| Widget | Kind | Config | What it shows |
|--------|------|--------|----------------|
| **Total Spend** | `FinanceHomeWidget` | Time range, hide cards | Period total + spend **by card** |
| **Spend by Category** | `CategorySpendWidget` | Time range, chart style | Period total + **category** chart |
| **Balances** | Static (no Edit Widget) | — | Checking & savings after Sync |

Hide-cards on Total Spend affects the **breakdown only**. The big total includes every card.

Config is **per widget instance** (`FinanceWizardConfigIntent` in `Widget/AppIntent.swift`). Category charts use `CategorySpendChartView` in `Shared/`.

## Timeline

- Total Spend / Category: `AppIntentTimelineProvider`
- Balances: classic `TimelineProvider`
- Refresh about every **15 minutes**, and immediately after app Sync (`WidgetCenter.reloadAllTimelines()`)

## Empty states

| Message | Cause |
|---------|--------|
| Open the app and tap Sync | Empty store |
| No spend in this week/month | Period filter empty |
| Store error | App Group / container failure |

## Development notes

- After model changes, delete the app from the simulator if migration fails.
- App and widget **must** use `group.net.roberth.FinanceWizard`.
- `Shared/` is in both targets (folder-synced).
