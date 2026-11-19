# Trillium pages on m-of-n.com

This folder is served at `https://m-of-n.com/ambient-lab/trillium/`:

| Path here | URL |
|---|---|
| `index.html` | `/ambient-lab/trillium/` |
| `zero/` | `/ambient-lab/trillium/zero/` |
| `privacy/` | `/ambient-lab/trillium/privacy/` |
| `assets/` | `/ambient-lab/trillium/assets/` (Trillium pages only) |

Only the Trillium pages live here. The rest of m-of-n.com, including `/ambient-lab/`, `/style.css`, `_headers`, `_redirects`, `sitemap.xml` and `functions/`, stays in the deploy tree and keeps its own palette. The pages still load `/style.css` for layout, then `assets/tokens.css` and `assets/trillium.css` for the Stage look from [`brand/BRAND.md`](../../brand/BRAND.md). Each page opens on the Trillium lockup; M-of-N appears only as a small footer credit (and, on the privacy page, as the operator named in the body).

- **Brand files:** `assets/tokens.css`, `assets/lockup.svg` and `assets/icons/` are unchanged copies of `brand/`. `assets/og-image-1200x630.jpg` and `assets/hero-*` are compressed from `brand/visuals/png/`. Refresh them all with `python3 tools/trillium_site.py assets`. `tools/test_trillium_site.py` checks the copies, the CSP rules and that the pages stay noindex.
- **Fonts:** Outfit, Inter and IBM Plex Mono (Latin subsets, woff2 from Fontsource 5.3.0), self-hosted under the SIL Open Font License 1.1. The licences are in `assets/fonts/`.
- **CSP:** `default-src 'self'`. No inline styles or scripts, no `data:` URIs and no external assets. Bump `?v=` on a stylesheet whenever it changes.
- **Indexing:** every page is `noindex` and stays out of `sitemap.xml`.

## Upload zip for deployment

```sh
python3 tools/trillium_site.py bundle <deploy tree or current upload zip> upload-m-of-n.com-trillium.zip
```

This command copies the whole site unchanged and swaps in this folder as `ambient-lab/trillium/`. Deploys go through the site's Cloudflare Pages project and need approval each time. This repository doesn't deploy anything.
