# Weft manual test runbook (macOS)

Foreground-first process for testing weftd as your window manager with yabai disabled.
Don't install the LaunchAgent until the foreground run is stable.

## A. Stop yabai / skhd

```bash
yabai --stop-service 2>/dev/null; brew services stop yabai 2>/dev/null; brew services stop skhd 2>/dev/null
sudo yabai --uninstall-sa 2>/dev/null
killall yabai skhd 2>/dev/null; sleep 1
pgrep -fl "yabai|skhd"  # should print nothing
```

Weft needs no scripting addition and no SIP change. Space switching is instant
on its own (a synthetic Dock swipe), and moving a window to another desktop
works by holding the window and pressing your "move a space" shortcut. If Dock
still has yabai's addition injected from an earlier setup, log out/in once
after `yabai --uninstall-sa`; weft will not use it either way.

## B. Build + install

Run from the repo root.
One command does it all (bins, WeftBar.app, config seed, launchd service):

```bash
./scripts/install.sh
export PATH="$HOME/.local/bin:$PATH"
```

Manual equivalent:

```bash
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/weftd .build/release/weftctl .build/release/weft-bar ~/.local/bin/
./scripts/build-app.sh  # builds build/WeftBar.app
mkdir -p ~/.config/weft
[ -e ~/.config/weft/weft.toml ] || cp examples/weft.toml ~/.config/weft/weft.toml
```

Then open WeftBar once — its Setup window checks Accessibility / Input
Monitoring / Screen Recording live, deep-links to each Settings pane, and
enables Restart only when all are green. Reopen anytime via the menu bar →
"Setup & Permissions…". `weftctl doctor` now reports the same three checks.

## C. Permissions (after build, before first run)

> Do B first — `~/.local/bin/weftd` doesn't exist until you build + copy.
> Verify: `ls -l ~/.local/bin/weftd`. If `~/.local` itself is missing, you
> skipped the `mkdir -p ~/.local/bin` + `cp` step in B.

`~/.local` is hidden, so Finder's `+` picker won't show it by default:

1. System Settings → Privacy & Security → **Accessibility** → `+`.
2. In the open dialog press `Cmd+Shift+G`, paste `~/.local/bin`, Enter →
   select `weftd` → Open. (`Cmd+Shift+.` also toggles hidden files.)
   Or in Terminal: `open ~/.local/bin`, then drag `weftd` into the Settings list.
3. Enable the checkbox. Repeat under **Input Monitoring** (hotkey /
   mouse-gesture tap needs it).
4. Repeat both for `WeftBar` if you run the bar app.
5. System Settings → Desktop & Dock → Mission Control shortcuts `ctrl-1..9`:
   enable (needed only when running without the scripting addition).

Alternative (visible path, no hidden-folder dance):

```bash
sudo mkdir -p /usr/local/bin
sudo cp ~/.local/bin/weftd ~/.local/bin/weftctl ~/.local/bin/weft-bar /usr/local/bin/
```

then add `/usr/local/bin/weftd` in Settings instead. If you rebuild later,
re-select the binary — macOS TCC can drop the grant when the binary changes.

## D. Foreground smoke test

Terminal 1 — daemon in the foreground so you see every log line (`Ctrl-C` kills cleanly):

```bash
~/.local/bin/weftd 2>&1 | tee /tmp/weft-manual.log
```

Terminal 2 — health + topology:

```bash
weftctl doctor
weftctl query spaces
weftctl query windows
weftctl query state
weftctl query capability  # SA false = degraded-but-testable fallback mode
weftctl subscribe --all   # live event stream, Ctrl-C to exit
```

Open 2x Terminal + Safari, then:

```bash
weftctl retile
weftctl query tree
tail -n 50 /tmp/weftd.err.log  # look for "frame-set failed" / "auto-floating"
```

Good state: two windows tile side-by-side, `query state` frames match the
screen, no `frame-set failed` spam. Known-bad (fixed in this tree): windows
overlap after tile, or focus jumps spaces on its own during sync.

## E. Functional matrix

Keybindings below are the `examples/weft.toml` defaults (`alt-*`). That file is
deliberately generic — no named spaces, no per-app placement, both integrations
off — so it behaves the same on any Mac. If you are testing against a migrated
yabai/skhd config instead, the chords will be that config's, not these:

| Area | Action | Expect |
|---|---|---|
| Focus | `alt-h/j/k/l` | focus moves directionally, cursor warps if `mouse-follows-focus` |
| Move | `alt-shift-h/j/k/l` | the window steps that way and **keeps its size**; a half-screen window must not come back a quarter. Single re-tile |
| Spaces | `alt-1..5` | one switch, layouts apply on arrival, no double-jump |
| Move to space | `alt-shift-1..5` | window leaves current tree, appears on target |
| Zoom | `alt-f` | window covers usable screen, toggle restores |
| Float | `alt-shift-space` | window centers at 70%, drag freely; toggle re-tiles |
| Stack | `alt-w`, `alt-bracketright/left`, `alt-u` | wrap / next / prev / unstack, one shared frame |
| Scroll | `alt-shift-n` to switch layout, then `alt-n/p/r` | column nav + width cycle, off-screen columns park |
| Resize | `alt-shift-r`, then `h/j/k/l`, `esc` | grows/shrinks focused split, `balance` on `=` |
| Sticky | `weftctl sticky --help` / `weftctl sticky` | needs SA; honest error without it |
| Display | `alt-ctrl-h/l`, `alt-ctrl-shift-h/l` | multi-display only; single display prints "already there" |
| Drag | drag tiled window by body | snaps back **once** after release, never fights mid-drag |

The example config declares no `[[space]]` blocks, so spaces are addressed by
their Mission Control number. `alt-4` and `alt-5` do nothing on a machine with
three desktops — that is correct, not a bug; `weftctl doctor` reports it.

Space-stability checks (regression for "spaces change without warning"):

```bash
weftctl space focus 2     # wait for arrival
weftctl sync              # must stay put, no second jump
weftctl query state       # `screen` == visible area (reserve excluded)
```

Settings UI (no TOML hand-editing) — run `build/WeftBar.app` → menu bar →
`Visual Config Editor…`:

1. General tab: change inner gap `8` → `20`, toggle mouse-follows → Save →
   windows re-tile within ~300ms via the file watcher, no restart needed.
2. Keys tab: enter garbage → Save → must show `Not saved — line N: …` and the
   file on disk stays untouched.
3. Confirm `~/.config/weft/weft.toml` still contains your `[integrations.*]`
   and `[mode.resize]` blocks (the old editor silently dropped these).

## F. Promote to launchd service (only after E passes)

```bash
weftctl service install
weftctl service status   # ACTIVE
tail -f /tmp/weftd.err.log
# reboot test: log out/in, `weftctl query state` still responds
```

Service details: label `com.weft.weftd`, plist at
`~/Library/LaunchAgents/com.weft.weftd.plist`, logs at
`/tmp/weftd.out.log` and `/tmp/weftd.err.log` (`Sources/weftctl/Service.swift`).

## G. Revert to yabai

```bash
weftctl service stop; weftctl service uninstall
killall weftd weft-bar 2>/dev/null
brew services start yabai; brew services start skhd
```

## H. Latency

Weft's latency is not one number. A retile is a WindowServer sweep, a pure
layout computation, one atomic `SLSTransaction` of positions and then a
cross-process AX write per app — and only the last of those is slow. So the
daemon keeps a bounded ring of samples per phase (always on: `Sources/WeftPlatform/Trace.swift`)
and `weftctl bench` prints them:

```bash
weftctl bench "window focus east" -n 100
weftctl query trace | jq          # the same numbers, raw
```

`WEFT_TRACE=1` on the daemon adds a stderr line per sample, for watching one
operation rather than aggregating many.

**Phases**

| Phase | What it covers |
|---|---|
| `cmd.dispatch` | Parse → reduce on the core queue → hand frames to the apply queue. What a keypress actually waits on. |
| `layout` | The pure `(Tree, Frame, Config) -> [WindowID: Frame]` pass. Microseconds; a tripwire test guards it (`Tests/WeftCoreTests/LayoutBudgetTests.swift`). |
| `apply.diff` | Reading each window's current bounds to decide whether it needs writing at all. |
| `apply.commit` | The single `SLSTransaction` that moves every window's origin at once. This is the motion you see first. |
| `ax.position` / `ax.size` | The cross-process AX writes. `ax.size` is the one that forces an app relayout — on Chromium/Electron windows it dominates everything else here. |
| `ax.verify` | `SLSGetWindowBounds` read-back and the correction write when the app landed somewhere else. |
| `apply.total` | Entry to last write completing, across every app in the batch. |
| `sweep.world` / `sweep.classify` / `sweep.bind` / `sweep.total` | The world resync. `sweep.total` is the cold-start cost and the per-event cost of learning about a new window. |

**Capturing a baseline.** Run each of these with a native app (Terminal,
Finder) and again with an Electron one (VS Code, Slack) in the layout — the
gap between the two is the thing worth fixing.

```bash
weftctl bench "window focus east"  -n 100   # focus only, no frames written
weftctl bench "swap east"          -n 50    # equal-size swap: commit-dominated
weftctl bench "window zoom-fullscreen" -n 50  # every window resizes
```

Close-and-refill and app-launch latency are event-driven, not command-driven,
so they are measured by watching the phases rather than driving them:

```bash
weftctl trace reset
# close a window by hand, wait a second
weftctl query trace
```

## I. What to send back when reporting

```bash
weftctl doctor
grep -E "frame-set failed|auto-floating|rule cannot|did not land" /tmp/weftd.err.log | tail -n 30
weftctl query state > /tmp/weft-state.json  # attach
```

The grep output tells us AX-control coverage (refuser strikes) and SA coverage
on your machine; the state dump shows computed vs. visible geometry.
