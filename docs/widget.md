---
layout: default
title: Widget
---

# Widgets

The extension registers **three** Home Screen widgets (`Widget/WidgetBundle.swift`). All read SwiftData through the App Group (`SharedStore`).

| Widget | Kind | Config | What it shows |
|--------|------|--------|----------------|
| **Total Spend** | `FinanceHomeWidget` | Time range, hide cards | Period total + spend **by card** |
| **Spend by Category** | `CategorySpendWidget` | Time range, chart style | Period total + **category** chart |
| **Balances** | (static, no Edit Widget) | — | Checking & savings balances after Sync |

## Total Spend

| Element | Behavior |
|---------|----------|
| Title | Total Spend |
| Subtitle | This week / This month |
| Big number | **Full period total** (all cards) |
| Card list | Per-card spend; respects **Hide cards** |
| Footer (medium+) | Transaction count in period |

Hiding cards only affects the **breakdown**, not the big total.

**Edit Widget:** Time range (week/month), Hide cards (multi-select). Config is **per instance** (`FinanceWizardConfigIntent` in `Widget/AppIntent.swift`).

## Spend by Category

**Edit Widget:** Time range + chart style (horizontal bars / vertical bars / pie). Default: horizontal bars. Uses `CategorySpendChartView` in `Shared/`.

## Balances

Checking/savings from Plaid depository accounts (`SharedStore` deposit snapshot). No Edit Widget intent. Empty until the app has synced.

## Timeline

- Total Spend / Category: `AppIntentTimelineProvider`
- Balances: classic `TimelineProvider`
- Refresh about every **15 minutes**, and immediately after app Sync (`WidgetCenter.reloadAllTimelines()`)

## Adding a widget

1. Run the app and **Sync**.  
2. Home Screen → long-press → **+** → **Finance Wizard**.  
3. Place small/medium/large.  
4. Edit (where available) for week/month.

## Empty states

| Message | Cause |
|---------|--------|
| Open the app and tap Sync | Empty store |
| No spend in this week/month | Period filter empty |
| Store error | App Group / container failure |

## Development

- After model changes, delete the app from the simulator if migration fails.  
- App and widget **must** use `group.net.roberth.FinanceWizard`.  
- `Shared/` is in both targets (folder-synced).
