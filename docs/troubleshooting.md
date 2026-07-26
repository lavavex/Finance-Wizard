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

1. Both targets have `group.net.roberth.FinanceWidget`.  
2. Team selected for both targets.  
3. Clean build folder, delete app from device/simulator, reinstall.  

## Sync / network

### Sync fails immediately / cannot connect

- Is finance-sync running on the PC?  
- Correct URL in **Settings**?  
- Same LAN / VPN / hostname resolution (`openwindow.local`)?  
- Local Network permission allowed?  
- ATS / local HTTP allowed for cleartext?  

Test from Mac:

```bash
curl -sS "http://YOUR_HOST:8787/api/status"
```

### Sync “works” but data never changes

- Plaid may be rate-limited (429) — app still GETs SQLite; PC may not have new bank data yet.  
- Wait for cooldown or check portal status `plaidSyncRate`.  
- Confirm months in Settings match the months you expect on the server.  

### 409 on Plaid sync

Another sync is running. App should still GET transactions. Retry later if Plaid refresh is required.

## Widget

### Widget empty after Sync

1. Sync from the **app** (not only widget scheme).  
2. Same App Group on both targets.  
3. Edit widget / remove and re-add.  
4. Wait for timeline reload or reboot simulator.  

### Hide cards empties Total Spend

That would be a bug — Total Spend must ignore hide list. Expected: total stays, list shrinks.

### Hide cards list empty in Edit Widget

Sync first so payment methods exist in the store; the intent query reads `SharedStore.allPaymentMethods()`.

## Data oddities

### Duplicate transactions

Should not happen if upsert by `transactionId` works. If IDs change on the server, new rows appear — check finance-sync id stability.

### Amounts look doubled or wrong sign

API expenses are positive; app stores negative. Total Spend uses absolute value. If you re-import with different conventions, wipe the app or clear the store.

### Wrong month of data

Sync always pulls **current + previous** calendar months in the device time zone. Older history needs a server-side export or a future app feature.

## Getting more diagnostics

- Read the in-app alert text on Sync failure.  
- Server logs on finance-sync.  
- `curl` the same URLs the app uses with the Settings base URL.  
