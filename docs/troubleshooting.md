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

## Plaid / Sync

### “Add your Plaid client_id and secret in Settings”

Save credentials under **Settings → Plaid developer account**. Use the secret that matches the selected **Environment** (Sandbox secret with Sandbox env).

### Link fails immediately

- Confirm client_id + secret + environment match the dashboard.  
- Sandbox only works with Sandbox secret.  
- Check the Sync Status / error text for Plaid `error_code`.  
- If the error mentions `redirect_uri`, add that exact URI under **Dashboard → Developers → API → Allowed redirect URIs**.

### “Continue to Login” does nothing

OAuth banks open the bank login in a new window. Finance Wizard keeps that navigation **inside** the Link webview and returns via your **redirect URI**.

1. Settings → OAuth redirect URI (default `http://localhost/plaid-oauth` for Sandbox).  
2. Plaid Dashboard → **Allowed redirect URIs** must include the **exact** same string.  
3. Save credentials, close Link, open **Link bank account** again (new link_token).  
4. Sandbox OAuth test bank: **Platypus OAuth Bank** / **First Platypus Bank - OAuth**. Non-OAuth Sandbox bank (**First Platypus Bank** with `user_good` / `pass_good`) skips this button.

### OAuth bank never returns to the app

- Redirect URI mismatch (dashboard vs Settings).  
- Production/Development often need an `https://` redirect you host (Universal Links for App-to-App). Sandbox allows `http://localhost…`.

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

## Widget empty

1. Run the **app**, Sync, then add the widget.  
2. Confirm App Group id matches on both targets.  
3. Delete and re-add the widget after major model changes.
