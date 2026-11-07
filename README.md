# Live Transit Detroit — native macOS app (codename:distro, T1 scaffold)

Native Objective-C / AppKit client for Live Transit Detroit, built for
distribution through codename:distro on macOS 10.13 (High Sierra).

## Scope ruling (2026-11-07) — one network, default-on, no exceptions

Justin's ruling, 2026-11-07 13:24–13:27 EST, applied to this scaffold:

1. **Permission to exclude SMART: DENIED.** SMART is a full, default-on
   part of Live Transit Detroit in this app.
2. **Permission to treat SMART as distinct from DDOT for non-technical
   purposes, including specific API reference: DENIED.**

Design consequence, implemented throughout: the app fetches both
vehicle feed files and **merges them into ONE vehicle list** — one
map (regional bounds, everything drawn by default — no layer, no
toggle), one table (no sections), one total count, and one
"Live Transit Detroit feed" status line. Nothing in the UI, copy, or
API presentation separates the network by agency; the per-vehicle
`agency` field survives only as data-fidelity/debugging plumbing
inside `LTDVehicle`, with a header comment saying exactly that.

## The no-browser rule (non-negotiable)

- Objective-C, **AppKit + Foundation only. Zero third-party dependencies.**
- **No WebView / WKWebView / WebKit, no WebGL, no Electron, no embedded
  browser of any kind.** The map is drawn with `NSBezierPath` into an
  `NSView`; the feed is fetched with `NSURLSession`.
- Performance comes from the architecture, not from a browser engine:
  the static route layer is rendered once into an offscreen `NSImage`
  cache, `drawRect:` only blits that image and draws the vehicle
  markers, fetches are conditional GETs (ETag / Last-Modified, 304 =
  no parse, no redraw), and the map redraws only when the keyed vehicle
  diff says something actually moved.

## Stack / target

- Deployment target: **macOS 10.13**
- Memory management: **ARC**, used consistently in all sources.
- Feeds (read-only, public) — three files, ONE product:
  - `https://detroitautomationacademy.com/live-data/vehicles.json`
  - `https://detroitautomationacademy.com/live-data/smart-display.json`
  - `https://detroitautomationacademy.com/live-data/alerts.json`
  - The two vehicle files are merged into one list (2026-10-18 samples:
    58 + 86 = **144 vehicles**). Envelopes differ only in plumbing:
    vehicles.json carries `sources` (plural), smart-display.json
    carries `source` (singular); the single parser in `LTDVehicle`
    tolerates both. Vehicle keys: `agency, route_id, vehicle_id, lat,
    lon, bearing (nullable — null in smart-display.json; see
    `hasBearing`), speed_mph (nullable), destination (absent in
    smart-display.json), updated_at`, verified against the 2026-10-18
    samples in `~/workspace/daa-site/live-data/`.
- Refresh: 60 s timer. The feed republishes on a ~5-minute cron —
  do not poll faster; conditional GET makes an unchanged poll a 304.
- Disk cache: last good payload of each feed file in
  `~/Library/Caches/com.detroitautomationacademy.livetransit/`; a cold
  launch restores the merged set from both vehicle caches at once, so
  the instant first paint is the whole network, never a partial one.

## Layout

```
Sources/
  LTDVehicle.h/.m      feed model + parser (both vehicle envelopes) +
                       keyed position diff
  LTDFeedClient.h/.m   NSURLSession client, conditional GET, disk cache
                       (all three feed files, same treatment)
  LTDMapView.h/.m      NSView map: cached static layer + vehicle markers,
                       equirectangular projection fitting the full
                       regional bounds (lat 42.11–42.73, lon
                       −83.58–−82.72) with the Detroit core drawn as
                       the anchor marker, flipped=YES (see header)
  LTDAppDelegate.h/.m  1100x700 window, map left ~70%, vehicle table
                       right, one status line, 60 s refresh fetching
                       all three feed files and merging the two
                       vehicle payloads into ONE list, diff-gated
                       redraw; cold launch restores the merged set
                       from both per-file caches
  main.m               programmatic NSApplication bootstrap (no XIB)
  Info.plist           com.detroitautomationacademy.livetransit, min 10.13,
                       version 0.1.0
```

## Build

On the High Sierra rig (Xcode 10.1):

1. Create an AppKit (Objective-C, ARC) app target named
   `LiveTransitDetroit`, deployment target 10.13, and add everything in
   `Sources/` (including `Info.plist`) to it. The deployment-target half
   of the floor's matched pair (REQ-H-1.2) is declared in
   `LiveTransitDetroit.xcconfig` at the repo root — assign it as the
   target's base configuration so the setting lives in a file, not only
   in this paragraph — or compile manually:

   ```
   clang -fobjc-arc -framework AppKit -mmacosx-version-min=10.13 \
       Sources/*.m -o LiveTransitDetroit
   ```

   and place the binary in a `.app` bundle with `Sources/Info.plist`.

## Verification status — read before trusting

- **This scaffold is syntax-checked only.** Every `.m` passes
  `clang -target x86_64-apple-darwin17 -isysroot MacOSX10.13.sdk
  -fobjc-runtime=macosx-10.13 -fobjc-arc -fsyntax-only` on the Linux VM.
- **No runtime testing has happened** (Objective-C/Foundation cannot run
  on this Linux VM; no parser smoke test is claimed).
- **Full build + run verification requires Justin's MacBook Air**
  (the native macOS 10.13 rig). Nothing here is shipped or published.

## Routes sample — SKIPPED (noted per instructions)

`Sources/routes-sample.json` was **not** generated. One conversion attempt
was made against `~/workspace/daa-site/ddot-routes-3d.json`: its route
`paths` are **projected x/z metre coordinates** (file extent roughly
-15213…19568 × -10305…13288) around `projection.lat0/lon0`, not lat/lon,
and the file carries no scale/inverse-projection formula. Converting it
would require guessing the projection — which would put wrong geometry
on the map — so it was skipped rather than fabricated. The T2 tranche
should derive lat/lon polylines from the GTFS shapes source instead.
`LTDMapView` already accepts lat/lon polylines via `LTDRoutePolyline`.

2026-11-07 scope-correction note: because no sample file existed,
extending one to the SMART routes in `smart-routes-3d.json` was likewise
skipped (same projected-coordinate problem, same no-fabrication rule).
This is a geometry-data gap only, **not** a scope reduction: the map's
default projection already covers the full regional bounds, and when
the T2 GTFS-derived polylines land, routes from every feed are drawn
together by default — there is no per-agency route layer to add.
