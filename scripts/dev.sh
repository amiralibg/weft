#!/usr/bin/env bash
# Try a change on this Mac without cutting a release.
#
#   ./scripts/dev.sh              build this checkout and run it in place of the
#                                 installed weft (engine + WeftBar), then restart
#   ./scripts/dev.sh test         swift build + swift test
#   ./scripts/dev.sh check        doctor, both hide/show self-tests, 20 s idle bench
#   ./scripts/dev.sh logs         follow the engine's log
#   ./scripts/dev.sh snapshots    render every Settings pane and Setup page to PNG
#   ./scripts/dev.sh status       which weft is installed: a release, or a local build
#   ./scripts/dev.sh release      go back to the latest published release
#
# The local build goes exactly where a release goes (~/.local/bin and
# ~/Applications/WeftBar.app) and is signed with the same local identity the
# release installer uses. macOS ties Accessibility and Input Monitoring to that
# identity, so switching between a local build and a release keeps every
# permission: no toggling switches in System Settings.
#
# Your config is never touched. A marker next to the binaries records which
# commit is running; `weftctl doctor` shows it, and `dev.sh release` removes it.
#
# Environment: PREFIX (default ~/.local), WEFT_APP_DIR (default ~/Applications).
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
APPDIR="${WEFT_APP_DIR:-$HOME/Applications}"
MARKER="$BINDIR/.weft-local-build"
LOG="$HOME/Library/Logs/weft/weftd.err.log"

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

version() { sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$DIR/Sources/WeftCore/Version.swift"; }

commit() {
    local sha
    sha="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    if [ -n "$(git -C "$DIR" status --porcelain 2>/dev/null)" ]; then sha="$sha+changes"; fi
    echo "$sha"
}

quit_bar() {
    # Politely first, so it saves the Settings window's last edit.
    osascript -e 'tell application id "com.weft.bar" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x WeftBar >/dev/null || return 0
        sleep 0.2
    done
    pkill -x WeftBar 2>/dev/null || true
}

install_local() {
    # shellcheck source=lib-codesign.sh
    . "$DIR/scripts/lib-codesign.sh"
    local sha; sha="$(commit)"

    say "building $(version) from $sha (release configuration)"
    local buildlog; buildlog="$(mktemp -t weft-dev-build)"
    if ! swift build -c release --package-path "$DIR" >"$buildlog" 2>&1; then
        grep -E "error:" "$buildlog" | head -20 >&2 || tail -20 "$buildlog" >&2
        die "the build failed — nothing was installed (full log: $buildlog)"
    fi
    rm -f "$buildlog"

    say "signing with your local identity (keeps permissions)"
    local identity; identity="$(weft_signing_identity || true)"
    if [ -n "$identity" ]; then
        # Not fatal, as in install.sh: unsigned still runs, it just loses
        # its permissions.
        weft_codesign com.weft.weftd   "$DIR/.build/release/weftd"    "$identity" \
            && weft_codesign com.weft.weftctl "$DIR/.build/release/weftctl"  "$identity" \
            && weft_codesign com.weft.bar     "$DIR/.build/release/weft-bar" "$identity" \
            || echo "    WARNING: signing failed — macOS may ask for permissions again"
    else
        echo "    WARNING: no signing identity — macOS will ask for permissions again"
    fi

    say "bundling WeftBar.app"
    WEFT_SELFSIGN_IDENTITY="$identity" "$DIR/scripts/build-app.sh" >/dev/null

    say "stopping the running weft"
    quit_bar
    "$BINDIR/weftctl" service stop >/dev/null 2>&1 || true

    say "installing into $BINDIR and $APPDIR"
    mkdir -p "$BINDIR" "$APPDIR"
    for b in weftd weftctl; do
        # Replace, never write in place: a running binary rewritten under
        # itself can crash, and the signature must match the bytes.
        cp "$DIR/.build/release/$b" "$BINDIR/.$b.new"
        mv -f "$BINDIR/.$b.new" "$BINDIR/$b"
    done
    rm -rf "$APPDIR/WeftBar.app"
    cp -R "$DIR/build/WeftBar.app" "$APPDIR/WeftBar.app"
    printf 'commit=%s\nversion=%s\nbuilt=%s\nsource=%s\n' \
        "$sha" "$(version)" "$(date '+%Y-%m-%d %H:%M')" "$DIR" > "$MARKER"

    mkdir -p "$HOME/.config/weft"
    if [ ! -e "$HOME/.config/weft/weft.toml" ]; then
        cp "$DIR/examples/weft.toml" "$HOME/.config/weft/weft.toml"
        echo "    no config yet — wrote the default ~/.config/weft/weft.toml"
    fi

    say "starting weft"
    if [ -e "$HOME/Library/LaunchAgents/com.weft.weftd.plist" ]; then
        "$BINDIR/weftctl" service start >/dev/null 2>&1 || "$BINDIR/weftctl" service restart
    else
        "$BINDIR/weftctl" service install
    fi
    sleep 1
    open "$APPDIR/WeftBar.app"

    echo
    echo "Running your local build: weft $(version), commit $sha."
    echo "  ./scripts/dev.sh logs      follow what the engine is doing"
    echo "  ./scripts/dev.sh check     health check and self-tests"
    echo "  ./scripts/dev.sh release   back to the published release"
}

status() {
    if [ ! -x "$BINDIR/weftctl" ]; then
        echo "weft is not installed in $BINDIR."
        return
    fi
    echo "Installed: $("$BINDIR/weftctl" --version 2>/dev/null || echo "weftctl does not run")"
    if [ -e "$MARKER" ]; then
        local built_from built_at
        built_from="$(sed -n 's/^commit=//p' "$MARKER")"
        built_at="$(sed -n 's/^built=//p' "$MARKER")"
        echo "Kind:      local build of commit ${built_from:-?}, built ${built_at:-?}"
        echo "           ./scripts/dev.sh release goes back to the published release"
    else
        echo "Kind:      published release"
    fi
    "$BINDIR/weftctl" service status 2>/dev/null || true
}

case "${1:-install}" in
    install|"")
        install_local
        ;;
    test)
        swift build --package-path "$DIR"
        swift test --package-path "$DIR" 2>&1 | grep -E "Test run with|✘|error:" || true
        ;;
    check)
        [ -x "$BINDIR/weftctl" ] || die "weft is not installed — run ./scripts/dev.sh first"
        status
        echo
        "$BINDIR/weftctl" doctor || true
        echo
        say "hide/show self-test, WindowServer path"
        "$BINDIR/weftctl" doctor --selftest || true
        say "hide/show self-test, public (Accessibility) path"
        WEFT_PUBLIC_ONLY=1 "$BINDIR/weftctl" doctor --selftest || true
        say "idle cost over 20 s — leave the machine alone"
        "$BINDIR/weftctl" bench idle 20 || true
        ;;
    logs)
        [ -e "$LOG" ] || die "no log yet at $LOG — is weft running?"
        tail -n 40 -f "$LOG"
        ;;
    snapshots)
        OUT="${2:-$DIR/build/snapshots}"
        swift build --package-path "$DIR" >/dev/null
        rm -rf "$OUT"
        "$DIR/.build/debug/weft-bar" --render-snapshots "$OUT"
        echo "Rendered into $OUT"
        open "$OUT"
        ;;
    status)
        status
        ;;
    release)
        say "going back to the latest published release"
        quit_bar
        rm -f "$MARKER"
        bash "$DIR/scripts/install-release.sh"
        ;;
    -h|--help|help)
        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        die "unknown command '$1' — try ./scripts/dev.sh help"
        ;;
esac
