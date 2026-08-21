---
layout: default
title: Troubleshooting
---

# Troubleshooting

## Build errors

### Multiple commands produce `Info.plist`

**Cause:** `Info.plist` is both processed as the app plist and copied as a resource (common with folder-synced Xcode projects).

**Fix:** Keep `Info.plist` in membership exceptions (not copied as a resource), or use only `GENERATE_INFOPLIST_FILE` + `INFOPLIST_KEY_*` without a conflicting copy phase.

### `Cannot find type Transaction` in widget

**Cause:** `Shared/` not in WidgetExtension target membership.

**Fix:** Select `Transaction.swift` / `SharedStore.swift` → File inspector → check **WidgetExtension**.

### `Failed to open ModelContainer` at launch

**Cause:** App Group missing, wrong id, or signing/capability not applied.

**Fix:**

1. Both targets have `group.net.roberth.FinanceWizard`.  
2. Team selected for both targets.  
3. Clean build folder, delete app from device/simulator, reinstall.  

## Xcode console noise (usually ignore)

### `CFPrefsPlistSource` / `group.net.roberth.FinanceWizard` / `kCFPreferencesAnyUser with a container`

App Group prefs warning. Common on Simulator when something touches the group container. SwiftData still uses the App Group for the store; logo **files** use the group folder. We avoid `UserDefaults(suiteName:)` for logo metadata to reduce this spam. If widgets can’t see shared data, re-check App Group entitlements + signing—not this log alone.

### `non-launching port is incompatible with service identifier "com.apple.PointerUI…"`

Apple system / Simulator pointer UI. Unrelated to Finance Wizard. Safe to ignore.

### `UIContextMenuInteraction updateVisibleMenuWithBlock: while no context menu is visible`

UIKit/SwiftUI trying to refresh a menu that isn’t open (often toolbar `Menu`). Harmless; “This won’t do anything” means no user impact.

## Plaid / Sync

### “Add your Plaid client_id and secret in Settings”

Save credentials under **Settings → Plaid developer account**. Use the secret that matches the selected **Environment** (Sandbox secret with Sandbox env).

### Link fails immediately

- Confirm client_id + secret + environment match the dashboard.  
- Sandbox only works with Sandbox secret.  
- Check the Sync Status / error text for Plaid `error_code`.  
- If the error mentions `redirect_uri`, add that exact URI under **Dashboard → Developers → API → Allowed redirect URIs**.

### “webview integration mode for link is deprecated”

Use the current app build — Link is **Hosted Link** in a system browser session, not WKWebView. Rebuild/reinstall if you still see this message.

### Link browser never opens / closes immediately

- Allow the system authentication browser sheet when iOS prompts.  
- Try again after **Save credentials**.  
- Confirm Sandbox keys with Sandbox environment.

### Link finishes but “no public_token”

Rare race after Hosted Link. Wait a few seconds and link again, or check Plaid Dashboard logs. The app polls `/link/token/get` automatically after the browser closes.

### OAuth bank never returns to the app (Production)

App-to-app OAuth may need an **https Universal Link** in Settings + Plaid Dashboard allowlist. Sandbox Hosted Link usually does not need this.

### Sync says no banks linked

**Settings → Link bank account** first, then **Sync → Sync now**.

### Sync works but list is empty

- Wait a few seconds after first link (initial product ready).  
- Try **Full re-sync**.  
- Confirm the linked Item still appears under Settings.  
- Pending transactions are skipped by default.

### Categories wrong after sync

Edit the transaction → **Save** with **learn** on. Future syncs respect locks and local vendor rules.

### Duplicates

Should not happen if upsert by `transactionId` works. If you reset Plaid Items and re-link, new transaction ids can appear as new rows.

## Onboarding / Welcome

### Welcome never appears

The completed flag is `settings.onboardingCompleted`. **Settings → Developer → Debug → Replay onboarding** (or turn **Onboarding completed** off). The live app uses `OnboardingGate` under splash, so Welcome should replace the tabs immediately.

### Splash logo does not match Welcome

Splash and Welcome both use **`AppIconImage`**, not `SplashLogo` and not `Image("AppIcon")` (app-icon sets are not loadable images).

## Widget empty

1. Run the **app**, Sync, then add the widget.  
2. Confirm App Group id matches on both targets.  
3. Delete and re-add the widget after major model changes.
