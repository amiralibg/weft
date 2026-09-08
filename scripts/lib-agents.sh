#!/usr/bin/env bash
# Shared by install.sh and uninstall.sh: stop whatever launchd agents are
# currently running yabai/skhd, and put back exactly those.
#
# Why this is not `brew services start yabai`: the agent running yabai is
# whatever plist the user installed, and its label is not fixed. On this
# machine it is `com.asmvik.yabai`, not `com.koekeishiya.yabai` (what
# `yabai --start-service` installs) and not `homebrew.mxcl.yabai` (what
# `brew services` installs). Guessing the label leaves the real agent stopped
# and bootstraps a SECOND, differently-configured one alongside it — both set
# to RunAtLoad, so the next login starts two window managers.
#
# So: discover the labels that are actually loaded, record them with their
# plist paths, and restore from that record.

WEFT_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/weft"
WEFT_DISPLACED="$WEFT_STATE_DIR/displaced-agents"

# Labels of loaded gui agents whose name ends in .yabai/.skhd (or is exactly
# that). Anchored on purpose: it must not match helper apps that merely
# mention yabai, e.g. `application.local.yabai.spaces.<pid>.<n>`.
weft_wm_labels() {
    /bin/launchctl list 2>/dev/null \
        | awk 'NR > 1 { print $3 }' \
        | grep -Ei '(^|\.)(yabai|skhd)$' \
        || true
}

weft_plist_for_label() {
    local label="$1" guess="$HOME/Library/LaunchAgents/$1.plist"
    if [ -f "$guess" ]; then
        printf '%s\n' "$guess"
        return
    fi
    # Not in the usual place — ask launchd where it loaded it from.
    /bin/launchctl print "gui/$(id -u)/$label" 2>/dev/null \
        | awk -F' = ' '/^[[:space:]]*path = /{ print $2; exit }'
}

# Stop every yabai/skhd agent and remember it. Safe to call when none run.
weft_stop_wms() {
    local uid label plist found=0
    uid="$(id -u)"
    mkdir -p "$WEFT_STATE_DIR"
    : > "$WEFT_DISPLACED"
    while IFS= read -r label; do
        [ -z "$label" ] && continue
        found=1
        plist="$(weft_plist_for_label "$label")"
        echo "    stopping $label"
        # bootout, not killall: these agents set KeepAlive, so a kill just
        # brings them straight back.
        /bin/launchctl bootout "gui/$uid/$label" 2>/dev/null || true
        if [ -n "$plist" ]; then
            printf '%s\t%s\n' "$label" "$plist" >> "$WEFT_DISPLACED"
        else
            echo "    WARNING: no plist found for $label — cannot restore it automatically"
        fi
    done < <(weft_wm_labels)
    [ "$found" = 0 ] && echo "    none running"
    return 0
}

# Put back exactly what weft_stop_wms took away.
weft_restore_wms() {
    local uid label plist restored=0
    uid="$(id -u)"
    if [ -s "$WEFT_DISPLACED" ]; then
        while IFS=$'\t' read -r label plist; do
            [ -z "$label" ] && continue
            if [ -f "$plist" ]; then
                echo "    starting $label"
                /bin/launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null \
                    || /bin/launchctl kickstart "gui/$uid/$label" 2>/dev/null \
                    || true
                restored=1
            else
                echo "    WARNING: $plist is gone — cannot restore $label"
            fi
        done < "$WEFT_DISPLACED"
        rm -f "$WEFT_DISPLACED"
    fi
    if [ "$restored" = 0 ]; then
        # No record (weft was installed some other way, or already restored).
        # Fall back to the stock service managers, which is a guess — say so.
        echo "    no record of a displaced agent; trying the stock services"
        yabai --start-service 2>/dev/null || true
        skhd --start-service 2>/dev/null || true
    fi
    return 0
}
