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

## Implementation

| Piece | Location |
|-------|----------|
| Credentials | `FinanceWizard/Plaid/PlaidCredentialsStore.swift` |
| Items / cursors | `FinanceWizard/Plaid/PlaidItemStore.swift` |
| Keychain | `FinanceWizard/Plaid/PlaidKeychain.swift` |
| UI | `FinanceWizard/SettingsView.swift` |

Credentials are **device-local** (not in the App Group).
