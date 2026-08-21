---
layout: default
title: Settings
---

# Settings

Plaid keys and banks are required to pull transactions. See [Getting started](getting-started.md) if you haven’t linked yet.

## Plaid account

| Field | What to enter |
|-------|----------------|
| **client_id** | From [Plaid Dashboard → Keys](https://dashboard.plaid.com/developers/keys) |
| **secret** | The secret for the **same** environment you pick below |
| **Environment** | Sandbox (test banks), Development, or Production |
| **Save credentials** | Stores keys on this iPhone (secret in the Keychain) |

## Linked banks

| Action | What happens |
|--------|----------------|
| **Link bank account** | Opens Plaid so you can sign in at your bank |
| **Relink** | Use when login expired |
| **Unlink** | Removes the bank from this iPhone |

## Privacy

**Hide for screenshots** masks dollar amounts and card last-four so you can share a picture of the app without balances.

## Backup & restore

**Back up everything** creates a password-encrypted `.fwbackup` file (keys, banks, transactions, budget, prefs). Keep the password somewhere safe.

**Restore** default is **Safe merge** (adds missing data; doesn’t overwrite live bank tokens). **Wipe device, then restore** deletes local data first, then restores the backup.

## About

Version and build of the TestFlight (or App Store) binary you have installed.

## Developer tools (optional)

**Settings → Developer → Debug** is for testers and contributors: replay Welcome, inspect counts, reset local pieces, or wipe local data. It does **not** change anything in the Plaid Dashboard. Implementation notes: [Developer Settings](../dev/settings.md).
