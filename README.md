# Finance Wizard

Personal iOS expense tracker: sync from a home **finance-sync** server (Plaid), store in **SwiftData** (App Group), browse by card, and show **Total Spend** on a Home Screen widget.

## Documentation (wiki)

Full guide lives in **[`docs/`](docs/index.md)** (GitHub Pages source).

| Topic | Doc |
|-------|-----|
| Setup | [docs/getting-started.md](docs/getting-started.md) |
| Architecture | [docs/architecture.md](docs/architecture.md) |
| Sync & API | [docs/sync-and-api.md](docs/sync-and-api.md) |
| Widget | [docs/widget.md](docs/widget.md) |
| Troubleshooting | [docs/troubleshooting.md](docs/troubleshooting.md) |
| Enable GitHub Pages | [docs/github-pages.md](docs/github-pages.md) |

After you push to GitHub, enable **Settings → Pages → Branch: main → Folder: /docs**.  
Site URL is typically `https://<user>.github.io/Finance-Wizard/` (set `baseurl` in `docs/_config.yml` to match the repo name).

## Quick start

1. Open `FinanceWizard.xcodeproj` in Xcode.  
2. Sign both targets with your team: **FinanceWizard** (main app) and **WidgetExtension** (home screen widgets).  
3. Confirm App Group `group.net.roberth.FinanceWizard` on both targets.  
4. Run scheme **FinanceWizard** → **Settings** → set server URL if needed → **Sync**.  

Bundle IDs `net.roberth.FinanceWizard` / `.Widget` install as a separate app from any older FinanceWidget build.

## Layout

```text
FinanceWizard/     App UI, sync, settings
Shared/            SwiftData model, store, filters, SF Symbols
Widget/            Total Spend widget
docs/              Project wiki (GitHub Pages)
```

## License

Personal project. Not affiliated with Apple Card or Plaid beyond using your own finance-sync portal.
