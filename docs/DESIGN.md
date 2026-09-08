# weft — Design & Build Plan

A tiling window manager for macOS.

*Weft* is the thread a loom runs horizontally across the vertical warp — the scroll strip
running across the tiled columns. Woven cloth is panes interlocking by construction.

Binaries: daemon `weftd`, CLI `weftctl`, scripting addition `weft-sa`.
Config `~/.config/weft/weft.toml`. Socket `$TMPDIR/weft-$USER.sock`.

Target: macOS 26.5.2, arm64, Swift 6.2. SIP partially disabled (already configured on this
machine: Filesystem Protections off, Debugging Restrictions off, NVRAM Protections off).

## 1. Goals

Four layouts, selectable **per macOS space**:

| Layout | Behaviour |
| --- | --- |
| `bsp` | Binary-split tiling, i3/yabai style. |
| `stack` | A *container* layout, usable as a node inside `bsp` — so "left half tiled, right half stacked" works (AeroSpace-style). Also usable as the whole space. |
| `scroll` | niri-style infinite horizontal strip of columns; each column may hold a vertical stack of windows. |
| `float` | Untiled, remembered frames. |

Hard constraints:

- **Native macOS Spaces only.** No virtual/emulated workspaces. Space identity comes from
  SkyLight; we never fake it by parking windows off-screen to simulate a workspace.
- **No animations, anywhere.** No interpolation, no `NSAnimationContext`, no easing.
  Frame changes are single writes.
- **Event-driven.** Zero polling timers in steady state; idle CPU must be 0%.
- SIP-off / scripting addition is acceptable and assumed.

## 2. Why the current setup is the baseline to beat

`~/.config/yabai/yabairc` + `~/.config/skhd/skhdrc` today:

- Layout is `bsp` globally (`yabai -m config layout bsp`) — per-space layout only via manual
  `space --layout` toggles, not declarative.
- Stacks exist but are whole-space only; there is no stack-inside-bsp. The skhd focus binds
  work around this with `--focus west || --focus stack.prev || --focus stack.last` fallback
  chains.
- No scroll layout at all.
- Every keypress forks a `yabai -m` process (skhd) — ~5–20 ms of `fork`+`exec`+socket per key,
  before any window work happens.
- Space labels are re-derived by a shell loop on every reload; two passes needed to dodge
  "label already registered".
- Your comments record two macOS 26 breakages — **one of which S3 shows is stale.**
  `space --create` works fine on 26.5.2 / yabai 7.1.25 (verified by creating and destroying a
  space). `space --move` to another display remains untested here: only one display is attached,
  so it is unverified rather than confirmed-broken.

Everything below is designed to fix those specifically.

## 3. Architecture

```
  ┌─ input thread ──────────────────────────┐
  │  CGEventTap (kCGHeadInsertEventTap)     │   never does work inline;
  │  chord match → enqueue Command          │   only matches + enqueues
  └───────────────┬─────────────────────────┘
                  │
  ┌───────────────▼─────────────────────────┐
  │ core serial queue — authoritative state │   pure reducer:
  │  World { displays, spaces, windows }    │   (State, Event|Command)
  │  SpaceLayout per space id               │     -> (State, [Mutation])
  └──────┬────────────────────────┬─────────┘
         │ frame mutations        │ space / order / tag ops
  ┌──────▼──────────────┐  ┌──────▼──────────────────┐
  │ AX apply            │  │ SkyLight + SA           │
  │ one serial queue    │  │ (WindowServer-local,    │
  │ PER PID             │  │  no target-app IPC)     │
  └─────────────────────┘  └─────────────────────────┘
         ▲
  ┌──────┴──────────────────────────────────────────┐
  │ observers → Events                              │
  │  AXObserver per app · SLSRegisterNotifyProc     │
  │  NSWorkspace launch/terminate                   │
  │  CGDisplayRegisterReconfigurationCallback       │
  └─────────────────────────────────────────────────┘
```

**The one rule that makes this fast: no Accessibility call ever runs on the core queue.**
AX is synchronous cross-process IPC; a hung Electron app must not stall the world. One serial
queue per pid means a hang is contained to that app.

Observer events land on a dedicated serial `syncQueue`, **not** on core: handling one reads the
whole WindowServer and can apply frames, and `handleCommand` takes `core.sync`, so anything slow
on core is latency on every single keypress. `applyFrames` and `raiseFronts` carry
`dispatchPrecondition(.notOnQueue(core))` so this cannot silently regress.

**The main thread must run a run loop.** `NSWorkspace` notifications
(`didLaunchApplication`, `didTerminateApplication`, `activeSpaceDidChange`) and
`CGDisplayRegisterReconfigurationCallback` are delivered through the main run loop.
The socket accept loop therefore runs on a background thread and `main` ends in `CFRunLoopRun()`.

### SwiftPM targets

| Target | Kind | Contents |
| --- | --- | --- |
| `SkyLightShim` | C, modulemap | `extern` decls for private SLS/CGS symbols, `_AXUIElementGetWindow`, small inline helpers |
| `WeftCore` | Swift, **no I/O** | geometry, layout tree, scroll engine, stack, reducer, command grammar |
| `WeftPlatform` | Swift | AX, SkyLight, spaces, displays, process tracking — behind protocols |
| `WeftConfig` | Swift | TOML → typed config, FSEvents hot reload, validation with line numbers |
| `WeftInput` | Swift | event tap, chord parsing, modes |
| `WeftIPC` | Swift | unix domain socket server, same command grammar as keybinds |
| `weftd` | executable | daemon |
| `weftctl` | executable | CLI |
| `weft-sa` | C dylib | scripting addition payload injected into Dock |

`WeftCore` is pure: layout is a function `(Tree, CGRect, Config) -> [WindowID: CGRect]`.
That makes the entire layout engine unit-testable with no display, no permissions, no macOS
window at all — which is the difference between this being maintainable and being yabai.

## 4. Layout model

### 4.1 Tiling tree (covers `bsp` **and** nested `stack`)

```swift
indirect enum Node {
  case window(WindowID)
  case container(Container)
}

struct Container {
  var layout: ContainerLayout   // .splitH | .splitV | .stack
  var children: [Node]
  var ratios: [Double]          // splits only; sums to 1
  var active: Int               // stack: index of the visible child
}
```

- **`bsp`** is this tree with an insertion policy: splitting the focused leaf into a 2-child
  container. The split axis comes from **the shape of the slot being split** — wider than tall
  splits side-by-side, taller than wide splits top-and-bottom (yabai's `split_type auto`, i3's
  default). With focus following each new window that generates the Fibonacci spiral —
  master left, top-right, bottom-right, right-of-that, below-again, … — so the documented
  shape is unchanged; but it *also* stays correct when you focus an older pane and insert
  there, which a globally alternating flag does not (see §13.7).
  `insertion = .bsp | .manual` — `.manual` appends into the focused container (i3 behaviour)
  for people who want it. The `split` command pins exactly one insertion (`pendingSplit`);
  the automatic rule resumes after.
- **Stack inside bsp** is just a container whose `layout == .stack`. Requested feature
  "choose right or left side to be stacked" is then:
  `split right` → `stack wrap`, or the single command `stack split right`.
- **Stack rendering is free**: every member gets the *same* frame; only z-order changes.
  Raising the active child is one `SLSOrderWindow` call — no AX, no resize, no repaint of
  the others. Switching stack members is the cheapest operation in the whole WM.
- Stack decoration (which window is active, how many) is not drawn by weft. It is published
  as state for sketchybar to render — see §10. weft never puts a pixel on screen.

### 4.2 Scroll engine (niri-style)

Not a tree — an ordered strip:

```swift
struct ScrollState {
  var columns: [Column]      // Column = { windows: [WindowID], widthPreset: Int }
  var viewportX: Double      // scroll offset in strip coordinates
  var focus: (col: Int, row: Int)
}
```

- Placement: `screenX = stripX(col) - viewportX + display.minX`. Windows that straddle the
  display edge are placed genuinely partially off-screen; macOS clips them correctly.
- Column widths cycle a preset ring (`[0.333, 0.5, 0.667, 1.0]`, configurable), same as niri.
- `center-focused-column = "always" | "never" | "on-overflow"`.
- Focusing a column scrolls the *minimum* distance to bring it fully into view.
- **Parking — via `SLSMoveWindow`, not AX** *(S4)*. Columns entirely outside
  `[viewportX - margin, viewportX + width + margin]` are moved **once** to
  `globalDisplayUnion.minX - 5000` and flagged parked; scrolling then costs nothing for them
  until they re-enter. Parking beyond the union of *all* displays (not just `-width` off the
  left edge) is what stops a parked window landing on a neighbouring monitor.

  **AX cannot do this.** macOS clamps AX-positioned windows so that **~40 px always remains on
  screen**: requests of −2000, −5000 and −20000 all clamped to −1654 for a 1694-wide window
  (`−(width − 40)`). `SLSMoveWindow` has no such clamp — −20000 sticks — and costs 0.002 ms.

  **Unparking needs a nudge.** After an `SLSMoveWindow` park the app still believes it is at
  its old position, so writing that same position back through AX is a **no-op** and the window
  stays stranded off-screen. Unpark is: `SLSMoveWindow` back on-screen → AX write a *different*
  position → AX write the real target. The asymmetry is acceptable because parking is the
  frequent operation while scrolling and unparking happens only on re-entry.
- **Scroll fast path — `SLSMoveWindow` is rejected for visible windows** *(S2)*. It is 79×
  faster than AX (0.002 ms vs 0.124 ms), but it moves the surface without telling the app:
  requesting x = 500 leaves the app's own `NSWindow` reporting x = 8. Every screen-coordinate
  the app computes itself — popover and menu anchors, sheet placement, drag origins — would be
  off by the delta. Visible columns move via **AX position-only**, measured at 0.12 ms p50,
  which was never the bottleneck. `SLSMoveWindow` is reserved for parked windows, where nothing
  can interact with the desync.

### 4.3 Per-space layout

```swift
enum SpaceLayout {
  case tiling(Tree)        // bsp and/or nested stacks
  case scroll(ScrollState)
  case float
}
```

Held in `[SpaceID: SpaceLayout]`. Switching a space's layout preserves window membership and
reconstructs: tree → columns in left-to-right leaf order; columns → tree by successive right
splits. Float remembers each window's pre-float frame.

Config declares the default per space **label**, so `web` can be `scroll` while `code` is
`bsp`, permanently, without a keybind.

## 5. Platform layer

> **M0 spike results are in — see [`spikes/RESULTS.md`](../spikes/RESULTS.md).** Five findings
> changed this section; each is marked *(S…)* below.

### 5.0 Window discovery — AX cannot enumerate *(S0)*

**`kAXWindowsAttribute` returns an empty array for any app whose windows are all on a
non-active space.** Not an error — `kAXErrorSuccess` with zero windows. Measured across five
apps at two different active spaces, correlation was exact. This is not the Electron/Gecko
`AXManualAccessibility` gate; poking that attribute changed nothing.

So discovery works in two layers:

1. **Enumerate from the WindowServer.** `CGWindowListCopyWindowInfo` / `SLSCopyWindowsWithOptionsAndTags`
   see every window on every space, always. They are noisy — per-app 1710×39 menubar shims,
   64×64 cursor windows, 0×0 agents, `borders`' own overlays. Filter: `layer == 0`, both
   dimensions > 100, and a non-empty `SLSCopySpacesForWindows` result. That reduced a 55-entry
   raw list to exactly the 8 real windows on this machine.
2. **Capture AX elements at creation, and hold them.** An `AXUIElement` obtained via
   `kAXWindowCreatedNotification` — fired while the window is necessarily on the active space —
   **keeps working after that space goes inactive**. So the element is captured once and cached
   for the window's lifetime.

**Cold-start gap, unavoidable:** windows that existed before `weftd` launched, on spaces that
have not been visited since, have no AX element and cannot get one. Their geometry and space
membership are known (WindowServer), so layout can be *computed*; it just cannot be *applied*
until the space is first focused. Apply-on-`space_changed` closes the gap, and the user never
sees the difference because an unvisited space is by definition not on screen. This is the same
constraint that makes yabai occasionally "lose" windows until you visit their space — the
difference is that weft treats it as a known state (`bound: false`) rather than a missing window.

### 5.1 Reading state — never via AX

| Need | Call | Cost |
| --- | --- | --- |
| Display → space → window topology | `SLSCopyManagedDisplaySpaces(cid)` | one call, whole world |
| Window frame | `SLSGetWindowBounds(cid, wid, &rect)` | WindowServer-local, µs |
| Window list w/ tags | `SLSCopyWindowsWithOptionsAndTags` | µs |
| Active space per display | `SLSManagedDisplayGetCurrentSpace(cid, uuid)` | µs |
| Space kind (user vs fullscreen) | `SLSSpaceGetType(cid, sid)` — `4` = native fullscreen, skip | µs |

AX is used **only** for: creating observers, setting position/size, raising, and bridging
`AXUIElement` ↔ `CGWindowID` via `_AXUIElementGetWindow`. Reading geometry through AX — which
is where a lot of WM latency traditionally goes — never happens.

### 5.2 AX hardening

- `AXUIElementSetMessagingTimeout(appRef, 0.15)` on **every** app element at creation. Without
  this a single wedged app hangs the WM indefinitely.
- One serial `DispatchQueue` per pid for all AX I/O.
- **Frame-set protocol** (avoids the blind triple-set most WMs do):
  1. `setPosition(p)`
  2. `setSize(s)`
  3. verify with `SLSGetWindowBounds` (cheap, no app IPC)
  4. only if off by >1pt: `setPosition(p)` again

  *(S1)* Measured: **~2.5 IPCs average, not 2.** The correction fired on **21/40** sets,
  alternating with grow-vs-shrink — `setPosition`→`setSize` lands wrong roughly half the time
  depending on direction. The verify step is load-bearing, not a safety net. Keeping it on
  `SLSGetWindowBounds` (0.03 ms p50, no app IPC) instead of an AX read-back is what makes
  paying it every time affordable. Measured cost of the whole protocol: **0.53 ms p50**,
  32 ms p99 — the tail is Gecko relayout inside the app, which is the case the per-pid queue
  exists to contain.
- **Diff before write.** Compute the full target layout, compare against `lastAppliedFrame`,
  send only what changed. Sub-pixel deltas are dropped.
- **Echo suppression.** Every write bumps a per-window `expectedFrame` epoch; the resulting
  `AXWindowMoved`/`AXWindowResized` notifications are matched and dropped. Missing this is the
  classic tiling-WM feedback-loop bug.
- **Quirk table** per bundle id for apps that lie about or ignore size (Electron, JetBrains,
  Simulator). Windows that report `AXSize` min/max constraints incompatible with their slot
  are auto-floated rather than fought.

### 5.3 Spaces — native, no emulation

- Space ids (`sid`) are **not stable across reboot**. Persist config by *label*; assign labels
  by ordinal at startup (same model as your current yabairc, but done once in-process, no
  two-pass shell loop and no "already registered" dance).
- Focus space: SA path (drive Dock's own transition — instant, no animation).
  Degraded path: `CGEventPost` of ctrl+N (costs the ~250 ms system animation).
- Move window to space without following: `SLSMoveWindowsToManagedSpace(cid, [wid], sid)`.
  This is the one core feature with **no acceptable non-SA fallback**. *(S3)* Verified working:
  window moved space 6 → 7 while the focused space stayed 3 throughout.
- Sticky (for scratchpads): `SLSSetWindowTags` sticky bit. *(S3)* Verified.
- `space create` / `space destroy`: *(S3)* **both work** on 26.5.2. Still behind the capability
  probe — the point of the probe is to survive the next OS update, not to encode today's result.

### 5.4 Multi-display *(implemented — see §14)*

- Identify by `CGDisplayCreateUUIDFromDisplayID` — stable across disconnect/reconnect, unlike
  display index. Confirmed on hardware to be byte-identical to the `"Display Identifier"`
  string `SLSCopyManagedDisplaySpaces` reports, which is what makes one uuid key both halves.
- Per-display space list and per-display focused space, straight from
  `SLSCopyManagedDisplaySpaces`.
- **One usable rect per display**, keyed by space: `SpaceState.displayBySpace` maps sid →
  display uuid and every layout computation goes through `usableScreen(for: sid)`.
- Commands: `focus display <west|east|north|south|next|prev|first|last|N>`,
  `move display <...> [--follow]`, `move space display <...>`.
  `move space display` is **impossible** on macOS 26, not merely broken — see §14.5.
- Because layout is per-space and spaces belong to displays, per-display layout is free.

## 6. Input

- `CGEventTap` at `kCGHeadInsertEventTap` on `keyDown` + `flagsChanged`, on a **dedicated
  thread with its own run loop**.
- The tap callback does exactly one thing: match the chord and enqueue. It never touches AX,
  never blocks. This matters because macOS *disables* a tap that exceeds its callback
  deadline — and the handler must also explicitly re-enable on `kCGEventTapDisabledByTimeout`
  / `...ByUserInput`, which is a footgun almost every event-tap implementation hits once.
- Modes (`default`, `resize`, arbitrary user modes), leader/chord sequences, per-space and
  per-app conditional binds.
- vs. skhd: no `fork`+`exec` per keypress. Keypress → command dispatch is sub-millisecond.
- A `weftctl` socket path still exists so Raycast/scripts/skhd can drive the same commands.

## 7. Config

TOML at `~/.config/weft/weft.toml`, hot-reloaded via FSEvents, validated with line numbers.
Keybind values use the **same command grammar** as `weftctl`, so config and scripting share one
vocabulary and anything bindable is scriptable.

```toml
[general]
inner-gap = 8
outer-gap = { top = 8, bottom = 8, left = 8, right = 8 }
default-layout = "bsp"
mouse-modifier = "alt"
mouse-follows-focus = true
focus-follows-mouse = false

[[space]]
label  = "code"
layout = "bsp"

[[space]]
label  = "web"
layout = "scroll"
scroll = { preset-column-widths = [0.333, 0.5, 0.667, 1.0], center-focused-column = "on-overflow" }

[[space]]
label = "main"
layout = "float"

[[rule]]
bundle-id = "com.apple.finder"
manage    = false

[[rule]]
app   = "^Ghostty$"
space = "term"

[[rule]]
app    = "^Brave Browser$"
title  = "Picture.in.Picture"
manage = false

[keys]
"alt-h"        = "focus west"
"alt-l"        = "focus east"
"alt-shift-h"  = "move west"
"alt-s"        = "stack wrap"
"alt-shift-s"  = "stack split right"
"alt-bracketleft"  = "scroll focus prev-column"
"alt-bracketright" = "scroll focus next-column"
"alt-r"        = "scroll width cycle"
"alt-c"        = "space focus code"
"alt-shift-c"  = "space move-window code"
"alt-ctrl-t"   = "app toggle com.mitchellh.ghostty"
"alt-shift-r"  = "mode resize"

[mode.resize]
"h"      = "resize left -60"
"l"      = "resize right 60"
"escape" = "mode default"

# ── integrations (see §10) ────────────────────────────────────────────────
[integrations.sketchybar]
enabled   = true
bar-name  = "sketchybar"
reserve   = { top = 34 }          # replaces yabai's `external_bar all:34:0`
coalesce-ms = 16
events = ["space_changed", "window_focused", "space_windows",
          "layout_changed", "stack_changed", "scroll_changed", "mode_changed"]

[integrations.borders]
enabled = true
args    = ["style=round", "width=5.0", "hidpi=on"]
supervise = true                  # restart if it dies; stop it when weftd exits
active-color = { bsp = "0xffe1e3e4", scroll = "0xff8aadf4", float = "0xfff5a97f" }
mode-color   = { resize = "0xffed8796" }
```

### App keybinds

`app toggle <bundle-id>` semantics:

- not running → `NSWorkspace.openApplication`
- running, not frontmost → focus it (switch to its space, raise its window)
- running, frontmost → hide (or `close-window`, per flag)

Plus `scratchpad <name>`: a named window made sticky + floating, toggled show/hide with
remembered geometry.

## 8. Milestones

**M0 — Spikes. ✅ Done** — full write-up in [`spikes/RESULTS.md`](../spikes/RESULTS.md).

| # | Spike | Result |
| --- | --- | --- |
| S0 | *(unplanned)* Does AX enumerate windows on inactive spaces? | ❌ **No — empty array, not an error.** Biggest finding of the round; forced §5.0 |
| S1 | AX frame-set latency | ✅ **0.53 ms p50**, 32 ms p99. But corrections fired 21/40 → cost model revised to ~2.5 IPCs |
| S2 | `SLSMoveWindow` position-only coherence | ❌ **Desyncs** (SkyLight 500, app AX 8). Rejected for visible windows; kept for parked |
| S3 | SA capability matrix on 26.5.2 | ✅ space focus, `window --space` *without following*, sticky, **and `space --create`/`--destroy`** |
| S4 | Park at `union.minX - 5000` | ❌ **AX clamps at −(width−40)**; ✅ `SLSMoveWindow` doesn't. Unpark needs a nudge |
| S5 | sketchybar bootstrap mach port | ⏸ **Deferred** — installed at `/opt/homebrew/bin/sketchybar` but not running |

**M1 — Skeleton.** SwiftPM layout, `SkyLightShim`, world model built from SLS,
`weftctl query displays/spaces/windows`. Read-only, mutates nothing.

**M2 — BSP + input.** Tiling tree, event tap, focus/warp/resize/split on one display.
*This is the point where it becomes daily-drivable and yabai can be turned off.*

**M3 — Stack containers.** `stack wrap`, `stack split <dir>`, stack cycling, z-order-only
rendering.

**M4 — Native spaces + multi-display.** SA integration, space focus/move, display commands,
per-display state, label persistence.

**M5 — Scroll layout.** Columns, presets, viewport, parking, scroll fast path.

**M6 — Float + rules + config.** Float layout, rule engine, `app toggle`, scratchpads, TOML
hot reload.

**M6.5 — Integrations.** Event bus, `weftctl subscribe`, sketchybar bridge with rich env vars,
borders supervision and per-mode colour. See §10. (The event bus itself lands earlier, in M2 —
it is how you debug the reducer. M6.5 is only the two bridges on top of it.)

**M7 — Ship.** launchd service, perf harness, crash-safe state restore, migration notes from
your yabairc/skhdrc.

## 9. Performance budget

Measured 2026-09-06 on this machine (M-series, 1710x1073 usable, 7 spaces, 20 windows,
12 AX-visible apps), over a persistent socket so the numbers exclude `weftctl` process start:

| command | p50 | p99 |
| --- | --- | --- |
| `focus east` / `focus west` | 0.02 ms | 0.03 ms |
| `retile`, `balance` | 0.02 ms | 0.03 ms |
| `window toggle zoom-fullscreen` | 0.03 ms | 0.04 ms |
| `space focus <label>` | 0.46 ms | 11.6 ms |
| idle CPU | 0.0 % | — |
| RSS | 18 MB | — |

`space focus` p99 is the WindowServer verification poll, which is deliberate: the scripting
addition acknowledges a write whether or not it acted on it, so the switch is confirmed by
re-reading `SLSManagedDisplayGetCurrentSpace` before the daemon believes it.

Budget (unchanged, now met with ~150x headroom on the common verbs):

- Keypress → all frames applied, 4-window layout: **p50 < 5 ms, p99 < 20 ms.**
- Stack-member switch: **< 1 ms** (z-order only).
- Scroll step: **< 3 ms** for on-screen columns; zero cost for parked ones.
- Idle CPU: **0.0%**. No timers. Verify with `powermetrics`.
- Instrumentation: `os_signpost` intervals across tap → core → AX so Instruments shows the
  whole pipeline; `weftctl bench <command> -n 500` prints an AX-call histogram.

## 10. Integrations — JankyBorders + sketchybar

**Decision: weft draws nothing.** No borders, no bar, no stack indicators, no overlay windows.
Drawing means an `NSWindow` per decoration, a compositing pass on every layout change, and a
whole class of z-order bugs against the parked/off-screen windows the scroll engine relies on.
borders already does borders better, and sketchybar already does bars better. weft's job is to
be the *authoritative, cheap, complete* source of state for both.

That only works if the state weft publishes is rich enough that neither tool ever has to ask a
follow-up question. Today your sketchybar plugins would have to shell out to `yabai -m query`
on every tick — a fork, a socket round-trip, and a JSON parse per bar item. Killing that is the
entire point of this section.

### 10.1 Event bus

One internal bus, three consumers. Events are emitted from the core queue *after* a mutation
commits, then handed to a low-priority `.utility` queue — no consumer can ever slow the
reducer down.

| Event | Payload |
| --- | --- |
| `space_changed` | display uuid, space id, label, layout |
| `space_windows` | space id, window ids, count |
| `window_focused` | window id, pid, bundle id, app, title, space, frame |
| `window_created` / `window_destroyed` | window id, space, app |
| `layout_changed` | space id, old layout, new layout |
| `stack_changed` | container id, space id, active index, count, member titles |
| `scroll_changed` | space id, focused column, column count, viewport x, column widths |
| `display_changed` | display uuid, active space per display |
| `mode_changed` | mode name |

Coalescing is the important bit. A single "focus a window on another space" produces
`space_changed` + `space_windows` + `window_focused` + possibly `stack_changed`. Naively that
is four bar redraws. weft buffers events for `coalesce-ms` (default 16 ms — one frame) and
emits **one** batched notification per tick, deduplicated by event type.

### 10.2 Three ways to consume it

1. **`weftctl subscribe <event>...`** — long-lived socket, newline-delimited JSON pushed to
   stdout. Zero forks. This is the efficient path for a custom bar, and it's also how you
   debug the reducer: `weftctl subscribe --all` is a live trace of every state transition.
2. **`[[signal]]` blocks in TOML** — run a shell command on an event, like yabai's
   `signal --add`. Forked on the `.utility` queue, coalesced, and rate-limited per signal so a
   misbehaving script cannot back up the bus. The escape hatch, not the default.
3. **Native bridges** — `[integrations.sketchybar]` and `[integrations.borders]` below, which
   skip the shell entirely.

### 10.3 sketchybar bridge

- **Transport.** sketchybar's CLI is a thin client over a bootstrap mach port
  (`git.felix.sketchybar`) speaking a simple length-prefixed argv blob. weft talks to that port
  directly, so a trigger costs a mach message rather than `fork` + `exec` + `dyld` of the
  `sketchybar` binary. *Gated on spike S5*; fallback is forking the binary, coalesced.
- **Rich env vars on every trigger**, so plugins never call back:

  ```
  WEFT_SPACE_ID, WEFT_SPACE_LABEL, WEFT_SPACE_LAYOUT, WEFT_SPACE_WINDOWS
  WEFT_DISPLAY_UUID, WEFT_DISPLAY_INDEX
  WEFT_FOCUSED_WID, WEFT_FOCUSED_APP, WEFT_FOCUSED_BUNDLE, WEFT_FOCUSED_TITLE
  WEFT_STACK_INDEX, WEFT_STACK_COUNT          # "◧ 2/4"
  WEFT_SCROLL_COL, WEFT_SCROLL_COLS, WEFT_SCROLL_WIDTH   # "‹ 3/7 ›"
  WEFT_MODE
  ```

  A space-indicator plugin becomes `echo "$WEFT_SPACE_LABEL"` — no subprocess at all.
- **Bar reservation** replaces `yabai -m config external_bar all:34:0`. `reserve = { top = 34 }`
  shrinks the usable rect that the layout engine tiles into, per display. Because it is just an
  inset on the display rect in `WeftCore`, it is unit-testable and costs nothing at runtime.
- Your current `yabairc` has all six sketchybar signal lines commented out because sketchybar is
  off. The bridge is a single `enabled = true`, so turning it back on is one line, not six.

### 10.4 borders bridge

borders is largely autonomous — it hooks the focused window itself via SkyLight and does not
need weft to tell it what to highlight. What weft adds:

- **Supervision.** Launch it as a child process with the configured args, restart on crash, and
  kill it on `weftd` exit. Today your `yabairc` does `killall borders; bordersrc &`, which
  leaves an orphan if yabai dies and a zombie config if it is reloaded twice.
- **State-reactive colour.** `borders active_color=…` at runtime, driven by `layout_changed`
  and `mode_changed`. A different border colour per layout is genuinely useful once a space can
  be bsp, scroll, or float — it's the cheapest possible "which mode am I in" indicator, and it
  costs one mach message on transitions only.
- **Parked-window interaction.** Scroll-parked windows sit at `union.minX - 5000`. Confirm in
  S4 that borders does not try to draw a border out there; if it does, add them to the borders
  blacklist as they are parked.

### 10.5 What this rules out

Being a pure state source means weft cannot render tab bars for stacks, cannot draw a scroll
minimap, and cannot show a workspace overview. If any of those turn out to be must-haves, they
should ship as a *separate* client binary reading `weftctl subscribe` — never inside `weftd`.

## 11. Known risks

1. **Scripting addition breakage on macOS updates.** The payload locates Dock internals by
   byte-pattern scan and must be re-derived most releases. This is the single largest ongoing
   maintenance cost. Mitigation: `PlatformCapability` abstraction with an SA and a non-SA
   backend from day one, so a broken SA *degrades* the WM instead of bricking it.
2. **Cold-start AX gap** *(S0)*. Windows on spaces not visited since `weftd` launched have no
   AX element and cannot get one. Layout is computed but applied on first `space_changed`.
   Tracked explicitly as `bound: false` rather than treated as a missing window.
3. **Stranded parked windows** *(S4)*. A crash between park and unpark leaves a window at
   −5000 with the app unaware. `weftd` must persist the parked set and unpark on startup, and
   ship `weftctl rescue` to sweep any window whose SkyLight bounds are off every display.
   The spike stranded a live window this way on the first attempt — this is not hypothetical.
4. Electron / JetBrains windows resize slowly and sometimes ignore requested sizes → quirk table.
5. Windows with hard AX size constraints (Simulator, System Settings) → auto-float on detection.
6. Native-fullscreen spaces (`SLSSpaceGetType == 4`) must be skipped entirely.
7. Feedback loops from our own AX move/resize notifications → epoch-based echo suppression.
8. Parked scroll windows will look odd in Mission Control / App Exposé. Accepted trade-off.
9. Stage Manager must be off — detect and warn at startup.
10. Requires Accessibility permission (`AXIsProcessTrustedWithOptions`) and `sudo` to load the SA.
11. yabai is MIT-licensed; where we adapt its SkyLight/SA techniques, attribute it.
12. sketchybar's mach wire format is not a public API — if S5 says it's unstable, the fork
    fallback is the supported path and the mach path stays an opt-in fast lane.

## 12. Open questions

- Vertical scroll layout (niri has columns only; some people want rows) — v2 or never?
- Window swallowing / auto-float heuristics for dialogs and sheets: opt-in or default?
- Should `weftctl subscribe` speak newline-delimited JSON only, or also a compact binary frame
  for a future high-frequency client?

---

## 13. Correctness pass — 2026-09-06

Nine defects found by reading the daemon against this document and confirmed on hardware.
Recorded here because most of them are invariants that are easy to reintroduce.

### 13.1 The main thread had no run loop — *the big one*

`main` ended in `server.run()`, a blocking `accept()` loop. So the main run loop never ran, and
every `NSWorkspace` notification was silently dead: `didLaunchApplication`,
`didTerminateApplication` and `activeSpaceDidChange`, plus
`CGDisplayRegisterReconfigurationCallback`. Consequences:

- A newly launched app was never discovered, so **its windows were never tiled** — they simply
  sat at their default size forever.
- A space change made by any means other than weft's own `space focus` (Mission Control,
  ctrl+arrow, clicking a window on another desktop) was never noticed, so every later command
  operated on whatever space weft last believed was current.
- Display reconfiguration was ignored.

AX observers were unaffected — they own a run loop on their own thread — which is exactly why
*some* events still arrived and the gap was hard to see from the logs.
Fix: accept loop on a background queue, `CFRunLoopRun()` on main.

### 13.2 AX IPC on the core queue

`WorldReader.snapshot()` called `axBoundWindowIDs`, which does three synchronous AX round trips
per running app at a 0.15 s messaging timeout each. `snapshot()` ran on the **core queue** via
observer events, and `handleCommand` takes `core.sync` — so every keybind queued behind it.
Measured on this machine: **172 ms cold, 3.6–7.7 ms warm**, unbounded if any app is wedged
(12 apps x 0.15 s worst case).

The `bound` flag it computed is diagnostic and read by nothing. It is now opt-in
(`snapshot(includeAXBinding:)`) and used only by `weftctl query windows`.

### 13.3 Sweep storms

Every observer event ran `syncFromSnapshot()` *and* scheduled a second one — so one window
opening cost six full WindowServer sweeps. `windowFocused` for any window not in the current
layout (every float, every unmanaged window) ran a sweep inline. Now a leading 20 ms debounce
collapses a burst into one sweep, with the 0.3 s trailing sweep kept to heal newborn windows.

### 13.4 The scripting addition reported success it had not achieved

`ScriptingAddition.send` returns `Data()` — non-nil — when the addition writes no reply, so
`focusSpace` returned `true` whenever *any* SA socket existed. The daemon then updated
`currentByDisplay` and retiled a space the screen had never switched to. `focusSpace` now
verifies against `SLSManagedDisplayGetCurrentSpace` and the keystroke fallback confirms too,
reporting an actionable error (Mission Control shortcut disabled / SA not loaded) instead of a
false success.

Note weft has no `weft-sa` of its own yet; it drives `/tmp/yabai-sa_$USER.socket` when present.
The opcode table matches yabai 7.1.25 (`SA_OPCODE_*` in `src/osax/common.h`).

### 13.5 Space ordinals were sorted space ids

`assignLabels` sorted raw sids. macOS hands out space ids in *creation* order, so as soon as a
desktop is removed and re-added the numeric order stops matching the left-to-right order, and
every label lands on the wrong desktop. `SpaceState.order` now holds Mission Control order
(display-major, as `SLSCopyManagedDisplaySpaces` reports it) and every label, ordinal and
ctrl+N fallback resolves against it.

### 13.6 Fullscreen spaces were never filtered

§11 risk 6 says they must be skipped; `SLSSpaceGetType` was read and discarded. Leaving them in
shifted every ordinal, so full-screening anything moved every `space focus <n>` by one.

### 13.7 The split axis ignored the slot it was splitting

`nextSplit` alternated globally per insertion. That produces the documented spiral only while
focus follows each new window; focus an older, tall pane and insert, and the flag splits it
side-by-side. Insertion now picks the axis from the slot's aspect ratio — yabai's
`split_type auto`, i3's default — with the `split` command pinning exactly one insertion
(`pendingSplit`). The spiral is unchanged, because the aspect-ratio rule is what generates it.

### 13.8 The command path blocked on AX writes

`applyFrames` waited on a semaphore (5 s timeout) and `raiseFronts` did a nested
`applyQueue.sync { queue(for: pid).sync { … } }`. Worse, `focusWindow`/`raiseSync` put
`NSRunningApplication.activate()` — which blocks in `_yieldToApplication` — on the app's own AX
queue, ahead of every later frame write for that app. Measured `window toggle zoom-fullscreen`:
**1249 ms**. Writes are now dispatched without waiting (ordering is still exact: per-window
writes and raises share one per-pid serial queue) and activation has its own queue.
Same command after: **21.7 ms**.

### 13.9 Unbounded caches

`AXApplier.windowElements` / `lastApplied` / `expectedFrame` / `epoch` and
`ObserverSet.windowElements` / `appObservers` grew for the life of the daemon. A recycled window
id inherited a dead AX element plus a stale expected frame that silently suppressed the new
window's move notifications, and `watchOnLoop` skips any wid already present — so it never
re-registered. Added `forget(keeping:)`, `forgetApp(pid:)` and `forgetWindow(_:)`.

### Still open

- **No `weft-sa`.** Instant space switching, move-window-without-following and sticky all depend
  on yabai's addition being loaded. Without it `space focus` degrades to the ctrl+N keystroke,
  which covers desktops 1–9 only.

---

## 14. Multi-display pass — 2026-09-07

Verified on the two-display machine described below, which is a useful worst case: the second
display is **above and west of** the built-in, so a layout computed in the wrong rect does not
merely land in the wrong place, it lands off-screen.

```
1  64FA7430  SAMSUNG 4K   usable 3840x2160 @ -1063,-2160
2* 37D8832A  built-in     usable 1710x1073 @     0,   39   (39px menu bar)
```

### 14.1 One screen rect for the whole machine

`usableScreen()` derived a single `Frame` from `NSScreen.main`, and `syncFromSnapshot`,
`applySpaceLayout`, the reducer, float placement, `query state` and `rescue` all used it. Every
space on the second display was therefore tiled into the *first* display's rect.

Now `SpaceState.displayBySpace` carries sid → display uuid, `screensByUUID` carries uuid →
usable rect, and `usableScreen(for: sid)` is the only way to get a rect. `syncMembership` takes
`screens: [SpaceID: Frame]` rather than one `screen`, because the split axis a new window picks
depends on the shape of the slot it lands in — and that is the shape of its own display.

### 14.2 The AppKit → CG coordinate flip

`NSScreen.visibleFrame` is the only source for "menu bar and Dock excluded", but it is in
AppKit's bottom-left space and **only the primary screen sits at AppKit's origin**. The old
code flipped through `screen.frame.height`, which is correct exactly when the screen *is* the
primary and wrong by (primaryHeight − thisHeight) otherwise. The flip now goes through the
primary's height for every screen. `SpaceControl.displayLayout()` is the one place that does
this, and it uses `CGGetActiveDisplayList`, not `CGGetOnlineDisplayList`, so a mirrored
secondary does not contribute a duplicate rect for the same pixels.

### 14.3 The menu bar moves, so `visibleFrame` moves

macOS draws the menu bar on the active display, so a display's usable height changes by ~22–39px
when focus arrives. Observed live: a window on the external display sat at y = −2152 while the
built-in was active and y = −2130 after focus moved. `refreshScreens()` therefore runs on every
sweep and on `displayChanged` — it is CG + NSScreen only, no WindowServer sweep, no AX.

### 14.4 "Which display am I on" is not the active menu bar

The obvious answer, `SLSCopyActiveMenuBarDisplayIdentifier`, is **wrong**. It is right at
startup and then only updates on real user interaction: after weft activates a window itself,
it keeps reporting the display it last saw a click on. Measured — `focus display south`
activated a built-in window and the call still reported the external display, so the value weft
had just set was clobbered by a stale read on the very next command.

The focused display is now derived from the focused window: `noteFocusedWindow(wid)` finds the
visible space whose layout contains the window and takes that space's display. Exact, no IPC,
and it is information the daemon already holds. The SLS call survives only as the startup seed
and as the rescue path when the tracked display is unplugged.

### 14.5 `move space display` is not broken, it is absent

Moving a whole space between displays needs the compat-id pair: `SLSSpaceSetCompatID` to tag
the space, then `SLSSetDisplaySpaceCompatID` to hand the tag to the destination. On macOS 26.5.2
SkyLight exports `_SLSSpaceGetCompatID` and `_SLSSpaceSetCompatID` and **not**
`_SLSSetDisplaySpaceCompatID` (`dyld_info -exports`, 2026-09-07). Declaring it fails the link.

So this is not an SA gap — no connection of any privilege can do it, and a `weft-sa` would not
change that. `query capability` reports it with that reason, and `move space display` answers
with it instead of no-opping. This is what "broken on macOS 26" in the user's skhdrc is.

### 14.6 Background raises steal the display

`applySpaceLayout` raised the focused window even for a space it was only tiling in the
background. When that space is visible *on another display*, the raise hands that display the
active menu bar — so `move display`, which is specified not to follow, became a display switch,
and a second `move display north` then failed with "no display north". `raiseFocus: false`
suppresses the raise for exactly that case.

### 14.7 Direction is geometric, with an arrangement fallback

`west`/`east` pick the nearest display whose centre lies that way (`north`/`south` likewise).
A monitor stacked directly above the built-in is neither west nor east of it, so west/east fall
back to stepping through arrangement order — the user's `alt+ctrl+h/l` binds keep working on a
vertically stacked setup. `next`/`prev` deliberately do **not** wrap: yabai fails at the last
display, and that failure is what makes `{ … next … } || { … first … }` in a keybind fall
through instead of quietly doing nothing.

### 14.8 One bind, not two

yabai needs `window --display east && display --focus east` to move a window and follow it.
weft keybinds are a single command, so `move display <target> --follow` does both, and
`weftctl migrate` now emits it for that skhd pattern (checked *before* `display --focus`, which
would otherwise match the same line and silently drop the move).


---

## 15. First-install pass — 2026-09-07

Everything in this section was found by installing weft for real and watching it fail.
None of it was reachable from a terminal-run daemon, which is why the previous passes missed
all of it.

### 15.1 The installer handed a yabai user a demo config

`install.sh` seeded `examples/weft.toml` whenever no config existed. For someone migrating from
yabai that is the wrong file in every particular, and the failures it produces look like bugs:

- The example makes one space `scroll` and sets `default-layout = "scroll"`. A single window in
  a scroll space sits at the preset column width — 0.5 — so it takes half the screen, hard left.
  That reads as "tiling is broken" and no amount of choosing BSP explains it.
- The example binds spaces to **digits**. The user's skhdrc binds them to **letters**
  (`alt-i` → term, `alt-b` → web, `alt-c` → code). So the keys they actually press were bound to
  nothing at all.

`weftctl migrate` already produced the right config from their own yabairc + skhdrc; the
installer simply never ran it. It now does whenever `~/.config/yabai/yabairc` or
`~/.config/skhd/skhdrc` exists.

### 15.2 The migrator dropped or mangled real bindings

Found by diffing its output against the user's skhdrc line by line:

- **Whole mode layers were discarded.** `:: resize @`, `alt + shift - r ; resize`,
  `resize < h : …` and `resize < escape ; default` were all unparsed, so the resize layer
  vanished silently. Modes now migrate, and a capture mode with no exit gets an `escape` binding
  synthesised — weft has no implicit way out.
- **`window --display east && display --focus east` lost the move.** The `display --focus` branch
  matched the line first. `window --display` is now tested before it, and emits `--follow`.
- **A toggle became one-way.** `if [ … = float ]; then bsp; else float; fi` matched on "bsp".
  Both layouts have to be present to recognise `space layout toggle`.
- **`--resize` and `--balance` were unmapped**, which is what emptied the resize layer.
  yabai names an edge and a signed delta (`right:-60:0` = pull the right edge left); weft names
  a direction, so the *sign*, not the edge, picks it.
- **`open -a 'Ghostty'` was dropped**; it now resolves to a bundle id and `app toggle`.

### 15.3 Refuser strikes were a life sentence

Two frame-set failures **ever** excluded a window from every layout for the life of the daemon.
Successes were never counted, so nothing could clear the tally — and because excluded windows
are never sent frames, a struck window could not earn its way back even in principle. `space
layout bsp` and `retile` were both powerless against it; only killing weftd helped.

Seen live: on a fresh install the newly-copied binary had no Accessibility grant, so *every*
write failed, and the user's browser was auto-floated within two sweeps. Selecting BSP in the
menu bar then did nothing to it — correctly, since it was no longer in the tree — which looked
exactly like broken tiling.

Three fixes: `ApplyResult` now reports `appliedIDs` and a success clears that window's count
(consecutive failures, not cumulative); a blanket `!AXIsProcessTrusted()` skips accounting
entirely, because a total denial is not evidence about any one app; and `retile` and
`space layout` forgive every strike, so the two commands a user reaches for actually work.
Rule-floated and hand-floated windows are untouched — those are decisions, not verdicts.

### 15.4 Every permission check asked the wrong process

TCC is per binary. `weftctl doctor` called `AXIsProcessTrusted()` **on itself** and printed
"Accessibility: Granted" while weftd, denied, could not move a single window. WeftBar's Setup
window did the same and labelled it "Enable for WeftBar AND weftd" — it could show all green
with weftd holding nothing.

weftd now answers `query permissions` for its own grants, including whether the event tap is
actually installed (a `CGPreflightListenEventAccess` can pass while tap creation fails, and the
difference is "no keybind fires"). Both doctor and Setup read that, and name the exact binary
path to add.

### 15.5 Two things made granting them miserable

**Nothing sequenced it.** The Setup window was a list of rows with buttons, in no stated order,
which the user had to drive themselves. It now has one button: it opens the first missing
permission's pane, watches, and moves to the next the moment that one goes green. `guidedIndex`
guards the reopen, or a one-second refresh would relaunch Finder and System Settings forever.

**`~/.local/bin` is hidden, so the binary could not be found.** The `+` picker will not browse
a dotted directory, and "add ~/.local/bin/weftd" is an instruction the Finder actively prevents
you from following.

The fix is not a better hint — it is to make the row appear by itself. A process that *requests*
one of these is added to the list by macOS, switched off, ready to toggle. weftd already did
this for Accessibility (`AXIsProcessTrustedWithOptions` with the prompt option) but not for
Input Monitoring: it created the tap, saw it fail, and logged. It now calls
`CGRequestListenEventAccess()` on that failure, so weftd lists itself and there is nothing to
find. Reveal-in-Finder plus the path on the clipboard stays as the fallback for when the row is
somehow absent.

**WeftBar needs no permissions of its own.** Its hotkeys are Carbon `RegisterEventHotKey` and
every window it lists comes from weftd over the socket. Setup no longer asks for any; it shows
weftd's, offers Reveal to put the binary in Finder (the `+` picker starts in /Applications and
`~/.local/bin` is hidden, which is most of why granting these is unpleasant), and treats Screen
Recording as optional — it only affects the borders highlight.


---

## 16. Polish pass — 2026-09-07

### 16.1 Menu-bar extras were tiled as if they were windows

Stats' panel is a layer-0 window, 280x674. weft's discovery filter was
`kCGWindowLayer == 0` plus "both dimensions over 100px", so it passed, entered the bsp tree,
and pushed the user's terminal into half a screen. Two of them did. The user has no yabai rule
for Stats and yabai handles it correctly, which is the tell: yabai filters these *structurally*,
by requiring an AX subrole of `AXStandardWindow`.

The subrole check alone does not work here. Measured on the real windows: Stats' panels have no
AX element **at all** — `kAXWindows` on that pid does not list them — so there is nothing to
read a subrole from, and `isStandardWindow` returns nil for exactly the windows it needs to
judge. The same is true of Ice, another menu-bar app.

The signal is AX *visibility itself*, but it is only meaningful on screen: on an unvisited space
a real window is not enumerable either (S0). Measured, with `term` current:

```
Ghostty  15586  bound=true    real window, current space
Zen      21507  bound=true    real window, NON-current space  ← S0 is narrower than assumed
Stats     5155  bound=false   panel, current space
Ice         26  bound=false   panel, non-current space
```

So the rule is: **a window that is on a visible space and still has no AX element after a
grace period is not a window.** Subrole first when an element exists (definitive), this
otherwise. The grace period is one second of wall-clock, not a sweep count — sweeps fire 20 ms
apart in a burst, and an app that is slow to publish its window must not be condemned by that.

Two things this needed to actually work:

- **A sweep to settle the verdict.** The judgement is made during a sweep, and a popover opening
  on an otherwise idle desktop generates no further events — so the timer expired with nothing
  to notice. Recording a pending judgement now schedules a one-shot re-check 1.1 s out. It is
  cancellable and self-limiting; there is still no steady-state polling.
- **A way back.** The classification is a heuristic and it is cached for the window's lifetime,
  so `forgiveQuirks()` (behind `retile` and `space layout`) clears the negative verdicts along
  with refuser strikes. A window judged wrongly must not be shut out for the life of the daemon.

### 16.2 The icon is generated, not drawn

`scripts/make-icon.swift` renders the iconset at build time by running the same alternating-axis
split the bsp layout does, with the focused pane solid and the rest receding — the borders
accent (`0xff7aa2f7`) in both. The trailing panes bottom out at 46% alpha rather than fading
toward transparent, because below that they vanish at 16px against the dark ground. The menu-bar
item now uses SF Symbols per layout instead of `⊞ ⇋ ❐`, which rendered at whatever weight and
baseline the user's menu-bar font gave them next to real icons.

### 16.3 Setup was hand-positioned NSRects

The old Setup window drew itself with literal frames — `NSRect(x: 390, y: y + 2, width: 110…)`
— and a running `y -= 62`. What shipped: the Close and "Grant permissions" buttons drawn on top
of each other, "Reveal" truncated to "Rev…", status dots sitting below the titles they belonged
to, and the header overlapping the first row. Nothing about that is fixable by nudging numbers;
a fixed layout cannot survive a string it did not anticipate.

It is now SwiftUI (`SetupView`), a three-page flow — welcome, permissions, done — with spring
transitions between pages, a progress bar, and per-row state that animates as each grant lands.
Points worth keeping:

- **The window tints itself `0x7aa2f7`, not the system accent.** Inheriting the accent put a red
  primary button under a blue app icon on this machine. `.tint(.weft)` keeps the controls, the
  progress bar and the icon reading as one product.
- **Close lives in each page's own bottom row**, not in a shared overlay. The pages anchor their
  buttons at different heights, so one overlay could only line up with one of them — the first
  attempt at this put Close 18pt above the buttons it was meant to sit beside.
- **The socket read never runs on the main thread.** It blocks, and a wedged daemon would freeze
  the window being used to diagnose it.
- The binary path is a footnote at the bottom rather than a subtitle inside a row: it matters
  only in the fallback case where the weftd row is missing, and it fills the space three cards
  leave over.

### 16.4 The installer hands off instead of instructing

`install.sh` ends by opening WeftBar rather than printing steps. It sleeps two seconds first:
weftd asks the system for its permissions on start, and that request is what makes macOS *list*
weftd in those panes — opening Setup before it lands shows a list missing the row the user needs.


---

## 17. The grant that never landed — 2026-09-08

Reported after a fresh `install.sh`: Setup "does not say clearly to drag weftd to give
permission, it just opens the folder", and after granting, "it is not updated instantly for the
input monitoring and screen recording".

Two separate bugs wearing one costume. The second is the real one.

### 17.1 Two of the three permission checks answered from a cache

§15.4 fixed *which process* is asked. It did not fix *when the answer is computed*, and for two
of the three the answer is fixed for the life of the process:

| permission | how weftd read it | live? |
|---|---|---|
| Accessibility | `AXIsProcessTrusted()` | yes — hits TCC every call |
| Input Monitoring | `input.tapInstalled` | **no** — the tap is created once, at launch |
| Screen Recording | `CGPreflightScreenCaptureAccess()` | **no** — per-process cache |

So a daemon that started without the grants reported "missing" forever, however many times the
user flipped the switch. The Setup window polls once a second and faithfully re-displayed the
stale answer, which is exactly the complaint. Only a restart cleared it — and the *keybinds*
were dead for the same reason, not just the display: nothing ever retried the tap.

Both fixes are about asking again rather than reporting harder:

- **`InputManager.ensureTap()`** — returns the tap if it is up, otherwise attempts
  `CGEvent.tapCreate` once more, throttled to once a second. `tapCreate` re-checks TCC on every
  call, so the attempt that failed at launch succeeds the moment the switch flips. `query
  permissions` calls this rather than reading `tapInstalled`: a query is the one moment we know
  something is watching for the answer to change. A late install fires `onTapInstalledLate`, and
  the daemon re-applies the *current* config's keymap and mouse modifier — the tap starts from
  whatever `init` handed it, and a reload may have replaced that in the meantime.
- **`Permissions.screenRecording()`** (new, `WeftPlatform`) — tries the preflight first because
  it is authoritative when it says yes, then falls back to the window list. Without the grant
  macOS redacts `kCGWindowName` for every window the process does not own, and un-redacts it the
  instant the grant lands. No cache, no restart. Filtered to layer-0 windows owned by another
  pid; `nil` when there is no such window on screen, because a missing title proves nothing then.

The Setup copy changed to match, and it is now true: *no restart needed*.

### 17.2 The Finder window was answering a question nobody asked

`open(kind)` revealed weftd in Finder **every time**, then opened System Settings half a second
later. §15.5 had already made that reveal almost always unnecessary: weftd requests both
permissions on launch, which is what makes macOS list it, so in the normal case there is a weftd
row sitting there waiting to be switched on and nothing whatsoever to find.

A Finder window appearing unasked reads as the instruction. People went looking for a file to
drag whether or not they needed to, and the one sentence that mattered — *turn the weftd switch
on* — was never said anywhere.

Setup now opens the pane and nothing else, and the active step expands to spell out the three
steps that are actually in front of the user (find the row named **weftd**, switch it on, choose
"Later" if macOS offers to quit and reopen). The reveal moved under a disclosure titled with the
one case it solves — "No weftd row in the list?" — which opens on its own, in orange, after
twenty seconds on the same step, because at that point "they are still reading" stops being the
likeliest explanation.

### 17.3 Settings was a debug panel

Absolute `NSRect` frames, a segmented control, and four raw TOML text areas — the same failure
as §16.3, in the window that had not been rewritten yet. Worse, its save path *reconstructed*
`[general]` from its fields and pasted the other sections back as text blobs, so the first save
deleted every comment in `[general]` and moved the file's banner to the bottom.

It is now SwiftUI: a vibrant sidebar, grouped cards, real controls per concept, and a drawing of
what the gap numbers do to a screen. Two things underneath matter more than the layout:

- **`WeftBarConfig`, a lossless line-oriented document model.** The file is parsed into sections
  of lines; a save *edits the lines the form owns in place* and copies everything else through
  untouched. A comment, a `scroll = { … }` table, a key added by a future weft — none of them
  are ever re-serialised from a model, so none of them can be lost. `outer-gap = 8` comes back
  as `8`, not as a four-field table, because a user who wrote the short form should get it back.
- **It is its own target, with tests.** Code that rewrites the user's config file needs them,
  and an executable target cannot have them. `WeftBarConfigTests` pins identity round-trip on
  the reference config, comment survival, single-line edits, and the multi-line-array guard —
  an `args = [` spread over several lines is detected and left strictly alone rather than
  half-rewritten, and the form field goes read-only and says why.

The cheatsheet moved onto the same model, which fixed a bug in passing: its hand-rolled parser
scanned for the literal string `[mode.resize]`, so anyone who named their modal layer anything
else had a cheatsheet that silently omitted every bind in it.

### 17.4 Smaller things in the same pass

- Duplicate chords in one mode are flagged. Two rows on the same chord is a silent bug — the
  file is a TOML table, so the second wins and the first never fires.
- The keybinding list has a filter. Sixty binds is a normal weft.toml, and scrolling to find the
  one you meant to change is why people give up and open the file instead.
- `open -a WeftBar --args --settings|--setup|--cheatsheet [--tab <name>]`. A support answer that
  begins "click the menu-bar icon, then…" is not one you can paste into a terminal.
- The gap preview is drawn against a nominal 820-point screen, not a real 1440. At true scale an
  8px gap is one point and invisible; the drawing exists to answer "bigger or smaller than I
  wanted", so it says "not to scale" and stays legible.
- `install.sh` prints what Setup is about to ask for *before* the user is looking at System
  Settings: which binary the grants belong to, the three steps, and the fallback.

### 17.5 Two ways a valid config quietly does nothing

Both surfaced as questions — "what if the user doesn't have my spaces?", "what if they don't have
borders installed?" — and both turned out to be real. The example config `install.sh` seeds ships
seven `[[space]]` blocks and `enabled = true` for *both* integrations, so a fresh user on a
three-desktop Mac with no Homebrew helpers hits both at once.

**Spaces are assigned by ordinal, and extras are dropped.** `assignLabels` walks the sids that
exist and takes `names[i]` for each; a config with more `[[space]]` entries than the machine has
desktops silently leaves the tail unassigned. Everything naming them then fails without a sound:
`space focus term` returns `unknown space 'term'` over the socket, which for a keybind means the
key does nothing, and a `[[rule]]` with `space = "term"` logs one line to stderr and leaves the
window where it was. Nothing is broken, nothing is reported, and the user concludes weft is flaky.

**A missing helper binary is a no-op with a log line.** `enabled = true` plus no `borders` on disk
produced a single stderr message at startup and silence thereafter.

Neither deserves a crash — both configs are legitimate, and a window manager must not refuse to
start over a decorative border. They deserve to be *visible*, so all three surfaces now say so:

- **Settings › Spaces** compares the declared rows against the desktops weftd reports and greys
  every row past that count with a "no desktop" marker, under a banner naming both numbers.
- **Settings › Window Rules** flags a rule whose target space has no desktop behind it — checked
  against the daemon's live labels, not the config's own list, so a runtime rename is caught too.
- **Settings › Integrations** resolves each helper binary once and shows where it is, or that it
  is missing with the `brew install` line to copy. Turning something on that cannot work no longer
  looks identical to turning something on that can.
- **`weftctl doctor`** cross-references rather than listing: "enabled in weft.toml but not
  installed" is the actionable combination, and it now enumerates the specific rules and keybinds
  aimed at spaces that do not exist.

Three smaller defects fell out of looking:

- `findBordersBinary()` searched three hardcoded prefixes and reported "not found in PATH" — it
  had never looked at PATH. Anyone who installed borders outside Homebrew got a message naming
  the one place their binary provably was not. Now `ExternalBinary.find`, shared by both bridges
  and doctor, which checks the usual prefixes *and* PATH and can say which it searched.
- `SketchybarBridge` ignored `bar-name` when locating the binary, so the setting only affected
  the config file.
- Borders' crash handler respawned every second, forever, with no cap. A `borders` that dies on
  its own arguments dies again in a millisecond, so a typo in `args` became a permanent 1 Hz fork
  bomb in a background daemon. Now exponential backoff, five attempts, then it stops and says why.

### 17.6 A build-system trap worth knowing

`swift build --target weft-bar` does not reliably recompile this target — an edit to
`ConfigEditor.swift` produced a byte-identical binary (same md5) while reporting "Build of target
complete". Two rounds of UI verification were checking a stale binary and reached the wrong
conclusion. `swift build -c release` (no `--target`) picks the change up correctly.

Verify against the artefact, not the build log: `strings` the binary for a marker, or compare
md5 before and after. Note that Swift stores string literals of 15 bytes or fewer inline, so a
short marker will not appear in `strings` — the first attempt at this check failed for that
reason and looked like more evidence for the wrong theory.

### 17.7 The shipped example was one person's machine

`examples/weft.toml` is not a sample — `install.sh` copies it verbatim into
`~/.config/weft` when there is no yabai/skhd config to migrate, so it *is* what a
first-time user's weft does. What it contained was a migration of one developer's
setup: seven named spaces (`main`, `chat`, `web`, `term`, `ai`, `code`, `design`),
thirty app rules naming Ghostty, Zen, Helium and Mattermost, and both integrations
`enabled = true`.

On any other machine that is a config where most of the keyboard is dead. Labels
are handed out in Mission Control order, so on a three-desktop Mac four of the
names never land, and `alt-4`, the rules pointing at `term`, and half the
`space move-window` binds all fail with no error anywhere (§17.5). Both
integrations point at Homebrew binaries the user probably does not have.

The replacement declares nothing it cannot guarantee:

- **No `[[space]]` blocks.** Desktops keep their Mission Control number as their
  label, which is what the `alt-1..5` binds use, so it behaves identically on one
  desktop or nine. Named spaces are a commented-out worked example instead.
- **`alt-1..5`, not `1..9`.** Enough for most setups without leaving four dead
  keys on a machine with three desktops.
- **Four rules, all for fixed-size system panels** — System Settings, Calculator,
  Archive Utility, Picture-in-Picture — plus commented examples of app→space
  placement. Nothing that names an app the user may not have installed.
- **Both integrations `enabled = false`**, with the `brew install` line next to
  each.

Six tests now hold it to being a *default*, not a preference: it parses, it
declares no spaces, every space reference is numeric or `recent`, every rule has
a matcher, neither integration is on, and — in `WeftBarConfigTests` — the whole
file survives a save from the Settings window with its commented-out examples
intact. `docs/TESTING.md`'s keybinding matrix follows the new chords.

Two bugs fell out of writing the tests:

- **`loadConfig` never validated mode targets.** It rejects a bad chord and an
  unparseable command, but `"alt-r" = "mode reisze"` loaded fine — and the input
  layer ignores a switch to an undefined mode, so the only symptom was one key
  that did nothing, with nothing logged. Now a `ConfigError` naming the chord,
  the missing mode and the modes that do exist. The check is deferred to after
  every section is parsed, because `[keys]` binds a mode long before
  `[mode.*]` is read.
- **`weftctl doctor` only checked *named* spaces.** With the new default
  declaring none, the failure mode is a *number* past the last desktop —
  `space focus 4` on a two-desktop Mac — which was invisible to it. It now
  reports both, and no longer returns early when the config declares no spaces.
