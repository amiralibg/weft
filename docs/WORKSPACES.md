# Workspaces — weft's own, inside macOS's

**Status:** plan. Nothing here is built. S9 in `spikes/RESULTS.md` establishes
that the mechanism works; this says what to build on it.

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

```swift
typealias WorkspaceID = UInt32          // weft's own, stable within a launch

struct Workspace {
    var id: WorkspaceID
    var label: String
    var desktop: SpaceID                // the native Space it lives on
    var display: String
    var layout: SpaceLayout             // .tiling(Tree) / .float(FloatState), unchanged
}
```

`SpaceState.layouts: [SpaceID: SpaceLayout]` becomes
`[WorkspaceID: Workspace]`, plus `active: [SpaceID: WorkspaceID]` — which
workspace is showing on each desktop.

**Membership has two owners, and the split is the whole design.** SLS says
which *desktop* a window is on; that is macOS's fact and stays authoritative.
weft says which *workspace within that desktop*; that is weft's own state. The
reconciliation rule is one sentence: **a window whose desktop changed under us
joins the active workspace of the desktop it arrived on.** That covers a user
dragging a window in Mission Control, a rule relocating one, and an app opening
a window wherever it likes.

## Park and unpark

```
park(wid)   SLSMoveWindow(cid, wid, bottomRightOf(display))
unpark(wid) SLSMoveWindow(cid, wid, itsTileFrame)
```

Both pure WindowServer, ~0.2 ms, and the application is never told — which is
what makes it uncloseable to clamping. S4's nudge caveat does not bite: a park
and an unpark that both go through `SLSMoveWindow` leave the app's own idea of
its position untouched throughout, so it is consistent again the moment the
window is back. AX is needed only when the layout actually changed while the
workspace was hidden, and that is the ordinary `applyFrames` path.

## Configuration

```toml
[general]
workspaces = "native"      # default — today's behaviour, one workspace per desktop
# workspaces = "virtual"   # every [[space]] becomes a workspace on the anchor desktop
# workspace-anchor = 1     # which desktop hosts them, by Mission Control ordinal
```

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
   workspace per desktop. No behaviour change, no new config, every existing
   test still passing. This is the large, boring, safe refactor and it is most
   of the work.
2. **Park and unpark in `WeftPlatform`**, with the crash-safe ledger: every
   park writes `{wid: real frame}` to disk before it moves anything, and
   startup unparks whatever the ledger holds before the first sweep. `weftctl
   rescue` already exists for the rest.
3. **Many workspaces on one desktop**, behind `workspaces = "virtual"`.
   `space focus` and `space move-window` resolve to a workspace first and a
   desktop second.
4. **The interactions.** Focus landing on a parked window — ⌘-Tab, a Dock
   click, `app toggle` — shows its workspace; this hooks into `focusChanged`,
   which is already one function. Borders are never drawn on a parked window.
   Divider zones and mouse hit-testing see the active workspace only. A display
   going away unparks anything parked on it.
5. **Nothing is deleted.** `DragMove`, `DockSwipe` and `SpaceShortcut` stay,
   because native desktops stay supported and a cross-desktop move still needs
   them. That is the price of the mixed model rather than AeroSpace's, and it
   is worth paying: it is also the only reason Mission Control and native
   fullscreen keep working.

## Risks

- **The anchor desktop's Mission Control.** The residual cost, and the one
  thing this design cannot fix. Hidden windows show as slivers.
- **A long park.** If Electron throttles rendering to nothing after an hour off
  screen, showing a workspace could mean a visible repaint stall. Phase 3 needs
  a soak before it is a default.
- **The crash window.** Between a park and the ledger write there is no state
  on disk. Write the ledger first, always, and accept a stale entry over a
  stranded window.
- **Two sources of truth for membership.** SLS for the desktop, weft for the
  workspace. Every bug in this design will live in that seam; the
  reconciliation rule above is deliberately one sentence so it can be held in
  the head and tested directly.
