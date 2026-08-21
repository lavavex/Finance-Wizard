# Finance Wizard

Personal iOS expense tracker: **your** Plaid developer keys, Hosted Link, SwiftData (App Group), tabs for spend / accounts / budget / recurring, and Home Screen widgets.

## Documentation

Wiki in **[`docs/`](docs/index.md)** (GitHub Pages source).

| Topic | Doc |
|-------|-----|
| **User** | [docs/user/](docs/user/index.md) |
| Getting started (TestFlight) | [docs/user/getting-started.md](docs/user/getting-started.md) |
| Using the app | [docs/user/using-the-app.md](docs/user/using-the-app.md) |
| **Developer** | [docs/dev/](docs/dev/index.md) |
| Development (Xcode) | [docs/dev/development.md](docs/dev/development.md) |
| Architecture | [docs/dev/architecture.md](docs/dev/architecture.md) |
| Sync & Plaid | [docs/dev/sync-and-api.md](docs/dev/sync-and-api.md) |
| Publishing the wiki | [docs/dev/github-pages.md](docs/dev/github-pages.md) |

Agent rules (docs + test builds): [`AGENTS.md`](AGENTS.md).

After push: **Settings → Pages → Branch: main → Folder: /docs**.  
URL is typically `https://<user>.github.io/Finance-Wizard/` (`baseurl` in `docs/_config.yml`).

## Quick start

**Testers:** [Getting started](docs/user/getting-started.md) — TestFlight → Welcome → Plaid keys → Link bank → Sync.

**Developers:** [Development](docs/dev/development.md) — Xcode 26+, same team on app + widget, App Group `group.net.roberth.FinanceWizard`.

## Layout

```text
FinanceWizard/     App UI, Features/, Plaid/
Shared/            SwiftData, analytics (app + widget)
Widget/            Total Spend, Category Spend, Balances
docs/user/         Tester / TestFlight guides
docs/dev/          Contributor / Xcode guides
AGENTS.md          Coding-agent rules
```

## License

Personal project. Not affiliated with Plaid or Apple Card beyond using your own Plaid keys and Apple platforms.
