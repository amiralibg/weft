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
# shellcheck source=lib-codesign.sh
. "$DIR/scripts/lib-codesign.sh"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
APPDIR="${WEFT_APP_DIR:-$HOME/Applications}"

echo "==> building (release)"
swift build -c release --package-path "$DIR"

# Sign before installing, and before the .app is built, so every copy carries
# the same identity. Unsigned, macOS keys weft's permissions to the exact bytes
# of the binary, and this rebuild would silently invalidate the grants the user
# already made — while leaving the switches in System Settings visibly ON, with
# nothing for them to fix. See scripts/lib-codesign.sh.
SIGN_IDENTITY="$(weft_signing_identity || true)"
if [ -n "$SIGN_IDENTITY" ]; then
    echo "==> signing binaries as \"$SIGN_IDENTITY\""
    # Non-fatal: an unsigned weft runs fine, it just loses its permissions on
    # the next rebuild. Half an install is worse than an unsigned one.
    SIGNED=1
    weft_codesign com.weft.weftd   "$DIR/.build/release/weftd"    "$SIGN_IDENTITY" || SIGNED=0
    weft_codesign com.weft.weftctl "$DIR/.build/release/weftctl"  "$SIGN_IDENTITY" || SIGNED=0
    weft_codesign com.weft.bar     "$DIR/.build/release/weft-bar" "$SIGN_IDENTITY" || SIGNED=0
    if [ "$SIGNED" = 1 ]; then
        echo "    identity fingerprint: $(weft_signing_fingerprint "$DIR/.build/release/weftd")"
        echo "    grants survive future rebuilds as long as this identity is kept"
    else
        echo "    WARNING: signing failed — macOS will drop weft's permissions on the next rebuild"
    fi
else
    echo "==> WARNING: no signing identity — permissions will be dropped by the next rebuild"
fi

echo "==> installing binaries to $BINDIR"
mkdir -p "$BINDIR"
cp "$DIR/.build/release/weftd" "$DIR/.build/release/weftctl" "$DIR/.build/release/weft-bar" "$BINDIR/"

echo "==> bundling WeftBar.app"
WEFT_SELFSIGN_IDENTITY="$SIGN_IDENTITY" "$DIR/scripts/build-app.sh"

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

# Other software is left alone unless asked. WEFT_PAUSE_WM=1 pauses a running
# yabai/skhd before the service starts — two window managers driving the same
# windows is a fight — and records it, so uninstall.sh restarts exactly that.
if [ "${WEFT_PAUSE_WM:-0}" = 1 ]; then
    echo "==> pausing yabai/skhd (WEFT_PAUSE_WM=1)"
    weft_stop_wms
fi

echo "==> installing launchd service"
"$BINDIR/weftctl" service install || true

echo "==> health check"
"$BINDIR/weftctl" doctor || true

# Give weftd a moment to initialize its socket before opening Setup.
sleep 1

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

Three permissions. ALL belong to the engine, which is a separate binary
called `weftd` — not to WeftBar, the menu-bar app you can see. macOS grants
these per binary, so granting them to WeftBar would do nothing at all.

  Accessibility     moving, resizing and focusing windows
  Input Monitoring  keybinds and mouse gestures
  Screen Recording  reading window titles

Screen Recording is not about recording anything. Without it macOS blanks
out the title of every window weft did not open itself, so rules that match
on a window title match nothing and the window switcher lists empty rows.

Setup opens each System Settings pane in turn. In each one:

  1. Look down the list for a row named  weftd
  2. Turn its switch ON  --  and if it is ALREADY on, turn it off and
     on again (see below)
  3. If macOS offers to quit and reopen something, choose "Later"

Why "off and on again": macOS ties a permission to the exact program that
was granted it, and until this version weft was not signed, so every
rebuild produced a program macOS considered different — while leaving the
switch visibly ON for the old one. This install signs weft with a stable
identity, so it is the LAST time you have to do this. Updates from here on
keep their permissions.

That is the whole job. Weft notices the switch within a second and moves
itself on to the next permission — no restart, no clicking Continue.

If macOS asks first, choose "Open System Settings". If there is still no
weftd row in a list, click "No weftd row in the list?" in the Setup window.
It reveals weftd in Finder and copies its path, so you can drag it onto
the list, or use + and Cmd-Shift-G to paste the path. (The + browser
cannot reach ~/.local/bin on its own: a dotted folder is hidden.)

--------------------------------------------------------------------------

Check status anytime:      weftctl doctor
Settings window:           open -a WeftBar --args --settings
Uninstall:                 ./scripts/uninstall.sh   (--purge removes settings too)
EOF
