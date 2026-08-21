# Finance Wizard

Personal iOS expense tracker: **your** Plaid developer keys, Hosted Link, SwiftData (App Group), tabs for spend / accounts / budget / recurring, and Home Screen widgets.

## Documentation

Wiki in **[`docs/`](docs/index.md)** (GitHub Pages source).

| Topic | Doc |
|-------|-----|
| Setup | [docs/getting-started.md](docs/getting-started.md) |
| Onboarding | [docs/onboarding.md](docs/onboarding.md) |
| Architecture | [docs/architecture.md](docs/architecture.md) |
| Features | [docs/app-features.md](docs/app-features.md) |
| Settings / Debug | [docs/settings.md](docs/settings.md) |
| Sync & Plaid | [docs/sync-and-api.md](docs/sync-and-api.md) |
| Widget | [docs/widget.md](docs/widget.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Enable GitHub Pages | [docs/github-pages.md](docs/github-pages.md) |

Agent rules (docs + test builds): [`AGENTS.md`](AGENTS.md).

After push: **Settings → Pages → Branch: main → Folder: /docs**.  
URL is typically `https://<user>.github.io/Finance-Wizard/` (`baseurl` in `docs/_config.yml`).

## Quick start

1. Open `FinanceWizard.xcodeproj` in Xcode 26+.  
2. Sign **FinanceWizard** and **WidgetExtension** with the same team.  
3. App Group `group.net.roberth.FinanceWizard` on both targets.  
4. Run scheme **FinanceWizard**. First launch: splash → **Welcome** → **Get Started**.  
5. **Settings** → Plaid `client_id` + secret (Sandbox) → **Save**.  
6. **Link bank account** → **Transactions → Sync**.  

Replay Welcome: **Settings → Developer → Debug → Replay onboarding**.

Bundle IDs `net.roberth.FinanceWizard` / `.Widget`.

## Layout

```text
FinanceWizard/     App UI, Features/, Plaid/
Shared/            SwiftData, analytics (app + widget)
Widget/            Total Spend, Category Spend, Balances
docs/              Wiki
AGENTS.md          Coding-agent rules
```

## License

Personal project. Not affiliated with Plaid or Apple Card beyond using your own Plaid keys and Apple platforms.
