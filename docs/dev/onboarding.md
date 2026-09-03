---
layout: default
title: Onboarding
---

# Onboarding

First launch shows a branded splash, then a single **Welcome** screen. **Get Started** opens the tab bar. There is no second onboarding page (bank linking stays in Settings / Transactions). End-user install steps: [Getting started](../user/getting-started.md).

## Launch sequence

```text
System launch screen (LaunchBackground — Light/Dark)
        │
        ▼
SplashScreenView          centered 256pt app icon (AppIconImage, squircle)
        │  ~1.35s, then 0.38s fade
        ▼
OnboardingGate
   ├── hasCompleted == false  →  OnboardingView (Welcome)
   └── hasCompleted == true   →  ContentView (tabs)
```

`FinanceWizardApp` hosts `RootWithSplash`, which draws the splash over `OnboardingGate`.

## Splash vs Welcome

Both use **`AppIconImage`** (a loadable imageset copied from the App Icon). `Image("AppIcon")` does **not** work — that name is an `.appiconset`, not an imageset.

| Moment | Icon | Layout |
|--------|------|--------|
| Splash | 256pt squircle, light shadow | Centered; no title; no fill |
| Welcome, before lift | Same 256pt treatment | Same centered layout so the fade is seamless |
| Welcome, after lift | 96pt at the top | Feature rows + full-width **Get Started** |

Welcome waits **1.6s** before lifting so the splash overlay has already faded. Replay onboarding (no splash) still uses that delay, then lifts.

No painted canvas: titles use `.primary`, supporting copy `.secondary`. `AccentColor` is ink (near-black in Light, near-white in Dark). **Get Started** is `.borderedProminent` (capsule). The default prominent label is often light in both schemes, so the title is `Color(.systemBackground)` — canvas color, which contrasts the ink fill. `.colorInvert()` only reads correctly in one scheme.

## Welcome copy

| Row | Title | Meaning |
|-----|--------|---------|
| 1 | All your charges | Link banks; recategorize |
| 2 | Cards and accounts | Credit, checking, savings, utilization, bills due |
| 3 | Monthly budget | Overall cap + category limits vs real spend |

## Completed flag

| Piece | Location |
|-------|----------|
| Key | `settings.onboardingCompleted` (`OnboardingStore.storageKey`) |
| Write | Welcome **Get Started** sets `@AppStorage` to `true` |
| Read | `OnboardingGate` uses the same `@AppStorage` so the UI swaps |
| Backups | `settings.` prefix is included in encrypted app backups |

`@AppStorage` is required so SwiftUI redraws when Debug flips the flag. A raw `UserDefaults` write would not update the gate.

## Replay / Debug

**Settings → Developer → Debug**

- Toggle **Onboarding completed**
- **Replay onboarding** — sets the flag off; Welcome replaces the tabs immediately (the gate is in the live hierarchy)

Wipe all local data also turns the flag off (prefs under `settings.` are cleared).

## Source

| File | Role |
|------|------|
| `FinanceWizard/App/SplashScreenView.swift` | Splash overlay + `RootWithSplash` |
| `FinanceWizard/Features/Onboarding/OnboardingGate.swift` | Welcome vs tabs |
| `FinanceWizard/Features/Onboarding/OnboardingView.swift` | Welcome UI |
| `FinanceWizard/Features/Onboarding/OnboardingStore.swift` | Key name |
| `FinanceWizard/Assets.xcassets/AppIconImage.imageset` | Light + dark icon for UI |
| `FinanceWizard/Features/Settings/DebugMenuView.swift` | Replay + other resets |
