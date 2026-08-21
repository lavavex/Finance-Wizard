---
layout: default
title: Publishing this wiki (GitHub Pages)
---

# Publishing this wiki (GitHub Pages)

These files live in **`docs/`**. GitHub Pages deploys from **`main`** (`docs/user/` testers, `docs/dev/` contributors). Day-to-day edits happen on **`dev`** and show up here when `dev` is merged to `main`. Maintainer-only notes in **`docs/local/`** are gitignored (except `docs/local/README.md`).

## 1. Push the repo (private is fine)

GitHub Pages works for **private** repos on paid plans; on free accounts private Pages may be limited—public repos always work. You can still keep source private and only enable Pages if your plan allows.

```bash
cd "/path/to/Finance Wizard"   # git root containing docs/
git add docs/
git commit -m "Add GitHub Pages documentation wiki"
git push origin main
```

## 2. Enable Pages

1. GitHub repo → **Settings** → **Pages**  
2. **Build and deployment** → Source: **Deploy from a branch**  
3. Branch: **main**  
4. Folder: **/docs**  
5. Save  

Wait a minute for the first build.

## 3. Set `baseurl` if needed

In `docs/_config.yml`:

```yaml
baseurl: "/Finance-Wizard"
```

Must match the **repository name** (case-sensitive).  
If the repo is `youruser/Finance-Wizard`, the site is usually:

```text
https://youruser.github.io/Finance-Wizard/
```

If the repo is a user/organization site named `youruser.github.io`, set `baseurl: ""`.

## 4. Theme

`_config.yml` uses the Cayman remote theme. If the build fails on the theme, either:

- Allow GitHub Actions / Pages to use remote themes, or  
- Remove `remote_theme` and use plain Markdown (still readable).

## 5. Local preview (optional)

```bash
# From docs/ with Ruby/Jekyll, or use:
bundle exec jekyll serve --source docs
```

Or simply open the Markdown files in the browser/IDE; structure is normal Markdown with a small Jekyll front matter (`layout: default`).

## 6. Navigation

Every page links from [Home](../index.md). User guides live in `docs/user/`; contributor guides in `docs/dev/`. Relative links work in GitHub’s file browser and on Pages when `baseurl` is correct.

## Wiki vs Pages

| Feature | GitHub **Wiki** | This **Pages** site |
|---------|-----------------|---------------------|
| Editing | Separate wiki git repo | Normal `docs/` in main repo |
| PRs / review | Awkward | Normal pull requests |
| Versioned with code | Partially | Yes |
| Custom domain | Limited | Supported on Pages |

This project uses **Pages + `docs/`** so documentation ships with the code.
