# StashDB API notes

Verified live 2026-07-09 against `https://stashdb.org/graphql` with a real API
key. StashDB is a stash-box instance; this doc covers only the GraphQL surface
this plugin consumes — no stash/stash-box source was read or copied to write
either this doc or stashdb.rb.

## Basics

- Single endpoint, POST `https://stashdb.org/graphql`, `Content-Type:
  application/json`, body `{"query": "...", "variables": {...}}`.
- Auth header is **`ApiKey: <token>`**, not `Authorization: Bearer`. Get a key
  from your stashdb.org account (Profile → Settings → API key) — per-user,
  never bundle one. Every read query requires it.
- Errors surface as a GraphQL `errors` array alongside a null `data`, not an
  HTTP status — still treat non-200 as a hard failure. Assume the same
  best-effort availability as any community-run instance: swallow failures to
  nil, never block imports.

## Fingerprint matching (our primary resolver path)

- **`findSceneByFingerprint` (singular) is gone from production.** Use
  `findScenesBySceneFingerprints` (plural, batch) only.
- Shape: `fingerprints: [[FingerprintQueryInput!]!]!` — a list of lists, one
  inner list per file you're identifying. Return type `[[Scene]!]!` is
  **index-aligned** to the input: `result[0]` is the candidate array for
  `fingerprints[0]`. We only ever identify one file at a time, so we always
  send one inner list and read `result[0]`.
  `FingerprintQueryInput = { hash: String!, algorithm: FingerprintAlgorithm! }`,
  `algorithm ∈ OSHASH | PHASH | MD5`. XVault only has oshash + phash — include
  only the entries whose hash is actually present.
- **No server-side duration filter.** The query returns every scene matching
  any of the given hashes, full stop. Apply a ±5s guard client-side against
  each candidate's `duration` (Int seconds) OR any of its own
  `fingerprints[].duration` before trusting a hit — a hash collision across
  unrelated scenes is otherwise indistinguishable from a real match.

```graphql
query FindByFP($fingerprints: [[FingerprintQueryInput!]!]!) {
  findScenesBySceneFingerprints(fingerprints: $fingerprints) {
    id title details release_date duration
    urls { url }
    studio { name }
    tags { name }
    images { url }
    performers { as performer { id name } }
    fingerprints { hash algorithm duration }
  }
}
```

Variables for a single file: `{"fingerprints": [[{"hash": "<oshash>",
"algorithm": "OSHASH"}, {"hash": "<phash>", "algorithm": "PHASH"}]]}`.

## Free-text scene search

`searchScenes(term, page, per_page)` → `{ count, scenes { ... } }`. Result
path: `data["searchScenes"]["scenes"]`. Fuzzy-ranked like TPDB's `?parse=`, not
filtered — a generic title returns several loosely-related candidates, so the
resolver's fallback still needs its own duration/title guard rather than
trusting the top result.

## Scene detail

`findScene(id)` → a Scene Hash directly, or `null`. Result path:
`data["findScene"]`. Richer than the search/fingerprint shape (`director`,
`code`, per-url `site { name }`), used for the Identify panel's Apply re-fetch.

## Performers

- `searchPerformers(term, page, per_page)` → `{ performers { ... } }`. Result
  path: `data["searchPerformers"]["performers"]`.
- `findPerformer(id)` → a Performer Hash directly, or `null`. Result path:
  `data["findPerformer"]`.
- Fields are flat strings/ints — no per-site vs. canonical-parent split like
  TPDB (one record per performer, full stop): `birth_date`, `death_date`,
  `country`, `ethnicity`, `eye_color`, `hair_color`, `height`, `cup_size`,
  `band_size`, `waist_size`, `hip_size`, `career_start_year`,
  `career_end_year`. Dates are ISO strings (`Date.iso8601`-parseable).
- `aliases` is a plain array of strings directly on the performer (no
  parent/child indirection to resolve first).
- `tattoos`/`piercings` are arrays of `{location, description}`, not a single
  string — join into one readable string to match the flat string contract
  every other connector's `map_performer` uses.
- No `bio`, no separate cropped-face image, no `full_name`, no
  `measurements`/`weight`/`birthplace`/`astrology`/`fake_boobs`/
  `same_sex_only` — StashDB's schema simply doesn't carry these; the mapped
  hash still emits the keys (nil) so the merger has one shape to handle
  regardless of source.

## Open questions before/while implementing

1. Official rate limit — nothing published; back off on 429 like TPDB.
2. Whether StashDB ever serves `images[].url` from a CDN host other than
   `cdn.stashdb.org` (affects the embed trusted-hosts allowlist).
