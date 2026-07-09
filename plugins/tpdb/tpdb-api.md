# ThePornDB API notes (Phase 2 groundwork)

Research snapshot 2026-07-07, reverse-engineered from official clients
(`ThePornDatabase/namer`, `Jellyfin.Plugin.ThePornDB`) and the upstream
stash-box GraphQL schema, plus live curl checks. No public docs page exists;
verify against the real API when implementing.

## Basics

- REST base `https://api.theporndb.net`, `Authorization: Bearer <token>`
  (token per user from `theporndb.net/user/api-tokens` — each install brings
  its own; never bundle one).
- Errors: 401 bad/expired token, 429 rate limited. Assumed safe budget
  ~120 req/min (unofficial, from a client-side throttle — back off on 429).
- Availability is best-effort: documented intermittent 500s. The resolver
  must swallow failures to nil, never block imports.

## Endpoints

| Purpose | Path |
|---|---|
| Scene search | `GET /scenes?parse={site.date.name}&hash={hash}&hashType={type}&year=&page=&limit=25` |
| Scene detail | `GET /scenes/{id}` |
| Movies / JAV | same shape under `/movies`, `/jav` |
| Performer search / detail | `GET /performers?q={name}`, `GET /performers/{id}` |
| Site search / detail | `GET /sites?q={name}`, `GET /sites/{id}` (parent_id/network_id = 3-tier hierarchy) |
| Auth check | `GET /auth/user` |
| Submit fingerprint | `POST /scenes/{id}/hash` body `{"type":"PHASH"\|"OSHASH"\|"MD5","hash":"…","duration":<sec>}` |

## Fingerprint matching (our primary resolver path)

- Only `hashType=PHASH` is **confirmed working for search**; OSHASH/MD5 are
  confirmed only on the submit side. Try PHASH first; treat OSHASH search as
  an experiment.
- TPDB PHASH == stash video phash (frame-grid collage + image phash, hex,
  Hamming-compared). Reference implementation to validate ours against:
  <https://github.com/ThePornDatabase/videohashes> (Go, "Stash and StashBox
  compatible"). Our implementation: `app/services/library/phash.rb` — not yet
  validated bit-exact against it.
- namer's confidence heuristic: Hamming distance 0 **and** duration agreement
  → treat phash as near-exact fingerprint, not fuzzy search.

## Lookup by URL

No REST `?url=` param. Practical flow: parse site/title from the pasted URL →
`GET /scenes?parse=…` → verify candidates by comparing their returned `url`
field to ours. (A GraphQL `SceneQueryInput.url` exists on the stash-box
interface at `metadataapi.net/graphql`, but that endpoint was unreachable at
research time — don't build on it.)

## Performers (profile images)

REST performer object: `name, disambiguation, aliases[], bio`,
`face` (single pre-cropped face image URL — ideal seed),
`image` (profile), `posters[] {url, size, order}` (multiple photos), and
`extras{birthday, measurements, ethnicity, nationality, …}`.

Images are served watermarked via `thumb.theporndb.net`. Per-user local
caching for performer pages is the intended usage; **do not** redistribute or
bundle them — and review the actual ToS (behind login) before anything beyond
per-user caching.

## Open questions before/while implementing

1. Does `hashType=OSHASH` work on `GET /scenes`?
2. Official rate limit + pricing/tier (nothing published).
3. Is a stash-box GraphQL endpoint still exposed anywhere (metadataapi.net
   DNS-failed at research time)?
4. Is `face` alone a good enough seed for performer pages, or do we want
   `posters[]` too?

## Phase 3 live verification (2026-07-07, parse-search fallback + Identify panel, #19)

Verified live with a real key via curl against the endpoints above.

- **`GET /scenes?parse=…` matches loosely across title, site, and performer
  names, not just the title.** `parse=Blacked Raw Kira Noir` (a cleaned
  filename-style query) returned exactly one candidate: id
  `77d5ad96-5a9f-4161-b06b-739ef6425166`, titled **"One Night"** (Blacked Raw,
  2021-02-22, duration 2544s) — matched because Kira Noir is a credited
  performer, confirmed via `GET /scenes/{id}` (`performers: ["Avi Love", "Kira
  Noir", "Sly Diggler"]`). A title-only similarity check would have rejected
  or misjudged this true match; this is why the fallback's guard checks
  duration/normalized-title against the *returned* candidate rather than
  trusting relevance ranking.
- **A generic single-word title returns many loosely-ranked candidates with
  no single correct answer.** `parse=Anniversary` returned 20 results
  (`"The Anniversary"`, `"Anniversary Surprise"` dur=1299, `"Anniversary
  Orgy"` dur=2988, `"2 Year Anniversary"` (no duration), `"Anniversary
  Show"` dur=1832, …) spanning unrelated studios. Confirms the strong-guard
  requirement in `Metadata::Tpdb.by_parse_search`: accept only a duration
  match (±10s) when the file's duration is known, else a near-exact
  normalized-title match — never just the first/top result.
- **A garbage/nonsense query returns a clean empty result**, not an error:
  `parse=zzqqxx nonsense garbage title 999` → `{"data": []}`. No 4xx/5xx;
  `results()`'s `Array(parsed["data"])` naturally yields `[]`.
- **`GET /scenes/{id}` and `GET /performers/{id}` both return the object as a
  bare Hash directly under `"data"`** (confirmed: `d["data"].class ==
  Hash`), unlike the list endpoints (`/scenes?parse=`, `/performers?q=`)
  which return an Array under `"data"`. `fetch_scene`/`fetch_performer` parse
  this directly rather than reusing the list-oriented `results()` helper.
- **Performer detail nuance vs. the Phase 2 note above:** `image` is served
  unwatermarked from `cdn.theporndb.net`, while `face` is served via
  `thumb.theporndb.net`. (Phase 2's "images are served watermarked via
  thumb.theporndb.net" note held for `face`, not for `image`.) `extras`
  confirmed present with `nationality`/`birthday` keys as expected by
  `map_performer`.
