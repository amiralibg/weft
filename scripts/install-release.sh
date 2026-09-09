#!/usr/bin/env bash
# Install a released weft build — no clone, no toolchain, no compile.
#
#   curl -fsSL https://raw.githubusercontent.com/amiralibg/weft/main/scripts/install-release.sh | bash
#
# Or, from an unpacked release archive, just: ./install.sh
#
# Environment:
#   WEFT_VERSION=v0.1.0   install a specific tag instead of the latest
#   PREFIX=/opt/homebrew  binaries go to $PREFIX/bin        (default ~/.local)
#   WEFT_APP_DIR=...      WeftBar.app goes here             (default ~/Applications)
#   WEFT_KEEP_WM=1        leave yabai/skhd running          (they will fight weft)
#   WEFT_NO_SERVICE=1     install the files but do not register the launchd job
#   WEFT_NO_OPEN=1        do not open Setup at the end
set -euo pipefail

REPO="amiralibg/weft"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
APPDIR="${WEFT_APP_DIR:-$HOME/Applications}"

say() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ preflight

[ "$(uname -s)" = "Darwin" ] || die "weft is macOS only (this is $(uname -s))."

major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || die "weft needs macOS 15 or later (this is $(sw_vers -productVersion))."

# ------------------------------------------------- find the payload to install
# Two modes: run from inside an unpacked archive (the file sits next to the
# payload), or run standalone from curl, in which case fetch the release first.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -d "$HERE/bin" ] && [ -d "$HERE/WeftBar.app" ]; then
    STAGE="$HERE"
    say "installing from $STAGE"
else
    command -v curl >/dev/null || die "curl is required."

    TAG="${WEFT_VERSION:-}"
    if [ -z "$TAG" ]; then
        say "looking up the latest release"
        TAG=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
              | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
        [ -n "$TAG" ] || die "could not determine the latest release. Set WEFT_VERSION=vX.Y.Z, or build from source: https://github.com/$REPO"
    fi
    VERSION="${TAG#v}"
    ASSET="weft-$VERSION-macos-universal.tar.gz"
    BASE="https://github.com/$REPO/releases/download/$TAG"

    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    say "downloading weft $VERSION"
    curl -fsSL "$BASE/$ASSET" -o "$TMP/$ASSET" \
        || die "could not download $BASE/$ASSET"

    # Verify before unpacking anything, not after.
    if curl -fsSL "$BASE/$ASSET.sha256" -o "$TMP/$ASSET.sha256" 2>/dev/null; then
        say "verifying checksum"
        expected=$(cut -d' ' -f1 < "$TMP/$ASSET.sha256")
        actual=$(shasum -a 256 "$TMP/$ASSET" | cut -d' ' -f1)
        [ "$expected" = "$actual" ] \
            || die "checksum mismatch — refusing to install.
  expected $expected
  got      $actual"
        echo "    ok ($actual)"
    else
        warn "no published checksum for this release; skipping verification"
    fi

    tar -xzf "$TMP/$ASSET" -C "$TMP"
    STAGE="$TMP/weft-$VERSION"
    [ -d "$STAGE/bin" ] || die "unexpected archive layout in $ASSET"
fi

# --------------------------------------------------------- upgrade detection
# Worth knowing before anything is replaced: ad-hoc signed binaries are
# identified to TCC by their contents, so a new build is a different program as
# far as macOS is concerned and the old grants do not carry over.
UPGRADE_FROM=""
if [ -x "$BINDIR/weftctl" ]; then
    UPGRADE_FROM="$("$BINDIR/weftctl" --version 2>/dev/null || echo "an older build")"
fi

# ------------------------------------------------------------------- install

say "stopping any running weft"
if [ -x "$BINDIR/weftctl" ]; then
    "$BINDIR/weftctl" service stop >/dev/null 2>&1 || true
fi
pkill -x WeftBar >/dev/null 2>&1 || true

say "installing binaries to $BINDIR"
mkdir -p "$BINDIR"
cp "$STAGE/bin/weftd" "$STAGE/bin/weftctl" "$BINDIR/"
chmod +x "$BINDIR/weftd" "$BINDIR/weftctl"

say "installing WeftBar.app to $APPDIR"
mkdir -p "$APPDIR"
rm -rf "$APPDIR/WeftBar.app"
cp -R "$STAGE/WeftBar.app" "$APPDIR/WeftBar.app"

# ------------------------------------------------------------------- signing
# Give the binaries a stable identity, unless this build already has one.
#
# macOS keys a permission to a program's designated requirement. For an ad-hoc
# signed build that requirement is the code directory hash, so the NEXT release
# is a different program and every grant silently stops applying — while the
# switches in System Settings stay visibly on, granting nothing. Signing with a
# self-signed certificate moves the requirement onto the identity, and it then
# survives every future update.
#
# A build signed with a Developer ID already has a stable identity and may be
# notarised; re-signing would break the notarisation and buy nothing, so the
# check is for a certificate in the requirement, not for the absence of one.
if [ -f "$STAGE/lib-codesign.sh" ]; then
    # shellcheck source=lib-codesign.sh
    . "$STAGE/lib-codesign.sh"
    if codesign -d -r- "$BINDIR/weftd" 2>&1 | grep -q "certificate leaf"; then
        say "release is signed with a certificate — permissions will survive updates"
    else
        say "signing with a local identity so permissions survive updates"
        # Never fatal. An unsigned weft works perfectly; it just loses its
        # permissions on the next update. Aborting here would leave binaries
        # installed and no service running, which is strictly worse.
        IDENT="$(weft_signing_identity || true)"
        SIGNED=1
        if [ -n "$IDENT" ]; then
            weft_codesign com.weft.weftd   "$BINDIR/weftd"        "$IDENT" || SIGNED=0
            weft_codesign com.weft.weftctl "$BINDIR/weftctl"      "$IDENT" || SIGNED=0
            weft_codesign com.weft.bar     "$APPDIR/WeftBar.app"  "$IDENT" || SIGNED=0
        else
            SIGNED=0
        fi
        if [ "$SIGNED" = 1 ]; then
            echo "    identity fingerprint: $(weft_signing_fingerprint "$BINDIR/weftd")"
        else
            warn "could not sign weft with a stable identity — it will still run, but
  macOS will drop its permissions the next time you update, and the switches in
  System Settings will still read as on. Re-granting them fixes it each time."
        fi
    fi
fi

# macOS quarantines anything that arrived over the network. On an ad-hoc signed
# build that means Gatekeeper refuses to launch it at all ("damaged and can't be
# opened"), which is a lie — it is unsigned, not damaged. Clearing the flag on
# the files we just placed is the honest fix; it is exactly what dragging from a
# notarised DMG would leave behind.
say "clearing the download quarantine flag"
xattr -dr com.apple.quarantine "$BINDIR/weftd" "$BINDIR/weftctl" \
    "$APPDIR/WeftBar.app" 2>/dev/null || true

# --------------------------------------------------------------- config seed

say "seeding config"
mkdir -p "$HOME/.config/weft"
if [ -e "$HOME/.config/weft/weft.toml" ]; then
    echo "    kept your existing ~/.config/weft/weft.toml"
elif [ -e "$HOME/.config/yabai/yabairc" ] || [ -e "$HOME/.config/skhd/skhdrc" ]; then
    # Their own setup is the only config that will feel right. Seeding the
    # generic example over a yabai user hands them keybinds on the wrong keys
    # and layouts they never chose — everything looks broken while working
    # exactly as configured.
    echo "    found yabai/skhd config — migrating it"
    "$BINDIR/weftctl" migrate --write
elif [ -e "$STAGE/weft.toml.example" ]; then
    cp "$STAGE/weft.toml.example" "$HOME/.config/weft/weft.toml"
    echo "    wrote ~/.config/weft/weft.toml — a generic starting point:"
    echo "      alt-hjkl focus, alt-shift-hjkl swap, alt-1..5 spaces, alt-shift-r resize mode"
fi

# ----------------------------------------------------------- other managers

if [ "${WEFT_KEEP_WM:-0}" = 1 ]; then
    say "leaving yabai/skhd alone (WEFT_KEEP_WM=1) — expect them to fight weft"
elif [ -f "$STAGE/lib-agents.sh" ]; then
    say "stopping any running yabai/skhd (uninstall.sh puts them back)"
    # shellcheck source=lib-agents.sh
    . "$STAGE/lib-agents.sh"
    weft_stop_wms
fi

# --------------------------------------------------------------- the service

if [ "${WEFT_NO_SERVICE:-0}" = 1 ]; then
    say "not registering the launchd service (WEFT_NO_SERVICE=1)"
    echo "    start it yourself with: $BINDIR/weftctl service install"
else
    say "installing the launchd service"
    "$BINDIR/weftctl" service install || true
fi

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) warn "$BINDIR is not on your PATH. Add this to your shell profile:"
       echo "  export PATH=\"$BINDIR:\$PATH\"" ;;
esac

# weftd asks the system for its permissions on start, and that request is what
# makes macOS *list* it in those panes. Opening Setup before it lands shows a
# list missing the row the user needs.
sleep 2

if [ "${WEFT_NO_SERVICE:-0}" != 1 ]; then
    say "health check"
    "$BINDIR/weftctl" doctor || true
fi

# ------------------------------------------------------------------- finish

echo
if [ -n "$UPGRADE_FROM" ]; then
    cat <<EOF
--------------------------------------------------------------------------
Upgraded from: $UPGRADE_FROM

macOS identifies an unsigned binary by its contents, so as far as Privacy &
Security is concerned this is a NEW program — the Accessibility and Input
Monitoring switches you granted before do not carry over.

The weftd row may still LOOK enabled while being denied. If so, toggle it
off and on again:

  System Settings > Privacy & Security > Accessibility     > weftd
  System Settings > Privacy & Security > Input Monitoring  > weftd

Setup opens by itself when anything is missing.
--------------------------------------------------------------------------
EOF
else
    cat <<'EOF'
--------------------------------------------------------------------------
Three permissions, and ALL belong to `weftd` — the engine — not to WeftBar,
the menu-bar app you can see. macOS grants these per binary.

  Accessibility     moving, resizing and focusing windows
  Input Monitoring  keybinds and mouse gestures
  Screen Recording  reading window titles, for rules and the switcher

Setup opens each pane in turn. In each one, find the row named `weftd` and
turn its switch on — and if it is ALREADY on, turn it off and on again.
Weft notices within a second; nothing needs restarting.
--------------------------------------------------------------------------
EOF
fi

echo
echo "Check status:   weftctl doctor"
echo "Settings:       open -a WeftBar --args --settings"
# Not a curl one-liner: uninstall.sh needs lib-agents.sh beside it to put the
# user's own yabai/skhd launchd agents back by the labels it recorded.
if [ -f "$STAGE/uninstall.sh" ]; then
    echo "Uninstall:      $STAGE/uninstall.sh   (keep this archive, or clone the repo)"
else
    echo "Uninstall:      ./scripts/uninstall.sh  from a clone of https://github.com/$REPO"
fi
echo

if [ "${WEFT_NO_OPEN:-0}" = 1 ]; then
    say "not opening Setup (WEFT_NO_OPEN=1) — open $APPDIR/WeftBar.app when ready"
else
    say "opening Setup"
    open "$APPDIR/WeftBar.app"
fi
