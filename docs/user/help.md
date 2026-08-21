---
layout: default
title: Help
---

# Help

Install and setup: [Getting started](getting-started.md). Building the app? [Developer troubleshooting](../dev/troubleshooting.md).

## Plaid and Sync

### “Add your Plaid client_id and secret”

**Settings** → paste **client_id** and **secret** → pick **Environment** → **Save credentials**. The secret must match that environment (Sandbox secret with Sandbox).

### Link closes immediately or never opens

- Allow the browser sheet when iOS asks.
- Save credentials again, then retry **Link bank account**.
- Sandbox only works with a Sandbox secret.

### Link finishes but nothing shows up

Wait a few seconds and try **Link** again, or check Plaid Dashboard logs.

### Sync says no banks linked

**Settings → Link bank account**, then **Transactions → Sync → Sync now**.

### Sync works but the list is empty

- Wait a moment after the first link, then **Sync → Full re-sync**.
- Confirm the bank still appears under Settings.
- Pending (not posted) charges may not appear yet.

### Categories look wrong

Open the transaction → fix **category** → **Save** with **learn** on. Future Syncs keep that mapping.

### Bank says login expired

**Settings** → Relink that bank.

### Real-bank (Production) OAuth never returns to the app

Some banks need extra Plaid / redirect setup. Sandbox test banks usually don’t.

## Widgets

Sync in the app first, then add the widget. If it stays empty, delete it and add it again. More: [Widgets](widgets.md).

## Welcome screen

Welcome appears only on first launch. TestFlight **updates** keep your data and skip Welcome. To see Welcome again (testers): **Settings → Developer → Debug → Replay onboarding**.
