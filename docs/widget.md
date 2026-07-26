---
layout: default
title: Widget
---

# Widget (Total Spend)

## Overview

Home Screen widget kind: **`FinanceHomeWidget`**.

- Display name: **Total Spend**
- Sizes: systemSmall, systemMedium, systemLarge
- Data: SwiftData App Group via `SharedStore.loadSnapshot`

## What it shows

| Element | Behavior |
|---------|----------|
| Title | **Total Spend** |
| Subtitle | Period label (This week / This month) |
| Big number | **Full period total** (all cards) |
| Card list | Per-card spend; respects **Hide cards** |
| Footer (medium+) | Transaction count in period |

Hiding cards only affects the **breakdown**, not the big total.

## Configuration (Edit Widget)

Long-press widget → **Edit Widget**:

| Parameter | Options |
|-----------|---------|
| **Time range** | This week / This month |
| **Hide cards** | Multi-select of payment methods from the store |

Configuration is stored **per widget instance** (you can add two widgets with different settings).

Implemented as `FinanceWidgetConfigIntent` in `Widget/AppIntent.swift`.

## Timeline

- Provider: `AppIntentTimelineProvider`
- Policy: refresh about every **15 minutes**, and immediately after app Sync (`reloadAllTimelines()`).

## Adding the widget

1. Run the app and **Sync** so data exists.  
2. Home Screen → long-press → **+**  
3. Find **Finance Widget** / **Total Spend**  
4. Place small/medium/large  
5. Edit to set week/month and hide cards  

## Template files not registered

`WidgetControl.swift` and `WidgetLiveActivity.swift` may still exist from the Xcode template but are **not** registered in `WidgetBundle` (only `FinanceHomeWidget` is).

## Empty states

| Message | Cause |
|---------|--------|
| Open the app and tap Sync | Empty store |
| No spend in this week/month | Period filter empty |
| Store error | App Group / container failure |

## Development tips

- After model changes, delete the app from simulator if the store schema migrates poorly during early development.
- Widget and app **must** use the same App Group id.
- `Shared/` must be in the WidgetExtension target membership.
