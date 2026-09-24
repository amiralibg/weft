# Redesign — weft owns workspaces, macOS owns nothing weft needs

**Status:** Proposal, 2026-09-23, against 0.9.12. Supersedes the "nest, do
not replace" decision in `WORKSPACES.md`. Phase 1 shipped in 0.9.13, phase 2 in
0.9.14, and phases 3 onward land together in 0.9.15.

## Requirements

1. **Switching to a workspace and moving a window to one always work.** They
   work for every window, from anywhere, instantly.
2. **No SIP, no scripting addition, no system hacks.** Install, grant
   Accessibility and Input Monitoring, and everything works.
3. **A macOS update may make weft slower, but it must never break tiling,
   workspaces, or launching.**
4. **No measurable cost when idle, and fast under load.**
5. **Multiple displays work well.** This includes plugging a display in or
   out, sleep and wake, mixed resolutions and the notch.
6. **Extra macOS desktops never break weft.** Neither do Mission Control,
   swipes, or apps that jump desktops.
7. **Native fullscreen works well with weft.** That includes Split View,
   borderless-fullscreen games and video players, and macOS's own window
   tiling.
8. **Settings has a clear visual editor for workspaces.** Users arrange
   workspaces, displays and apps by looking at them, without writing TOML.

## Why the current design cannot be fixed in place

0.9.11 added virtual workspaces and 0.9.12 made them the default. On a real
machine they still do not move windows to their workspace, and switching or
moving often does nothing. These are not bugs in the new layer. They come
from the design.

1. **Virtual mode is still native mode for most desktops.** `adoptDesktops`
   (`Sources/WeftCore/Spaces.swift`) puts the `[[space]]` workspaces on the
   anchor desktop, then gives **every other desktop its own workspace**. A
   window on desktop 3 is in desktop 3's workspace. Sending it to `term` goes
   through `moveWindow` → `SpaceControl.moveWindowToSpace` → `DragMove`, the
   title-bar carry. Focusing `term` from desktop 3 goes through `DockSwipe` or
   ⌃N. The fragile layer is still there, with a second layer on top.
2. **Windows already on other desktops are never gathered.** "weft does not
   move anyone's windows" (WORKSPACES.md, Migration).
3. **Only tiled windows are parked.** `switchWorkspace` parks
   `layout.windows`. Manual floats, rule-unmanaged windows and quirk windows
   are left out of the layout, so they appear on every workspace.
4. **Moving a window between native desktops has no supported route without
   SIP.** S8: sixteen SkyLight routes refused. What is left is simulated input
   (hold the title bar and press the user's space shortcut). That fails
   without a title bar, without the shortcut bound, when an AX write lands
   mid-drag, and whenever Apple changes drag or Dock behaviour.
5. **Switching native desktops depends on a private gesture payload.**
   `DockSwipe` works on 26.6 and later, and the ⌃N fallback is off on a stock
   Mac. yabai breaking on 27 is this kind of dependency.
6. **One missing symbol stops the daemon from launching.** `SkyLightShim.h`
   declared 28 private functions as strong `extern`s, linked with
   `-framework SkyLight`. If Apple removed any one of them, dyld refused to
   load `weftd`. (Fixed in 0.9.13, phase 1.)
7. **Two Settings panes describe one thing in two models.** "Workspaces" and
   "Desktops" each explain a mode, an anchor, and how names map to desktops.
   The editor is a list of rows. It has no picture of displays or of where
   anything goes.

## The decision: one managed desktop per display

weft keeps its own workspaces on **one native desktop per display**, the way
AeroSpace does. S9 already showed that parking works for every kind of app
tried, including the terminal the carry cannot move.

| | owner | weft's relationship |
| --- | --- | --- |
| **Workspace** | weft | the only kind of "space" weft switches, moves windows to, and labels |
| **Managed desktop** | macOS | one native desktop per display, where weft tiles. weft records it and never switches it |
| **Other desktops, fullscreen spaces** | macOS | weft pauses on that display. It does not tile, park or move anything there, and it never switches to them |

What the user gives up, stated plainly:

- **Mission Control on the managed desktop shows hidden windows as small
  slivers.** Same cost as AeroSpace. It cannot be fixed.
- **weft no longer moves windows between native desktops or switches between
  them.** Those were the features that could not meet requirement 2.
- `workspaces = "native"` and `workspace-anchor` go away. There is one mode.

## Model

```swift
struct Workspace {
    var id: WorkspaceID
    var label: String
    var members: Set<WindowID>     // every window in it: tiled, floating, unmanaged
    var layout: SpaceLayout        // arrangement of the tiled subset only
    var overrideKind: LayoutKind?
    var pin: DisplayMatcher?       // from [[space]] display = …
}

enum DisplayState { case active, paused(PauseReason) }
enum PauseReason { case otherDesktop, fullscreen, locked }

struct WorldState {
    var workspaces: [WorkspaceID: Workspace]
    var order: [WorkspaceID]                    // config order; alt-N counts this
    var displays: [DisplayKey: DisplayRecord]   // keyed by stable key, see below
    var focusedDisplay: DisplayKey
    var hidden: Set<WindowID>                   // mirrors the park ledger
    var fullscreen: [WindowID: FullscreenMemo]  // where to put it back
}

struct DisplayRecord {
    var shown: WorkspaceID                      // always one
    var managedDesktop: SpaceID?                // recorded, never switched
    var state: DisplayState
    var parkCorner: Corner?                     // nil = no free corner, see below
}
```

The key change is **membership separate from layout**. Today a window is in a
workspace only if it is in the layout, which is why floats leak (defect 3).
`members` is what gets hidden and shown. `layout` only decides where the tiled
members go.

- A new window joins the workspace shown on the display it opened on, unless
  a `[[rule]]` names another workspace. If that workspace is hidden, the
  window is hidden right away.
- A window leaves a workspace only when it closes or is moved. Its native
  desktop is not a fact membership depends on.
- A `sticky` window belongs to no workspace and is never hidden.

## Multiple displays

**Identity.** A display is keyed by `CGDisplayCreateUUIDFromDisplayID`, which
is public and stable per monitor across reboots and replugs, not by
`CGDirectDisplayID` or index. `labels.json`-style persistence stores the
last-shown workspace per display UUID, so a replugged monitor comes back
showing what it showed before.

**Which workspace shows where.**

- Each display shows exactly one workspace. A workspace shows on at most one
  display.
- `[[space]] display = "main" | "secondary" | "<name contains>" | N` pins a
  workspace. A pin to a display that is not connected falls back to the main
  display until that display returns.
- `space focus X`, when X is pinned, shows X on its display and focuses that
  display. When X is unpinned, it shows X on the **focused** display. If X is
  already showing on the other display, focus moves there. Nothing is
  swapped, because a swap moves windows the user was not asking about.
- `space move-window X` from display A to a workspace showing on display B is
  an AX frame write. The window is re-tiled into B's rect and the focus stays
  or follows as asked. It uses public API only, and today's
  `moveAcrossDisplays` already does it.
- `focus display <dir>` / `move display <dir>` stay geometric (DESIGN §14.7).

**Where hidden windows go.** A parked window keeps a sliver on screen (S9),
and macOS assigns a window to whichever display holds most of it. So each
display needs a corner where the sliver does not overlap, and is not next to,
another display. For each display weft picks the first free corner in the
order bottom-right, bottom-left, top-right, top-left, and records it in
`parkCorner`. When a display has no free corner, such as a middle monitor
with neighbours on both sides and above, weft parks its hidden windows at
the free corner of another display and moves them back on show. That costs one
extra frame write per window, and nothing is lost. The Settings canvas marks
the chosen corner on each display, and `doctor` reports any display with no
free corner of its own.

**Display changes** (plug, unplug, clamshell, sleep and wake, resolution,
arrangement):

- One coalesced handler for `CGDisplayRegisterReconfigurationCallback` and
  `NSApplication.didChangeScreenParametersNotification`, run once the storm
  settles (the callback fires several times per change). It rebuilds
  `displays` and recomputes the park corners and usable rects from
  `NSScreen.visibleFrame`, which accounts for the menu bar, the notch and a
  visible Dock.
- **Unplug:** the gone display's shown workspace moves to the main display
  as a hidden workspace, and its windows are re-parked at the new corner.
  Nothing is left stranded at a corner that no longer exists.
  WORKSPACES.md's "display unplugged while parked" row closes.
- **Replug:** pinned workspaces and the last-shown workspace go back to that
  display by UUID.
- **Wake:** displays can come back one at a time. Changes are applied only
  after the set has been stable for 500 ms, so windows are not moved twice.
  This is the one place a delay is allowed, and it is event-triggered, not a
  timer.

**"Displays have separate Spaces."** Supported on (the default) and off.
Off, macOS has one desktop across all displays. weft still gives each display
its own shown workspace, and the only difference is that the managed desktop
is shared. It is read from the public `com.apple.spaces` `spans-displays`
preference and shown in `doctor`, and weft does not ask the user to change it.

## Other macOS desktops

Extra desktops are allowed and never cause errors. weft pauses on them.

- **Detection:** `NSWorkspace.activeSpaceDidChangeNotification` (public)
  starts a check per display: is that display's managed desktop still the one
  showing? The T1 path is `SLSManagedDisplayGetCurrentSpace`. The public path
  checks whether any of the managed desktop's windows, parked ones included,
  are still in `CGWindowList .optionOnScreenOnly`. Parked windows keep a
  sliver on screen, so an empty managed desktop still has a signal unless it
  truly has no windows. In that case weft places a 1×1 transparent marker
  window of its own there, and that covers the gap.
- **While paused on a display:** no tiling, parking or border on that
  display. Windows that open there are left alone. Keybinds that act on
  workspaces still work, and they act on the paused display's workspace
  state, which is applied when the managed desktop is back. The bar shows the
  display as paused. Commands answer "paused: another macOS desktop is
  showing", and do not fail silently.
- **Coming back** re-checks every member's frame once and re-applies the
  layout.
- **Windows the user drags into the managed desktop** in Mission Control join
  the shown workspace. Windows dragged out stay members, but are treated as
  "elsewhere" (not tiled, not hidden) until they come back.
- **`AppleSpacesSwitchOnActivate`** (the setting "When switching to an
  application, switch to a Space with open windows") is fine either way. A
  parked window is on the managed desktop, so ⌘-Tab to it never jumps
  desktops, and weft shows its workspace (Phase 4 hook, unchanged).
- **The managed desktop is deleted** in Mission Control. macOS moves its
  windows, parked ones included, to a neighbouring desktop. weft adopts the
  display's current desktop as the new managed desktop, keeps membership, and
  unparks whatever the ledger says is hidden but should be shown. No window is
  lost, because the ledger does not care which desktop a window is on.
- weft never creates, deletes, reorders or switches native desktops. It does
  not change "Automatically rearrange Spaces"; the managed desktop is
  recorded by Space id, not by position.

## Fullscreen and macOS's own window features

**Native fullscreen** (green button, ⌃⌘F):

- **Entering:** weft sees `kAXFullScreen` become true on the window, from AX
  observers on `AXResized`/`AXMoved` plus a read of the attribute (public). The
  window **stays a member** of its workspace, but leaves the layout. The
  remaining windows re-tile. weft stores a `FullscreenMemo`: its workspace
  and its place in the tree.
- **The fullscreen Space** is "another desktop" to weft, so that display
  pauses. Other displays are not affected.
- **Never park a fullscreen window.** Switching away from a workspace whose
  member is fullscreen leaves that window in its own Space.
- **Exiting:** the window returns to the managed desktop. weft puts it back
  into its old workspace, in its old slot if the tree still has that
  neighbour, or appends it otherwise. If that workspace is hidden, the exit
  was the user's own action on that window, so weft shows the workspace.
- **Split View** (two apps in one fullscreen Space) is two fullscreen windows,
  handled by the same rules.

**weft's own `fullscreen` command** (zoom within the tiled rect) is a layout
state, not a macOS Space. It stays as it is.

**Borderless fullscreen** (games, video players, some Electron apps): a window
whose frame equals its display's full frame (not the visible frame) floats
automatically, gets no border, and is never re-tiled while it stays that
size. When it shrinks, it rejoins the layout.

**macOS window tiling** (drag to screen edge, Fn-⌃-F, "Fill"): this conflicts
with weft, because both try to size the same window. weft reads the
`com.apple.WindowManager` preferences (public defaults; Stage Manager's
`GloballyEnabled` is already read in `SystemChecks.swift`) and shows each
conflicting one in Setup and in the Settings canvas, with a button that
opens the right pane of System Settings. weft does not write these settings.
**Stage Manager** pauses weft, as it does today.

## Settings: the workspace editor

The "Workspaces" and "Desktops" panes merge into one **Workspaces** pane.
There is only one mode now, so there is no mode chooser, no anchor, and no
"names follow Mission Control order". It is built around a picture.

```
┌─ Workspaces ─────────────────────────────────────────────────────────┐
│                                                                      │
│   ┌───────────── Studio Display ─────────┐ ┌── Built-in ────┐        │
│   │ ● web                    ⌥3   ▦ bsp  │ │ ● term  ⌥I     │        │
│   │ [Zen] [Safari]                       │ │ [Ghostty]      │        │
│   │                                  ◢   │ │            ◢   │        │
│   └──────────────────────────────────────┘ └────────────────┘        │
│                                                                      │
│   Pinned to Studio Display   code ⌥C   design ⌥7                     │
│   Pinned to Built-in         (none)                                  │
│   Any display                main ⌥1   chat ⌥2   ai ⌥5   + Add       │
│                                                                      │
│   ⚠ 2 extra macOS desktops — weft pauses there.        [Why?]        │
│   ⚠ "Drag windows to screen edges to tile" is on.      [Open…]       │
└──────────────────────────────────────────────────────────────────────┘
```

- **The canvas** draws the real display arrangement from `NSScreen` frames,
  to scale, with names from `NSScreen.localizedName`. Each display shows the
  workspace currently on it when the engine is running, with live app icons
  from `query bar-state`. The free park corner is marked `◢`, and a display
  with no free corner is marked in orange.
- **Workspace chips**, one per `[[space]]`, grouped by where they are pinned.
  **Drag a chip onto a display** to pin it, and onto "Any display" to unpin
  it. **Drag to reorder**: the order is what ⌥1…⌥9 count, and the chip shows
  the shortcut it has right now.
- **Select a chip** to open its inspector:
  - name, edited inline;
  - layout (`bsp` / `float`) with a miniature drawn by the existing
    `DesktopPreview`, so it shows this user's gaps and borders;
  - **apps:** drag an app from a list of running and installed apps, or from
    the Finder, onto the chip, which writes `[[rule]] app = … space = …`.
    Remove it with ⌫. An app claimed by two workspaces is flagged, not saved
    twice;
  - shortcuts: focus and move-window binds for this workspace, shown and
    editable in place. Rebinding here writes to `[keybinds]`, the same keys
    the Shortcuts pane edits.
- **Live mode**, when the engine is running: clicking a chip does
  `space focus`, and dragging an app icon from one live workspace to another
  does `space move-window`. The editor doubles as a way to check that the
  config does what it looks like it does.
- **Warnings are shown in the picture where they apply**, not in a list:
  extra macOS desktops on a display, no free park corner, "Displays have
  separate Spaces" state, macOS edge-tiling on, and Stage Manager on.
- **Saving** goes through `TomlDocument`, which keeps comments, as all of
  Settings does. The pane only writes `[[space]]` (`label`, `layout`,
  `display`), `[[rule]] … space =`, and the workspace keybinds. Everything
  else in the file is left byte-for-byte as it was.
- Setup's two workspace pages become one page that shows the same canvas
  read-only, with the user's real displays in it.

Config additions: `[[space]] display = …`. That is the only new key.

## Platform budget

Every feature gets a public path. Private API is allowed only as a checked
speed-up (T1). Anything else is forbidden.

| Feature | Public path (always there) | T1 speed-up, checked at launch |
| --- | --- | --- |
| Find windows | `CGWindowListCopyWindowInfo` + AX per-app `kAXWindows` | `SLSCopyManagedDisplaySpaces` |
| Window id ↔ AX element | match pid + frame + title | `_AXUIElementGetWindow` (every Mac WM uses it; AeroSpace's only private call) |
| Read a frame | `CGWindowList` bounds | `SLSGetWindowBounds` |
| Set a frame | AX position/size | — |
| **Hide / show** | AX position to the display's park corner | `SLSMoveWindow`, only if the launch self-test passes |
| On this desktop? | `CGWindowList .optionOnScreenOnly` (already trusted, S8) | — |
| Managed desktop showing? | onscreen check + marker window | `SLSManagedDisplayGetCurrentSpace` |
| Native fullscreen | `kAXFullScreen` | `SLSSpaceGetType` |
| Focus events | AX observers, `NSWorkspace.didActivateApplication` | — |
| Displays | `NSScreen`, `CGDisplayCreateUUIDFromDisplayID`, reconfiguration callback | — |
| Borders | `NSPanel` overlay, click-through | the current SLS renderer |
| Corner radii | fixed config value | `SLSWindowIterator…CornerRadii` |
| Keybinds | `CGEventTap` | — |

**Forbidden:** writing a foreign window's Space, synthetic Dock gestures,
event choreography (drag + shortcut), scripting another app's menus, writing
system preferences, and any symbol linked strongly.

Two mechanics make the table hold up across updates:

- **All private symbols are resolved with `dlsym`**, as `WindowCorners.swift`
  already does. `SkyLightShim.h` loses its strong externs and nothing links
  `-framework SkyLight`. A missing symbol turns off one speed-up. It cannot
  stop the launch.
- **Each T1 speed-up has a self-test at launch** that checks behaviour, not
  return codes (S6 and S8 both showed rc lies here). Example: park a 1×1
  weft-owned window, read the bounds back, and unpark. The result is cached
  per macOS build, reported by `weftctl doctor`, and decides which path the
  process uses. **One path per launch**, so a window is never hidden by SLS
  and shown by AX. That mix is the S4 desync.

## Hide and show

Same crash-safe ledger as today (`ParkLedger.swift`, write before move, and
the `parkedAt` check). It stays. What changes:

- **What:** `members` minus fullscreen windows, not `layout.windows`.
- **Where:** the display's `parkCorner`, or a neighbour's corner (see
  Multiple displays).
- **How, public path:** AX `setPosition`, in parallel across pids on the
  existing per-pid queues, so a switch costs about as much as the slowest
  app, not the sum. S9 measured 30 ms per window one at a time. If this misses
  the budget on a real 30-window session, the self-test enables SLS. It is
  never the only path.
- **Show:** unhide, then one `applyFrames` for the tiled members, as one
  `SLSTransaction` on T1, or AX otherwise.

## Performance

Budgets, measured by `weftctl bench` and written in the release checklist:

| | budget |
| --- | --- |
| idle CPU, `weftd` | 0.0% over 60 s with nothing happening; no timers armed |
| workspace switch, 20 windows / 6 apps | < 60 ms public path, < 10 ms T1 |
| move window to workspace | < 30 ms (same display), < 60 ms (other display) |
| new window to tiled | < 50 ms from `kAXWindowCreated` |
| display plug/unplug settled | < 1 s after the reconfiguration storm ends |
| memory, `weftd` | < 40 MB resident after 8 h |
| Settings canvas | redraws only on config, display or bar-state change |

Rules that keep them:

- **Event-driven only.** Sweeps run in response to AX, NSWorkspace or display
  events, coalesced into one pass per run-loop turn. Most of the `asyncAfter`
  settle delays in `weftd/main.swift` exist to deal with native desktop
  switches, and they go with that layer.
- No AX call on the core queue (DESIGN §13.2).
- The paused state is cheap. While a display is paused, weft does no work
  for it beyond the one check per space-change notification.
- A switch writes to the ledger twice. Measure the fsyncs. If they dominate,
  batch park and unpark into one write.

## What gets deleted

About 1,400 lines in the platform layer, plus their callers:

- `DragMove.swift` (517), `DockSwipe.swift` (226), `DockSwipePayload.swift`
  (112), `SpaceShortcut.swift` (99), most of `SpaceControl.swift` (483).
- `checkSpaceChanged`, `startSpaceWatch`, `scheduleSpaceRechecks`, every
  `DragMove.isCarrying` guard, the symbolic-hotkey reader, the ⌃N fallback
  and its error messages.
- The native branch of `adoptDesktops`, `workspace-anchor`, `pin-workspaces`,
  the mode chooser, and the separate Desktops pane.
- The declarations for `SLSMoveWindowsToManagedSpace`, `SLSSetWindowTags`
  and the other Space writes S8 showed do nothing from an ordinary
  connection, plus `SLSSpaceSetCompatID`/`SLSSetDisplaySpaceCompatID` if
  nothing is left using them once `DockSwipe` goes.

## Migration

- On first launch, windows on non-managed desktops are **left there**. The
  user put them there. Setup and the canvas say once that weft pauses on
  extra desktops.
- `workspaces = "native"` and `workspace-anchor` are read, ignored, and noted
  once in the log. `weftctl config migrate` removes them.
- `[[space]]` labels, keybinds and rules keep their meaning. `alt-3` is still
  the third workspace.

## Phases

Each phase can ship on its own as the next 0.9.x release.

1. **Symbols by `dlsym`, with self-tests.** No behaviour change. It removes
   the "an update stops weftd from launching" risk immediately. `doctor` lists
   each speed-up and whether it passed. **Done in 0.9.13:**
   - `SkyLightShim.h` declares each of the 28 private symbols with
     `WEFT_PRIVATE_FN`: a pointer filled by `SkyLightShim.c` before `main`,
     and an inline wrapper with the symbol's own name, so no Swift call site
     changed. A missing symbol returns `kCGErrorNotImplemented`, 0, NULL, or
     does nothing, and every call site already handled that as a failed call.
   - Nothing links `-framework SkyLight`. CI and the release job both reject a
     binary that does.
   - `PrivateAPI.selfTest()` checks the connection, the display topology, and
     reading, moving and transaction-moving a 1×1 window of weft's own that is
     never shown. It takes a few milliseconds. `weftd` logs the result as its
     second line, `weftctl doctor` runs it fresh, and `Parker.park` refuses
     with `.unsupported` when the move check failed.
   - Not done: caching the result per macOS build. It costs less to run the
     test than to read a cache.
2. **Membership separate from layout.** Floats and unmanaged windows hide
   with their workspace. Fixes defect 3 on the current code. **Done in
   0.9.14:**
   - `Workspace.loose` holds members that are not laid out: floated by hand,
     `manage = false` rules, quirk strikes, and apps weft always floats.
     `members` is the layout's windows, then the loose ones.
   - The sweep reconciles both kinds together against `members`, so a window
     keeps its workspace across float and tile, and a float in a hidden
     workspace stays in it. Panels and popovers are still in no workspace:
     a menu-bar extra's popover is not the workspace's to hide.
   - `SpaceState.file(_:in:laidOut:)` is the one way a command moves a window
     between workspaces. It is used by `space move-window`, moves to another
     display, rule placement and `float toggle`, so a float that is sent
     somewhere arrives floating instead of being tiled by the move.
   - Switching parks and unparks `members`. Focusing a float in a hidden
     workspace (⌘-Tab, the switcher) shows that workspace and focuses the
     float. `query spaces` and `query bar-state` list floats under their
     workspace.
3. **One mode, one managed desktop per display.** Delete the native-desktop
   layer. Space focus and move are state plus hide/show. Add the paused state
   for other desktops. This is the release that fixes switching and moving. **Done for 0.9.15:**
   - `adoptDisplays` replaces `adoptDesktops`: each display gets a managed
     desktop (kept while it exists, never a fullscreen space), workspaces are
     never deleted when a display or desktop goes — they rehome — and every
     managed desktop always has a workspace, preferring one that costs no
     window moves.
   - `reconcileWorkspaces` follows the rule in "Model": membership is weft's,
     a window on no managed desktop is in no workspace, a window dragged to
     another display joins what shows there, and windows weft is moving
     (`inFlight`) keep their workspace.
   - `space focus` shows a hidden workspace on the focused display, or moves
     focus to the display already showing it. `space move-window`, `move
     display`, rules and `app toggle` are state plus a park or a frame write.
     `move space display` works, as a swap. `sticky` works: a window in no
     workspace. A paused display refuses workspace commands with a message
     that says which desktop to go back to.
   - Numbered workspaces are created on first use (`space focus 4`), so the
     shipped `alt-1…5` binds work with no `[[space]]` blocks.
   - Membership persists across restarts in `membership.json`, stamped with
     the boot time because window ids are reused after a reboot. The first
     sweep re-files every window and parks the hidden workspaces again.
   - Deleted: `DragMove`, `DockSwipe`, `DockSwipePayload`, `SpaceShortcut`,
     `ScriptingAddition`, the desktop-switching half of `SpaceControl`, the
     3-second space-watch timer, `workspaces`/`workspace-anchor` (now warned
     and ignored; `weftctl config tidy` removes them), and two private
     symbols nothing calls any more.
4. **Displays and fullscreen.** Display keying by UUID, park corners, the
   coalesced reconfiguration handler, unplug and replug behaviour,
   `[[space]] display =`, `FullscreenMemo`, borderless-fullscreen floating,
   and the edge-tiling check. **Done for 0.9.15:**
   - `freeCorner` picks, per display, the first corner (bottom-right,
     bottom-left, top-right, top-left) whose park zone — the display's own
     size outward from the corner — covers no other display. A display with
     none parks at another display's free corner. `Parker.park` takes the
     corner and computes each window's spot from its own size;
     `unparkOutside` now asks whether the parked window still overlaps a
     display rather than whether its origin is on one.
   - `[[space]] display = "main" | "secondary" | N | "name"` pins a
     workspace; `space focus` shows a pinned workspace on its display, and a
     display with nothing to show takes a workspace pinned to it first.
   - `SpaceState.lastShown`: a display plugged back in shows what it showed.
   - Display reconfiguration is handled once the storm has been quiet for
     500 ms; afterwards every hidden workspace is parked again at the corners
     the new arrangement leaves free. A float whose saved frame is on no
     display comes to the middle of the display showing it.
   - Native fullscreen: a window that goes fullscreen is remembered with its
     workspace (`fullscreenMemo`) and goes back into it when it returns; a
     hidden workspace is shown. Borderless fullscreen — a window covering its
     display and the showing menu bar — floats until it is window-sized.
   - `weftctl doctor` reports each display's name, corner, and paused state,
     macOS's own edge tiling when it is on, and "Displays have separate
     Spaces" when it is off. `query workspaces` carries names and corners for
     the Settings canvas.
   - Not done: returning a fullscreen window to its exact old slot (it is
     re-inserted like a new window), and measuring corners on real
     two- and three-display arrangements — still first in "Still to measure".
5. **The Workspaces canvas.** The merged pane, drag to pin and reorder, the
   inspector, app rules by drag, live mode, and the warnings in place. It
   needs phase 4's `display =` key and nothing else, so it can be built in
   parallel with phase 4.
6. **Public-path parity.** AX hide/show in parallel, `NSPanel` borders, and
   the marker window. Run the whole daemon with `WEFT_PUBLIC_ONLY=1` and check
   that nothing is missing, only slower.
7. **Budgets in the release checklist**, plus `weftctl doctor --selftest`,
   which the maintainer runs on each macOS beta before it ships.

## Still to measure

Each one is a spike before the phase that depends on it.

- **Park corners with two and three displays** (phase 4). Does a sliver in a
  free corner stay on its own display, including with "Displays have separate
  Spaces" off? The whole multi-display design depends on this, and only one
  display has been tested (S9).
- **Fullscreen exit timing** (phase 4). How long after `kAXFullScreen` turns
  false does the window report the managed desktop and accept a frame? A
  write that arrives too early is dropped.
- **AX hide/show at scale, in parallel** (phase 6). 30 windows across 10
  apps. Decides whether T1 hiding is optional or required.
- **Long parks.** One hour for Electron and a browser, the soak WORKSPACES.md
  lists as still to be run. It matters more now, since every workspace but one
  per display is parked.
- **Public-only managed-desktop detection** (phase 6). Does the onscreen check
  plus marker window hold up through swipes, Mission Control and fullscreen,
  without `SLSManagedDisplayGetCurrentSpace`?
- **`NSPanel` borders against foreign windows** (phase 6). If a public window
  cannot stay just above the focused window, public-path borders are drawn
  only for the focused window, which is frontmost anyway.
