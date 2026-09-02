---
layout: default
title: Settings & Debug
---

# Settings & Debug (implementation)

User-facing Settings: [User Settings](../user/settings.md).

## Code map

| Piece | Location |
|-------|----------|
| Credentials | `FinanceWizard/Plaid/PlaidCredentialsStore.swift` |
| Items / cursors | `FinanceWizard/Plaid/PlaidItemStore.swift` |
| Keychain | `FinanceWizard/Plaid/PlaidKeychain.swift` |
| UI | `FinanceWizard/Features/Settings/SettingsView.swift` (`AboutBuildView`, `AppBuildInfo`) |
| Debug menu | `FinanceWizard/Features/Settings/DebugMenuView.swift` |
| Debug export | `FinanceWizard/Features/Settings/DebugDataExport.swift` |
| Backup wipe | `PlaidConnectionBackup.wipeLocalAppData` (public; restore + Debug) |

Credentials are **device-local** (not in the App Group). UserDefaults prefixes `plaid.` / `card.` / `settings.` ride along in encrypted backups.

Link completion uses `financewizard://hosted-link-complete` (Hosted Link). A leftover `https://localhost/plaid-oauth` override is cleared if still stored.

## Debug menu

**Settings → Developer → Debug**

| Action | What it does |
|--------|----------------|
| **Onboarding completed** / **Replay onboarding** | Flips `settings.onboardingCompleted`. Replay shows Welcome immediately via `OnboardingGate`. |
| Local counts | Transactions, income, accounts, Recurring marks, payoff plans, linked banks, vendor rules |
| Plaid (no secret) | Configured?, environment, client id |
| Reset pieces | Sync cursors, vendor rules, nicknames, Recurring marks, logos, budget, payoff plans |
| **Wipe all local data** | Same local wipe as wipe-then-restore (no backup). Plaid Dashboard unchanged. Turns onboarding off. |
| Prefs list | Keys under `plaid.` / `card.` / `settings.` |

## Debug export

**Settings → About → Export database for debug** — zip for AirDrop. Includes transactions JSON and store files; excludes Plaid secret and access tokens (tokens listed as present true/false). Primary file: `debug-snapshot.json`. Still contains real merchant names and balances.

## About / build numbers

| Field | Source |
|-------|--------|
| **Version** | `CFBundleShortVersionString` ← **MARKETING_VERSION** |
| **Build** | `CFBundleVersion` ← **CURRENT_PROJECT_VERSION** |

| Where | What happens |
|-------|----------------|
| **Xcode Cloud** | `ci_pre_xcodebuild.sh` sets `CURRENT_PROJECT_VERSION` to **`CI_BUILD_NUMBER`** |
| **Local** | `./scripts/set-build-number.sh <CI_BUILD_NUMBER>` |

Do not ship a lower build than the last Cloud / TestFlight build.
