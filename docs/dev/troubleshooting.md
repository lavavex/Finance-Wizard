---
layout: default
title: Troubleshooting
---

# Troubleshooting (development)

In-app problems for testers: [User help](../user/help.md).

## Build errors

### Multiple commands produce `Info.plist`

**Cause:** `Info.plist` is both processed as the app plist and copied as a resource (folder-synced Xcode projects).

**Fix:** Keep `Info.plist` in membership exceptions (not copied as a resource), or use only `GENERATE_INFOPLIST_FILE` + `INFOPLIST_KEY_*` without a conflicting copy phase.

### `Cannot find type Transaction` in widget

**Cause:** `Shared/` not in WidgetExtension target membership.

**Fix:** Select `Transaction.swift` / `SharedStore.swift` → File inspector → check **WidgetExtension**. (Folder-sync should already do this.)

### `Failed to open ModelContainer` at launch

**Cause:** App Group missing, wrong id, or signing/capability not applied.

**Fix:** Both targets have `group.net.roberth.FinanceWizard`, same Team, then Clean + delete the app + reinstall.

## Xcode console noise (usually ignore)

### `CFPrefsPlistSource` / `group.net.roberth.FinanceWizard` / `kCFPreferencesAnyUser with a container`

App Group prefs warning, common on Simulator. SwiftData still uses the group for the store; logo **files** use the group folder. We avoid `UserDefaults(suiteName:)` for logo metadata. If widgets can’t see data, re-check entitlements + signing—not this log alone.

### `non-launching port is incompatible with service identifier "com.apple.PointerUI…"`

Simulator pointer UI. Unrelated. Ignore.

### `UIContextMenuInteraction updateVisibleMenuWithBlock: while no context menu is visible`

SwiftUI refreshing a toolbar menu that isn’t open. Harmless.

## Plaid (contributor)

### “webview integration mode for link is deprecated”

Current builds use **Hosted Link** + `ASWebAuthenticationSession`. Rebuild/reinstall.

### Link finishes but “no public_token”

Race after Hosted Link. The app polls `/link/token/get`. Retry or check Plaid Dashboard logs.

### OAuth bank never returns (Production)

May need an **https Universal Link** in Settings + Plaid Dashboard allowlist.

### Duplicates

Should not happen if upsert by `transactionId` works. Re-linking can mint new Plaid ids → new rows.

## Onboarding / Welcome

### Welcome never appears

Flag is `settings.onboardingCompleted`. **Settings → Developer → Debug → Replay onboarding**. `OnboardingGate` sits under splash in the live app.

### Splash logo does not match Welcome

Both use **`AppIconImage`**, not `SplashLogo` and not `Image("AppIcon")` (`.appiconset` is not a loadable `Image`).

## Widget empty (simulator)

1. Run the **app**, Sync, then add the widget.
2. Confirm App Group id on both targets.
3. Delete and re-add the widget after major model changes.
