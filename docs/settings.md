---
layout: default
title: Settings
---

# Settings

## Plaid developer account

| Field | Description |
|-------|-------------|
| **client_id** | From [Plaid Dashboard → Keys](https://dashboard.plaid.com/developers/keys) |
| **secret** | Environment-specific secret (stored in **Keychain**) |
| **Environment** | Sandbox / Development / Production |
| **Optional OAuth redirect** | https Universal Link for Production app-to-app (optional; leave blank in Sandbox) |
| **Save credentials** | Writes client_id + env + redirect to `UserDefaults`, secret to Keychain |

Link completion uses the custom scheme `financewizard://hosted-link-complete` (Hosted Link). That URI is **not** registered in the Plaid Dashboard.

## Linked banks

| Action | Description |
|--------|-------------|
| **Link bank account** | Opens Plaid Link; exchanges public_token; stores Item |
| Swipe **Unlink** | Deletes local access token; best-effort `POST /item/remove` |

## Status

| Label | Meaning |
|-------|---------|
| Credentials | Configured vs missing |
| Environment | Active Plaid host |
| Linked items | Count of stored Items |
| API host | Hostname for the selected environment |

## Debug export

**Settings → Export data for debug** builds a zip you can AirDrop / save / share:

| Included | Excluded |
|----------|----------|
| Transactions, income, bank accounts, credit payments (JSON) | Plaid `client_id` / secret |
| Nicknames, vendor learn rules | Access tokens (only “present: true/false”) |
| Linked Item metadata (institution, cursor length) | Institution logo PNG binary blobs |
| Raw SwiftData store files under `store/` when found | |

Primary file for review: `debug-snapshot.json` (pretty-printed). Safe for debugging with a trusted helper; still contains real merchant names and balances.

Implementation: `FinanceWizard/DebugDataExport.swift`.

## About / build info

**Settings → About** shows values from the installed binary’s Info.plist:

| Field | Source |
|-------|--------|
| **Version** | `CFBundleShortVersionString` ← Xcode **MARKETING_VERSION** |
| **Build** | `CFBundleVersion` ← Xcode **CURRENT_PROJECT_VERSION** |
| Bundle ID | `Bundle.main.bundleIdentifier` |
| Minimum iOS | Info.plist minimum OS |

These match what Xcode Cloud embeds when it archives (same target version/build numbers).

## Implementation

| Piece | Location |
|-------|----------|
| Credentials | `FinanceWizard/Plaid/PlaidCredentialsStore.swift` |
| Items / cursors | `FinanceWizard/Plaid/PlaidItemStore.swift` |
| Keychain | `FinanceWizard/Plaid/PlaidKeychain.swift` |
| UI | `FinanceWizard/SettingsView.swift` (`AboutBuildView`, `AppBuildInfo`) |
| Debug export | `FinanceWizard/DebugDataExport.swift` |

Credentials are **device-local** (not in the App Group).
