#!/usr/bin/env bash
# Fully uninstall weft and hand the desktop back to yabai + skhd.
#
#   ./scripts/uninstall.sh          # keep ~/.config/weft (reinstall-friendly)
#   ./scripts/uninstall.sh --purge  # also delete config + onboarded flag
#
# Mirrors scripts/install.sh.
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib-agents.sh
. "$DIR/scripts/lib-agents.sh"
BINDIR="${PREFIX:-$HOME/.local}/bin"
APPDIR="${WEFT_APP_DIR:-$HOME/Applications}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

# Scroll layouts park off-screen columns by moving them ~5000px west of every
# display. Killing weftd with columns parked strands those windows where no
# amount of clicking finds them, so unpark before anything else — while the
# daemon that knows about them is still alive.
if [ -x "$BINDIR/weftctl" ]; then
    echo "==> rescuing parked windows"
    "$BINDIR/weftctl" rescue || echo "    (daemon not running — nothing to rescue)"
fi

echo "==> stopping weft service"
if [ -x "$BINDIR/weftctl" ]; then
    "$BINDIR/weftctl" service stop || true
    "$BINDIR/weftctl" service uninstall || true
else
    # Binary already gone: bootout directly.
    /bin/launchctl bootout "gui/$(id -u)/com.weft.weftd" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.weft.weftd.plist"
fi

echo "==> killing processes"
killall weftd weft-bar WeftBar 2>/dev/null || true
sleep 1
if pgrep -fl "weftd|weft-bar|WeftBar" >/dev/null 2>&1; then
    echo "    leftover weft processes:"
    pgrep -fl "weftd|weft-bar|WeftBar" || true
else
    echo "    no weft processes running"
fi

echo "==> removing binaries from $BINDIR"
rm -f "$BINDIR/weftd" "$BINDIR/weftctl" "$BINDIR/weft-bar"

echo "==> removing WeftBar.app"
rm -rf "$APPDIR/WeftBar.app" "/Applications/WeftBar.app"

if [ "$PURGE" = 1 ]; then
    echo "==> purging config"
    rm -rf "$HOME/.config/weft"
else
    echo "    kept ~/.config/weft (use --purge to delete)"
fi

# Restore the exact agents install.sh stopped, by label and plist path. See
# lib-agents.sh for why `brew services start yabai` is the wrong thing: it
# starts a different agent than the one that was running and leaves two
# registered, both RunAtLoad.
echo "==> starting yabai + skhd"
weft_restore_wms
sleep 1

# Scripting addition: only needed if it was uninstalled for weft testing.
if ! yabai --check-sa 2>/dev/null; then
    echo "NOTE: yabai scripting addition not loaded."
    echo "  If you uninstalled it earlier, restore with:"
    echo "    sudo yabai --install-sa && yabai --load-sa"
    echo "  (requires SIP with scripting-addition exception; then log out/in)"
fi

echo
echo "==> verifying"
pgrep -fl "yabai|skhd" || echo "WARNING: yabai/skhd do not appear to be running"
if pgrep -fl "weftd|weft-bar" >/dev/null 2>&1; then
    echo "WARNING: weft processes still alive (see above)"
else
    echo "weft fully uninstalled."
fi
