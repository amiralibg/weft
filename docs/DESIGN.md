# weft — Design & Build Plan

A tiling window manager for macOS.

*Weft* is the thread a loom runs horizontally across the vertical warp. Woven cloth is panes
interlocking by construction.

Binaries: daemon `weftd`, CLI `weftctl`, menu-bar app `WeftBar`. No scripting addition — see §13.4.
Config `~/.config/weft/weft.toml`. Socket `$TMPDIR/weft-$USER.sock`.

Target: macOS 26.5.2, arm64, Swift 6.2. **No SIP change required**, and none is used: weft
acts on other apps' windows only through Accessibility and through SkyLight calls any process
may make, and draws only into windows it owns. The development machine happens to have SIP
partially disabled, which makes it the *worst* place to assume a capability — every privileged
operation is therefore verified by re-reading state rather than by a return code.

## 1. Goals

Four layouts, selectable **per macOS space**:

| Layout | Behaviour |
| --- | --- |
| `bsp` | Binary-split tiling, i3/yabai style. |
| `stack` | A *container* layout, usable as a node inside `bsp` — so "left half tiled, right half stacked" works (AeroSpace-style). Also usable as the whole space. |
| `float` | Untiled, remembered frames. |

Hard constraints:

- **Native macOS Spaces are never faked away.** Space identity comes from SkyLight, Mission
  Control and native fullscreen keep working, and weft does not take a Mac down to one desktop
  the way AeroSpace does. Since 0.9.11 it *also* offers its own workspaces, several to a
  desktop, switched by parking windows off screen — nested inside macOS's model rather than
  replacing it, and the default since 0.9.12. `docs/WORKSPACES.md` is the whole argument;
  the constraint that survived it is this one, which is why `DragMove`, `DockSwipe` and
  `SpaceShortcut` all still exist.
- **No animations, anywhere.** No interpolation, no `NSAnimationContext`, no easing. Frame
  changes are single writes. Interpolating a retile means an AX write per window per frame —
  a cross-process round trip an app can be slow at — so the layout falls behind whatever is
  driving it. The one carve-out this used to have, the scroll strip's viewport pan, went with
  the strip (§19).
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
| `SkyLightShim` | C, modulemap | private SLS/CGS symbols and `_AXUIElementGetWindow`, resolved by name at load and called through inline wrappers (nothing links SkyLight); small inline helpers |
| `WeftCore` | Swift, **no I/O** | geometry, layout tree, stack, reducer, command grammar |
| `WeftPlatform` | Swift | AX, SkyLight, spaces, displays, process tracking — behind protocols |
| `WeftConfig` | Swift | TOML → typed config, FSEvents hot reload, validation with line numbers |
| `WeftInput` | Swift | event tap, chord parsing, modes |
| `WeftIPC` | Swift | unix domain socket server, same command grammar as keybinds |
| `weftd` | executable | daemon |
| `weftctl` | executable | CLI |

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
- Stack decoration: members behind the front one show as title-bar strips
  above it, and a bare click on a strip raises that member — the strips are hit
  zones published to the event tap beside the divider zones (`stackPeeks`), under the same
  `mouse-border-resize` opt-in. Stack state is still published on the bus for sketchybar
  (§10) for anyone who wants it in their bar instead.
- `stack all` puts every window on the space in one stack (again to undo); `stack move <dir>`
  pushes the focused window into the neighbour's stack — the mirror of `stack split`.

### 4.2 Scroll engine — removed 2026-09-10

weft shipped a niri-style scroll strip until 0.4. It was removed, not deprecated; see §19
for why. Two findings from building it are worth keeping, because they are facts about
macOS rather than about the strip:

- **AX cannot put a window off screen.** macOS clamps AX-positioned windows so that ~40 px
  always remains visible (`−(width − 40)`); `SLSMoveWindow` has no clamp *(S4)*.
- **An `SLSMoveWindow` desyncs the app.** It moves the surface without telling the app, so
  the app's own `NSWindow` keeps reporting the old origin and every screen coordinate it
  computes — menu anchors, sheets, drag origins — is off by the delta *(S2)*. Recovering
  needs a *nudge*: SLS back into place, AX write a different position, then the real one.
  `weftctl rescue` still uses that protocol (`AXApplier.restore`).

### 4.3 Per-space layout

```swift
enum SpaceLayout {
  case tiling(Tree)        // bsp and/or nested stacks
  case float(FloatState)
}
```

Held in `[SpaceID: SpaceLayout]`. Switching a space's layout preserves window membership:
float remembers each window's real frame, and coming back out rebuilds a tree by successive
right splits in that order.

Config declares the default per space **label**, so `web` can be `float` while `code` is
`bsp`, permanently, without a keybind. A config or a saved override that still says
`scroll` loads as `bsp` with a line-numbered warning (`ConfigWarning`) rather than failing.

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

### 5.1a What counts as a tileable window

`CGWindowList` filtering (layer 0, both dimensions over 100px) is not enough, and neither
is the AX subrole on its own:

- A menu-bar extra's panel — Stats, iStat, a Now Playing popover — is a layer-0 window
  bigger than 100×100. Its subrole is `AXSystemDialog` / `AXUnknown`, so the subrole test
  catches it.
- An Electron popup — Mattermost's in-call widget, a Slack huddle badge — reports
  `AXStandardWindow` and is caught by nothing. It is **fixed-size**, though, and a window
  the app will not resize cannot hold a tile: given a slot it keeps its own 470×180, ignores
  the frame, and the layout has silently handed a quarter of the screen to a badge.

So `AXApplier.classify` asks three questions, in one batch on the app's own queue:
subrole is `AXStandardWindow`; `AXSize` is settable; and — for windows under 480×320 only —
at least one title-bar button exists (close, minimise or full-screen). The size gate on the
last test matters: a legitimately chromeless window (a game, a kiosk view) is always large,
and floating one of those is much worse than tiling a badge.

`nil` means *cannot tell* — the app is not AX-enumerable right now (S0), the window is on an
unvisited space. Callers must re-ask, never read it as "no": answering no on a cold read
would unmanage every window on every space the user has not visited yet. The answer is
cached for the window's lifetime and `weftctl retile` forgives it, because every part of it
is a heuristic and a heuristic needs a way back.

`weftctl query windows` reports the verdict per window in a `floating` field
(`manual` / `popup` / `quirk` / `rule`, absent when the window is tiled). Nothing was
harder to debug from outside than a window weft had quietly decided not to manage.

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
- **Mouse.** The tap also carries `left/rightMouseDown|Dragged|Up`. Two ways in:
  - *Modifier drag* (`mouse-modifier`, default `alt`): left drags a floating window's
    body, right resizes.
  - *Border drag* (`mouse-border-resize`, default on): a **plain** click is claimed only
    when it lands inside a border's grab strip. The daemon publishes those strips as a flat
    `[Frame]` to the tap on every layout apply, and the callback point-tests them and
    returns — it may not ask the daemon, because it may not block. Every other unmodified
    click passes through untouched, which is the property that makes claiming bare clicks
    acceptable at all.
- Border geometry is pure (`WeftCore/Dividers.swift`) and derived from the computed frames
  rather than the tree: adjacency in a tiled layout *is* "two frames separated by at most
  the inner gap, overlapping on the other axis". Overlapping frames — stack members sharing a slot — are never adjacent, which is
  correct: there is no border between two windows in the same place.
- Dragging a border uses `Tree.resizing(divider:_:axis:deltaPoints:frames:)`, not the
  keybind resize. The keybind one walks down from the root and adjusts the first container
  matching the axis, which is right for "resize my window" and wrong for a drag: in
  `splitV[splitV[A, B], C]` it moves the (AB)|C divider while the cursor is holding A|B.
  The divider version finds the deepest container separating the pair and measures the ratio
  delta against those two children's on-screen extent, so N points of mouse is N points of
  border however deep it sits.
- Drag frame writes are **latest-wins coalesced**: at most one apply in flight, newest
  target replaces any waiting. A mouse reports every 8 ms and an AX frame write costs
  single-digit milliseconds, so one apply per event builds a backlog the drag never catches
  up with — the window keeps resizing after the button comes up. Intermediate frames of a
  drag are worth nothing once a newer one exists.
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
layout = "float"

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
"alt-bracketleft"  = "stack prev"
"alt-bracketright" = "stack next"
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
          "layout_changed", "stack_changed", "mode_changed"]

[integrations.borders]
enabled = true
args    = ["style=round", "width=2.0", "hidpi=on"]
supervise = true                  # restart if it dies; stop it when weftd exits
active-color = { bsp = "0xffe1e3e4", float = "0xfff5a97f" }
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

**M5 — Scroll layout.** Columns, presets, viewport, parking, scroll fast path. *Shipped, then
removed in the tiling-first pivot (§19).*

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
- Idle CPU: **0.0%**. No timers. Verify with `powermetrics`.
- Instrumentation: `os_signpost` intervals across tap → core → AX so Instruments shows the
  whole pipeline; `weftctl bench <command> -n 500` prints an AX-call histogram.

## 10. Integrations — JankyBorders + sketchybar

**Decision: weft draws borders, and nothing else.** No bar, no stack indicators, and never a
window laid over another window's area.

> Between 0.6 and 0.7.3 weft drew borders with one full-window transparent overlay per window.
> Measured on an M4, five interleaved cycles per condition, paired per cycle against weft-off,
> it cost **+15.8pp of GPU utilisation (t=4.17)**, and weftd carried one full-window RGBA
> backing store per visible window — 59.5MB of 80MB. It was removed in 0.7.4 for JankyBorders.
>
> The bisect then showed where the cost was: an overlay ordered in but never painted cost the
> whole amount. It was the overlay's *area*, not drawing. So weft draws again, with no area to
> speak of: a border is four strips and four corner pieces covering only the ring
> (`WeftCore/BorderGeometry.swift`), opaque where the colour allows, moved by transaction and
> repainted only when colour or size changes (`WeftPlatform/BorderRenderer.swift`).
>
> Measured on macOS 27.0 (M4, two windows, 5 paired cycles, `spikes/bordercost.swift`):
> full-window overlay **+24.2pp** (t=3.29, +154MB); one window shaped to the ring **+13.1pp**
> (t=3.28, +154MB) — the compositor and the backing store follow a window's bounds, not its
> shape, so shaping does not help; JankyBorders **+14.2pp** (t=3.86); strips and corners
> **+4.8pp** (t=0.82, not significant, +4.9MB). A second run of the shipped renderer put it at
> +4 to +8pp against JankyBorders' +14 to +22pp whenever the apps underneath were drawing, and
> both at zero when nothing was. The runs are noisy; the order is consistent across both.

sketchybar already does bars better. weft's job is to be the *authoritative, cheap, complete*
source of state for it, and for JankyBorders when `backend = "janky"`.

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
  be bsp or float — it's the cheapest possible "which mode am I in" indicator, and it costs one
  mach message on transitions only.

### 10.5 What this rules out

Being a pure state source means weft cannot render tab bars for stacks and cannot show a
workspace overview. If any of those turn out to be must-haves, they
should ship as a *separate* client binary reading `weftctl subscribe` — never inside `weftd`.

## 11. Known risks

1. **Scripting addition breakage on macOS updates.** The payload locates Dock internals by
   byte-pattern scan and must be re-derived most releases. This is the single largest ongoing
   maintenance cost. Mitigation: `PlatformCapability` abstraction with an SA and a non-SA
   backend from day one, so a broken SA *degrades* the WM instead of bricking it.
2. **Cold-start AX gap** *(S0)*. Windows on spaces not visited since `weftd` launched have no
   AX element and cannot get one. Layout is computed but applied on first `space_changed`.
   Tracked explicitly as `bound: false` rather than treated as a missing window.
3. **Stranded windows.** Retired as a design risk with the scroll strip (§19): it was the
   only thing weft did that moved windows off screen on purpose. A window can still end up
   off every display — dragged there, or left behind by an unplugged monitor — and
   `weftctl rescue` puts any such window back at its computed frame.
4. Electron / JetBrains windows resize slowly and sometimes ignore requested sizes → quirk table.
5. Windows with hard AX size constraints (Simulator, System Settings) → auto-float on detection.
6. Native-fullscreen spaces (`SLSSpaceGetType == 4`) must be skipped entirely.
7. Feedback loops from our own AX move/resize notifications → epoch-based echo suppression.
8. *(Retired with the scroll strip — nothing is parked any more.)*
9. Stage Manager must be off — detect and warn at startup.
10. Requires Accessibility permission (`AXIsProcessTrustedWithOptions`) and `sudo` to load the SA.
11. yabai is MIT-licensed; where we adapt its SkyLight/SA techniques, attribute it.
12. sketchybar's mach wire format is not a public API — if S5 says it's unstable, the fork
    fallback is the supported path and the mach path stays an opt-in fast lane.
13. **A macOS update removes or neuters a private symbol.** Until 0.9.13 every one was a
    strong link against SkyLight, so a single removal stopped `weftd` launching. Now
    `SkyLightShim.c` looks each one up at load and a missing one fails its own call;
    `PrivateAPI.swift` reports presence and self-tests the calls that matter on a window
    of weft's own, `weftd` logs the result on its second line, `weftctl doctor` prints
    it, and parking refuses outright when the move test fails. CI rejects any binary
    that links SkyLight again. See REDESIGN.md, phase 1.

## 12. Open questions

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

Superseded. weft no longer reads yabai's socket — when macOS 27 broke its Dock patterns, weft
could do nothing but wait for someone else's release — and weft ships no addition of its own.
The client remains for a socket that will not normally exist; everything it used to be needed
for now has a route that works with SIP on (§13.10).

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

- **Sticky, per window.** The WindowServer accepts the "on every desktop" tag from an ordinary
  connection and drops it, so weft cannot mark one window. macOS *can* do it per application —
  Dock → Options → All Desktops — and that is confirmed working with SIP on, taking a window
  from 1 desktop to 5 (spikes/RESULTS.md §S8). weft does not drive it: it is a synthetic click
  into another process's menu, and per-application is a different shape from the per-window verb
  `sticky` implies. `doctor` points at the Dock menu rather than reporting a dead end.
  (Space switching and moving a window between desktops are both solved with SIP on — §13.10.)

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

## 18. The green wall — 2026-09-08

Install, grant Accessibility in the one modal macOS shows, and Setup jumped
straight to **"Everything required is granted"** — for an Input Monitoring
switch the user had never seen, let alone flipped. Pressing Finish relaunched
WeftBar into the same screen. Then again. There was no way out of the flow
except closing the window.

Two bugs, and they compound: the first makes Setup *lie*, the second makes it
say so *forever*.

### 18.1 A live event tap is not an Input Monitoring grant

§17.1 made `query permissions` report Input Monitoring from `input.ensureTap()`
rather than a preflight, and for its own purpose that is right: the tap is what
keybinds run on, and it can fail where a preflight passes. What it missed is
that the reverse also holds. macOS lets a process that already holds
Accessibility create a `CGEventTap` — Input Monitoring is a second, independent
route to the same capability, not a prerequisite. So on a machine where
Accessibility had just been granted:

```
accessibility:    true
inputMonitoring:  ensureTap() -> true    # the switch is off
```

Both required rows went green off one grant. Every downstream consumer inherited
it: the progress bar read 2 of 2, `advanceStep()` found nothing left to ask for
and fell through to the done page, `weftctl doctor` printed a checkmark, and the
Settings sidebar said the engine was healthy. All of them correct about whether
weft *works*, all of them wrong about what the user had done — and the user is
the one who has to go find that switch when it matters.

The fix is to stop answering two questions with one field. `DaemonPermissions`
now carries both:

| field | source | question it answers |
|---|---|---|
| `inputMonitoring` | `CGPreflightListenEventAccess()` | is the switch on? |
| `keybindsLive` | `input.ensureTap()` | do keybinds fire? |

`SetupModel` splits along the same seam. `granted(_:)` is the switch and feeds
every label; `satisfied(_:)` is the capability and drives every decision — which
step is next, when the flow advances, what the progress bar counts. Nobody is
stopped on a step that already works, and nobody is told they granted something
they did not. Where the two disagree the card says **Covered**, not *Granted*,
with the reason in the subtitle. `keybindsLive` decodes as optional so a newer
WeftBar still reads an older daemon.

The done page lost its summary sentence in the process. "Everything required is
granted" is the one claim on that screen a user cannot check, and when it was
wrong nothing on the page contradicted it. Three rows naming each permission and
what it currently reads cost the same vertical space and cannot lie.

### 18.2 Finish restarted the daemon, then asked it a question

`finish()` writes `~/.config/weft/.onboarded`, restarts weftd, and relaunches
WeftBar so its Carbon hotkeys re-register under the new grants. The relaunched
instance then decides whether to show Setup:

```swift
if !FileManager.default.fileExists(atPath: flagURL.path) { return true }
return !shared.allGreen()          // one blocking round trip, no retry
```

`launchctl kickstart -k` returns as soon as it has signalled. For a second or so
after it there is no socket to connect to — and that second is precisely when
the relaunched WeftBar asks. `allGreen()` got nothing back, could not tell "the
daemon says a permission is missing" from "the daemon has not opened its socket
yet", and returned false for both. Setup reopened. Finish restarted the daemon
again. The loop was self-sustaining and had nothing to do with permissions:
granting the missing switch would not have broken it, because the query never
reached a daemon either way.

Silence is not an answer, so it no longer counts as one:

- `awaitDaemon(timeout:)` polls the socket every 300 ms until weftd replies,
  giving it six seconds to finish coming up. `finish()` waits on it before
  relaunching, so the successor starts against a daemon that can talk.
- `shouldShow()` is async and reopens Setup only when weftd *answers* and
  reports something missing. A daemon that never answers means the engine is
  down, which is a service problem Setup has no fix for — `weftctl doctor` and
  the Settings sidebar both say so plainly.

The first-run path is untouched: with no flag on disk, Setup always shows.

## 19. The grant that was never really there — 2026-09-08

Reported as "onboarding lied and then looped". §18 fixed the lying and the
looping. Reinstalling to test the fix reproduced the *original* complaint
instead — windows floating free, no keybinds, nothing tiling — with a fully
green doctor sitting next to it. The onboarding was never the disease.

### 19.1 The log named a cause it had not checked

Every failure printed the same line:

```
weftd: frame-set failed for [238, 1603] (app ignored/timeout)
```

"app ignored/timeout" was a guess baked into the format string. The frame-set
protocol has four distinct ways to fail — the WindowServer refusing
`SLSMoveWindow`, no AX element, unreadable bounds, an app that kept its own
geometry — and only one of them is a timeout. It was reporting the wrong one,
and that sent the first hour of diagnosis at app quirks.

`setFrameOnQueue` now returns a `FailureReason?` instead of a `Bool`; it always
knew which step it failed at, it just was not saying. The line became:

```
weftd: frame-set failed — 238: no AX element and the WindowServer move did not land
weftd: accessibility permission missing — requesting prompt
```

Which is a different bug entirely.

### 19.2 Every rebuild silently revoked weft's permissions

macOS stores a TCC grant against a program's **designated requirement**.
`swift build` leaves binaries ad-hoc, linker-signed — no identity to name — so
the requirement degrades to the code directory hash:

```
designated => cdhash H"3c959e1f…"      # different after every build
```

`install.sh` rebuilds weftd. So every install, and every update, produced a
program that macOS considered unrelated to the one the user had granted. That
alone would be survivable if TCC cleared the row. It does not: **the switch in
System Settings stays visibly ON**. The user opens the pane they were sent to,
finds weftd already enabled, and has nothing to do — while weftd is trusted for
nothing, every AX frame-set is refused, and weft auto-floats each window as a
"refuser quirk". The visible result is a window manager that does not manage
windows, with no error anywhere pointing at permissions.

Signing with a certificate — any certificate, including one we generate — moves
the requirement off the bytes:

```
designated => identifier "com.weft.weftd" and certificate leaf = H"a012e0d5…"
```

`scripts/lib-codesign.sh` creates one self-signed code-signing identity on first
install and signs every binary with it, passing an explicit `--identifier` so
the requirement does not vary with the file's path. Three details that took a
try each to get right:

- **Its own keychain, not the login keychain.** `codesign` must reach the
  private key without a GUI authorization dialog, which needs
  `security set-key-partition-list` — which needs the keychain's password. We
  know the password of a keychain we created; the alternative is prompting for
  the user's login password mid-install.
- **The certificate is deliberately not trusted.** `codesign` signs happily
  with an untrusted self-signed cert (`find-identity -v` lists zero identities,
  which is expected and misleading). Trusting it needs an admin prompt and buys
  nothing: TCC matches the requirement, it does not walk a trust chain.
- **`--identifier` is not optional.** Left alone, `codesign` derives the
  identifier from the file name, so the same binary at `.build/release/weftd`
  and at `~/.local/bin/weftd` would satisfy two different requirements.

Verified end to end against live TCC rather than by argument: grant all three
permissions, change a string in `weftd`, reinstall, confirm the new binary is
the one running (`cdhash 3c959e1f…` → `e381b86f…`, probe string in the log) —
and all three grants still read `true`. Before this change that sequence
revoked every one of them.

`weftd` reports `stableIdentity` alongside the grants, from
`Permissions.hasStableSigningIdentity()` (ad-hoc signatures carry no
certificates, so a certificate chain is the whole test). When it is false and
something is missing, Setup leads with the only instruction that works —
*the switch is probably already on; turn it off, then on again* — and `doctor`
says the same before its per-permission verdicts, because that fact changes how
to read all of them.

### 19.3 Reinstalling did not reinstall

`weftctl service install` ran `launchctl bootstrap` on a service that was
already loaded, which fails with `5: Input/output error` and does nothing. The
previous weftd kept running from the previous binary — so an install over an
existing install put new binaries on disk and left the old one driving the
windows. It boots the service out first now.

### 19.4 Screen Recording is not optional

It had been waved through as "only the focus highlight. Tiling works without
it." What it actually gates is `kCGWindowName`: without it macOS redacts the
title of every window weftd does not own, and `query windows` returns
`"title": ""` across the board. Every title-matching rule then matches nothing,
silently, and the window switcher lists blank rows — which reads as "weft
ignores my rules", not as a missing permission. It is required in `isRequired`,
in `DaemonPermissions.ready`, and in `doctor`.

## 20. Four things that were not the window manager's fault — 2026-09-09

A round of "it does not feel finished" reports, each with a different cause.

### 20.1 Dragging to resize a tiled window did nothing

The tiled branch of a modifier + right-drag emitted a resize only when a
*single* drag event carried more than 8 points, and threw the rest away:

```swift
if abs(dx) >= 8 { _ = handleCommand("resize \(dir) \(abs(dx))") }
```

A mouse reports one to five points per event. Nothing ever cleared the bar
except a flick, so the feature read as unimplemented. The remainder is carried
in the drag state now, so slow drags resize smoothly and fast ones behave as
before. Floating windows were never affected — they take the delta directly,
which is why this looked like "resize works sometimes".

### 20.2 The focus highlight stayed on the window you just left

Reported as a JankyBorders bug. It was three, in the same call.

`focusWindow` raised the window and activated the app, and did nothing else.
Neither tells the *application* which of its windows is now focused, so its
`AXFocusedWindow` never moved: focusing the second of two Ghostty windows
raised the right one and left the app focused on the first. Anything reading
real focus — borders, sketchybar, `mouse-follows-focus` — followed the app, not
weft. Setting `AXMain` then `AXFocused` on the element is what moves it.

Then two smaller ones underneath:

- The element was looked up in `windowElements`, never resolved. That cache is
  populated as a side effect of *writing a frame*, so a window that had never
  been laid out had no entry and focusing it did nothing at all, silently.
- `activate()` went out on its own queue, in parallel with the AX writes.
  Activating an app makes macOS restore that app's own key window, so when it
  won the race it undid the `AXMain` write that had just landed. It is
  sequenced after the writes now.

### 20.3 Stacks were invisible, and one-way

A stack gave every member the identical frame. That is what a stack *is*, and
it is unreadable: the slot looks exactly like a single window, with nothing on
screen to say the others are there. Members are now inset from the one behind
them (`stack-offset`, default 8, capped at three visible layers so a deep stack
does not shrink its own slot away) — the ones behind peek out along two edges,
the same affordance AeroSpace uses.

`stack wrap` was also a documented no-op on a window already in a stack: one
key in, no key out unless you had separately bound `stack unstack`. It is
`stack toggle` now, and `wrap` still parses to it because that is what every
existing config says.

### 20.4 Menu-bar panels were being tiled

A Stats or Ice dropdown is layer 0 and larger than 100×100, so the geometry
filter in `readWindows` waved it straight through: it took a slot in the
layout, and because weft focused and raised it, the click-outside that normally
dismisses such a panel never reached it — the only way to close it was to click
its menu bar icon again.

Every one of these belongs to an agent app: `LSUIElement`, no Dock icon,
`.accessory` activation policy. That is the whole test, and it costs a cached
`NSRunningApplication` lookup rather than the AX subrole round trip this path is
not allowed to make. `manage-menubar-apps = true` opts back in, for the rare
real app that runs as an agent.

### 20.5 Setup could be closed with nothing granted

A half-granted weft is not a degraded weft: windows float free, keybinds do
nothing, and window titles come back empty, with nothing anywhere naming a
permission as the reason. The one window that explains that had a Close button
on every page. It is gone until `ready`, along with the title bar's close
button and ⌘W; a refused dismiss says why rather than silently not closing.
A daemon that is not answering is still dismissable — there is nothing to grant
against, and trapping someone in a window that cannot help them is its own bug.

### 20.6 A rule-placed window was laid out by the wrong space

Two terminals opened one after the other landed on exactly the same pixels, one
invisible underneath the other, and the focus highlight appeared to follow only
the newer one. `query windows` told the story:

```
id=2376  sp=[6]                 # where SLS says the window is
space 5 'web'  windows=[156, 2376]   # where weft was laying it out from
```

The two phases of `syncFromSnapshot` disagree by construction. Phase 2, on the
core queue, files every window under the space the snapshot reported for it.
Phase 3, off it, performs the space-placement rules — a socket round trip and a
settle sleep, which is exactly why it is not on the core queue. So a window a
rule relocates has already been filed under the space it was *created* on, and
the layout that owns it is the wrong one from that moment forward.

Nothing brought it back: moving a window between spaces produces no event weft
observes, so on an otherwise idle desktop no further sweep ever ran and the
membership stayed wrong for the life of the window. Both terminals then
computed the east half of their own space's layout — same screen, same split,
same coordinates.

A successful rule move now schedules one follow-up sweep, 250 ms later, which
re-runs the real membership logic against where the windows actually are.
`spaceMoveAttempts` already caps each window at one move per lifetime, so the
extra pass cannot move anything again and cannot feed itself.

## 21. Shipping 0.1.0 — 2026-09-09

### 21.1 Nothing would ever tell a user a fix existed

weft installs from `curl | bash` or a clone. There is no App Store, no Sparkle
feed, no package manager — so an install stays on whatever version it started
on until its owner independently decides to revisit the repository, which is to
say forever. Every fix in §18–§20 would have reached nobody.

`UpdateCheck` asks GitHub's releases API once a day, caches the answer in
`~/.config/weft/.update-check.json`, and WeftBar shows one menu item when the
published tag is newer than the running build. It is deliberately a *notifier*,
not an updater: it downloads nothing and replaces nothing. Swapping a running
window manager's binaries underneath itself — while it holds an event tap and
every window on the desktop — is a much larger promise than a menu line, and
not one worth making for a first release.

Three details that matter more than the feature:

- **Versions compare numerically.** The bug every hand-rolled update check
  ships with is `String` comparison, where `"0.10.0" < "0.9.0"` and the tenth
  release is never offered to anyone. `WeftVersion.isNewer` splits and compares
  component-wise, treats a missing component as 0 so `0.2` and `0.2.0` are one
  release, and drops pre-release suffixes rather than throwing on them. Four
  tests, because this is exactly the code nobody notices is broken until the
  release that breaks it.
- **Failure is silent.** No network, a rate limit, GitHub down — none of these
  are the user's problem and none should produce a dialog in a window manager.
  The stale answer is kept and the next check happens on schedule.
- **`check-for-updates = false`** turns it off. It is a network call a window
  manager makes without being asked, so it gets a switch.

### 21.2 The release installer left users where §19 started

§19 gave `install.sh` a stable signing identity so a rebuild stops silently
revoking weft's permissions. `install-release.sh` — the path almost every
actual user takes — still installed whatever the workflow produced, and without
Developer ID secrets configured that is ad-hoc signed. So the source install was
fixed and the *shipped* install was not: every release would have dropped the
grants again, with the switches still reading as on.

It now applies the same self-signed identity, but only when the build does not
already carry a certificate-based designated requirement — re-signing a
notarised build would break the notarisation and buy nothing. `lib-codesign.sh`
ships inside the release archive so the standalone `curl | bash` path has it.

### 21.3 Unchecking a checkbox pushed the sidebar out of the window

Settings › General › Gaps: "Same on all sides" off swaps one spin field for
four. Four fields need ~356pt, the row spends 164 on its label, and the layout
preview beside it takes 236 — about 1050pt of intrinsic width inside a window
whose minimum is 880. Nothing in that column could shrink, so the `HStack`
overflowed, and what spilled off the edge was the fixed-width sidebar: the
navigation left the window.

The fields wrap to two rows when one will not fit (`ViewThatFits`), which fixes
the reported case. The structural guard matters more, because this was a class
of bug rather than one instance: the sidebar takes layout priority, the detail
column is explicitly allowed to shrink, and its `ScrollView` scrolls
horizontally as well as vertically. Any future pane that wants more width than
it has now scrolls inside its own column instead of shoving the navigation off
screen. The identical four-field group under "Screen reserve" was one edit away
from the same bug and now shares the wrapping component.

### 21.4 One dropped connection ended the install

The first real `curl | bash` install failed on the release asset:

```
curl: (35) LibreSSL SSL_connect: SSL_ERROR_SYSCALL in connection to release-assets.githubusercontent.com:443
ERROR: could not download .../weft-0.1.0-macos-universal.tar.gz
```

Not a block — measured from the same connection, the download succeeded twice
in three attempts. The installer simply had no retry anywhere: one `curl -fsSL`
per file, and any transient reset ended the install with a bare "could not
download" and nothing to do about it.

Every fetch now retries with backoff. `--retry-all-errors` is the flag that
matters: plain `--retry` covers HTTP 5xx and would not have caught a connection
reset, which is the failure that actually happens. Retries are silent, because
a recovered attempt printing `curl: (35)` mid-install reads as a failure to
exactly the audience this is for; `WEFT_VERBOSE=1` puts it back.

There is also a second route. The download URL redirects to the asset CDN;
`api.github.com` streams the asset itself and, from a connection where the CDN
is unreliable, is markedly steadier — three for three where the CDN managed two.
So it is a fallback rather than another try at the host that just failed.
Verified by pointing the primary route at a repository that does not exist: the
install fell through to the API, verified the checksum and completed.

Because `curl | bash` fetches this script from `main`, the fix reaches users
without re-cutting the release.

---

## 19. Tiling first — 2026-09-10

**Decision:** remove the scroll layout; make bsp and stacks the whole product, and make them
fast enough that tiling reads as instant.

**Why the strip went.** It was the one layout that fought macOS rather than working with it.
Hiding a column meant moving it off screen, which AX refuses to do (§4.2), so it needed
`SLSMoveWindow` — which desyncs the app, which needed the nudge protocol to undo, which needed
a persisted parked set to survive a crash, which needed `rescue` to clean up when that failed.
Each layer was a correct answer to the one below it, and together they were ~1,500 lines and
the source of every "my window vanished" report. Pans added a frame-rate path through the
WindowServer that once pegged the GPU (the reason `scroll-animation-ms` defaulted to off). None
of that machinery exists for bsp: every window has a frame and every frame is on screen.

**What changed for a user.**
- `layout = "scroll"`, `default-layout = "scroll"`, `[[space]] scroll = {…}`,
  `scroll-animation-ms` and `scroll …` keybinds all still *load*: each becomes a
  `ConfigWarning` with a line number, reported by the daemon log, `weftctl doctor` and the
  settings window. The parser stays strict for everything else.
- `space layout scroll` answers with bsp and says so.
- A `layouts.json` override saved as `scroll` is dropped on load, and the space tiles bsp.
- `⌥N`, `⌥P`, `⌥R`, `⌥⇧N`, `⌥⇧[` and `⌥⇧]` are free.
- `weftctl rescue` survives, repurposed from "unpark crash debris" to "bring back a window
  that is off every display".

**What comes next** is measured, not guessed: `Trace` (`Sources/WeftPlatform/Trace.swift`)
keeps a ring of samples per phase of every apply, and `weftctl bench` prints them. The two
stalls this pivot is aimed at — survivors slow to fill a closed window's slot, and a beat
before a new window takes its slot — both live in the AX half of the apply path, which the
trace splits into `ax.position`, `ax.size` and `ax.verify` per app.

---

## 22. Borders draw what is there, not what was asked for — 2026-09-17

§S8's border section ends "**So the border bug is unexplained.**" It is
explained. The report that closed it was: *staying on one desktop, only opening
and closing windows, and the borders did not know how to render around the
windows.* Staying put is the important half — it rules out every theory about
desktop switching, which is where the previous rounds looked.

### 22.1 A border was drawn around the frame weft had asked for

`refreshDividerZones` computed each visible space's layout and handed those
frames straight to the renderer, which drew a ring around each one. But
`applyFrames` is fire-and-forget by design (§13.8): the write is *queued*, and
the window arrives later. How much later varies by three orders of magnitude:

| window | when it reaches the frame |
| --- | --- |
| native app | ~0.5 ms (§S1 p50) |
| Gecko / Electron mid-relayout | 32 ms p99, and worse under load |
| no AX element yet (§S0) | not until the space is first visited |
| refuser, or a window mid-space-transition | never |

So the border was correct only in the steady state it had already reached.
Opening a window re-slots every sibling at once; closing one does the same to
every survivor. Those are precisely the two moments the report names, and at
those moments every ring on screen is around a rectangle its window has not
got to yet.

The single correction path made it worse rather than better. `observe(wid:actual:)`
took the frame from an AX move notification and substituted it for the target —
but only when `BorderGeometry.settles` judged it a *settle* rather than a read
from mid-flight, because accepting a mid-flight frame had previously latched a
half-width ring around a full-width window permanently. That gate is correct for
its own purpose and it is exactly wrong here: the deltas it rejects are the
large ones, which are the visible ones. A border that was wrong by a whole slot
could not be corrected by the mechanism built to correct borders.

### 22.2 Membership is weft's question; geometry is the WindowServer's

The renderer now takes the layout's frames as *membership plus a target*, and
resolves the geometry itself with one `SLSGetWindowBounds` per bordered window
per pass — WindowServer-local, 0.03 ms, no app IPC, so a screenful costs a
fraction of a millisecond. A window the WindowServer will not report loses its
border rather than keeping one over its last known position.

That deletes rather than fixes the arbitration: `observed`, `lastTargets`, the
substitution and the judgement about which frames may be believed are all gone.
`observe` became `windowMoved(_:)`, which carries no frame at all — an AX
notification is a signal that the geometry changed, and the renderer asks what
it changed to. `BorderGeometry.settles` survives with the same numbers and a
different job: not *may the border follow this frame* but *has this window
arrived*, which is what stops the re-read ladder.

Following a window that is still in flight without a polling timer: each pass
asks whether anything is short of its target and, if so, arms one wake-up from
a decaying ladder — 8, 16, 32, 64, 128, 256, 512 ms, about a second in total,
generation-counted so a newer intent cancels it. It is armed by a change and
always terminates, so the 0%-idle invariant (§1) holds. The ladder covers the
windows that send no AX notification at all, which is every window with no AX
element; `windowMoved` covers apps slower than the ladder.

`Border.target` was renamed `Border.around`, because the file now holds two
things that were both called `target` and mean opposites — where weft asked the
window to be, and where the ring is drawn. Conflating those two is the bug.

### 22.3 Three smaller ones found in the same path

- **Borders for windows that are not on screen.** A closed-but-kept window
  (Ghostty, most Electron apps) and a minimised one both stay in the layout with
  no destroy notification. `evictOrderedOut` finds them — on the next *focus
  change*, and closing a window with the mouse need not move focus. The border
  set is now filtered through `WorldReader.onScreenWindowIDs()` on every refresh.
- **The desktop was read from weft's cache of it.** `refreshDividerZones`
  iterated `SpaceState.currentByDisplay`, which `space focus` already refuses to
  trust because it goes stale on every switch weft did not perform (§13.1). The
  pieces are sticky (tag bit 11) so they show on whatever desktop is on screen —
  meaning a stale read painted the previous desktop's layout over the new one.
  It now asks `WorldReader.currentSpaces()`, ~40 µs, no window list.
- **Two writers disagreed about focus.** `noteFocusedWindow` pushed the raw
  system-focused window to the renderer on every focus change; `refreshDividerZones`
  pre-resolved the same value to nil when that window had no border. Last writer
  won, and the order varied. With `show-inactive = false` the two readings are
  "no highlight" and "no borders at all". The renderer holds the rule now, and
  both writers pass the same thing.

## 23. `space move-window` follows by default — 2026-09-17

The move is a held window plus the bound desktop shortcut (§S8), so the screen
visibly changes desktop on the way. Not following does not avoid that — it adds
a second switch to get back. The command was paying an extra visible transition
to end up where someone who just sent a window somewhere usually did not want to
be, and the whole gesture read as a bug rather than as the deliberate
"do not follow" it was.

Following is now the default and `--no-follow` is the opt-in. It is the cheaper
path: the carry already ends on the destination, so following is the branch that
does nothing. A carry that *failed* still returns the user, whichever was asked
for — being left on a desktop you did not ask for with the window still behind
you is the one case where going back is unambiguously right.

`weftctl migrate` used to emit `--no-follow` for a bare `yabai -m window --space
N`, which does not follow, so a migrated config kept doing what it did. Since
0.9.17 it emits the default. With workspaces on one desktop (REDESIGN.md),
following is a workspace switch rather than a desktop switch, and a bind that
stays put leaves the user on the workspace the window just left. A line that
chains `space --focus` onto it also becomes one weft command with the default. That
branch also had to move above `space --focus` in the matcher — the same ordering
bug §15.2 fixed for `window --display`, which the chained form hits the same way.

## 24. `exec` — 2026-09-17

weft replaces skhd, and skhd's other job is running commands. There was no way
to bind a key to one: `weftctl migrate` mapped the yabai lines and dropped the
rest in silence, so a migrated config came back missing the screenshot bind, the
volume keys and every script its owner had.

`exec <anything>` hands the rest of the line to `/bin/sh -c`. The rest of the
line, taken from the raw string rather than from the tokens the rest of the
grammar splits on — `exec sed 's/a  b/c/'` must not be rewritten by being
split and rejoined.

Three properties that matter more than the verb:

- **Nothing waits for it.** The event tap has a deadline macOS enforces by
  *disabling the tap*, and the socket handler is shared with every command. Fork
  and exec happen on a `.utility` queue and nobody waits for the result.
- **Children are reaped.** A window manager runs for weeks; an unwaited child is
  a zombie for all of it.
- **It cannot run away.** A held key repeats. Past 32 in flight, launches are
  refused with one line of log — refused, not queued, because queueing turns a
  fork bomb into one that also fires for the next ten minutes.

The command gets weft's state in its environment — `WEFT_SPACE_LABEL`,
`WEFT_FOCUSED_APP`, `WEFT_MODE` and the rest — from `StateSummary.environment`,
the same list the sketchybar bridge publishes. One list, because a second
hand-rolled one would drift on the first field either gained.

`weftctl migrate` now emits `exec <line>` for any action that was never a yabai
verb, guarded on the line not mentioning `yabai`: a yabai command that failed to
map must not be handed to a shell, or a verb weft does not implement silently
starts driving yabai instead. Those are named on stderr instead.

---

## 25. `move <dir>` restructures instead of swapping — 2026-09-17

`move <dir>` found the geometric neighbour and called `Tree.swapping`, which
exchanges two **leaves**. That is right only when the two windows own
equivalent slots, and in a bsp tree they usually do not:

```
  +-------+-------+        splitV[A, splitH[B, C]]
  |       |   B   |
  |   A   +-------+        A owns half the screen, B a quarter.
  |       |   C   |
  +-------+-------+
```

`move east` on A swapped the leaves A and B, so A came back as a quarter in the
top-right corner and B grew to half the screen. The window obeyed the direction
and changed size doing it, and the size change is the part that reads as a bug —
"I asked it to move, not to shrink". i3, AeroSpace and yabai's `window --warp`
all restructure instead, which is why weft felt different from all three on the
verb people press most after `focus`.

`Tree.moving(_:towards:)` walks up from the window to the nearest ancestor that
both runs along the direction's axis and has somewhere to go in that direction:

- **Direct child of that ancestor** — exchange places with the neighbour there,
  *ratios included*, so both windows keep their size. A is exchanged with the
  whole B/C subtree, giving `splitH[B, C] | A`: A on the right, still half.
- **Nested deeper** — lift the window out of the subtree it is in and drop it
  beside that subtree at the matching level. B moved west leaves the B/C column
  and lands between A and C: three columns, one step west.
- **A stack** runs along no axis, so a stacked window walks straight out of the
  stack. `stack move <dir>` remains the verb for putting one in.
- **No such ancestor** — already against that edge — does nothing, deliberately.
  yabai fails here too, and that failure is what lets `{ move east } || { … }`
  in a keybind fall through instead of quietly rearranging something.

Two details the implementation turns on:

- **The insertion index is resolved after the removal, never before.** Lifting a
  window out can collapse the container it came from — a two-member column
  becomes a bare window — so indices taken from the pre-removal tree are off by
  one or off the end. The slot it left is found again by *identity* (which
  windows were beside it), not by index.
- **Ratios travel with the children.** Exchanging positions without exchanging
  ratios means the window adopts the size of the slot it arrives in, which is
  the same defect in a smaller form.

`swapping` survives, behind a new `swap <dir>`, because the literal exchange is
occasionally what someone wants and yabai spells it separately too.
`weftctl migrate` now maps `window --swap <dir>` → `swap` and
`window --warp <dir>` → `move`; it used to map both to `move`, which silently
changed what half of those keys did.

`Tests/WeftCoreTests/MoveTests.swift` pins the shapes, and one test does every
direction from every window of a four-window tree and checks that all four come
back, none twice, each with exactly one non-degenerate frame. An edit that
removes a node and reinserts it is the shape of change that loses a window, and
a layout engine that loses one is worse than one that arranges badly.

---

## 26. The update that showed no progress — 2026-09-17

Reported as: opening Settings "did not work and update the app, and it did not
show any progress". Reproduced by running what the Updater runs —
`WEFT_VERSION=v0.9.5 bash scripts/install-release.sh` with `PREFIX` and
`WEFT_APP_DIR` pointed at a scratch directory — and sampling the log:

```
t=2s   ==> downloading weft 0.9.5
t=12s  ==> downloading weft 0.9.5
...
t=150s ==> downloading weft 0.9.5        curl: 44.9%
```

Every later stage — verify, stop, install, sign, quarantine, seed, service —
fires within a couple of seconds of each other once the download is done. So
the update is one long phase and a flurry, and the long phase was publishing
exactly one line.

### 26.1 The percentage was in the log and thrown away

`install-release.sh` speaks two channels. `==> <stage>` lines, once per stage,
and curl's `--progress-bar`: hashes and a figure, rewritten in place with a
carriage return. The poller read only the first. From GitHub's CDN to the
machine this was reported from that meant a static sentence for **five minutes**
— indistinguishable from a hang, and reported as one.

`WeftCore/UpdateProgress.percent(in:)` reads the figure. In `WeftCore` rather
than in WeftBar because an executable target cannot have tests (§17.3) and this
decides what a progress bar claims: a parser that returns a stale percentage
shows a bar that sticks or runs backwards, which is worse than showing none. So
a stage line appearing *after* the bar returns nil rather than the figure behind
it, and only curl's own line — hashes, spaces, figure — is read, so a message
that merely contains a percentage cannot drive the bar.

Settings now shows that bar, the percentage, and **an elapsed clock**. The clock
is the part that matters: over four seconds a creeping bar and a stalled one look
the same, and the complaint was about minutes. A number visibly counting says
*slow*; a still sentence says *broken*.

A correction worth recording, because the first draft of the fix asserted the
opposite in a comment and a test caught it: `CharacterSet.newlines` **includes**
the carriage return, so splitting the log on `.newlines` already separates each
redraw of the bar. The original code's failure was never about splitting.

### 26.2 Three ways the update could end without saying anything

- **`String(contentsOf:encoding: .utf8)` on a file curl is mid-write.** A
  partial byte sequence makes the strict decode return nil for the whole log, so
  progress stops dead with nothing to say why. Read `Data` and decode lossily.
- **`finish(withFailure: nil)` was silent.** On the happy path the installer
  *quits this app* before it finishes, so an update that reaches that line has
  stopped early without replacing anything — and saying nothing put the Update
  button back exactly as it was. That is the report, verbatim: it did not work
  and showed no progress. It now says the installer finished without replacing
  weft, and where the log is.
- **The pending marker died with the process.** `UserDefaults.standard.set` is
  flushed on the system's own schedule, and the installer signals this process
  partway through — so the marker that exists precisely to survive being killed
  was the thing least likely to. `synchronize()` before the installer can get
  there.

### 26.3 Settings read the cache and only the cache

`EngineHealth.refresh` took `UpdateCheck.cached()`, a file read with no network
by design — the window polls every five seconds and must not turn that into
traffic. But nothing else ran a check when the window opened, so Settings opened
before the once-per-launch background check had landed, or on a machine where it
had never run, showed the running version with nothing beside it and no Update
button. That is indistinguishable from "you are up to date", and it is the other
half of "when I open it, it did not work".

Opening the one window that displays update state is as clear a request for the
answer as pressing Check Now, so `start()` now calls `refreshIfNeeded` when the
cached answer is stale or missing. It still honours the daily throttle and
`check-for-updates`, so this is at most one request a day and none at all when
updates are off.

---

## 27. Moving a window there, then back — 2026-09-17

Reported against 0.9.6: moving Zen from one desktop to another "worked, it was
so laggy and delayed but it worked", and then moving it back "did not work at
all". The asymmetry is the whole clue — the second move is the one the first
move breaks.

### 27.1 The grab probe believed weft's own writes

`carry` picks a point on the window's top edge, presses, nudges the pointer
down a few points, and asks whether the window moved. If it did, it is held and
the desktop shortcut can go out.

"Did it move" was the wrong question, because **weft writes frames to that same
window**. `space move-window` schedules a trailing `applySpaceLayout` 250 ms
after it finishes (§20.6), and any sweep can retile. Land one of those during
the next move's grab probe and it reads as a successful grab — so the shortcut
went out with *nothing held*. The desktop changed, the window stayed, the
verification correctly failed, and the user was switched back. Two visible
desktop changes, no move, and a first move that had itself worked.

The probe now asks whether the window is **following the pointer**: down by
something, by no more than the pointer travelled, with no sideways movement and
no resize. Not `≈ dy` exactly — macOS needs a few points before it starts a
window drag, so a window picked up on the third nudge has travelled less than
the pointer and an exact match would reject it. The upper bound is what keeps a
retile out: those move a window by a slot and change x or the size doing it.

### 27.2 The carry guard was not on the funnel

`DragMove.isCarrying` existed for exactly this and was checked in three places,
one of them `applyCurrentSpace`, described as "the funnel every re-apply
reaches". It is not: the trailing pass above calls `applySpaceLayout` directly.
The guard moved onto `applySpaceLayout`, which is where frames are actually
written, so every path in is covered including the one that caused this.

Two fixes for one bug on purpose. Either alone leaves the failure reachable —
the probe can be fooled by a sweep weft did not schedule, and a write during
the hold ends the drag session whether or not the probe was fooled.

### 27.3 The lag, itemised

Per move, before this:

| | cost |
| --- | --- |
| `SLSMoveWindowsToManagedSpace` + its settle | **150 ms, every move, always wasted** |
| grab probe, per missed candidate | ~110 ms, up to 4 |
| per desktop of travel | 40 ms of keypress + the macOS animation |
| drop settle | flat 150 ms |

Three of those four are now paid only when they buy something:

- **The dead API call is probed once per daemon, not once per move.** S8 proved
  it is refused on macOS 27, but "never" is a fact about today's macOS and the
  probe is what survives the next release — so it is kept and its answer cached.
- **The working grab point is remembered per app.** An app's title bar is in the
  same place every time; the second move of the same app costs one attempt
  instead of four. A remembered point that stops working is forgotten rather
  than tried first forever.
- **The drop settle polls** for the membership change instead of sleeping 150 ms
  to cover the slowest case.
- A move to the desktop the window is already on now returns immediately
  instead of carrying it in a circle.

What remains is the **macOS space-switch animation**, one per desktop of travel,
and it cannot be removed. The fast synthetic Dock swipe weft uses for
`space focus` is *refused while a drag is in flight* (§S8) — a held window is
precisely the case it does not serve — so the carry must use the bound keyboard
shortcut, which triggers the real animated transition. System Settings →
Accessibility → Display → **Reduce motion** turns that animation into a
crossfade, and it is the only lever there is.

### 27.4 A failure now says which failure

Every refusal in `DragMove` named itself, under `WEFT_TRACE` only, and the
socket reply listed the things it might have been. A keybind that does nothing
is exactly the case where nobody is watching stderr, and telling someone to
re-run under a trace is asking them to reproduce a bug to find out what it was.
`DragMove.failureReason` carries the actual one out to the reply, including two
that had no message at all: a desktop list that does not contain both spaces,
and a carry whose keys went out but left the window where it was.

---

## 28. Four bugs that shared one shape

Reported together: moving a window to another desktop moved the pointer and
nothing else; spaces, focus and borders misbehaved across two displays;
`float toggle` held until the next space change and then re-tiled; and the
in-app updater downloaded, showed progress, and reported that it had not
installed.

They are unrelated in mechanism and identical in shape. In each one weft asked
a question of something that could not answer it — its own event tap, its own
cached idea of the focused display, its own compile-time version constant — and
believed the answer.

### 28.1 weft's event tap swallowed weft's own clicks

`DragMove.carry` picks a window up by posting a `leftMouseDown` on its title
bar. The loopback guard that exists precisely so weft's synthetic events do not
re-enter its own keybinds sat **after** the mouse branches of `tapCallback`,
reachable only by `keyDown`.

`CGEvent(mouseEventSource: nil, …)` stamps a new event with the modifiers that
are physically down at the time, and the keybind that starts a carry is
modifier-heavy by nature — `alt-shift-1`. So the press arrived carrying alt,
which is exactly what `mouse-modifier = "alt"` claims a click for. The tap
claimed it and returned nil; the application never saw a press; the window was
never picked up; and the grab probe (§27.1) correctly refused to send a desktop
shortcut to a window weft was not holding. Everything worked as specified and
the only thing that reached the screen was the pointer jumping between the four
grab candidates.

A divider or stack-strip grab zone under a candidate point does the same thing
with no modifier at all.

The guard moved above every branch, and `DragMove` now clears `e.flags` on the
events it posts: what a person does to drag a window is press with nothing
held, and an application is entitled to treat a modified click on its chrome as
something else entirely.

The carry also waits for the desktop transition to finish before letting go.
`waitForChange` returns the moment the WindowServer reports the new desktop,
which is earlier than the moment the switch is over, and a drop taken during it
replays the last movement on the desktop being left. `spikes/dragmove.swift`
waits here and says why; the shipped version never did.

### 28.2 `focusedDisplay` was set by one path and read by all of them

`SpaceState.currentSpace` — the space every command, every border pass and
every new window resolves against — is `currentByDisplay[focusedDisplay]`. Only
`noteFocusedWindow` ever wrote that field, and it wrote it by looking the
focused window up in each visible space's **layout**.

Three consequences, all of them "the other monitor is buggy":

- `space focus` never touched it. Switching a desktop on the second monitor
  left `currentSpace` resolving through the first, so the space weft then
  tiled, bordered and focused was the one nobody had asked about. It looked
  correct only when the destination happened to have a window that
  `applySpaceLayout(stealFocus:)` could activate, which then set the field as a
  side effect.
- A space already showing on the other display was answered with "already on
  \<label\>" and nothing else. That is true of the *desktop* and false of the
  user: keyboard focus stayed where it was, so the space they had just named
  was not the one their next keybind acted on.
- A float, a rule's `manage = false`, a quirked window and a panel are in no
  layout, so the lookup never matched them. Clicking a floating window on the
  second monitor left weft's idea of the current display behind.

`space focus` now resolves the target's display up front and sets the field on
every path that lands — the swipe, the keystroke fallback, and the new
focus-only path for a space that is already showing elsewhere.
`noteFocusedWindow` falls back to the window's own centre against the display
rects, which is the question membership was standing in for.

`move display <dir>` was broken outright on any two-display Mac for a related
reason: it goes through the carry, and the carry presses "move left/right a
space", which only ever steps along one display's own list — so it refused with
*"target N and window space M are not on one display"* and nothing else was
tried. It does not need the carry. With separate Spaces per display the
WindowServer decides a window's display from where the window **is**: writing
its frame inside the other monitor joins it to that monitor's showing desktop.
One AX write, no desktop switch, no keystroke, verified by re-reading
membership like every other mutation here. Only valid for a desktop that is
showing — which is exactly what `move display` always names.

### 28.3 A hand float was excluded from layouts but not from membership

`syncFromSnapshot` builds `bySpace` — the window→space membership
`syncMembership` reconciles layouts against — and then folded `manualFloat`
into `unmanagedNow` **after** that loop. So a floated window got the "do not
manage it" flag and stayed in `bySpace` all the same: the next sweep put it
straight back into its space's tree, and the next apply tiled it.

`float toggle` therefore held exactly until the next sweep. Leave the desktop
and come back, or open any window anywhere, and the float was a tile again.
Every other reason to leave a window alone — a rule, a quirk, a panel — already
`continue`s past the membership line. This is the one that did not.

`handleFloat` also worked against `currentSID()` rather than the window's own
space, so floating a window on the second monitor took the *other* display's
layout apart (a no-op) and then centred the window on a screen it was not on.

### 28.4 The updater proved failure with a constant

`install-release.sh` runs as a child of WeftBar. It `pkill`s the app, then
`rm -rf`s the bundle and copies the new one in. Under `set -euo pipefail` an
exit status of 0 means all of that succeeded — the new bundle **was** written.

But `pkill` returns as soon as the signal is queued. An app that does not
actually go is survivable — its binary stays mapped — and the result is the old
build running on top of a new bundle. The installer's closing `open` then
activates that same old process rather than starting anything, and the old
process reports:

> The installer finished without replacing weft, which is still 0.9.6.

`WeftVersion.current` is this binary's compile-time constant. It cannot change
however well the update went, so that branch could only ever report failure.
The one outcome the code was written to never produce — silence — had been
replaced with an outcome that was always wrong.

Two fixes, because either alone leaves it reachable:

- The installer **waits for the quit**, and kills outright if it must. A bundle
  is never replaced underneath a live process. It then reads the installed
  version back out of the bundle and puts it in the log, because "the copy
  returned 0" and "the app on disk is the new one" are different claims.
- The updater **asks the disk**. `finish` reads `CFBundleShortVersionString`
  from the bundle it just replaced. If that is the version it asked for, the
  update worked and this process is the copy left behind: it launches the new
  build — `createsNewApplicationInstance`, or LaunchServices answers by
  activating this old one — and stands down. Only a disk that really does still
  hold the old build produces a failure, and it names the version it found.

Both ship inside the app, so they take effect for updates started *from* a
build that carries them. That lag is inherent to an updater that lives in the
thing being updated.
