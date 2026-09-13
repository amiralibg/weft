#!/usr/bin/env bash
# Remove weft from this Mac.
#
#   uninstall.sh            remove weft, keep your settings for a reinstall
#   uninstall.sh --purge    remove everything: settings, the signing identity,
#                           and weft's rows in Privacy & Security
#   uninstall.sh --dry-run  list what would be removed, and remove nothing
#
# This is also what "Uninstall Weft…" in the menu bar runs: WeftBar carries
# this script and passes its own location as WEFT_APP_PATH.
#
# Your windows are not touched. They stay where they are, as ordinary windows.
set -u

PURGE=0
DRY=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        --dry-run | -n) DRY=1 ;;
        -h | --help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BINDIR="${PREFIX:-$HOME/.local}/bin"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/weft"
SOCKET="${TMPDIR:-/tmp/}weft-${USER:-$(id -un)}.sock"
PLIST="$HOME/Library/LaunchAgents/com.weft.weftd.plist"
KEYCHAIN="$HOME/Library/Keychains/weft-signing.keychain-db"

say() { printf '==> %s\n' "$*"; }

# Remove paths, or in a dry run name them.
remove() {
    for path in "$@"; do
        [ -e "$path" ] || [ -L "$path" ] || continue
        if [ "$DRY" = 1 ]; then
            echo "    would remove $path"
        elif rm -rf "$path"; then
            echo "    removed $path"
        fi
    done
}

[ "$DRY" = 1 ] && say "Dry run — nothing will be removed"

# A window left off every display — dragged there, or stranded by an
# unplugged monitor — comes back while the engine that knows where it
# belongs is still running.
if [ "$DRY" = 0 ] && [ -x "$BINDIR/weftctl" ]; then
    say "Bringing back any window that is off screen"
    "$BINDIR/weftctl" rescue >/dev/null 2>&1 || true
fi

say "Stopping the engine"
if [ "$DRY" = 1 ]; then
    /bin/launchctl print "gui/$(id -u)/com.weft.weftd" >/dev/null 2>&1 \
        && echo "    would stop the com.weft.weftd login service"
else
    /bin/launchctl bootout "gui/$(id -u)/com.weft.weftd" >/dev/null 2>&1 || true
    killall weftd >/dev/null 2>&1 || true
fi
remove "$PLIST"

say "Quitting the menu bar app"
if [ "$DRY" = 0 ]; then
    killall WeftBar weft-bar >/dev/null 2>&1 || true
fi

# Earlier versions paused other tools when they were installed, and recorded
# exactly which ones. Put those back, and only those. A Mac weft never paused
# anything on has no record, and nothing here runs. Done before the app goes:
# the helper that knows how may live inside it.
if [ -s "$STATE/displaced-agents" ]; then
    for lib in "$HERE/lib-agents.sh" "$HERE/../scripts/lib-agents.sh"; do
        [ -f "$lib" ] || continue
        say "Restarting what weft paused when it was installed"
        if [ "$DRY" = 1 ]; then
            cut -f1 "$STATE/displaced-agents" | sed 's/^/    would restart /'
        else
            # shellcheck source=lib-agents.sh
            . "$lib"
            weft_restore_wms
        fi
        break
    done
fi

say "Removing the engine"
remove "$BINDIR/weftd" "$BINDIR/weftctl" "$BINDIR/weft-bar" \
    "$BINDIR/.weftd.new" "$BINDIR/.weftctl.new"

say "Removing the app"
remove ${WEFT_APP_PATH:+"$WEFT_APP_PATH"} "$HOME/Applications/WeftBar.app" "/Applications/WeftBar.app"

say "Removing logs and leftovers"
remove "$SOCKET" "$HOME/Library/Logs/weft" \
    /tmp/weftd.out.log /tmp/weftd.err.log \
    "$HOME/Library/Logs/weft-install.log" "$HOME/Library/Logs/weft-update.log" \
    "$STATE"

if [ "$PURGE" = 1 ]; then
    # The identity every permission grant is keyed to. Only on a purge: keep
    # it, and a reinstall keeps its permissions without asking again.
    #
    # Before the settings, which hold its password: a keychain that outlives
    # its password file makes the next install ask for a password nobody knows.
    say "Removing weft's signing identity"
    if [ -f "$KEYCHAIN" ]; then
        if [ "$DRY" = 1 ]; then
            echo "    would remove $KEYCHAIN"
        elif security delete-keychain "$KEYCHAIN" >/dev/null 2>&1; then
            echo "    removed $KEYCHAIN"
        elif rm -f "$KEYCHAIN"; then
            echo "    removed $KEYCHAIN (not on the keychain search list)"
        else
            echo "WARNING: could not remove $KEYCHAIN — delete it by hand"
        fi
    fi

    say "Removing your settings"
    remove "$HOME/.config/weft"

    say "Removing weft from Privacy & Security"
    for id in com.weft.weftd com.weft.bar; do
        if [ "$DRY" = 1 ]; then
            echo "    would reset the permissions granted to $id"
        else
            tccutil reset All "$id" >/dev/null 2>&1 || true
        fi
    done
    [ "$DRY" = 0 ] && echo "    if a weftd row is still listed in System Settings, select it and press −"
else
    echo "    kept your settings (~/.config/weft) and the signing identity, so a"
    echo "    reinstall picks up where you left off — run with --purge to remove them too"
fi

if [ "$DRY" = 0 ]; then
    if pgrep -x weftd >/dev/null 2>&1; then
        echo "WARNING: weftd is still running"
    else
        say "Weft is removed"
    fi
    # Run from the app, nobody is watching this output: the app has quit.
    if [ -n "${WEFT_APP_PATH:-}" ]; then
        osascript -e 'display notification "Weft has been removed from this Mac." with title "Weft"' \
            >/dev/null 2>&1 || true
    fi
fi
