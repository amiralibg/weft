#!/usr/bin/env bash
# Full weft install: binaries + WeftBar.app + config + launchd service.
#
#   ./scripts/install.sh              # user install (~/.local/bin, ~/Applications)
#   PREFIX=/opt/homebrew ./scripts/install.sh   # system-wide bins (needs write perm)
#
# After install, launch WeftBar once — its Setup window walks through the
# Privacy permissions one pane at a time. Grants take effect live: weftd
# re-tries the event tap on every check, so flipping a switch is the whole
# interaction and nothing needs restarting.
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-agents.sh
. "$DIR/scripts/lib-agents.sh"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
APPDIR="${WEFT_APP_DIR:-$HOME/Applications}"

echo "==> building (release)"
swift build -c release --package-path "$DIR"

echo "==> installing binaries to $BINDIR"
mkdir -p "$BINDIR"
cp "$DIR/.build/release/weftd" "$DIR/.build/release/weftctl" "$DIR/.build/release/weft-bar" "$BINDIR/"

echo "==> bundling WeftBar.app"
"$DIR/scripts/build-app.sh"

echo "==> installing WeftBar.app to $APPDIR"
mkdir -p "$APPDIR"
rm -rf "$APPDIR/WeftBar.app"
cp -R "$DIR/build/WeftBar.app" "$APPDIR/WeftBar.app"

echo "==> seeding config"
mkdir -p "$HOME/.config/weft"
if [ -e "$HOME/.config/weft/weft.toml" ]; then
    echo "    kept existing ~/.config/weft/weft.toml"
elif [ -e "$HOME/.config/yabai/yabairc" ] || [ -e "$HOME/.config/skhd/skhdrc" ]; then
    # A yabai user's own setup is the only config that will feel right. Seeding
    # the example instead — which this used to do unconditionally — hands them
    # a demo: layouts they never chose (the example makes one space `scroll`,
    # so a single window sits at half width) and keybinds on the wrong keys
    # (digits, when their skhdrc switches spaces with letters). Everything then
    # looks broken while working exactly as configured.
    echo "    found yabai/skhd config — migrating it"
    "$BINDIR/weftctl" migrate --write
else
    cp "$DIR/examples/weft.toml" "$HOME/.config/weft/weft.toml"
    echo "    wrote ~/.config/weft/weft.toml — a generic starting point:"
    echo "      alt-hjkl focus, alt-shift-hjkl swap, alt-1..5 spaces, alt-shift-r resize mode"
    echo "      no named spaces, no per-app placement, integrations off"
    echo "    Edit it in the menu bar (Settings…), or open the file directly."
fi

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) echo "NOTE: $BINDIR is not on PATH. Add:"; echo "  export PATH=\"$BINDIR:\$PATH\"" ;;
esac

# Before the service, not after: `weftctl service install` bootstraps weftd
# immediately, and weftd + yabai both driving the same windows is a fight the
# user watches happen. skhd goes too — its keybinds still fire yabai commands
# at a desktop weft now owns.
if [ "${WEFT_KEEP_WM:-0}" = 1 ]; then
    echo "==> leaving yabai/skhd running (WEFT_KEEP_WM=1) — expect them to fight weft"
else
    echo "==> stopping any running yabai/skhd (uninstall.sh puts them back)"
    weft_stop_wms
fi

echo "==> installing launchd service"
"$BINDIR/weftctl" service install || true

echo "==> health check"
"$BINDIR/weftctl" doctor || true

# weftd is running by now, and on start it asks the system for Accessibility
# and (when the tap fails) Input Monitoring. That request is what makes macOS
# LIST weftd in those panes — so give it a moment before Setup opens, or the
# user is looking at a list that does not have the row they need yet.
sleep 2

echo
echo "==> opening Setup"
if [ "${WEFT_NO_OPEN:-0}" = 1 ]; then
    echo "    skipped (WEFT_NO_OPEN=1) — open $APPDIR/WeftBar.app when ready"
else
    open "$APPDIR/WeftBar.app"
fi
cat <<'EOF'

--------------------------------------------------------------------------
What Setup is about to ask you for
--------------------------------------------------------------------------

Two permissions. BOTH belong to the engine, which is a separate binary
called `weftd` — not to WeftBar, the menu-bar app you can see. macOS grants
these per binary, so granting them to WeftBar would do nothing at all.

  Accessibility     moving, resizing and focusing windows
  Input Monitoring  keybinds and mouse gestures

Setup opens each System Settings pane in turn. In each one:

  1. Look down the list for a row named  weftd
  2. Turn its switch ON
  3. If macOS offers to quit and reopen something, choose "Later"

That is the whole job. Weft notices the switch within a second and moves
itself on to the next permission — no restart, no clicking Continue.

If there is no weftd row in a list — it should be there, weftd asks for
both on startup — click "No weftd row in the list?" in the Setup window.
It reveals weftd in Finder and copies its path, so you can drag it onto
the list, or use + and Cmd-Shift-G to paste the path. (The + browser
cannot reach ~/.local/bin on its own: a dotted folder is hidden.)

Screen Recording is offered too. It is optional and only powers the focus
highlight — every tiling and keybind feature works without it.

--------------------------------------------------------------------------

Check status anytime:      weftctl doctor
Settings window:           open -a WeftBar --args --settings
Back to yabai + skhd:      ./scripts/uninstall.sh
EOF
