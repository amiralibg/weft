# Workspaces — weft's own, inside macOS's

**Status:** Built (Phases 1–5), released in 0.9.11, and the default for new
installs since 0.9.12 — see "The default" below. S9 in `spikes/RESULTS.md`
establishes that the mechanism works.

## The problem, stated once

weft manages native macOS Spaces, and macOS will not cooperate:

- It will not move another app's window between desktops. Sixteen SkyLight
  routes were tried and refused (S8); what is left is holding the window by its
  title bar and pressing the user's "move a space" shortcut. That costs two
  visible desktop animations, and it fails outright for any window with no
  draggable title bar — a terminal with `macos-titlebar-style = hidden` is the
  reported case, and Ghostty makes that window non-draggable deliberately.
- It will not say reliably which desktop is showing.
  `activeSpaceDidChangeNotification` is a GUI notification arriving in a
  daemon, does not name the display, and on a swipe arrives while the
  WindowServer is still animating. `checkSpaceChanged`, `startSpaceWatch` and
  `scheduleSpaceRechecks` are three stacked heuristics around that one gap.

`DragMove.swift`, `DockSwipe.swift`, `SpaceShortcut.swift`, the symbolic-hotkey
reader and the space watcher exist only because of those two sentences. Three
of the four bugs reported against 0.9.9 came out of that layer.

## The idea: nest, do not replace

AeroSpace's answer is to stop using native Spaces: keep every window on one,
and hide a workspace by moving its windows off screen. That works — S9 measured
it on this machine — but it hands macOS's own window UI back broken, and a
window manager that breaks Mission Control and native fullscreen has traded one
kind of weird behaviour for another.

So: **a workspace lives inside a desktop, and never spans two.**

| | owner | what it is |
| --- | --- | --- |
| **Desktop** | macOS | a native Space. Mission Control shows it, a swipe switches it, full-screening an app makes one |
| **Workspace** | weft | a named set of windows with a layout, on exactly one desktop of one display |

Today's model is the special case where every desktop holds exactly one
workspace, and that stays the default. Nothing changes for anyone who does not
ask for it.

The useful configuration is several workspaces on **one** desktop per display —
the *anchor* — with the remaining desktops left holding one workspace each,
exactly as now. That gives both halves at once:

- Switching between workspaces on the anchor is a park and an unpark:
  **0.2 ms a window, no animation** (S9).
- Moving a window between them is a state edit plus a park. **It works for
  every window, including one with no title bar.** This is the Ghostty case,
  and it stops being a special case.
- Every other desktop is untouched. Native fullscreen makes its own Space and
  weft skips it, as now. Mission Control, swipes and ⌃← still work. A desktop
  weft has no workspace on is simply not tiled.
- `space focus` on a workspace that lives on another desktop switches the
  desktop first (DockSwipe, as now) and then shows the workspace. One native
  switch, then instant.

## What is measured, and what is assumed

Measured (S9, plus `parked.swift` on 2026-09-18):

- Five applications — a terminal, a browser, Electron, Finder, a VPN client —
  all parked into the bottom-right corner, stayed parked, and restored to the
  exact pixel.
- `SLSMoveWindow` parks in **0.2 ms a window** and lands on the pixel asked
  for, because no application is consulted and so none can clamp. The AX path
  is 30 ms a window and lands 32pt short.
- **A parked window still reports `kCGWindowIsOnscreen = true` and stays in
  `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`.** This is the one that
  decides whether the design is possible at all: `evictOrderedOut` drops any
  window in a layout that the on-screen list stops reporting, and it runs on
  every focus change. A parked workspace is not eaten by it.
- S4's "AX clamps off-screen parking" is direction-dependent. Parking to
  negative x is clamped to keep 40px reachable; parking past the right edge is
  not. The bottom-right corner is not an aesthetic choice.

Assumed, and to be proven before Phase 3 ships:

- An application parked for an hour behaves like one parked for a second.
  Occlusion state drives render throttling in Electron and browsers, and S9
  parked nothing for longer than 1.2 s.
- Mission Control on the anchor desktop is *degraded but usable*. It will show
  a sliver per hidden window. AeroSpace's guide says "Group windows by
  application" makes it bearable; weft should not need to ask for that.
- Fifty windows behave like five.

## Model

Built in Phase 1; this is what is in `Sources/WeftCore/Spaces.swift` today.

```swift
struct WorkspaceID: Hashable { let raw: UInt32 }   // weft's own, within a launch

struct Workspace {
    var id: WorkspaceID
    var label: String
    var desktop: SpaceID                // the native Space it lives on
    var layout: SpaceLayout             // .tiling(Tree) / .float(FloatState), unchanged
    var overrideKind: LayoutKind?       // what `space layout <kind>` asked for
}
```

`WorkspaceID` is a struct rather than an alias for `UInt32`, because the whole
difficulty of this model is telling a workspace from the desktop it sits on and
several places derive one from the other in a single expression. It is not
`Codable`: nothing outside the daemon has a use for one, so a workspace id put
on the wire is a build error rather than a number that decodes cleanly and
names the wrong thing.

There is **no `display` field**. A workspace lives on one desktop and a desktop
on one display, so the display is `displayBySpace[desktop]` — the lookup every
screen rect already goes through. Storing it would be a second copy of a fact
that has an owner, and the two would drift the first time a monitor was
unplugged.

`SpaceState.layouts: [SpaceID: SpaceLayout]` became
`workspaces: [WorkspaceID: Workspace]` plus `active: [SpaceID: WorkspaceID]` —
which workspace is showing on each desktop. `labels` folded into
`Workspace.label`, because a workspace is what a label names.

Two orderings, and keeping them apart is what lets a desktop hold more than one
workspace:

- `order: [SpaceID]` — Mission Control's own desktop numbering, which is what
  the ctrl+N fallback keystroke has to post and can never be weft's.
- `wsOrder: [WorkspaceID]` — the ordinal that labels and `space focus 3` count
  in, and the one both persistence files are keyed by.

**Workspace ids are never persisted.** `labels.json` and `layouts.json` are
ordinal-keyed, exactly as before, so there is nothing to migrate when the
mapping stops being one-to-one.

`adoptDesktops(_:names:)` is the identity mapping written down in one place:
one workspace per desktop, showing, created and destroyed together with it. It
is **the one function Phase 3 changes**; everything else already asks which
workspace rather than which desktop.

### The seam

**Membership has two owners, and the split is the whole design.** SLS says
which *desktop* a window is on; that is macOS's fact and stays authoritative.
weft says which *workspace within that desktop*; that is weft's own state.

It is one function, `reconcileWorkspaces`, taking plain dictionaries rather
than a `SpaceState` so it can be read on its own and cannot reach for a fact it
was not handed:

```swift
func reconcileWorkspaces(
    windowDesktops: [WindowID: [SpaceID]],   // straight from SLS
    membership: [WorkspaceID: [WindowID]],   // weft's current answer
    desktopOf: [WorkspaceID: SpaceID],
    activeOn: [SpaceID: WorkspaceID]
) -> [WorkspaceID: [WindowID]]
```

One rule in two halves:

- A window still on the desktop its workspace lives on **keeps that
  workspace**, showing or not. This is the half that makes a hidden workspace
  possible at all: SLS reports a parked window on its desktop exactly like any
  other, so without it the first sweep after a switch would vacuum every hidden
  window into whatever is on screen.
- A window whose desktop changed under us **joins the active workspace of the
  desktop it arrived on.** That covers a user dragging a window in Mission
  Control, a rule relocating one, and an app opening a window wherever it
  likes.

A window leaves a workspace by no longer being reported on that workspace's
desktop, so nothing in there removes anything. A sticky window is resolved once
per desktop and holds a slot in one workspace on each.

**Every live desktop must have an entry in `active`.** A desktop without one
drops what arrives on it, `evictOrderedOut` finds nothing held and returns
early so closed windows never give their slots back, and `refreshDividerZones`
skips it so its borders and grab zones stop being drawn — three silent
failures. The sweep checks it and logs when it does not hold.

## Park and unpark

Built in Phase 2; this is `Sources/WeftPlatform/Parker.swift` and
`ParkLedger.swift`. Nothing calls `park` — under the identity mapping no
workspace is ever hidden — so it is the primitive Phase 3 turns on. The
*recovery* is live already, because a path whose first run is the first crash
that needs it has not been shown to work.

```
park(wid)   SLSMoveWindow(cid, wid, Parker.spot(in: display))
unpark(wid) SLSMoveWindow(cid, wid, the frame the ledger recorded)
```

Both pure WindowServer, ~0.2 ms, and the application is never told — which is
what makes it uncloseable to clamping. S4's nudge caveat does not bite: a park
and an unpark that both go through `SLSMoveWindow` leave the app's own idea of
its position untouched throughout, so it is consistent again the moment the
window is back. `AXApplier.restore` keeps its nudge because it is the mixed
case, SkyLight out and Accessibility back. AX is needed only when the layout
actually changed while the workspace was hidden, and that is the ordinary
`applyFrames` path.

### The ledger

`~/.config/weft/parked.json`, beside `labels.json` and `layouts.json`.

```json
{
  "version": 1,
  "parked": [
    {
      "wid": 4321,
      "frame":    { "x": 0, "y": 38, "width": 1728, "height": 1079 },
      "parkedAt": { "x": 1727, "y": 1116 }
    }
  ]
}
```

An array of records rather than a `[WindowID: …]` dictionary, because
`JSONEncoder` cannot key a JSON object by `UInt32` and emits a flat array of
alternating keys and values instead — a shape nobody would choose for the one
file that has to be readable by hand after a crash.

`frame` is the window's **real** frame at park time, read from
`SLSGetWindowBounds` inside `park` and never handed in by the caller. An app
that refuses its tile is exactly the app whose restore would otherwise put it
somewhere it has never been, and after a crash there is nothing else left to
restore from: trees are not persisted, and a float workspace's arrangement
belongs to the user.

`parkedAt` is the answer to recycled window ids. The WindowServer hands ids out
again, and a daemon that crashed never ran `forgetWindow`, so an entry read at
startup may name a window weft never touched. Nothing is moved until the
window's live bounds are compared against the corner the entry records — a
window that is not sitting there is not the window that was parked. That check
is deliberately not a hook into `forgetWindow`: that runs in a loop inside
`evictOrderedOut`, so pruning the ledger there would put a synchronous fsync on
a hot path, and it could not help in the one case the file exists for.

`version` earns its place for the same reason. `labels.json` and `layouts.json`
can be thrown away when they do not parse; throwing this one away strands
windows, so a build meeting a file it does not understand has to be able to say
so rather than read it as "nothing is parked". For the same reason `load`
distinguishes an absent file from an unreadable one — collapsing the two is
precisely how a stranded window becomes silent.

### Where the write sits

**Before the move, always.**

```
park(wids, on: display)
  1. read each window's real frame      SLSGetWindowBounds, ~0.03 ms each
  2. encode the whole ledger            the current set, not an append
  3. write to parked.json.tmp
  4. fsync(tmp)                         ← survives the process dying
  5. rename(tmp → parked.json)          ← a reader sees old or new, never half
  6. fsync(the directory)               ← survives the machine dying
  7. SLSMoveWindow for each wid         ~0.2 ms each
```

A failure anywhere in 2–6 throws and **moves nothing**: a workspace that cannot
write its ledger does not get hidden. Step 6 is the only one that is about a
panic rather than a crash, and it is one syscall.

Unpark is the mirror — the moves land first, the ledger is rewritten after —
because dropping an entry and then failing to move the window is the one
ordering that produces a window off screen with no record of it. A crash the
other way round leaves an entry for a window that is already home, and the
`parkedAt` check discards it on the next read. In both directions the disk is
pessimistic, which is the rule: a stale entry over a stranded window.

Writing is per set, not per window: one ledger write and then N moves. A
workspace switch is a park and an unpark, so it is two writes and four fsyncs —
the only part of a switch that is not microseconds, and unmeasured so far,
against the ~500 ms of animation a native desktop switch costs today. Worth
timing when Phase 3 wires it.

### `rescue()` does not overlap with this

`rescue()` heals a window that is off **every** display, tested with
`Frame.intersects`. A parked window's origin is one point inside the display's
bottom-right corner, so it intersects by that point and `rescue()` skips it.
That is not a gap that could be tuned away: the same point is what keeps
`kCGWindowIsOnscreen` true and keeps `evictOrderedOut` from reading a hidden
workspace as a set of closed windows, which is the measurement the whole design
rests on.

They also heal different things. `rescue()` puts a window at its **computed**
frame for the current space; the ledger puts it at the **real** frame it had,
on whatever desktop it was on. Neither substitutes for the other, and they are
not merged.

### What strands a window, and what fails loudly

| when | what happens | outcome |
| --- | --- | --- |
| the ledger write fails (disk full, permissions) | `park` throws, moves nothing | loud |
| crash between the write and the moves | ledger names windows still at home; `parkedAt` discards them | clean |
| crash partway through the moves | ledger covers all of them; the parked ones are restored, the rest discarded | clean |
| crash while parked | the case the file exists for | clean |
| the app moves its own window while it is hidden | `parkedAt` misses, entry dropped, window left where the app put it | clean |
| `SLSMoveWindow` refuses a park | the entry is taken back out — while the daemon runs it is the one stale entry that is not safe | loud |
| `SLSMoveWindow` refuses an unpark | logged, the entry is kept, the next launch tries again | loud |
| the ledger cannot be read | logged, the file is left on disk for a later build, nothing is moved | loud |
| crash while parked **and** `parked.json` lost | the windows sit at the corner and nothing can find them | **strands** |
| a display is unplugged while a workspace is parked on it | the recorded frame names a display that is gone | Phase 4 |

The last stranding row is the residual, and it has no answer in Phase 2.
Widening `rescue()` to treat a few points of visible area as debris would close
it; that is deliberately not done here, because Phase 4 already owns the
neighbouring case — a display going away unparks whatever is parked on it — and
this phase changes no shipped command's behaviour.

## Configuration

```toml
[general]
workspaces = "virtual"     # default since 0.9.12 — every [[space]] is a workspace on the anchor desktop
# workspaces = "native"    # one workspace per macOS desktop, the behaviour before 0.9.12
workspace-anchor = 1       # which desktop hosts them, by Mission Control ordinal
```

Both keys are in Settings › Workspaces, which also shows which mode the running
engine is in, and the anchor picker only offers desktops that exist.

An existing config works unchanged: eight `[[space]]` labels become eight
workspaces, the `alt-1`…`alt-9` and `alt-i`/`alt-c`/`alt-b` keybinds keep
meaning what they meant, and `[[rule]] space = "term"` keeps placing windows.

Two things get better on their own under `virtual`:

- `follow-space-rules` can default to **on**. It is off today because a
  rule-driven move costs two visible desktop switches for a window that merely
  opened; at 0.2 ms there is nothing to defend against.
- `sticky` starts working. It has never worked — the WindowServer accepts the
  tag from an ordinary connection and drops it (S8) — and as weft's own state
  it is simply "a window that is never parked".

## The default

0.9.12 made `virtual` the parser's default. Upgrading must not change what
`alt-2` means under someone, so the three installers run

```sh
weftctl config pin-workspaces native
```

on the "kept your existing weft.toml" branch and after a yabai migration. It
writes `workspaces = "native"` into `[general]` only when the key is absent,
through the same comment-preserving `TomlDocument` Settings uses, and does
nothing at all when there is no file. A fresh install copies
`examples/weft.toml`, which says `virtual`. Setup's two workspace pages end in
a mode chooser that runs the same command, and they stay reachable afterwards
from the menu's **How Weft Works…**.

Four defects had to go before the flip was safe:

- **Changing mode stranded windows.** A reload never diffed `workspaces` or
  `workspace-anchor`, so virtual → native left every hidden workspace parked
  with no verb to bring it back — `rescue()` cannot see a parked window, see
  above. A reload that changes either key now unparks everything and calls
  `SpaceState.resetWorkspaces()`, so the next sweep re-seeds from `[[space]]`.
  Trees are lost; the workspace set is being rebuilt, so that is correct.
- **The window switcher labelled every anchor window alike.** Every anchor
  workspace reports the anchor's space id, and a `[SpaceID: String]` map is
  last-wins. It now looks a window up in its own workspace's `windows` list.
- **`labels.json` ratcheted the count up.** `persistedNames()` writes one name
  per workspace, including one per non-anchor desktop, and the sweep fed that
  back as the anchor count: three labels, five workspaces, seven. With nothing
  declared the sweep now passes no anchor count, and `adoptDesktops` derives
  it as the exact inverse of `persistedNames()`.
- **An anchor past the last desktop clamped silently.** weftd logs it once,
  `query workspaces` reports the requested and the effective anchor, and
  `weftctl doctor` prints both.

Two smaller ones rode along: Settings wrote `follow-space-rules = false` on
every save, cancelling the mode-aware default — it now writes the key only once
the toggle is touched — and a config with no `[general]` table never reached
that default at all.

## Migration

weft does not move anyone's windows. Turning on `virtual` creates the
workspaces on the anchor desktop; windows already scattered across other
desktops stay where they are until they are moved, and each keeps being tiled
on the desktop it is on. Moving one across is the carry, once, with today's
limits — and for a window the carry cannot hold, Mission Control's own drag
works on any window because it drags the thumbnail rather than the title bar.
It converges after one pass, and a `[[rule]]` places the window instantly from
then on.

## Phases

Each is shippable and reversible on its own.

0. **Spike.** Done — S9.
1. **`Workspace` as a pure-core type**, with the identity mapping: one
   workspace per desktop. No behaviour change, no new config. **Done** — see
   the Model section above. It landed in four commits: the seam and the type
   unused, the layout and label re-key, the override and `recent`, and this.
   Two things came out of it. A vanished desktop used to lose its label but
   keep its layout, because the cleanup was split across two functions that
   each knew half of what had happened; `adoptDesktops` now owns both. And the
   wire is deliberately unchanged — `query spaces` and `query bar-state` still
   report native space ids, because weft-bar decodes them as `UInt64` and hands
   them straight back to `space focus`.
2. **Park and unpark in `WeftPlatform`**, with the crash-safe ledger. **Done**
   — see the Park and unpark section above. Three commits: the file format,
   the two moves, and the startup unpark. Two things came out of it. `weftctl
   rescue` turns out **not** to be "already there for the rest": it cannot see
   a parked window at all, because the point of itself that a parked window
   keeps on screen is the same point `rescue()` reads as "this window is on a
   display". And a ledger entry needs to record the corner as well as the
   frame, because a recycled window id otherwise gets dragged to a dead
   window's place.
3. **Many workspaces on one desktop**, behind `workspaces = "virtual"`.
   `space focus` and `space move-window` resolve to a workspace first and a
   desktop second. **Done.**
4. **The interactions.** Focus landing on a parked window — ⌘-Tab, a Dock
   click, `app toggle` — shows its workspace; this hooks into `focusChanged`,
   which is already one function. Borders are never drawn on a parked window.
   Divider zones and mouse hit-testing see the active workspace only. A display
   going away unparks anything parked on it. **Done.**
5. **Nothing is deleted.** `DragMove`, `DockSwipe` and `SpaceShortcut` stay,
   because native desktops stay supported and a cross-desktop move still needs
   them. That is the price of the mixed model rather than AeroSpace's, and it
   is worth paying: it is also the only reason Mission Control and native
   fullscreen keep working.

## Risks

- **The anchor desktop's Mission Control.** The residual cost, and the one
  thing this design cannot fix. Hidden windows show as slivers.
- **A long park.** If Electron throttles rendering to nothing after an hour off
  screen, showing a workspace could mean a visible repaint stall. It became the
  default in 0.9.12 with the one-hour soak still to be run on a release build;
  a stall found there is a finding against the default.
- **The crash window.** Closed in Phase 2: the ledger is written and fsynced
  before anything moves, and a write that fails moves nothing. What is left is
  a crash while parked with `parked.json` itself gone, which nothing can
  recover from — see the table above.
- **Two sources of truth for membership.** SLS for the desktop, weft for the
  workspace. Every bug in this design will live in that seam. It is one pure
  function with seven tests, two of which describe several workspaces on one
  desktop — a configuration nothing creates yet, so that the rule is already
  right when something does.
