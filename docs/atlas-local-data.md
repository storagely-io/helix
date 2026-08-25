# Where Atlas's local data comes from

Atlas's data lives in **its own Supabase database**, not in Helix's. Standing up Atlas locally
therefore means standing up a second database and putting rows in it. The 301 migrations give
you schema and **almost no rows**, so a fresh local Atlas renders an empty, apparently-broken
app even when every service is healthy.

## Populate it with the sync, not by hand

```bash
make sync-atlas
```

This POSTs Atlas's own hourly cron endpoint
(`atlas/src/routes/api/public/hooks/sync-helix-location-pages.ts`) — the same code path
production runs. It:

1. enumerates `atlas_companies` rows with a connected Helix `accountId`;
2. asks Helix, signed, for that account's websites (`GET /api/v1/accounts/{id}/websites`);
3. asks Helix for each website's page catalog (`…/websites/{id}/atlas/pages`);
4. reconciles into `atlas_locations`, matching on `platform_location_id` — so existing rows are
   **adopted/refreshed, never duplicated**;
5. caches the first website id onto `atlas_companies.platform_website_id`.

It is idempotent: a second run reports `unchanged=N`.

Step 5 is not incidental. The locations list inner-joins on
`atlas_companies.platform_website_id`, so until it is set, **every locations list is empty
regardless of how many location rows exist.**

### Why not write the rows directly

A hand-written seed was tried first and superseded (`scripts/_superseded/`). It got the rows
roughly right and the **fields** wrong in the one way that matters — see the filter below — and
it invented rows for Helix pages that are not location pages at all. Helix returns its whole
page catalog (20 pages for the local website: `page/city`, `page/state`, `page/checkout`,
`page/home`, untagged…); only 4 carry `page/location`.

## The filter that makes a row invisible without making it missing

`atlas/src/lib/atlas-locations-list.functions.ts:149`:

```
.or('fields.cs.{"helix_tags":["page/location"]},fields->>atlas_origin.eq.import')
```

A row with `fields = {}` passes neither branch. It is not reported, not warned about, and not
absent — it simply never appears. The same predicate appears in
`atlas-reserve-gapfill.server.ts:43` and `atlas-reserve-readiness.functions.ts:78`.

Two consequences worth holding onto:

- **A row can be findable and unlistable at once.** The location resolver
  (`atlas-page-resolve.functions.ts`) queries `platform_location_id` directly and applies no
  such filter, so `?pageId=` can resolve while every list stays blank.
- `make status` reports the count that actually passes the filter, not `count(*)`. That is the
  number that predicts whether the UI works.

## The FMS location code has two homes

| Reader | Source of the code |
|---|---|
| locations list | `fields.fms_location` **\|\|** `helix_page_location_code` |
| `edge-settings` (`edge-settings.functions.ts`) | `fields.fms_location` **only** |

This asymmetry is intentional. `fields.fms_location` is the **operator's** binding — written by
`FmsSoftwarePage.tsx`, the `LocationDetail` field editor, or the bulk-id CSV — and Helix does
not own it, so the reconcile must not write it. `helix_page_location_code` is Helix's own
page→code binding.

Net effect locally: a facility can display a code in the header and simultaneously report
*"This location has no FMS location code assigned."* `make sync-atlas` closes the gap by
binding one from the other and recording `sources.fms_location = 'fms'`, matching
`atlas-import.functions.ts:2968`.

## A location's display name is derived, not stored

`atlas-locations-list.functions.ts` resolves the name in this order:

```
explicitName (only when sources.name === 'override')
  || templatedName (company defaultLocationNameTemplate)
  || deriveRoadName(street)
  || row.name
  || titleCaseSlug(slug)
  || 'Untitled'
```

`deriveRoadName(street)` outranks the stored `name`. Locally `street` is empty — nothing has
scraped or GBP-synced — so a facility shows its full Helix page name (*"Clemmons Towncenter
Drive"*) where production shows the road (*"Towncenter Drive"*). **That is missing data depth,
not a naming bug**, and it is the most likely thing to be misreported as one.

The `sources.name === 'override'` guard exists to fix a real revert loop: an automated source
(`helix`) must not beat the operator's company template, or the template appears to undo itself
after every sync.

## What is in the local database, and who put it there

| Rows | Origin | Notes |
|---|---|---|
| 4 location rows under `account-fdl4h-6dc5c8ftp` | `make sync-atlas` | Matches Helix's 4 `page/location` pages |
| `Storagely Demo Co`, `Lone Star Storage`, the Houston location | the **tracked migrations** | Lovable-authored demo seed — present in the repo, so leave them; deleting is a local divergence |
| `account_SsTtwJgWkFksSxX` company row | hand-created, then removed | See [open-items.md](open-items.md) |

## Account ids do not survive an import

Helix mints a fresh id for every entity on creation (`generatePrefixedId`), including on import,
and no prod→local id map is persisted. Production `website_TDXHh4JJcsBRsWX` arrived locally as
`website_g_cNyzHQqzPXKsB`; the account is `account_FDL4h_6DC5C8Ftp`.

The local URL is therefore **not** the production URL with the host swapped:

```
/users/<userId>/accounts/account_FDL4h_6DC5C8Ftp/atlas/website_g_cNyzHQqzPXKsB
```

Since Atlas's data is local too, this needs no id-preservation and no tracked change — the
`atlas_companies` row just has to point at whatever local account exists. Preserving ids on
import would require editing tracked files (`importer.ts` / `websites.ts`) and is unnecessary.
