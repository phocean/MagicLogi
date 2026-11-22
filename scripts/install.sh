#!/bin/bash
# magiclogi installer (per user, no root, no network).
#
#   scripts/install.sh                  build, test, sign, install, start
#   scripts/install.sh --check          build, test and sign into .build only
#   scripts/install.sh --prebuilt FILE  install an already built agent (release
#                                       disk image): no build, no Xcode tools;
#                                       FILE must carry a valid Developer ID
#                                       signature of the release team
#
# Environment (optional):
#   MAGICLOGI_SIGN_IDENTITY  codesign identity (SHA-1 or name, "-" = ad hoc).
#       Default: first "Developer ID Application:", else first "Apple
#       Development:" identity of the keychain, else ad hoc. Ad hoc ties the
#       macOS permissions to this exact build (see docs/architecture.md §4, M2).
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
set -euo pipefail

LABEL=com.jcbaptiste.magiclogi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN_DIR=$HOME/.local/bin
DAEMON=$BIN_DIR/magiclogid
CTL=$BIN_DIR/magiclogictl
AGENT_DIR=$HOME/Library/LaunchAgents
AGENT=$AGENT_DIR/$LABEL.plist
CONFIG_DIR=$HOME/.config/magiclogi
CONFIG=$CONFIG_DIR/config.toml
DOMAIN=gui/$(id -u)
SERVICE=$DOMAIN/$LABEL

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

CHECK_ONLY=0
PREBUILT=""
while [ $# -gt 0 ]; do
    case $1 in
        --check) CHECK_ONLY=1 ;;
        --prebuilt)
            [ $# -ge 2 ] || die "--prebuilt needs a file"
            PREBUILT=$2; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done
[ -z "$PREBUILT" ] || [ "$CHECK_ONLY" = 0 ] || die "--check and --prebuilt cannot be combined"
[ "$(id -u)" -ne 0 ] || die "do not run as root: magiclogi is a per-user agent"
case $HOME in /*) ;; *) die "HOME must be an absolute path" ;; esac
case $HOME in *$'\n'*) die "HOME must not contain a newline" ;; esac

TMP_FILES=()
PRIVATE_DIR=""
cleanup() {
    local f
    for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do rm -f "$f"; done
    [ -z "$PRIVATE_DIR" ] || rm -rf "$PRIVATE_DIR"
}
trap cleanup EXIT

# Copy $1 to $2 with mode $3 through a temp file in the same directory: the
# final mv is an atomic rename.
install_file() {
    local tmp
    tmp=$(mktemp "$(dirname "$2")/.magiclogi-install.XXXXXX")
    TMP_FILES+=("$tmp")
    cp "$1" "$tmp"
    chmod "$3" "$tmp"
    mv -f "$tmp" "$2"
}

loaded() { launchctl print "$SERVICE" >/dev/null 2>&1; }

# A release binary must be signed with a Developer ID Application certificate
# (Apple anchor, Developer ID intermediate and leaf) of the release team, for
# this identifier. scripts/make-dmg.sh writes the team of its signing
# certificate here in the copy it packs.
RELEASE_TEAM=26N2RN6N67
DEVELOPER_ID_REQ="=anchor apple generic and identifier \"$LABEL\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$RELEASE_TEAM\""

verify_release_signature() {
    codesign --verify --strict -R "$DEVELOPER_ID_REQ" "$1" 2>/dev/null \
        || die "$1 is not signed with the Developer ID Application certificate of team $RELEASE_TEAM for $LABEL (or was modified)"
}

choose_identity() {
    local ids found=""
    ids=$(security find-identity -v -p codesigning 2>/dev/null || true)
    if [ -n "${MAGICLOGI_SIGN_IDENTITY:-}" ]; then
        SIGN_ID=$MAGICLOGI_SIGN_IDENTITY
        say "Signing identity (MAGICLOGI_SIGN_IDENTITY): $SIGN_ID"
        return
    fi
    for prefix in "Developer ID Application:" "Apple Development:"; do
        found=$(printf '%s\n' "$ids" | awk -v p="\"$prefix" 'index($0, p) { print $2; exit }')
        if [ -n "$found" ]; then
            SIGN_ID=$found
            say "Signing identity: $(printf '%s\n' "$ids" | awk -v h="$found" '$2 == h { sub(/^[^"]*"/, ""); sub(/"[^"]*$/, ""); print; exit }')"
            return
        fi
    done
    SIGN_ID="-"
    say "Signing identity: ad hoc"
    warn "ad hoc signature: macOS ties the Input Monitoring and Accessibility grants"
    warn "to this exact build; after every reinstall they must be granted again."
}

build_and_sign() {
    if [ -n "$PREBUILT" ]; then
        case $PREBUILT in /*) ;; *) PREBUILT=$PWD/$PREBUILT ;; esac
        [ -f "$PREBUILT" ] && [ -x "$PREBUILT" ] || die "not an executable file: $PREBUILT"
        # Verify, run and install one private copy, never the original path:
        # a file swapped after the check could otherwise be installed.
        PRIVATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/magiclogi-prebuilt.XXXXXX")
        cp "$PREBUILT" "$PRIVATE_DIR/magiclogid"
        BUILT=$PRIVATE_DIR/magiclogid
        verify_release_signature "$BUILT"
        say "Prebuilt agent $("$BUILT" --version 2>/dev/null || echo '?'), Developer ID team $RELEASE_TEAM"
        return
    fi
    command -v swift >/dev/null 2>&1 || die "swift not found: install Xcode or its command line tools (xcode-select --install)"
    say "Building"
    make -C "$ROOT" build >/dev/null
    BUILT=$(cd "$ROOT" && swift build -c release --arch arm64 --show-bin-path)/magiclogid
    [ -x "$BUILT" ] || die "build failed"
    say "Testing"
    local out
    out=$(make -C "$ROOT" test 2>&1) || { printf '%s\n' "$out" | tail -n 30; die "tests failed (make test)"; }
    printf '%s\n' "$out" | grep -E "^[[:space:]]*Executed .* tests" | tail -n 1
    choose_identity
    say "Signing"
    codesign --force --options runtime --identifier "$LABEL" --timestamp=none --sign "$SIGN_ID" "$BUILT"
    codesign --verify --strict "$BUILT"
}

build_and_sign
for f in "$ROOT/tools/magiclogictl" "$ROOT/launchd/$LABEL.plist.in" "$ROOT/config/config.example.toml"; do
    [ -f "$f" ] || die "missing file: $f"
done
"$BUILT" check --config "$ROOT/config/config.example.toml" >/dev/null || die "example configuration rejected"
if [ "$CHECK_ONLY" = 1 ]; then
    say "Check OK: $BUILT is built, tested, signed and verified. Nothing installed."
    exit 0
fi

mkdir -p "$BIN_DIR" "$AGENT_DIR" "$CONFIG_DIR"
if loaded; then
    # SIGTERM: the agent gives the buttons back to the mouse before exiting.
    say "Stopping the running agent"
    launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do loaded || break; sleep 0.1; done
    loaded && die "$LABEL is still loaded after bootout"
fi

say "Installing $DAEMON and $CTL"
install_file "$BUILT" "$DAEMON" 755
if [ -n "$PREBUILT" ]; then verify_release_signature "$DAEMON"; else codesign --verify --strict "$DAEMON"; fi
install_file "$ROOT/tools/magiclogictl" "$CTL" 755

say "Writing $AGENT"
ESCAPED=$(printf '%s' "$DAEMON" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
TMP=$(mktemp "$AGENT_DIR/.magiclogi-install.XXXXXX")
TMP_FILES+=("$TMP")
MAGICLOGI_REPL=$ESCAPED awk '{
    out = ""; line = $0; key = "@DAEMON_PATH@"
    while ((i = index(line, key)) > 0) { out = out substr(line, 1, i - 1) ENVIRON["MAGICLOGI_REPL"]; line = substr(line, i + length(key)) }
    print out line
}' "$ROOT/launchd/$LABEL.plist.in" > "$TMP"
plutil -lint -s "$TMP" || die "generated LaunchAgent does not lint"
got=$(plutil -extract ProgramArguments.0 raw -o - "$TMP") || die "cannot read back ProgramArguments"
[ "$got" = "$DAEMON" ] || die "LaunchAgent path round-trip mismatch: '$got' != '$DAEMON'"
chmod 644 "$TMP"
mv -f "$TMP" "$AGENT"

if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
    say "Keeping existing $CONFIG"
    "$DAEMON" check --config "$CONFIG" || warn "your configuration is invalid: the agent will leave the mouse unchanged"
else
    say "Creating $CONFIG (everything native until you edit it)"
    TMP=$(mktemp "$CONFIG_DIR/.magiclogi-install.XXXXXX")
    TMP_FILES+=("$TMP")
    cp "$ROOT/config/config.example.toml" "$TMP"
    chmod 644 "$TMP"
    mv -n "$TMP" "$CONFIG"   # -n: never clobber, even on a race
fi

say "Starting the agent"
launchctl bootstrap "$DOMAIN" "$AGENT" || die "launchctl bootstrap failed (try: magiclogictl status)"

cat <<EOF

magiclogi is installed and started.

One-time permissions, in System Settings > Privacy & Security:
  1. Input Monitoring: turn on magiclogid (always needed).
  2. Accessibility: turn on magiclogid (only if you remap a button).
  Simplest: run this command, turn on what it opens, and repeat until it
  answers "All permissions granted.":
       $CTL permissions

Commands: magiclogictl status | reload | restart | log | check | diag
Config:   $CONFIG
EOF
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) printf '\nNOTE: %s is not in your PATH. Add to ~/.zshrc:\n  export PATH="$PATH:$HOME/.local/bin"\n' "$BIN_DIR" ;;
esac
