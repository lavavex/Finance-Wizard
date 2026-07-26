# FinanceWidget

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
Site URL is typically `https://<user>.github.io/FinanceWidget/` (set `baseurl` in `docs/_config.yml` to match the repo name).

## Quick start

1. Open `FinanceWidget.xcodeproj` in Xcode.  
2. Sign **FinanceWidget** and **WidgetExtension** with your team.  
3. Confirm App Group `group.net.roberth.FinanceWidget` on both targets.  
4. Run the app → **Settings** → set server URL if needed → **Sync**.  

## Layout

```text
FinanceWidget/     App UI, sync, settings
Shared/            SwiftData model, store, filters, SF Symbols
Widget/            Total Spend widget
docs/              Project wiki (GitHub Pages)
```

## License

Personal project. Not affiliated with Apple Card or Plaid beyond using your own finance-sync portal.
