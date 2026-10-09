# Native Spaces — weft drives macOS's own desktops

**Status:** Approved 2026-10-09, against 0.9.21. Building waits only on the
spikes listed under "Spikes before building". Supersedes
`REDESIGN.md`'s "one managed desktop per display" and with it the virtual
workspace engine. Ships whole, as one release: **0.9.22**.

Evidence: `spikes/RESULTS.md` §S10 and §S11, harnesses `spikes/bridgedmove.swift`
and `spikes/nativeops.swift`.

## Problem Statement

weft keeps its workspaces on one macOS desktop per display and hides the
inactive ones by parking their windows at a screen corner. That works, but it
throws away the desktop model macOS users already know:

- Mission Control shows every workspace's windows as slivers on one desktop.
- The trackpad swipe and ⌃←/⌃→ move between macOS desktops that weft does not
  use, so they either do nothing useful or land somewhere weft pauses.
- Native fullscreen makes a Space weft can only pause on.
- Users have to learn a second, invisible set of "workspaces" that nothing
  else on the Mac knows about.

weft left native desktops for two reasons (`WORKSPACES.md`): macOS would not let
it move another app's window between desktops, and would not say reliably
which desktop was showing. The first is no longer true on macOS 27.0.1 (S10,
S11), and the second has an answer that does not depend on notifications.

## Solution

**A workspace is a macOS desktop.** weft tiles every desktop, switches between
them instantly from the keyboard, and moves any window — including one with
no title bar — to any desktop on any display in about 10 ms, without an
animation and without switching the user's desktop. Mission Control, the
swipe, ⌃←/⌃→ and native fullscreen all behave exactly as macOS intends,
because weft is driving macOS's own desktops rather than imitating them.

weft cannot create or delete desktops; the user does that in Mission Control,
and weft adapts to however many there are. When a macOS update takes away the
private routes this depends on, weft says so, keeps tiling every desktop, and
falls back to the next-best way to switch.

## What changed

| | before (S8, `WORKSPACES.md`) | now (S10, S11, macOS 27.0.1, SIP on) |
| --- | --- | --- |
| Move another app's window to a desktop | refused by 16 SkyLight routes; only the title-bar carry, which fails without a title bar | `SLSBridgedMoveWindowsToManagedSpaceOperation`, ~10 ms, 5 windows in 7 ms, cross-display too, user's desktop untouched |
| Frame after a cross-display move | — | follows: the window lands inside the target display |
| Lay out a desktop that is not showing | impossible: AX lists no windows there (S0) | an AX element captured earlier still takes frame writes, and the window stays hidden |
| Switch desktop | synthetic Dock swipe, one step at a time | `ShowSpaces` + `HideSpaces` + `ManagedDisplaySetCurrentSpace` through the bridge: one step to any desktop, 16–21 ms, no animation, Dock stays in sync |
| Create / destroy desktops | yabai needs a scripting addition | still impossible: the bridged create returns an id for nothing |
| Sticky windows | refused | still refused through the bridge |

The bridged operations go through two C++ statics in SkyLight that `dlsym`
cannot see — `SLSPerformAsynchronousBridgedWindowManagementOperation` and
`_SLSPerformSynchronousBridgedWindowManagementOperation` — found by walking
SkyLight's in-memory symbol table, as yabai 7.1.25 does.

## User Stories

Switching

1. As a weft user, I want ⌥N to show desktop N instantly, so that I keep weft's keyboard speed on real macOS desktops.
2. As a weft user, I want ⌥N to work for a desktop several positions away in one step, so that distance does not cost time.
3. As a weft user, I want the window I last used on a desktop to be focused when I switch to it, so that I can keep typing.
4. As a weft user, I want switching to an empty desktop to leave focus on that desktop rather than on a window elsewhere, so that my next keystroke does not go to a hidden app.
5. As a weft user, I want ⌥N for a desktop already showing on another display to move focus there without switching anything, so that nothing I was not asking about changes.
6. As a weft user, I want `space focus next` and `prev` to step through the focused display's desktops the way ⌃←/⌃→ do, so that weft and macOS agree on what "next" means.
7. As a weft user, I want `space focus recent` to flip between the two desktops I used last, across displays, so that back-and-forth is one key.
8. As a weft user, I want the trackpad swipe and ⌃←/⌃→ to keep working exactly as macOS ships them, so that I do not have to unlearn them.
9. As a weft user, I want weft to notice when I switch desktops by swipe, ⌃←/⌃→, Mission Control or ⌘-Tab, so that its idea of what is showing is never stale.
10. As a weft user, I want weft to leave windows alone while Mission Control is open, so that it never re-tiles under the overview.
11. As a weft user, I want a switch weft could not complete to fall back to another method and tell me, so that a failed switch never looks like a frozen keyboard.

Moving windows

12. As a weft user, I want `space move-window N` to send the focused window to desktop N without taking me with it, so that I can file windows away quickly.
13. As a weft user, I want `space move-window N --follow` to go with the window, so that I can still move and follow in one key.
14. As a Ghostty user with a hidden title bar, I want moving my terminal to another desktop to work, so that the window type no longer matters.
15. As a multi-display user, I want moving a window to a desktop on another display to land it on that display and tile it there, so that I do not have to drag it.
16. As a weft user, I want the destination desktop to be laid out before I switch to it, so that when I arrive the window is already in its tile.
17. As a weft user, I want `[[rule]] app = … space = …` to put a new window on its desktop as it opens, without switching me there, so that apps open where they belong.
18. As a weft user, I want windows I drag between desktops in Mission Control to be tiled where I dropped them, so that Mission Control is a valid way to organise.
19. As a weft user, I want a move that macOS refused to be reported, so that I never think a window moved when it did not.

Numbering and labels

20. As a weft user, I want desktop numbers to match Mission Control's left-to-right order, main display first, so that ⌥3 is the third desktop I can see in the overview.
21. As a multi-display user, I want the second display's desktops to continue the numbering after the first display's, so that every desktop has one number.
22. As a weft user, I want fullscreen apps' Spaces left out of the numbering, so that entering fullscreen does not shift every number after it.
23. As a weft user, I want my `[[space]]` labels to name desktops by position, so that "term" is still my third desktop after a reboot.
24. As a weft user, I want to be warned when "Automatically rearrange Spaces based on most recent use" is on, with a button that opens the setting, so that my numbers do not shuffle without my knowing why.
25. As a weft user, I want `space label` to rename the current desktop, so that I can name desktops from the keyboard.

Desktop count

26. As a weft user with fewer desktops than labels, I want ⌥7 to tell me desktop 7 does not exist and how to add one, so that a missing desktop is not a silent no-op.
27. As a weft user, I want desktops I have not labelled to work as numbered workspaces, so that I can add desktops in Mission Control and use them immediately.
28. As a weft user, I want weft to adapt when I add, remove or reorder desktops in Mission Control, so that I never have to restart it.
29. As a weft user, I want Settings to show labels that have no desktop yet, with a button that opens Mission Control, so that I can see what to create.

Fullscreen, all-desktop windows

30. As a weft user, I want native fullscreen to work as macOS ships it, so that videos, games and Split View are unaffected by weft.
31. As a weft user, I want a window that leaves fullscreen to go back into its desktop's layout, so that exiting fullscreen does not leave it floating loose.
32. As a weft user, I want windows of apps I assigned to "All Desktops" in the Dock to float and never be moved by weft, so that they stay where I put them.
33. As a former `sticky` user, I want weft to tell me that Dock › Options › All Desktops replaces it, so that I can get the same effect.

Displays

34. As a multi-display user, I want each display's desktops tiled to that display's usable area, so that the menu bar, notch and Dock are respected.
35. As a laptop user, I want a display I unplug and plug back in to come back with its layouts, so that docking does not cost me my arrangement.
36. As a weft user, I want weft to keep working when "Displays have separate Spaces" is off, so that the setting is my choice.

Startup and migration

37. As a weft user starting weft with windows already spread over desktops, I want every desktop tiled the first time I visit it, so that nothing needs a manual retile.
38. As a weft user upgrading from 0.9.21, I want windows parked by the old version to come back, so that nothing is stranded at a corner.
39. As a weft user upgrading from 0.9.21, I want each of my old virtual workspaces' windows spread onto the matching macOS desktop, so that ⌥3 shows the same windows it did before.
40. As a weft user who had more workspaces than desktops, I want the windows of the unmatched ones to stay put and a single notice telling me to add desktops and run `weftctl spread`, so that nothing disappears.
41. As a weft user, I want `weftctl spread` to be re-runnable, so that I can redistribute after adding desktops.
42. As a weft user, I want config keys that no longer mean anything (`workspace-swipe-fingers`, `[[space]] display`) to be warned about once and removed by `weftctl config tidy`, so that my config stays honest.
43. As a weft user, I want the release notes to say once that `move-window` no longer follows by default, so that the change does not surprise me.

Robustness

44. As a weft user, I want weft to check on launch that it can move windows on this macOS build, and to check on every move that it did, so that a lying return code never fools it.
45. As a weft user after a macOS update, I want the switch method re-checked once, with at most one brief flicker, so that a broken method is found before I rely on it.
46. As a weft user on a macOS where the bridge is gone, I want weft to keep tiling every desktop and switch by Dock swipe instead, so that an update degrades weft rather than breaking it.
47. As a weft user on a macOS where moving is impossible, I want move-window to say so in the bar, the CLI and `doctor`, so that I know it is the OS, not my config.
48. As a weft user, I want `weftctl doctor` to list each private route, whether it passed on this build, and what is lost without it, so that I can report problems precisely.
49. As the maintainer, I want `weftctl doctor --selftest` to re-run the visible switch test on demand, so that I can check each macOS beta.
50. As the maintainer, I want `WEFT_PUBLIC_ONLY=1` to run weft with every private route off, so that I can see what degrades.
51. As a weft user, I want weft to cost nothing while idle, so that native desktops do not bring back polling.

Settings and bar

52. As a weft user, I want the Workspaces pane to draw my displays with their real desktops in Mission Control order, so that the picture matches the overview.
53. As a weft user, I want each desktop card to show its number, label, layout and live app icons, so that I can tell desktops apart at a glance.
54. As a weft user, I want to rename a desktop, set its layout, and assign apps to it by drag in the inspector, so that I never need to edit TOML.
55. As a weft user, I want clicking a desktop card to switch to it when weft is running, so that the editor doubles as a check.
56. As a weft user, I want the pane to say that desktop order is changed in Mission Control, so that I do not look for a reorder that cannot exist.
57. As a weft user, I want warnings — rearrange-by-use on, moves unavailable on this macOS, separate Spaces off — shown where they apply, so that I see each at the moment it matters.
58. As a new user, I want Setup to explain that weft uses my macOS desktops and to show how many I have, so that I know to add more if I want them.
59. As a weft user, I want the menu-bar item to list my real desktops, so that the bar and Mission Control agree.

## Implementation Decisions

### Platform rules (rewrites `REDESIGN.md`)

- **Requirement 3 becomes:** "A macOS update may disable native moves or
  switches. weft detects it, says so, and tiling and launching never break."
- **The Forbidden list loses** "writing a foreign window's Space" and
  "synthetic Dock gestures". Both are now allowed under one condition: **no
  private write runs unless its self-test passed on this macOS build, and
  every call is verified by read-back.** Return codes from this family are
  never trusted (S8, S10, S11).
- Still forbidden: event choreography (drag plus shortcut), scripting another
  app's menus, writing system preferences, strongly linked symbols.

### The model

- **Pure native: one workspace is one macOS desktop.** No desktop holds more
  than one workspace, and nothing is ever parked.
- **macOS owns membership.** Which desktop a window is on is
  `SLSCopySpacesForWindows`, full stop. weft's own membership state, the
  two-owner reconcile and the "window on no managed desktop" rules are
  deleted.
- A workspace's identity in memory is its SpaceID; on disk it is
  (display UUID, position), because SpaceIDs are not stable across logout.
- The layout trees, overrides and per-desktop focus history are weft's state,
  keyed by SpaceID.

### Which desktop is showing

- **Truth:** `SLSManagedDisplayGetCurrentSpace` re-read for **every** display.
- **Triggers:** `NSWorkspace.activeSpaceDidChangeNotification`, display
  reconfiguration, weft's own switch completing, Mission Control closing.
  A notification is only a reason to re-read; its contents are never used,
  so a stale or display-less notification cannot mislead.
- **Mission Control:** observe the Dock's AX `AXExposeShowAllWindows` /
  `AXExposeExit` (as Glide does). While open, weft does not tile; on exit it
  re-reads every display and every window's desktop.
- `SLSManagedDisplayIsAnimating` is not relied on: it never reported true in
  S11. Its behaviour under a finger swipe is a pre-build spike.
- **Fallback** when the read is missing: the existing synthetic desktop per
  display (public on-screen inference). Tiling continues; switching and
  moving are off.

### Moving windows

- One bridged `MoveWindowsToManagedSpace` operation per destination desktop,
  carrying every window going there.
- Verified by re-reading `SLSCopySpacesForWindows` until every window reports
  exactly the target, with a short deadline; a window that did not arrive is
  reported, not assumed.
- Across displays the frame follows on its own (S11); weft then writes the
  tile frame for the destination.
- **Layout before show:** when windows arrive on a desktop that is not showing
  and weft holds AX elements for its windows, weft re-tiles it immediately.
  Arriving later is paint-only.
- `space move-window N` **does not follow by default**; `--follow` follows.
- Rules place new windows with the same move; `follow-space-rules` defaults
  to on, because a rule move is invisible.

### Switching

- **Primary:** the bridged triple, in this order: `ShowSpaces([target])`,
  `HideSpaces([current])`, `ManagedDisplaySetCurrentSpace(display, target)`.
  Never `SetCurrentSpace` alone: S11 showed it leaves the old desktop on the
  glass with two menu bars.
- **Verified per call:** the display's current space reads back as the target
  **and** the target's windows (if it has any) are in the on-screen window
  list. A failed verify disables the triple for the rest of the session and
  falls back.
- **Fallback:** the synthetic Dock swipe, restored from history (it was
  deleted in phase 3 of `REDESIGN.md`), one step per desktop, each step
  verified. If that is unavailable too, `space focus` answers "weft cannot
  switch desktops on this macOS; use ⌃←/⌃→".
- After landing, weft focuses the desktop's most recently focused window, or
  the desktop itself when it is empty.

### Self-tests and degradation

| Route | Launch self-test | Per call | When it fails |
| --- | --- | --- | --- |
| Symbol walk | both perform statics and the operation classes resolve | — | every bridged route off |
| Bridged move | move weft's own 1×1, never-shown window to another desktop and back, judged by read-back | read-back of every window | move-window, rules and spread refuse loudly; tiling continues |
| Bridged switch | **once per macOS build** (keyed on `kern.osversion`): switch to a neighbouring desktop and back, judged by read-back and the on-screen list; one brief flicker; result cached in the config directory | read-back + on-screen | Dock swipe |
| Dock swipe | inside the same per-build test, when the triple fails | read-back per step | "use ⌃←/⌃→" |

- The per-build test needs a display with at least two desktops; without one
  there is nothing to switch, and the result stays "untested".
- `weftctl doctor` lists each route, its result on this build and what is lost
  without it. `weftctl doctor --selftest` re-runs all of them, including the
  visible switch test.
- `WEFT_PUBLIC_ONLY=1` turns every private route off in weftd and weftctl.
- **No automatic fallback to virtual workspaces.** An OS update must never
  gather every window onto one desktop.

### Numbering and labels

- **Global, in Mission Control order:** the main display's ordinary desktops
  first, then each other display west to east. Fullscreen and Split View
  Spaces are skipped. One pure function computes this from the display
  snapshot.
- `[[space]]` labels attach by position. `labels.json` stays position-keyed.
- `space focus` accepts a label, a number, `next`, `prev` or `recent`.
  `next`/`prev` stay within the focused display and do not wrap.
- `[[space]] display = …` is meaningless (macOS decides a desktop's display):
  warned once, ignored, removed by `config tidy`.
- `com.apple.dock mru-spaces` on produces a `doctor` and Setup warning with a
  button that opens Desktop & Dock settings. weft does not change it.

### Desktop count

- weft never creates, destroys, reorders or moves desktops between displays.
- A number or label with no desktop answers: "desktop N does not exist; add
  desktops in Mission Control (weft cannot create them)". The bar shows only
  desktops that exist. weft never blocks Setup on the count.

### Fullscreen and all-desktop windows

- A fullscreen or Split View Space is not a workspace: no number, no tiling.
  A display showing one is paused (existing pause logic). On exit, macOS
  returns the window to its desktop and weft reinserts it.
- A window macOS reports on more than one desktop (Dock › Options › All
  Desktops) always floats and is never moved.
- `sticky` is **removed**: the bridged per-window route is refused (S11) and
  driving the Dock's menu was rejected in S8. The docs and `query windows`
  point at Dock › Options › All Desktops.

### Cold start

- Accessibility lists only the showing desktop's windows (S0). weft captures an
  AX element for every window at creation and holds it.
- A desktop with windows weft holds no element for is tiled **lazily**, the
  first time it is shown after launch. No warm-up sweep through desktops.

### Commands and config

- Changed: `space move-window` default (no follow).
- Removed: `sticky`, `move space display`, the workspace trackpad swipe
  (`workspace-swipe-fingers`, warned and tidied). macOS's own swipe replaces it.
- New: `weftctl spread [--dry-run]`.
- Kept as they are: `space label`, `space layout`, `focus display`,
  `move display` (a move to that display's showing desktop).

### Migration from 0.9.21

On the first launch of 0.9.22:

1. The park ledger unparks everything (existing startup path, kept for this
   release only).
2. **Spread:** each window in old virtual workspace *k*, read from 0.9.21's
   position-keyed `membership.json`, is moved to desktop *k* by the global
   numbering, one batch per desktop. Workspaces with no desktop stay where
   they are, and one notice says which, and to add desktops and run
   `weftctl spread`.
3. `membership.json` is kept, read-only, until every old workspace in it has
   a desktop, then deleted. `labels.json` is kept. Layout trees are rebuilt
   on first visit.

`weftctl spread` is step 2 on demand: it moves the windows of old workspaces
that had no desktop last time and now do, and puts every open window a
`[[rule]]` names on its desktop.

### Settings, Setup, bar

- **Workspaces pane:** the to-scale display canvas stays; each display holds
  its real desktops as cards in Mission Control order, with ⌥N, label, layout
  and live app icons; fullscreen Spaces appear greyed with no number. Labels
  with no desktop appear greyed with **Open Mission Control**.
- Removed from the pane: drag-to-pin, drag-to-reorder (the pane says "reorder
  in Mission Control"), park corners, the "weft pauses on extra desktops"
  warning.
- Kept: the inspector (rename, layout with preview, app rules by drag,
  shortcuts) and live mode (clicking a card switches).
- Warnings in place: rearrange-by-use on, moves or switches unavailable on
  this macOS, "Displays have separate Spaces" off, Stage Manager, macOS edge
  tiling.
- **Setup:** the workspace page explains the native model and ends with the
  desktop count and the rearrange-by-use check.
- **Bar:** lists real desktops by global number and label.

### Persistence

| File | Fate |
| --- | --- |
| `labels.json` | kept, position-keyed |
| `layouts.json` | trees keyed by (display UUID, position) |
| `membership.json` | read for migration and `spread`, deleted once every old workspace has a desktop |
| `parked.json` | read once at startup to unpark; the ledger goes in the release after |
| switch self-test cache | new, keyed by macOS build |

### Deleted

The virtual engine: parking on switch, park corners, `freeCorner`, the
two-owner reconcile, membership persistence, workspace pins, `move space
display`, `sticky`, the workspace swipe, the paused-on-another-desktop state,
and the Settings pieces listed above. Git keeps all of it. The DragMove carry
is **not** restored.

### Budgets

| | budget |
| --- | --- |
| switch, any distance, including verify | < 30 ms |
| move to a desktop, including verify | < 20 ms (same display), < 40 ms (other display, including the tile write) |
| idle CPU | 0.0%, no timers armed |

## Rejected options

- **Hybrid (several virtual workspaces inside one desktop).** It brings the
  Mission Control slivers back on any desktop holding more than one, and it is
  the "nest" model `WORKSPACES.md` abandoned for keeping both layers' fragility.
- **Keeping virtual as a second mode.** Two engines are what `REDESIGN.md`
  found unfixable. A bridge-less macOS gets tiling per desktop, which is a
  better failure than a second model to maintain.
- **Automatic fallback to virtual.** An OS update would gather every window
  onto one desktop under the user.
- **Reviving DragMove** as the move fallback. It fails without a title bar and
  fought the daemon's own frame writes (S8).
- **Trusting `activeSpaceDidChange`** with debouncing. That was the stack of
  heuristics that failed before.
- **`SetCurrentSpace` alone.** Corrupts the screen (S11).
- **Per-display numbering, or identity by SpaceID.** Per-display does not match
  Mission Control's reading order; SpaceIDs do not survive a logout.
- **Requiring N desktops in Setup.** weft cannot create them, so it must not
  block on them.
- **A warm-up sweep through every desktop at launch.** A visible flicker on
  every start to save one re-tile per desktop.
- **Self-testing the switch on every launch.** A flicker per launch for no more
  information than once per build gives.
- **Keeping weft's own trackpad swipe.** The native swipe is the point; an
  instant variant can come back later as a small feature.
- **Shipping in two releases** (infrastructure first). The maintainer chose one
  complete release.

## Testing Decisions

A good test here asks about behaviour a user can see — which desktop shows,
where a window ends up, what a command answers — never about which private
call was made. Two seams, nothing in between:

1. **Core state: snapshot in, effects out.** `SpaceState` is fed a display and
   desktop snapshot in Mission Control order plus each window's desktop, and
   is asked commands; it returns effects (switch display D to desktop S, move
   these windows to S, focus W, re-tile S, refuse with a message) and touches
   nothing on the Mac. Tested here:
   - global numbering, fullscreen Spaces skipped, displays west to east;
   - `focus N` / `next` / `prev` / `recent`, including "already showing on
     another display";
   - `move-window` with and without `--follow`, rule placement;
   - the missing-desktop refusal;
   - multi-desktop windows floating, fullscreen exit reinsertion;
   - lazy tiling on first visit and layout-before-show;
   - the migration spread plan from a 0.9.21 membership file;
   - layouts surviving a logout (new SpaceIDs, same display UUID and
     position);
   - the per-call switch verdict as a pure function of before/after snapshots.

   Prior art: the existing Spaces, Move and Membership tests, which build state
   only through `adoptDisplays` from `DisplayDesktops` snapshots. That stays the
   only way to build a state.

2. **The bridge on real hardware: `weftctl doctor --selftest`.** The bridged
   move and switch are judged by read-back on the machine, because their return
   codes lie. Includes `WEFT_PUBLIC_ONLY=1` to show degradation rather than
   breakage. Prior art: the park self-test and the private API tests for
   symbol resolution.

Verification before the release: `swift build`, `swift test`,
`./scripts/dev.sh snapshots` for the Settings pane, then the maintainer runs
`./scripts/dev.sh` and the checklist in `docs/TESTING.md`.

## Spikes before building

These block the build. Commands are from `spikes/`.

1. **Real applications through the bridged move.** Ghostty without a title bar
   (`./nativeops moveto <wid> <sid>` and back), Zen on the showing desktop,
   an Electron app across displays. Each must render and take keyboard input
   on arrival.
2. **Finger swipe against `IsAnimating`** (`./nativeops watch`): does the
   current-space read change before the animation ends, and does anything
   need to wait for it?
3. **Mission Control right after a triple switch** (`./nativeops switch 1
   showhide stay`): does it highlight the right desktop?
4. **The triple on the second display**, and with a fullscreen Space in the
   display's list.
5. **Scale:** 30 windows across 10 apps moved in batches; does ~10 ms hold?

A spike that fails reopens the decision it feeds, before code is written.

## Build order

All inside 0.9.22, each step a commit that builds and passes tests.

1. **Bridge** in the platform layer: symbol walk, move and switch operations,
   the three self-tests, the per-build cache, `doctor` reporting,
   `WEFT_PUBLIC_ONLY`.
2. **Dock swipe restored** as the switch fallback, inside the same self-test.
3. **Current-desktop truth** and the Mission Control observer; the
   paused-on-another-desktop state goes, the fullscreen pause stays.
4. **Core model:** workspace = desktop, the numbering function with tests,
   layouts keyed by SpaceID and persisted by (display UUID, position); delete
   the reconcile, membership persistence and park-on-switch.
5. **Commands, rules, config** warnings and `tidy`.
6. **Lazy tiling** and layout-before-show.
7. **Migration** and `weftctl spread`.
8. **Settings pane, Setup, bar**; remove the extra-desktops warning.
9. **Docs:** README, `DESIGN.md`; mark `REDESIGN.md` and `WORKSPACES.md`
   superseded; rewrite the "weft vision" memory; release 0.9.22.

## Out of Scope

- Creating, destroying or reordering macOS desktops, and moving a desktop to
  another display (`SLSBridgedMoveManagedSpaceToDisplayIndexOperation` on a
  real desktop is a roadmap spike).
- Sticky windows of any kind beyond the Dock's own All Desktops.
- An instant weft-owned trackpad swipe.
- weft's own overview (ScreenCaptureKit), now much less needed.
- macOS versions before 27.0.1: the bridge is unverified there and the
  self-test decides.
- A scripting addition or anything needing SIP off.

## Further Notes

- Nothing in this design is visible from a public API path except tiling.
  That is the trade being made: `REDESIGN.md` bought update-proofing with the
  virtual engine; this buys macOS's own desktops with two private routes that
  degrade loudly.
- The bridged family is not a blanket pass: move and the switch triple work,
  create, destroy and add-to-spaces do not. Each new use needs its own spike.
- `docs/TESTING.md` gains a per-macOS-beta step: `weftctl doctor --selftest`,
  then spikes 1–4 above.
