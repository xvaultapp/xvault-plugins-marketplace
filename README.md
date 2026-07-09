# XVault plugin marketplace

The community plugin catalog for [XVault](https://github.com/xvaultapp) — the
self-hosted, open-source "private Netflix" for your own media library.

XVault ships with **zero site-specific scrapers** by design: its built-in
`GenericJsonLd` extractor already reads any site that publishes a schema.org
`VideoObject`. This repo is where the community publishes the rest — declarative
scraper/search plugins that XVault can install with one click from
**Settings › Plugins › Browse marketplace**.

## How XVault finds this catalog

XVault fetches [`index.json`](./index.json) from the URL in its
`XVAULT_PLUGIN_INDEX_URL` environment variable and lists every entry. Point a
self-hosted instance here with:

```
XVAULT_PLUGIN_INDEX_URL=https://raw.githubusercontent.com/xvaultapp/xvault-plugins-marketplace/main/index.json
```

The catalog **is the security boundary**: XVault only installs a URL that is
currently listed in the fetched `index.json`, and every filename is reduced with
`File.basename` and regex-checked before any disk write. Side-loading a plugin
by dropping a YAML into `scrapers/community/` is always possible too — that stays
the operator's own risk.

## `index.json` format

```json
{
  "plugins": [
    {
      "name": "Eporner",
      "url": "https://raw.githubusercontent.com/xvaultapp/xvault-plugins-marketplace/main/plugins/eporner/eporner.yml",
      "description": "Free-text search and web recommendations from eporner.com. No API key required."
    }
  ]
}
```

- `name` (required) — shown in the marketplace list.
- `url` (required) — raw URL of the plugin's `.yml`. Its basename becomes the
  installed filename (`ScraperPlugin#filename`) and must match `\A[\w.-]+\.ya?ml\z`.
- `description` (optional) — one line shown under the name.

A bare top-level array (`[ { ... } ]`) is also accepted.

## Writing a plugin

A plugin is one YAML file (plus an optional co-located `.rb` escape hatch). It
can declare a `search:` block (joins XVault's Identify connectors, searchable by
free-text term) and/or a `scene:` block (scrapes a matched `webpage_url`). See
the plugins already in [`plugins/`](./plugins) for worked examples,
and the full field reference in XVault's own
[`docs/scraper-plugin-authoring.md`](https://github.com/xvaultapp/xvault/blob/main/docs/scraper-plugin-authoring.md).

A plugin that references a `script:` file ships Ruby that XVault evaluates on
your instance. Only install `script:` plugins from a catalog you trust — this
one is curated, but review the code.

## Submitting a plugin

1. Add your `plugins/<name>/<name>.yml` (and any `script:`/`connector:` `.rb` beside it).
2. Add an entry to `index.json`.
3. Open a PR. Plugins must be **clean-room** — written from the site's own public
   HTML, never ported from another project's scrapers — and respect each site's
   terms. Adult-site scrapers are a legal/ToS gray area; you are responsible for
   your submission.

## License

AGPL-3.0-or-later. Copyright © XVault. See [`LICENSE`](./LICENSE).
