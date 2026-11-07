# Live Transit Detroit — native macOS app (codename:distro, T1 scaffold)

Native Objective-C / AppKit client for Live Transit Detroit, built for
distribution through codename:distro on macOS 10.13 (High Sierra).

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
- Feeds (read-only, public):
  - `https://detroitautomationacademy.com/live-data/vehicles.json`
  - `https://detroitautomationacademy.com/live-data/alerts.json`
  - Envelope: `{generated_at, count, vehicles[], sources}` — vehicle keys
    `agency, route_id, vehicle_id, lat, lon, bearing, speed_mph (nullable),
    destination (nullable), updated_at}`, verified against the
    2026-10-18 sample in `~/workspace/daa-site/live-data/vehicles.json`.
- Refresh: 60 s timer. The feed republishes on a ~5-minute cron —
  do not poll faster; conditional GET makes an unchanged poll a 304.
- Disk cache: last good payload in
  `~/Library/Caches/com.detroitautomationacademy.livetransit/` for an
  instant cold launch.

## Layout

```
Sources/
  LTDVehicle.h/.m      feed model + parser + keyed position diff
  LTDFeedClient.h/.m   NSURLSession client, conditional GET, disk cache
  LTDMapView.h/.m      NSView map: cached static layer + vehicle markers,
                       equirectangular projection centred 42.3314,-83.0458,
                       flipped=YES (documented in header)
  LTDAppDelegate.h/.m  1100x700 window, map left ~70%, vehicle table right,
                       status line, 60 s refresh, diff-gated redraw
  main.m               programmatic NSApplication bootstrap (no XIB)
  Info.plist           com.detroitautomationacademy.livetransit, min 10.13,
                       version 0.1.0
```

## Build

On the High Sierra rig (Xcode 10.1):

1. Create an AppKit (Objective-C, ARC) app target named
   `LiveTransitDetroit`, deployment target 10.13, and add everything in
   `Sources/` (including `Info.plist`) to it — or compile manually:

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
