#!/usr/bin/env bash
# A stable code-signing identity for locally built weft binaries.
#
# THE PROBLEM THIS SOLVES
#
# macOS ties an Accessibility / Input Monitoring / Screen Recording grant to a
# program's *code signature*. A binary that is only ad-hoc signed — which is
# what `swift build` leaves behind — has no stable identity, so TCC falls back
# to keying the grant on the exact bytes:
#
#     designated => cdhash H"c0ffee..."      # changes on every single build
#
# Rebuild weftd and that grant no longer applies to it. What makes this vicious
# rather than merely annoying is that TCC does not remove the row: System
# Settings still lists `weftd` with its switch ON, so the user opens the pane,
# sees everything already enabled, and has nothing to do — while weftd is
# untrusted, every AX frame-set is refused, every window gets auto-floated as a
# "quirk", and no keybind fires. Every `install.sh` run did this.
#
# Signing with a certificate — any certificate, including a self-signed one we
# make ourselves — moves the requirement off the bytes and onto the identity:
#
#     designated => identifier "com.weft.weftd" and certificate leaf = H"..."
#
# That is stable across rebuilds, so the grant survives every future update.
# Verified by signing two entirely different binaries with the same cert and
# identifier: different cdhashes, identical designated requirement.
#
# NOTES ON THE APPROACH
#
# The certificate lives in its own keychain, not the login keychain, for one
# practical reason: `codesign` needs the private key to be usable without a
# GUI authorization prompt, and `security set-key-partition-list` needs the
# keychain's password to arrange that. We know the password of a keychain we
# created; we would have to ask for the user's login password otherwise.
#
# The certificate is deliberately NOT added to the trust store. `codesign` is
# happy to sign with an untrusted self-signed cert (`find-identity -v` will not
# list it, which is expected), and trusting it would need an admin prompt while
# buying nothing — TCC cares about the designated requirement matching, not
# about the certificate chaining to a trusted root. Gatekeeper is a separate
# question and is what WEFT_CODESIGN_IDENTITY plus notarization are for.

WEFT_SIGN_KEYCHAIN="${WEFT_SIGN_KEYCHAIN:-$HOME/Library/Keychains/weft-signing.keychain-db}"
WEFT_SIGN_CN="weft self-signed"
# The keychain's password lives beside weft's state, not in ~/.config/weft.
#
# That folder is the one people delete to reset their settings, and losing the
# password retires the keychain (see _weft_signing_retire_orphan): a new
# certificate, a new designated requirement, and every grant silently stops
# applying while System Settings still shows the switches on. That is "no
# keybind works after updating", and one machine had its identity retired three
# times in six days. The old location is still read, once, and carried over.
WEFT_SIGN_PASSFILE="${WEFT_SIGN_PASSFILE:-$HOME/Library/Application Support/weft/signing-keychain-password}"
WEFT_SIGN_PASSFILE_LEGACY="$HOME/.config/weft/.signing-keychain"
# And a copy in the login keychain, which no settings reset or folder cleanup
# touches. A file can always be deleted by hand; this one machine lost it three
# times, and each loss cost every permission grant weft had.
WEFT_SIGN_PASS_SERVICE="weft-signing-keychain"
WEFT_SIGN_LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Echoes the identity to sign with, creating it on first run. Empty output
# means signing is not available and the caller should carry on unsigned.
weft_signing_identity() {
    # A real Developer ID always wins: the release workflow sets this, and a
    # notarized build has a stable identity already.
    if [ -n "${WEFT_CODESIGN_IDENTITY:-}" ]; then
        echo "$WEFT_CODESIGN_IDENTITY"
        return 0
    fi
    if [ "${WEFT_NO_SELFSIGN:-0}" = 1 ]; then
        return 1
    fi

    if _weft_signing_ready; then
        echo "$WEFT_SIGN_CN"
        return 0
    fi
    _weft_signing_retire_orphan >&2
    if _weft_signing_create >&2; then
        echo "$WEFT_SIGN_CN"
        return 0
    fi
    return 1
}

_weft_signing_password() {
    if [ ! -s "$WEFT_SIGN_PASSFILE" ] && [ -s "$WEFT_SIGN_PASSFILE_LEGACY" ]; then
        mkdir -p "$(dirname "$WEFT_SIGN_PASSFILE")"
        cp "$WEFT_SIGN_PASSFILE_LEGACY" "$WEFT_SIGN_PASSFILE" && chmod 600 "$WEFT_SIGN_PASSFILE"
    fi
    if [ ! -s "$WEFT_SIGN_PASSFILE" ]; then
        local saved
        saved="$(security find-generic-password -s "$WEFT_SIGN_PASS_SERVICE" -w \
            "$WEFT_SIGN_LOGIN_KEYCHAIN" 2>/dev/null)"
        if [ -n "$saved" ]; then
            mkdir -p "$(dirname "$WEFT_SIGN_PASSFILE")"
            printf '%s' "$saved" > "$WEFT_SIGN_PASSFILE" && chmod 600 "$WEFT_SIGN_PASSFILE"
        fi
    fi
    if [ ! -s "$WEFT_SIGN_PASSFILE" ]; then
        mkdir -p "$(dirname "$WEFT_SIGN_PASSFILE")"
        # The keychain holds one self-signed code-signing key and nothing
        # else, but a random password kept 0600 costs two lines and avoids a
        # constant in a public repo being the thing that unlocks it.
        LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 > "$WEFT_SIGN_PASSFILE"
        chmod 600 "$WEFT_SIGN_PASSFILE"
    fi
    # Mirror it into the login keychain every time: that also covers every
    # install that made its password before the copy existed. `-U` updates in
    # place. Never fatal — a locked login keychain (an SSH session) just
    # leaves the file as the only copy, which is how it always was.
    security add-generic-password -U -a "$(id -un)" -s "$WEFT_SIGN_PASS_SERVICE" \
        -w "$(cat "$WEFT_SIGN_PASSFILE")" "$WEFT_SIGN_LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
    cat "$WEFT_SIGN_PASSFILE"
}

# Does the keychain exist, unlock, and hold our identity?
_weft_signing_ready() {
    [ -f "$WEFT_SIGN_KEYCHAIN" ] || return 1
    local pw
    pw="$(_weft_signing_password)"
    security unlock-keychain -p "$pw" "$WEFT_SIGN_KEYCHAIN" >/dev/null 2>&1 || return 1
    # `-v` filters to trusted identities and ours deliberately is not one, so
    # match on the unfiltered list.
    security find-identity -p codesigning "$WEFT_SIGN_KEYCHAIN" 2>/dev/null \
        | grep -q "\"$WEFT_SIGN_CN\""
}

# A keychain our saved password cannot unlock is one whose password file was
# lost — `~/.config/weft` deleted, or a purge whose keychain delete failed. The
# password was random and lived only in that file, so nothing can open it again.
# Left in place, the next `security` call on it raises a GUI "enter the keychain
# password" dialog that no password the user knows will satisfy. Move it aside
# instead: the new identity costs one re-grant, which the old one already did.
_weft_signing_retire_orphan() {
    [ -f "$WEFT_SIGN_KEYCHAIN" ] || return 0
    local pw
    pw="$(_weft_signing_password)"
    # `-p` never prompts; a wrong password just fails.
    security unlock-keychain -p "$pw" "$WEFT_SIGN_KEYCHAIN" >/dev/null 2>&1 && return 0

    local bak
    bak="$WEFT_SIGN_KEYCHAIN.orphaned-$(date +%Y%m%d%H%M%S).bak"
    echo "==> weft's signing keychain no longer matches its saved password"
    echo "    moving it to $bak and making a new one;"
    echo "    macOS permissions will need granting once more"
    cp "$WEFT_SIGN_KEYCHAIN" "$bak" 2>/dev/null || true
    # delete-keychain also drops it from the search list, which a plain mv
    # would leave pointing at nothing.
    security delete-keychain "$WEFT_SIGN_KEYCHAIN" >/dev/null 2>&1 \
        || rm -f "$WEFT_SIGN_KEYCHAIN"
}

_weft_signing_create() {
    local pw tmp
    pw="$(_weft_signing_password)"
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    echo "==> creating a self-signed signing identity (once)"
    echo "    so that rebuilding weft does not drop its macOS permissions"

    if [ ! -f "$WEFT_SIGN_KEYCHAIN" ]; then
        security create-keychain -p "$pw" "$WEFT_SIGN_KEYCHAIN" || return 1
    fi
    # No auto-lock timeout: a locked keychain mid-build fails signing with a
    # message that explains nothing.
    security set-keychain-settings "$WEFT_SIGN_KEYCHAIN" || true
    security unlock-keychain -p "$pw" "$WEFT_SIGN_KEYCHAIN" || return 1

    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
        -subj "/CN=$WEFT_SIGN_CN" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1 || return 1

    openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -out "$tmp/bundle.p12" -passout pass:"$pw" -name "$WEFT_SIGN_CN" \
        >/dev/null 2>&1 || return 1

    security import "$tmp/bundle.p12" -k "$WEFT_SIGN_KEYCHAIN" -P "$pw" \
        -T /usr/bin/codesign -A >/dev/null 2>&1 || return 1

    # Without this, the first `codesign` raises a GUI "wants to use a key in
    # your keychain" dialog — in the middle of a script, behind other windows.
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$pw" "$WEFT_SIGN_KEYCHAIN" >/dev/null 2>&1 || true

    # Put it on the search list so `codesign -s` resolves the name even where
    # --keychain is not threaded through (the .app bundle path).
    #
    # Append, never replace. `codesign` cannot resolve an identity out of a
    # search list that has no login keychain in it — it reports "no identity
    # found" for a certificate `security find-identity` is happy to list — so
    # writing our keychain in as the *only* entry breaks the very thing this
    # is for. Skip it entirely when the list comes back empty.
    local existing
    existing="$(security list-keychains -d user | sed 's/[" ]//g')"
    case "$existing" in
        "") ;;  # no list to extend; --keychain still covers our own calls
        *weft-signing*) ;;
        *) security list-keychains -d user -s $existing "$WEFT_SIGN_KEYCHAIN" >/dev/null 2>&1 || true ;;
    esac

    _weft_signing_ready
}

# weft_codesign <identifier> <path>
#
# The explicit identifier is what makes the requirement stable. Left to itself
# `codesign` derives one from the file name, so the same binary signed at
# `.build/release/weftd` and at `~/.local/bin/weftd` would satisfy different
# requirements and TCC would treat them as two programs.
# Returns non-zero on failure and prints why. Callers must treat that as a
# warning, not a fatal error: an unsigned weft still works perfectly, it just
# loses its permissions on the next update, and aborting the install over that
# would leave the user with binaries in place and no service running.
weft_codesign() {
    local identifier="$1" path="$2" identity="$3"
    [ -n "$identity" ] || return 1
    local args=(--force --sign "$identity" --identifier "$identifier")
    # A bundle has nested code; the bare form would sign the wrapper and leave
    # the executable inside it with whatever signature it arrived with.
    case "$path" in *.app) args+=(--deep) ;; esac
    if [ -z "${WEFT_CODESIGN_IDENTITY:-}" ]; then
        args+=(--keychain "$WEFT_SIGN_KEYCHAIN")
    else
        args+=(--options runtime --timestamp)
    fi
    local err
    if ! err="$(codesign "${args[@]}" "$path" 2>&1)"; then
        printf 'codesign failed for %s: %s\n' "$path" "$err" >&2
        return 1
    fi
}

# The leaf hash TCC will key grants on. Printed after signing so a support
# answer can say whether two installs share an identity.
weft_signing_fingerprint() {
    codesign -d -r- "$1" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-f]*\)".*/\1/p'
}
