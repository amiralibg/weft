<p align="center">
  <img src="docs/assets/weft-icon.png" alt="Weft" width="140">
</p>

<h1 align="center">Weft</h1>

<p align="center">
  A tiling window manager for macOS.<br>
  Tiling and keybinds in one native daemon — no <code>yabai</code> + <code>skhd</code> pair, no shell out per keypress.
</p>

<p align="center">
  <img alt="platform: macOS 15+" src="https://img.shields.io/badge/platform-macOS%2015%2B-1d1f2b?style=flat-square">
  <img alt="swift 6.2" src="https://img.shields.io/badge/swift-6.2-7aa2f7?style=flat-square">
  <img alt="license: MIT" src="https://img.shields.io/badge/license-MIT-7aa2f7?style=flat-square">
</p>

---

## What it is

Weft tiles your windows and owns your keybinds in a single process. A keypress
is matched inside the daemon's event tap and dispatched in-process — there is no
`fork` + `exec` of a CLI per binding, which is the design `skhd` is stuck with.

It talks to the WindowServer through SkyLight and moves windows through the
Accessibility API, so it manages **native macOS spaces** rather than inventing
its own.

- **Two layouts per space** — `bsp` (binary split) and `float` (no tiling at
  all). Switch a space between them at runtime; window membership and focus
  survive the change.
- **Stacks** — collapse several windows into one slot and cycle through them.
  The windows behind show as a row of title bars you can click to bring one
  forward, and a row of dots on the front window's border says how many there
  are and which one you are looking at. `stack all` puts the whole space in one
  stack; `stack move <dir>` drops the focused window into its neighbour's.
- **Modes** — modal layers, like vim's. The shipped config puts resizing behind
  one so `h/j/k/l` can be bare keys while it is active.
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

> **If you already run yabai or skhd**, the installer stops them first — two
> window managers driving the same windows is a fight you get to watch. It
> records exactly which launchd agents it stopped, and `uninstall.sh` puts those
> back. Pass `WEFT_KEEP_WM=1` to skip that.

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
adds a single menu-bar item when there is one; clicking it opens the release
page. `weftctl doctor` reports the same thing from the cached answer.

It downloads nothing and installs nothing — updating is the same one-liner as
installing, and the permissions you granted carry over because the installer
signs weft with a stable identity. Turn the check off with
`check-for-updates = false` under `[general]`.

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

The Setup window opens each System Settings pane in turn. In each one, find the
row named **weftd** and turn its switch on — weft notices within a second and
moves itself along. Nothing needs restarting.

In practice you will often only be asked for Accessibility. macOS lets a
process that already holds Accessibility open an event tap, so keybinds go live
the moment that switch flips, and Setup marks Input Monitoring **Covered** and
moves past it rather than claiming you granted it. Turning it on as well is
harmless if you would rather have it explicit.

`weftd` asks the system for both permissions on launch, which is what makes
macOS *list* it, so the row should already be there waiting. If it is not, the
Setup window's "No weftd row in the list?" section reveals the binary in Finder
and copies its path — `~/.local/bin` is a hidden directory, so the pane's `+`
browser cannot reach it on its own.

Reopen it any time from the menu-bar icon → **Permissions…**, or:

```bash
open -a WeftBar --args --setup
weftctl doctor          # the same checks, in a terminal
```

## Default keybindings

`⌥` is Option/Alt. A matched chord is swallowed, so `⌥H` moves focus rather than
typing `˙`. Chords are hardware key *positions*, so they are identical on
QWERTY, Colemak and Dvorak.

| Chord | Does |
|---|---|
| `⌥H` `⌥J` `⌥K` `⌥L` | Focus the window left / down / up / right |
| `⌥⇧H` `⌥⇧J` `⌥⇧K` `⌥⇧L` | Swap the focused window that way |
| `⌥1`…`⌥5` | Go to desktop 1–5 |
| `⌥⇧1`…`⌥⇧5` | Send the focused window to that desktop |
| `⌥Tab` | Back to the desktop you came from |
| `⌥F` | Zoom the window to fill the space; again to restore |
| `⌥⇧Space` | Float the window, or put it back in the tiling |
| `⌥V` / `⌥⇧V` | Next window splits vertically / horizontally |
| `⌥\` | Flip the split under the focused window |
| `⌥B` | Even out every split on this space |
| `⌥W` `⌥N` `⌥P` `⌥U` | Stack: wrap / next / prev / unstack (`⌥]` `⌥[` work too) |
| `⌥⇧B` `⌥⇧F` | Switch this space to bsp / float |
| `⌥⌃H` `⌥⌃L` | Focus the display west / east |
| `⌥⌃⇧H` `⌥⌃⇧L` | Send the window to that display and follow it |
| `⌥⇧R` | Enter resize mode — then `h/j/k/l`, `⇧` for bigger steps, `=` to balance, `Esc` to leave |
| Drag a border | Resize the two windows either side of it — no modifier, no mode |
| `⌃⌥Space` | Window switcher |
| `⌘K` | Keybinding cheatsheet |

All of it is configuration — change any of it in `~/.config/weft/weft.toml`.

## Configuration

One file: `~/.config/weft/weft.toml`. Weft watches it and reloads within 100 ms
of a save — layout changes, new keybinds and new rules all take effect without
restarting anything.

The shipped [`examples/weft.toml`](examples/weft.toml) is deliberately generic:
no named spaces, no per-app placement, both integrations off. It behaves the
same on a Mac with one desktop as on one with nine. Named spaces and app
placement are in it as commented-out worked examples.

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

> **A note on `[[space]]`.** Labels are handed out in Mission Control order, so
> there must be at least as many desktops as blocks. Declare more and the extras
> have nowhere to land — and every keybind and rule naming them fails *silently*.
> `weftctl doctor` and the Settings window both report this; add the desktops in
> Mission Control first.

## Command line

`weftctl` drives a running `weftd` over a Unix socket. Every keybind is just one
of these commands.

```bash
weftctl focus east                  # same thing your keybind does
weftctl space focus 3
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
reality: rules and keybinds pointing at desktops that do not exist, integrations
switched on whose binary is not installed.

## Coming from yabai + skhd

```bash
weftctl migrate           # print the translated weft.toml
weftctl migrate --write   # write it to ~/.config/weft/weft.toml
```

`install.sh` runs this for you when it finds a `yabairc` or `skhdrc` and no
existing weft config — your own keybinds are the only ones that will feel right,
and seeding a demo config over them makes a working install look broken.

## Instant space switching (optional)

Without help, switching desktops uses the Mission Control `⌃N` shortcut, which
covers desktops 1–9 and plays the system animation.

Weft also speaks the Dock scripting-addition protocol. If you already have
yabai's loaded (`sudo yabai --install-sa && yabai --load-sa`, which needs SIP
configured with a scripting-addition exception), weft drives it and space
switches become instant and animation-free — and sticky windows and
non-activating window moves start working too.

Entirely optional. `weftctl doctor` reports which capabilities you have.

## Integrations

Both are off by default, because both drive a program weft does not install.

| | What it does | Install |
|---|---|---|
| [JankyBorders](https://github.com/FelixKratz/JankyBorders) | Highlight around the focused window, recoloured per layout and per mode | `brew install FelixKratz/formulae/borders` |
| [SketchyBar](https://github.com/FelixKratz/SketchyBar) | Fires `--trigger weft_event` with `WEFT_*` variables on layout, space and focus changes | `brew install FelixKratz/formulae/sketchybar` |

Turn them on in `[integrations.*]`, or in Settings → Integrations, which tells
you whether the binary is actually there.

## Building from source

```bash
swift build -c release      # weftd, weftctl, weft-bar
swift test                  # 97 tests, no window manager required
./scripts/build-app.sh      # bundles build/WeftBar.app
```

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

```bash
./scripts/uninstall.sh
```

Stops and removes the service, the binaries and the app, and restores whatever
yabai/skhd launchd agents `install.sh` stopped — by the labels it actually
recorded, not by guessing. Your `~/.config/weft` is left alone.

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
