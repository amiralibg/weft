#!/usr/bin/env bash
# Install weft's engine from inside WeftBar.app. WeftBar runs this on first
# launch, and again whenever the app has been replaced by a newer version —
# which is what makes installing weft "open the app" and updating it
# "replace the app".
#
# WeftBar.app carries weftd and weftctl in Contents/MacOS, but they are not
# run from there. The stable signing identity that keeps macOS permissions
# alive across updates (lib-codesign.sh) is created on this machine, and
# re-signing code inside the app bundle would break the app's own signature.
# So the engine is copied to ~/.local/bin and signed there: the same place
# and the same identity install.sh and install-release.sh use, so any of the
# three can update what another one put down.
#
# Lines starting with "==> " are the step WeftBar shows; everything else is
# detail for the log (~/Library/Logs/weft-install.log). Exit status is the
# verdict.
#
#   WEFT_BUNDLE     path to WeftBar.app (required)
#   PREFIX          binaries go to $PREFIX/bin (default ~/.local)
#   WEFT_PAUSE_WM=1 pause a running yabai/skhd first (uninstall restarts it)
#   WEFT_MIGRATE=1  seed the config from yabai/skhd, not weft's example
set -euo pipefail

BUNDLE="${WEFT_BUNDLE:?WEFT_BUNDLE must point at WeftBar.app}"
ENGINE="$BUNDLE/Contents/MacOS"
RES="$BUNDLE/Contents/Resources"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"

say() { printf '==> %s\n' "$*"; }

if [ ! -x "$ENGINE/weftd" ] || [ ! -x "$ENGINE/weftctl" ]; then
    echo "this WeftBar.app does not carry the engine ($ENGINE)" >&2
    exit 1
fi

say "Stopping the running engine"
if [ -x "$BINDIR/weftctl" ]; then
    "$BINDIR/weftctl" service stop >/dev/null 2>&1 || true
fi

say "Copying the engine into place"
mkdir -p "$BINDIR"
# Beside the target, then renamed over it: a running weftd being truncated
# under itself is a crash, while a rename leaves the old inode to whoever
# still has it open.
for b in weftd weftctl; do
    cp "$ENGINE/$b" "$BINDIR/.$b.new"
    chmod +x "$BINDIR/.$b.new"
    mv -f "$BINDIR/.$b.new" "$BINDIR/$b"
done
# The app arrived over the network, so its contents may carry the flag.
xattr -d com.apple.quarantine "$BINDIR/weftd" 2>/dev/null || true
xattr -d com.apple.quarantine "$BINDIR/weftctl" 2>/dev/null || true

say "Signing it so macOS keeps its permissions across updates"
# A binary that is already certificate-signed — a Developer ID release, or a
# local build install.sh signed with this machine's identity — keeps its
# signature: re-signing would break notarisation and buys nothing.
if codesign -d -r- "$BINDIR/weftd" 2>&1 | grep -q "certificate leaf"; then
    echo "    already signed with a certificate"
else
    # shellcheck source=lib-codesign.sh
    . "$RES/lib-codesign.sh"
    IDENT="$(weft_signing_identity || true)"
    if [ -n "$IDENT" ] \
        && weft_codesign com.weft.weftd "$BINDIR/weftd" "$IDENT" \
        && weft_codesign com.weft.weftctl "$BINDIR/weftctl" "$IDENT"; then
        echo "    identity fingerprint: $(weft_signing_fingerprint "$BINDIR/weftd")"
    else
        # Never fatal: an unsigned weft works, it just loses its permissions
        # on the next update. Stopping here would leave no engine running.
        echo "    WARNING: could not sign weft with a stable identity — it will run,"
        echo "    but macOS will drop its permissions the next time it is updated"
    fi
fi

say "Setting up your config"
mkdir -p "$HOME/.config/weft"
if [ -e "$HOME/.config/weft/weft.toml" ]; then
    echo "    kept your existing ~/.config/weft/weft.toml"
    # Drop the two workspace-model keys 0.9.15 retired (0.9.11–0.9.14 wrote
    # them); weft warns about them otherwise. Comment-preserving, no-op if absent.
    "$BINDIR/weftctl" config tidy || true
elif [ "${WEFT_MIGRATE:-0}" = 1 ]; then
    # Migrating is opt-in. Doing it whenever a yabairc existed gave every
    # yabai user, the maintainer included, their old desktops, apps and binds
    # instead of weft's own starting point, often with no idea where they
    # came from. The example is what weft is designed around; the migration
    # is one command away and says so.
    echo "    migrating your yabai/skhd config (WEFT_MIGRATE=1)"
    "$BINDIR/weftctl" migrate --write || cp "$RES/weft.toml" "$HOME/.config/weft/weft.toml"
else
    cp "$RES/weft.toml" "$HOME/.config/weft/weft.toml"
    echo "    wrote ~/.config/weft/weft.toml"
fi

# Other software is left alone unless asked: switching off someone else's
# tools is not an installer's call. WEFT_PAUSE_WM=1 pauses a running
# yabai/skhd and records it; uninstall.sh restarts exactly what it recorded.
if [ "${WEFT_PAUSE_WM:-0}" = 1 ]; then
    say "Pausing yabai and skhd"
    # shellcheck source=lib-agents.sh
    . "$RES/lib-agents.sh"
    weft_stop_wms
fi

say "Starting the engine"
"$BINDIR/weftctl" service install

say "Done"
