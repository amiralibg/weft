<p align="center">
  <img src="docs/assets/weft-icon.png" alt="Weft" width="140">
</p>

<h1 align="center">Weft</h1>

<p align="center">
  A tiling window manager for macOS.<br>
  Fast, light, native tiling — with your keyboard shortcuts built in.
</p>

<p align="center">
  <img alt="platform: macOS 15+" src="https://img.shields.io/badge/platform-macOS%2015%2B-1d1f2b?style=flat-square">
  <img alt="swift 6.2" src="https://img.shields.io/badge/swift-6.2-7aa2f7?style=flat-square">
  <img alt="license: MIT" src="https://img.shields.io/badge/license-MIT-7aa2f7?style=flat-square">
</p>

---

## What it is

Weft arranges your windows for you and runs your keyboard shortcuts, in one
small native app. A shortcut is handled inside weft the instant you press it —
nothing is launched per keypress — so focusing, moving, resizing and switching
windows happens with no wait, and weft stays out of the way the rest of the time.

It keeps its own **workspaces** on one macOS desktop per display, so switching
and moving windows are instant and work for every window — with System
Integrity Protection left exactly as it is.

- **Two layouts per space** — `bsp` (binary split) and `float` (no tiling at
  all). Switch a space between them at runtime; window membership and focus
  survive the change.
- **Moving restructures, it does not swap** — `move east` takes the window one
  step east *in the layout tree*, so it keeps its size. Swapping it with
  whatever window is over there, which is what most BSP tilers do by default,
  means a half-screen window can come back as a quarter. `swap <dir>` is there
  for when you do want the literal trade.
- **Stacks** — collapse several windows into one slot and cycle through them.
  The windows behind show as a row of title bars you can click to bring one
  forward, and a row of dots on the front window's border says how many there
  are and which one you are looking at. `stack all` puts the whole space in one
  stack; `stack move <dir>` drops the focused window into its neighbour's.
- **Modes** — modal layers, like vim's. The shipped config puts resizing behind
  one so `h/j/k/l` can be bare keys while it is active.
- **Runs your commands too** — `exec <anything>` goes through `/bin/sh`, so the
  half of an skhd config that was never about windows keeps working. The
  command gets `WEFT_SPACE_LABEL`, `WEFT_FOCUSED_APP` and the rest of weft's
  state in its environment, so a script never has to ask.
- **Window rules** — regex on app name or window title; send an app to a space,
  or tell weft to leave it alone entirely.
- **Multi-display** — spaces are tiled in *their own* display's rect, and
  `west`/`east` pick the display geometrically rather than by arrangement index.
- **Mouse** — drag the border between two tiled windows to resize them, with no
  modifier and no mode; hold a modifier to drag a window by its body. Weft
  claims a plain click only when it lands on a border, so every other click
  reaches the app untouched.
- **Knows a popup when it sees one** — a dialog, a window the app refuses to
  resize, or a small frameless panel with no title-bar buttons is floated rather
  than given a slot. That is what an Electron app's floating call widget is, and
  tiling one hands a quarter of the screen to a badge.
- **A menu-bar app** with a visual settings editor, a searchable keybinding
  cheatsheet (`⌘K`), and a window switcher (`⌃⌥Space`).

Weft is young, and it asks for real system permissions to do its job. The design
notes in [`docs/DESIGN.md`](docs/DESIGN.md) are candid about what is solved, what
is a heuristic, and what macOS simply will not allow — read them before trusting
it with your desktop.

## Install

macOS 15 or later, Intel or Apple Silicon.

```bash
curl -fsSL --retry 5 --retry-all-errors \
  https://raw.githubusercontent.com/amiralibg/weft/main/scripts/install-release.sh | bash
```

That downloads the [latest release](https://github.com/amiralibg/weft/releases/latest),
verifies its checksum, installs `weftd` and `weftctl` into `~/.local/bin` and
`WeftBar.app` into `~/Applications`, seeds a config, registers the launchd
service, and opens Setup. No toolchain, no compile.

**Without a terminal:** download `WeftBar-<version>.zip` from the
[releases page](https://github.com/amiralibg/weft/releases/latest), open it,
and drag **WeftBar** into Applications. The first time you open it macOS will
say it cannot check the app — it is not notarised — so go to **System Settings ›
Privacy & Security** and click **Open Anyway**. WeftBar then installs the engine
itself (into `~/.local/bin`, signed so your permissions survive updates), writes
a starting config, and walks you through the permissions. Updating is the same:
use **Update to weft …** in its menu, or replace the app.

Prefer to look before you run it? Download the archive from the
[releases page](https://github.com/amiralibg/weft/releases/latest), check it,
and run the `install.sh` inside:

```bash
shasum -a 256 -c weft-*-macos-universal.tar.gz.sha256
tar -xzf weft-*-macos-universal.tar.gz && cd weft-*/
./install.sh
```

<details>
<summary><b>Build from source instead</b></summary>

Needs a Swift 6.2+ toolchain (`swift --version`).

```bash
git clone https://github.com/amiralibg/weft.git
cd weft
./scripts/install.sh
```

</details>

Either way, if `~/.local/bin` is not on your `PATH`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

### About the released binaries

They are **ad-hoc signed, not notarised** — weft has no paid Apple Developer
account behind it. Two consequences worth knowing up front:

- macOS quarantines anything downloaded from the internet, and refuses to launch
  an unsigned app that carries the flag — reporting it as "damaged", which it is
  not. The installer clears the flag from the files it installs. That is the one
  thing in it you should read before piping it to a shell.
- macOS identifies an *unsigned* binary by its **contents**, so every new build
  would be a different program as far as Privacy & Security is concerned — and
  an update would drop weftd's grants while leaving the switches in System
  Settings visibly on, granting nothing. `install.sh` avoids this by creating
  one self-signed code-signing identity on first run (kept in its own keychain,
  no password prompt) and signing every binary with it. The permission is then
  tied to that identity rather than to the bytes, so **grants survive every
  future rebuild and update**. Deleting `~/Library/Keychains/weft-signing.keychain-db`
  starts a new identity and costs one re-grant.

Neither applies to a build signed with a Developer ID — the release workflow
does that automatically if the repository has the signing secrets configured.

## Updates

weft installs from a script or a clone, so nothing would otherwise tell you a
fix exists. WeftBar asks GitHub once a day whether a newer release is out and
adds a menu-bar item when there is one. **Settings › Advanced › Updates** shows
the same thing with a **Check Now** button, and opening it asks for you if the
answer on disk has aged out.

Clicking **Update** asks first, then runs the release's own
`install-release.sh` — the same script the one-liner runs, not a second
updater. It downloads the release, verifies the checksum, replaces the copy of
WeftBar you are running, restarts the service and reopens the app. Your settings
and permissions carry over, because the installer signs weft with a stable
identity.

Most of an update is the download, and on a slow link to GitHub that is minutes
rather than seconds, so Settings shows a progress bar, the percentage and an
elapsed clock throughout. WeftBar quits partway through by design — that is the
installer replacing it — and reopens on its own.

Turn the check off with `check-for-updates = false` under `[general]`. Updating
by hand is always the one-liner at the top of this file.

## Workspaces

A **workspace** is weft's: a named set of windows with its own layout, what
`⌥1`…`⌥9` and your `[[space]]` blocks refer to. Weft keeps them on **one macOS
desktop per display**. Switching moves the windows you are not using just off
the edge of the screen and puts the others back: instant, nothing animates,
and it works on every window — including a terminal with its title bar hidden.
Sending a window to another workspace is the same, and so is a rule's
`space = "…"`.

- **Eight to start with.** The default config declares workspaces 1–8: 1–5
  on the main display (the one with the menu bar) and 6–8 on a second one. On
  a single display all eight live there. A number past the list, like
  `space focus 9`, is created the first time you use it.
- **Several displays.** Each display shows one workspace. `[[space]] display =`
  keeps a workspace on one: `"main"`, `"secondary"`, `"built-in"` (the Mac's
  own screen), `"external"`, a number counted west to east, or part of the
  display's name. Settings › Workspaces sets it by dragging a workspace onto a
  display, and the change applies at once. An unpinned workspace shows on the
  display you are on; `move space display east` sends the current workspace to
  the other display and brings that one's back.
- **Other macOS desktops and full-screen apps keep working.** Weft pauses on a
  display while one of them is showing and resumes when you come back. It never
  switches desktops for you. `weftctl doctor` shows which desktop weft manages
  on each display and whether it is paused.
- **Restarts keep your workspaces.** An update or a restart puts every window
  back in the workspace it was in.
- **The cost:** Mission Control on weft's desktop shows a thin sliver for each
  hidden window, the same trade AeroSpace makes.

The design, and what it measured, is in [`docs/REDESIGN.md`](docs/REDESIGN.md).

## Permissions

Weft needs three macOS privacy permissions, and **all belong to `weftd`** — the
engine — not to the `WeftBar` menu-bar app you can see. macOS grants these per
binary, so granting them to WeftBar does nothing at all.

| Permission | What it is for | Required |
|---|---|---|
| **Accessibility** | Moving, resizing and focusing windows | Yes |
| **Input Monitoring** | Keybinds and mouse gestures | Usually covered by Accessibility |
| **Screen Recording** | Reading window titles — rules, switcher, sketchybar | Yes |

Screen Recording is not about recording. Without it macOS redacts
`kCGWindowName` for every window `weftd` does not own, so every title comes back
empty: title-matching rules stop matching, and the switcher lists blank rows.

The Setup window takes you through them one at a time. At each step macOS may
ask first — choose **Open System Settings** — and then you find the row named
**weftd** and turn its switch on. Weft notices within a second and moves itself
along. Nothing needs restarting.

In practice you will often only be asked for Accessibility. macOS lets a
process that already holds Accessibility open an event tap, so keybinds go live
the moment that switch flips, and Setup marks Input Monitoring **Covered** and
moves past it rather than claiming you granted it. Turning it on as well is
harmless if you would rather have it explicit.

macOS only lists an app after the app asks, and asking is what shows its
dialog. So `weftd` never asks on its own — Setup asks at the step you are on,
which is why the dialog appears right after you click and never out of nowhere.
If a `weftd` row still isn't there, the Setup window's "No weftd row in the
list?" section reveals the binary in Finder and copies its path —
`~/.local/bin` is a hidden directory, so the pane's `+` browser cannot reach it
on its own.

Reopen it any time from the menu-bar icon → **Permissions…**, or:

```bash
open -a WeftBar --args --setup
weftctl doctor          # the same checks, in a terminal
```

### System Integrity Protection

**Weft never asks you to change it.** Nothing weft does needs SIP off, and weft
loads no code into any other process.

| Feature | With SIP on |
|---|---|
| Tiling, focus, shortcuts, rules, stacks, borders, the switcher | Yes |
| Switching workspaces (`space focus`) | Yes — instant |
| Sending a window to a workspace (`space move-window`), and a rule's `space = "…"` | Yes — instant, any window |
| Keeping a window visible on every workspace (`sticky`) | Yes |
| Switching or moving windows between **macOS desktops** | Not done — see below |

macOS refuses every route an ordinary process has for moving another app's
window between its own desktops — sixteen SkyLight calls were tried, and three
return success while doing nothing. What remains is simulated input (holding a
title bar while pressing a desktop shortcut) and private Dock gestures, and both
broke on macOS updates. So weft does not drive macOS desktops at all: its
workspaces do that job, on one desktop per display, and nothing there depends on
what a macOS update changes about Dock.

The private calls weft does use are looked up by name when it starts rather
than linked, each one checked by a self-test. A macOS update that removes one
costs the feature that uses it, never the launch — `weftctl doctor` lists them.

## Default keybindings

`⌥` is Option/Alt. A matched chord is swallowed, so `⌥H` moves focus rather than
typing `˙`. Chords are hardware key *positions*, so they are identical on
QWERTY, Colemak and Dvorak.

| Chord | Does |
|---|---|
| `⌥H` `⌥J` `⌥K` `⌥L` | Focus the window left / down / up / right |
| `⌥⇧H` `⌥⇧J` `⌥⇧K` `⌥⇧L` | Move the focused window that way |
| `⌥1`…`⌥8` | Go to workspace 1–8 (1–5 main display, 6–8 second display) |
| `⌥⇧1`…`⌥⇧8` | Send the focused window to that workspace, and go with it |
| `⌥Tab` | Back to the workspace you came from |
| `⌥F` | Zoom the window to fill the space; again to restore |
| `⌥⇧Space` | Float the window, or put it back in the tiling |
| `⌥V` / `⌥⇧V` | Next window splits vertically / horizontally |
| `⌥\` | Flip the split under the focused window |
| `⌥B` | Even out every split on this space |
| `⌥⇧P` | Keep the window on every workspace; again to put it back |
| `⌥W` `⌥N` `⌥P` `⌥U` | Stack: wrap / next / prev / unstack (`⌥]` `⌥[` work too) |
| `⌥⇧W` | Every window on this workspace in one stack, and back |
| `⌥⇧B` `⌥⇧F` | Switch this space to bsp / float |
| `⌥⌃H` `⌥⌃L` | Focus the display west / east |
| `` ⌥` `` | Focus the next display |
| `⌥⌃⇧H` `⌥⌃⇧L` | Send the window to that display and follow it |
| `⌥⇧R` | Enter resize mode — then `h/j/k/l`, `⇧` for bigger steps, `=` to balance, `Esc` to leave |
| `⌥↩` `⌥E` `⌥S` | Terminal / Finder / Safari: open it, go to it, or hide it when it is in front |
| Drag a border | Resize the two windows either side of it — no modifier, no mode |
| `⌃⌥Space` | Window switcher |
| `⌘K` | Keybinding cheatsheet |

All of it is configuration — change any of it in `~/.config/weft/weft.toml`.

## Configuration

One file: `~/.config/weft/weft.toml`. Weft watches it and reloads within 100 ms
of a save — layout changes, new keybinds and new rules all take effect without
restarting anything.

The shipped [`examples/weft.toml`](examples/weft.toml) is what a fresh install
writes, and it is deliberately generic: workspaces 1–8 pinned by role rather
than by monitor, shortcuts only for apps every Mac has, no per-app placement,
both integrations off. Per-app placement is in it as commented-out examples.
Coming from yabai or skhd? `weftctl migrate` prints your setup as weft config,
and `weftctl migrate --write` saves it.

```toml
[general]
inner-gap = 8
outer-gap = 8
stack-offset = 8                # how far a stack's members peek out
default-layout = "bsp"          # bsp | float
mouse-border-resize = true      # drag a window border to resize, no modifier
mouse-modifier = "alt"          # hold to drag a window by its body
mouse-follows-focus = true
reserve = 0                     # room for an always-on-screen bar

[keys]
"alt-h" = "focus west"
"alt-1" = "space focus 1"
"alt-shift-r" = "mode resize"
"alt-return" = "app toggle com.apple.Terminal"
"alt-shift-return" = "exec open -a Terminal ~"   # anything, through /bin/sh

[mode.resize]
"h" = "resize left 40"
"escape" = "mode default"

[[rule]]
app = "System Settings"
manage = false                  # never tiled, never moved

[[space]]                       # optional — see the note below
label = "term"
layout = "bsp"
```

Prefer buttons? The menu-bar icon → **Settings…** is a full editor for the file
— gaps with a live preview of what they do, spaces, rules, a keybinding table
with a chord recorder, and integrations. It writes back into the same lines,
so your comments and any key it does not recognise survive untouched.

```bash
open -a WeftBar --args --settings
```

> **A note on `[[space]]`.** Each block is a workspace, in the order `space
> focus 1`, `2`, … count. Declare as many as you like — they are weft's, not
> macOS desktops, so there is nothing to create in Mission Control.

## Commands

Every shortcut runs one of these, and so does `weftctl <command>`. A direction
is `west`, `east`, `north` or `south`. A display is one of those, `next`,
`prev`, `cycle`, `first`, `last`, or a number counted west to east.

| Command | Does |
|---|---|
| `focus <direction>` | Focus the window that way |
| `move <direction>` | Move the window that way; it keeps its size |
| `swap <direction>` | Trade places with the window that way |
| `resize left` / `right` / `up` / `down` `<px>` | Grow or shrink the window that way by that many points |
| `split vertical` / `split horizontal` | Which way the next window splits this one |
| `window toggle split` | Flip the split under the window |
| `window toggle zoom-fullscreen` | Fill the workspace with the window; again to restore |
| `float` / `float on` / `float off` | Float the window, or put it back in the tiling |
| `sticky` / `sticky on` / `sticky off` | Keep the window on every workspace |
| `balance` | Even out every split on the workspace |
| `stack toggle` / `next` / `prev` / `unstack` / `all` | Stacks: several windows in one slot |
| `stack move <direction>` / `stack split <direction>` | Join the stack that way / pull that window in |
| `space focus <name or number>` | Go to a workspace (`recent` goes back) |
| `space move-window <name or number>` | Send the window there and go with it (`--no-follow` stays) |
| `space layout bsp` / `float` / `toggle` | Change this workspace's layout |
| `space label <name>` | Rename this workspace |
| `focus display <display>` | Focus another display |
| `move display <display>` | Send the window to another display (`--follow` goes with it) |
| `move space display <display>` | Swap this workspace with the one on another display |
| `app toggle <bundle id>` | Open the app, go to its window, or hide it when it is in front |
| `mode <name>` | Enter a `[mode.<name>]` layer; `mode default` leaves it |
| `exec <shell command>` | Run anything through `/bin/sh` |

**Making a shortcut.** In Settings › Shortcuts, click **Add Shortcut…**, press
the keys, and pick what they do from the list of everything above, in plain
words, with menus for the details. Add more steps and one key does several
things in a row. In the file, it is one line under `[keys]`, and a list runs
its commands in order:

```toml
"alt-m" = "app toggle com.apple.mail"      # Settings › Choose an app… finds any bundle id
"alt-shift-m" = ["space move-window 3", "app toggle com.apple.mail"]   # several steps, in order
"alt-shift-9" = "space move-window 9 --no-follow"
"alt-d" = "exec open ~/Downloads"
```

## Command line

`weftctl` drives a running `weftd` over a Unix socket. Every keybind is just one
of these commands.

```bash
weftctl focus east                  # same thing your keybind does
weftctl space focus 3
weftctl exec 'screencapture -i -c'  # run a shell command
weftctl space layout float
weftctl query state                 # JSON: the world as weftd sees it
weftctl query windows
weftctl subscribe --all             # live event stream
weftctl doctor                      # health check: permissions, config, helpers
weftctl bench "focus east" -n 200   # latency histogram + per-phase daemon timings
weftctl rescue                      # bring back any window stranded off every display
weftctl service restart
```

`weftctl doctor` is the first thing to run when something is wrong. It reports
the daemon's *own* permissions (not `weftctl`'s — TCC is per binary, and asking
the wrong process is how a green checklist sits next to a weft that cannot move
a window), validates the config with line numbers, and cross-checks it against
reality: rules and keybinds pointing at workspaces that do not exist, integrations
switched on whose binary is not installed.

## Integrations

| | What it does | Install |
|---|---|---|
| Borders | Highlight around the focused window, recoloured per layout and per mode | Nothing — weft draws them |
| [SketchyBar](https://github.com/FelixKratz/SketchyBar) | Fires `--trigger weft_event` with `WEFT_*` variables on layout, space and focus changes | `brew install FelixKratz/formulae/sketchybar` |

Both are off by default.

### Window borders

```toml
[integrations.borders]
enabled = true
width = 2.0
style = "round"          # follows each window's own corners; or "square"
active-color = { bsp = "0xff7aa2f7", float = "0xffe0af68" }
inactive-color = "0x40414868"
show-inactive = true     # false borders only the focused window
```

Every key applies live, from Settings or the file. `radius = 12.0` fixes the
corner radius instead of following each window.

Weft draws borders in `weftd`, from the frames it is applying, so a border does
not trail its window while it moves. Only windows in a layout get one, so
popovers, Spotlight and other panels never do.

A border is four thin strips and four small corner pieces around the window —
about 1% of its area — rather than one transparent window laid over it. That
difference is most of the cost: the compositor pays for a window's area on every
frame the app underneath draws. Strips in an opaque colour are copied, not
blended. Moving windows moves every border in one WindowServer transaction with
no redraw; a border is redrawn only when its colour or size changes.

Measured on a MacBook Air (M4), macOS 27.0, two windows, interleaved cycles
compared against no borders:

| | GPU, apps drawing | Memory |
|---|---|---|
| One transparent window per border (weft's renderer until 0.7.4) | +24 pp | +154 MB |
| JankyBorders | +14 to +22 pp | its own process |
| Weft | +4 to +8 pp | +2 MB in weftd |

With nothing on screen changing, all of them measure at zero. Background load
moved between cycles, so treat the numbers as an order, not a precise result.

`backend = "janky"` hands drawing to
[JankyBorders](https://github.com/FelixKratz/JankyBorders) instead, for what
weft does not draw: `gradient(...)` colours, `blacklist`, `background_color`.
Weft then starts and supervises `borders`, passes the keys above to it, and
passes `args` through unchanged.

## Building from source

```bash
swift build -c release      # weftd, weftctl, weft-bar
swift test                  # no window manager required
./scripts/build-app.sh      # bundles build/WeftBar.app
```

### Trying a change on your own Mac

`scripts/dev.sh` runs your checkout in place of the installed weft, with no
release in between:

```bash
./scripts/dev.sh            # build, install over the current weft, restart it
./scripts/dev.sh logs       # follow what the engine is doing
./scripts/dev.sh check      # doctor, both hide/show self-tests, idle cost
./scripts/dev.sh snapshots  # every Settings pane and Setup page as PNGs
./scripts/dev.sh release    # back to the latest published release
```

It installs where a release installs and signs with the same local identity,
so macOS keeps weft's permissions when you switch between a local build and a
release. Your config is left alone. `weftctl doctor` says when a local build is
running, and which commit.

To produce what a release ships — universal binaries for both architectures:

```bash
swift build -c release --arch arm64 --arch x86_64
WEFT_PRODUCT_DIR="$PWD/.build/apple/Products/Release" ./scripts/build-app.sh
```

`.build/release` is a symlink to the *host* architecture's products, so the fat
binaries do not land there — they go to `.build/apple/Products/Release`, which
is why `build-app.sh` takes that override.

Releases are cut by tagging. `.github/workflows/release.yml` refuses to publish
a tag that disagrees with `WeftVersion.current` in
[`Sources/WeftCore/Version.swift`](Sources/WeftCore/Version.swift), so
`weftctl --version` always matches what was downloaded:

```bash
# bump Version.swift, commit, then:
git tag v0.2.0 && git push origin v0.2.0
```

> Use `swift build` without `--target`. In this package `swift build --target
> weft-bar` can report success while producing a byte-identical binary, so an
> edit appears to have no effect.

## Uninstall

**From the app:** open Settings (weft icon in the menu bar → **Settings…**), go
to **Advanced**, and click **Uninstall Weft…** at the bottom. It asks first, and offers to remove
your settings and permissions too. Your windows are left exactly where they are.

**From a terminal**, with the script that ships inside the app:

```bash
~/Applications/WeftBar.app/Contents/Resources/uninstall.sh            # keep your settings
~/Applications/WeftBar.app/Contents/Resources/uninstall.sh --purge    # remove everything
~/Applications/WeftBar.app/Contents/Resources/uninstall.sh --dry-run  # only list what it would remove
```

(From a release archive or a clone it is `./uninstall.sh` or `./scripts/uninstall.sh`.)

What it removes:

| | Kept without `--purge` |
|---|---|
| The engine (`~/.local/bin/weftd`, `weftctl`) and its login service | |
| WeftBar.app, wherever it is | |
| Logs and temporary files | |
| Your settings (`~/.config/weft`) | ✓ — a reinstall picks up where you left off |
| Weft's signing identity | ✓ — a reinstall keeps its permissions |
| Weft's rows in Privacy & Security | ✓ |

macOS sometimes keeps a `weftd` row in Privacy & Security after a purge; select
it and press **−** to clear it.

## Layout of the repo

| Path | |
|---|---|
| `Sources/WeftCore` | Geometry and the world model. Pure — no I/O, no AppKit, no SkyLight. |
| `Sources/WeftPlatform` | Accessibility, SkyLight, spaces, displays, permissions. |
| `Sources/WeftConfig` | TOML parsing and validation of `weft.toml`. |
| `Sources/WeftInput` | The event tap, chord matching and modes. |
| `Sources/weftd` | The daemon. |
| `Sources/weftctl` | The CLI. |
| `Sources/weft-bar` | The menu-bar app, Settings, cheatsheet, switcher. |
| `docs/DESIGN.md` | Why things are the way they are, including the mistakes. |
| `docs/TESTING.md` | The manual test matrix. |
| `docs/TODO.md` | What is queued next, and what each item already has in place. |

## License

MIT — see [LICENSE](LICENSE).
