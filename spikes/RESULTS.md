# M0 spike results — macOS 26.5.2 (25F84), arm64, yabai 7.1.25 + SA loaded

Measured 2026-09-03. Single display 1710×1112. Test window: Zen (Gecko) 1694×1056,
plus AX-reachability sampling across Ghostty, Claude, Docker Desktop, WireGuard, Zen.
yabai stopped during S1/S2/S4 so it could not contend on the same AX queues.

Harness: `spike.swift` (`list`/`s1`/`s2`/`s4`), `s24b.swift`, `diag*.swift`.
Private symbols bound with `@_silgen_name`, linked `-F /System/Library/PrivateFrameworks
-framework SkyLight`. No C shim was needed for the spikes.

---

## S0 (unplanned) — AX only vends windows on the **active space**

The most consequential result of the whole M0 round, and it was not on the spike list.

`AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)` returns **0 windows** for any app
whose windows are all on a non-active space. It returns `kAXErrorSuccess` — an empty array,
not an error. Correlated against `SLSCopySpacesForWindows` + `SLSManagedDisplayGetCurrentSpace`
across two samples with different active spaces:

| App | WindowServer | space | active space | AX windows |
| --- | --- | --- | --- | --- |
| Zen | 1 real | 5 | **5** | **1** |
| Ghostty | 1 real | 6 | 5 | 0 |
| Claude | 1 real | 7 | 5 | 0 |
| Docker Desktop | 1 real | 3 | 5 | 0 |
| WireGuard | 1 real | 3 | 5 | 0 |

Second sample, active space 6: Ghostty → 1, everything else → 0. Perfect correlation both times.

Ruled out first: this is *not* the Electron/Gecko `AXManualAccessibility` gate. Poking
`AXManualAccessibility` (accepted, err 0, on Claude and Docker) and `AXEnhancedUserInterface`
(unsupported, −25208) changed nothing — 0 windows before, 0 after.

`CGWindowListCopyWindowInfo` sees **everything**, on every space, always. But it is noisy:
per-app 1710×39 menubar shims, 64×64 cursor windows, 0×0 agents, and `borders`' own overlays.
Filtering on `layer == 0` + both dimensions > 100 + non-empty `SLSCopySpacesForWindows`
result cleaned it to exactly the 8 real windows.

**Consequence:** the world model cannot be built by AX enumeration. Discovery must come from
the WindowServer; AX elements must be captured at `kAXWindowCreatedNotification` time (while
the window is necessarily on the active space) and **held** — a captured element keeps working
after its space goes inactive. Cold start has an unavoidable gap: windows that existed before
`weftd` launched, on non-active spaces, have no AX element until their space is first visited.

---

## S1 — AX frame-set latency: **PASS, with a revised cost model**

Zen, 40 iterations, alternating grow/shrink:

| Call | p50 | p99 | max |
| --- | --- | --- | --- |
| `setPosition` | 0.12 ms | 6.90 ms | 6.90 ms |
| `setSize` | 0.36 ms | 8.00 ms | 8.00 ms |
| `SLSGetWindowBounds` (verify) | 0.03 ms | 3.67 ms | 3.67 ms |
| **full frame-set** | **0.53 ms** | **32.31 ms** | 32.31 ms |

p50 is ~10× better than the §9 budget assumed. The p99 tail is real and lives in the app, not
in us — Gecko relayout. It is an argument for the per-pid queue, not against the budget.

**Revision:** re-position corrections fired **21/40 (53%)**, alternating with grow-vs-shrink.
`setPosition`→`setSize` gets the position wrong about half the time depending on direction.
So the design's "typical 2 IPCs, worst case 3" should read **~2.5 IPCs average**. The verify
step is not an occasional safety net; it is load-bearing. Keeping it on `SLSGetWindowBounds`
(0.03 ms, no app IPC) rather than an AX read-back is what makes that affordable.

---

## S2 — `SLSMoveWindow` position-only: **FAIL for visible windows, PASS for parked**

Speed is not in doubt — **79× faster** than AX:

| | p50 |
| --- | --- |
| `SLSMoveWindow` | 0.002 ms |
| AX `setPosition` | 0.124 ms |

But it desyncs the app. Requesting x = 500 / 900 / 200:

```
requested 500 -> SkyLight 500, AX 8   *** DESYNC ***
requested 900 -> SkyLight 900, AX 8   *** DESYNC ***
requested 200 -> SkyLight 200, AX 8   *** DESYNC ***
```

The WindowServer moves the surface; the app's `NSWindow` never learns. Anything the app
computes in screen coordinates — popover and menu anchors, sheet placement, drag origins —
will be wrong by the delta. **Rejected for the on-screen scroll fast path.** Visible columns
must be moved via AX.

It is, however, exactly right for windows nobody can interact with. See S4.

---

## S4 — parking: **AX FAILS, `SLSMoveWindow` PASSES**

AX clamps off-screen placement hard. For the 1694-wide test window:

```
park x=-2000   -> actual x=-1654   CLAMPED
park x=-5000   -> actual x=-1654   CLAMPED
park x=-20000  -> actual x=-1654   CLAMPED
```

−1654 = −(1694 − 40): macOS enforces **~40 px of every window remaining on screen** when
positioning via Accessibility. The design's `union.minX - 5000` parking scheme is impossible
through AX.

`SLSMoveWindow` has no such clamp:

```
park -2000   -> SkyLight -2000    OK not clamped
park -5000   -> SkyLight -5000    OK not clamped
park -20000  -> SkyLight -20000   OK not clamped
```

**Corollary, found the hard way — un-parking needs a nudge.** After an `SLSMoveWindow` park,
the app still believes it is at its old position. Setting the AX position back to that believed
value is a **no-op**: AX sees no change, sends nothing, and the window stays parked off-screen.
The spike left a live Zen window stranded at −20000 this way. Resync requires writing a
*different* position first, then the real target — a 2-call unpark.

**Net:** park with `SLSMoveWindow` (0.002 ms, no clamp), unpark with `SLSMoveWindow` back
on-screen followed by nudge-then-target AX writes. The asymmetry is fine: parking is the
frequent operation during scrolling, unparking happens only when a column re-enters view.

---

## S3 — scripting addition: **PASS, and two comments in `yabairc` are stale**

Probed through yabai 7.1.25 with its SA loaded, as a proxy for what `weft-sa` will be able to do:

| Operation | Underlying call | Result |
| --- | --- | --- |
| `space --focus` | Dock transition | **OK** |
| `window --space` | `SLSMoveWindowsToManagedSpace` | **OK — and does not switch the focused space** |
| `window --toggle sticky` | `SLSSetWindowTags` | **OK** |
| `space --create` | Dock | **OK** |
| `space --destroy` | Dock | **OK** |
| `window --display next` | — | inconclusive, only one display attached |

The critical one — moving a window to another space *without following it* — works: window
moved from space 6 → 7 while the focused space stayed 3 throughout.

Two corrections to the assumptions in `~/.config/yabai/yabairc`:

- The comment *"macOS 26.x can't make Desktops from the CLI (`space --create` errors)"* is
  **stale**. It works on 26.5.2 / yabai 7.1.25. (Verified by creating space 8 and destroying it.)
- `space --move` to another display could not be tested with one display attached; it stays
  unverified rather than confirmed-broken.

---

## S5 — sketchybar mach port: **deferred**

`sketchybar` is installed (`/opt/homebrew/bin/sketchybar`) but not running and not registered
with launchd, so the bootstrap port could not be probed. Re-run when it is up. The fork
fallback is unaffected either way.

---

## S6 — weft draws its own borders: **works, entirely**

Measured 2026-09-10, macOS 26.5.2 / arm64. Harness: `border.swift`, plus a pixel read-back.

Every private call the native renderer needs succeeds from an ordinary,
unprivileged connection — no scripting addition, no entitlement beyond what weft
already has:

| Call | Result |
| --- | --- |
| `SLSNewWindow(cid, 2, x, y, region, &wid)` | ok |
| `SLSSetWindowResolution(cid, wid, 2.0)` | ok — backing store comes back 800×600 for a 400×300pt window, so the context is drawn in points and is retina-correct |
| `SLSSetWindowOpacity(cid, wid, false)` | ok — required, or the overlay is a filled rectangle |
| `SLSSetMouseEventEnableFlags(cid, wid, false)` | ok — click-through |
| `SLSOrderWindow(cid, ourWID, 1, theirWID)` | **ok** — the rc=1000 refusal in §11.11 applies to reordering *another app's* window, not to ordering *ours* relative to one |
| `SLWindowContextCreate` + `CGContext` stroke | ok |
| `SLSSetWindowShape(cid, wid, x, y, region)` | ok |
| `SLSReleaseWindow` | ok |

Read-back of the overlay's own backing store (`SLWindowContextCreateImage`, no
screen-recording permission needed): 6.8% of pixels painted, 99.4% of those the
stroke colour. An outline, not a fill.

Three findings that are not obvious from the symbol names:

1. **`SLSSetWindowShape`'s `(x, y)` is the window's global origin, not an offset.**
   Passing `0, 0` to "just resize" teleports the window to the corner of the main
   display until the next move. Shape and position are one call.
2. **`SLSTransactionCommit`'s return value is not an error code.** It came back as
   `1158907464`, `90381480`, `19038648` on successive runs — uninitialised. Verify a
   transaction by reading the bounds back, never by the rc.
3. **A `CGSRegionRef` handed back through an out-parameter is owned by ARC.**
   `CGSNewRegionWithRect(&rect, &region)` followed by `CGSReleaseRegion(region)` is a
   double free, and it crashes on the *second* border, not the first. The renderer
   therefore creates and releases regions in C (`BorderShim.h`) so no region ever
   crosses into Swift.

Also confirmed: an overlay is layer 0, larger than 100×100 and owned by a process
with no bundle, so it passes every filter in `WorldReader` — weft tiles its own
borders unless they are excluded by pid.

## S7 — batched window moves: **`SLSTransaction` works**

`SLSTransactionCreate` → N × `SLSTransactionMoveWindowWithGroup` →
`SLSTransactionCommit(t, 0)` moved two windows to their targets, verified by reading
the bounds back. The object is a real CF type (`SLSTransactionGetTypeID` = 80,
description `<SLSTransaction … valid>`) created at +1, so `CF_RETURNS_RETAINED` is
the correct annotation and ARC releases it.

This is what a multi-window tiling change should use: individual `SLSMoveWindow`
calls composite on whatever frame each one lands in, so the windows visibly arrive
one after another.

---

## Design changes this forces

1. **Discovery moves off AX entirely** (S0). WindowServer for enumeration, AX captured at
   window-creation time and cached. New cold-start caveat to document.
2. **Parking switches from AX to `SLSMoveWindow`** (S4), plus a nudge-then-target unpark.
3. **Scroll fast path via `SLSMoveWindow` is rejected** for visible windows (S2); AX
   position-only remains the path, at 0.12 ms p50 — fast enough that it was never the problem.
4. **Frame-set cost revised** to ~2.5 IPCs average (S1); verify step is load-bearing.
5. **`space --create`/`--destroy` are available**, not broken (S3) — the capability probe can
   report them as working on this build.
6. **Borders move in-process** (S6). JankyBorders becomes optional rather than the
   only option, and the borders weft draws are the ones weft is managing — a
   menu-bar popover never gets one, because it was never in a layout.
7. **Multi-window moves go through one transaction** (S7), so a retile is one
   compositor frame rather than one per window.
