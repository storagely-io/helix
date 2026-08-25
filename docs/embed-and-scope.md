# The embed: shell, iframe, and scope

Atlas is a **full-bleed iframe** inside the Helix platform shell (`AtlasRoute.tsx`: *"the iframe
fills the full content area; Atlas owns all chrome inside"*). That boundary is the ownership seam
described in `../CLAUDE.md`, and it is also where most confusing behaviour originates: two apps,
two repos, one screen, and a message channel between them.

## Wiring

`apex-app/packages/platform/.env.local` (gitignored), written by `make wire`:

```
VITE_ATLAS_IFRAME_URL=http://<wsl-lan-ip>:9730?apiBase=http://localhost:9600
```

Three non-obvious constraints, each of which has produced a bug here:

- **The iframe URL must use the LAN IP, not `localhost`.** `isLovableHost()`
  (`atlas/src/lib/iframe-session.tsx:110`) treats `localhost`/`127.0.0.1` as a top-level Lovable
  preview, so `useIsEmbedded()` returns false (line 678) and Atlas renders its own shell —
  duplicated chrome inside the frame.
- **The parent must be exactly `http://localhost:9720`.** That is the allowlisted dev origin, and
  `?apiBase=` is honoured *only* for it — which is what stops the override leaking to production.
  So: browse `localhost:9720`, embed the LAN IP.
- **Vite reads env at boot only.** Changing it requires restarting the platform; that is part of
  why `make dev` exists.

`resolveAtlas()` / `atlasIframeUrl()` (`shell/atlasEmbed.ts:31,95`) parse that URL and re-apply
`apiBase` per surface.

## The handshake

```
iframe-ready → channel-init → channel-ready → auth        (MessageChannel port)
then: lock { accountId, websiteId, pageId, section }  ↓
      route-change { path, section, pageId }          ↑
```

`AtlasRoute.tsx:177` pins `targetOrigin` from the frozen `iframeSrc` and drops any message whose
origin differs (line 580). Scope errors come back as `?ctx_error=…` (`UNKNOWN_ACCOUNT`,
`WEBSITE_NOT_IN_ACCOUNT`, …) with copy in `CONTEXT_ERROR_COPY`.

## How `?pageId=` becomes a location

**The iframe `src` never carries `pageId`.** `atlasIframeUrl()` appends only `apiBase` — by
design, after a bug where some surfaces preserved it and one dropped it, leaving a stale
location. So the pageId travels over the bridge in `lock` (`AtlasRoute.tsx:270`), and Atlas
resolves it server-side via `resolveLocationForPage`
(`atlas/src/lib/atlas-page-resolve.functions.ts`):

1. `atlas_pages.id = pageId` → its `location_id` (only when `pageId` is a uuid; Helix pageIds
   never are, so in practice this misses);
2. **fallback:** `atlas_locations.platform_location_id = pageId` — the one that actually matches;
3. `assertHelixAccountAccess(…, "read")` on the resolved location's account;
4. re-select with `atlas_companies!inner(slug)` to get the company slug.

Then `iframe-session.tsx` navigates to `/atlas/{companySlug}/overview/{locationSlug}`.

Two debugging notes:

- **This path applies no `helix_tags` filter.** A location can resolve here and still be absent
  from every list. See [atlas-local-data.md](atlas-local-data.md).
- **Failures log to the browser console** (`iframe-session.tsx:504` is a `console.warn`), never
  to the Atlas server log. Grepping `.logs/atlas.log` for a resolution failure finds nothing.
  Combined with `ssr: false`, this is why an HTTP 200 says nothing about whether the page worked.

## The section round-trip, and where it stops

The shell mirrors Atlas's reported section into `?section=` and replays it on the next `lock`, so
switching location can keep you on the same sub-page. `LocationSwitcher.openLocation()`
(`shell/header/LocationSwitcher.tsx:198`) deliberately drops the inner path tail and rebuilds:

```
atlasWrapperUrl(userId, accountId, scope, "") + "?pageId=" + pageId + (section ? "&section=" + section : "")
```

Dropping the tail avoids a stale-location 404; the `section` is what carries continuity.

**`section` is a closed vocabulary of nine tokens** — `EmbeddedNavSection` in
`atlas/src/lib/embedded-nav.ts`: `location-core`, `hours`, `amenities`, `photos`, `faqs`,
`seo-block-content`, `google-profile`, `storage-types`, `website-meta`.

`checkout-settings` **is not one of them.** It appears only in `FLAT_LOCATION_SURFACES` (line 48)
— a different set, used for URL parsing — and is absent from `SURFACE_TO_SECTION` (line 344), so
`sectionFromPathname("/atlas/{c}/checkout-settings/{loc}")` returns **null**. With no token:
nothing is mirrored to `?section=`, `openLocation` appends no `&section=`, Atlas re-locks without
one, and the operator lands on the location's default surface.

So the behaviour is a **vocabulary gap, not a routing bug**, and the fix is a nav-vocabulary
change (`EmbeddedNavSection`, `EMBEDDED_NAV_SECTIONS`, `routeForSection`, `SURFACE_TO_SECTION`,
`SECTION_TO_FLAT_SURFACE`) — which `atlas/CLAUDE.md` puts behind the design owner: *"Do not build
or restructure the navigation. Nav structure and section order are being settled by the design
owner."* Hence unfixed; see [open-items.md](open-items.md).

Note the TanStack file-naming trap while reading those routes: `checkout-settings_.$location.tsx`
has a `_` suffix meaning "escape the parent layout". **It is not part of the URL** — the real path
is `/atlas/{c}/checkout-settings/{loc}`, which is why `FLAT_LOCATION_SURFACES` stores the
underscore-free form and no code normalizes one.

## Route ownership, restated

The seam decides the repo, and it is worth re-deriving rather than guessing:

- **Inside the frame** — page body, Atlas's own nav, its lists and forms ⇒ `atlas/`
- **Around the frame** — shell, top nav, switchers, scope, URL mirroring, the handshake, error
  overlays, and every `/api/v1` endpoint Atlas calls ⇒ `apex-app/`

A change spanning both is **two commits in two repos**. `atlas/` pushes to
**`storagely-home-base`**, not `atlas`.
