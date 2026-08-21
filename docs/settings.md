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
| **Save credentials** | Writes client_id + env to `UserDefaults`, secret to Keychain |

Link completion uses the custom scheme `financewizard://hosted-link-complete` (Hosted Link). No `https://localhost/plaid-oauth` field — that was a leftover sample redirect and is cleared automatically if still stored.

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

## Privacy

**Hide for screenshots** (`settings.screenshotPrivacy`) masks dollar amounts and card last-four in the UI so you can share a screen without balances.

## Backup & restore

Password-encrypted `.fwbackup` from **Settings → Backup & restore**. Includes Plaid keys, bank tokens, SwiftData, nicknames, vendor rules, and UserDefaults under `plaid.` / `card.` / `settings.` (including onboarding). Default restore is **Safe merge**. **Wipe device, then restore** deletes local data first.

## Debug menu

**Settings → Developer → Debug** (`DebugMenuView.swift`):

| Action | What it does |
|--------|----------------|
| **Onboarding completed** / **Replay onboarding** | Flips `settings.onboardingCompleted`. Replay shows Welcome immediately. |
| Local counts | Transactions, income, accounts, Recurring marks, linked banks, vendor rules |
| Plaid (no secret) | Configured?, environment, client id |
| Reset pieces | Sync cursors, vendor rules, nicknames, Recurring marks, logos, budget, rewards profiles |
| **Wipe all local data** | Same local wipe as wipe-then-restore (no backup). Plaid Dashboard unchanged. Turns onboarding off. |
| Prefs list | Keys under `plaid.` / `card.` / `settings.` |

Does not change anything in the Plaid Dashboard.

## Debug export

**Settings → About → Export database for debug** builds a zip you can AirDrop / save / share:

| Included | Excluded |
|----------|----------|
| Transactions, income, bank accounts, credit payments (JSON) | Plaid `client_id` / secret |
| Nicknames, vendor learn rules | Access tokens (only “present: true/false”) |
| Linked Item metadata (institution, cursor length) | Institution logo PNG binary blobs |
| Raw SwiftData store files under `store/` when found | |

Primary file for review: `debug-snapshot.json` (pretty-printed). Safe for debugging with a trusted helper; still contains real merchant names and balances.

Implementation: `FinanceWizard/Features/Settings/DebugDataExport.swift`.

## About / build info

**Settings → About** shows values from the installed binary’s Info.plist:

| Field | Source |
|-------|--------|
| **Version** | `CFBundleShortVersionString` ← Xcode **MARKETING_VERSION** (e.g. `1.0`) |
| **Build** | `CFBundleVersion` ← Xcode **CURRENT_PROJECT_VERSION** |
| Bundle ID | `Bundle.main.bundleIdentifier` |
| Minimum iOS | Info.plist minimum OS |

### Keeping local and Xcode Cloud build numbers aligned

| Where | What happens |
|-------|----------------|
| **Xcode Cloud** | `ci_pre_xcodebuild.sh` sets `CURRENT_PROJECT_VERSION` to **`CI_BUILD_NUMBER`** before `xcodebuild` (app + widget). About / TestFlight show that integer. |
| **Local** | `project.pbxproj` holds the committed build number. Set it to match Cloud with: |

```bash
./scripts/set-build-number.sh <CI_BUILD_NUMBER>
```

Example: shipping **1.0 (1)** locally uses `MARKETING_VERSION = 1.0` and `./scripts/set-build-number.sh 1`. After a Cloud build **N**, re-run with **N** (or commit the bump) so local Xcode runs show the same build as Cloud.

In App Store Connect → Xcode Cloud → Settings → **Build Number**, you can set the next Cloud counter if you ever need to jump ahead of App Store / local.

## Implementation

| Piece | Location |
|-------|----------|
| Credentials | `FinanceWizard/Plaid/PlaidCredentialsStore.swift` |
| Items / cursors | `FinanceWizard/Plaid/PlaidItemStore.swift` |
| Keychain | `FinanceWizard/Plaid/PlaidKeychain.swift` |
| UI | `FinanceWizard/Features/Settings/SettingsView.swift` (`AboutBuildView`, `AppBuildInfo`) |
| Debug menu | `FinanceWizard/Features/Settings/DebugMenuView.swift` |
| Debug export | `FinanceWizard/Features/Settings/DebugDataExport.swift` |
| Backup wipe | `PlaidConnectionBackup.wipeLocalAppData` (public; used by restore + Debug) |

Credentials are **device-local** (not in the App Group).
