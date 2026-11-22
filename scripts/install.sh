#!/bin/bash
# magiclogi installer (per user, no root, no network).
#
#   scripts/install.sh          build, test, sign, install, start
#   scripts/install.sh --check  build, test and sign into .build only
#
# Environment (optional):
#   MAGICLOGI_SIGN_IDENTITY  codesign identity (SHA-1 or name, "-" = ad hoc).
#       Default: first "Developer ID Application:", else first "Apple
#       Development:" identity of the keychain, else ad hoc.
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
case ${1:-} in
    --check) CHECK_ONLY=1 ;;
    "") ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
esac
[ "$(id -u)" -ne 0 ] || die "do not run as root: magiclogi is a per-user agent"
case $HOME in *$'\n'*|"") die "unusable HOME" ;; esac
command -v swift >/dev/null 2>&1 || die "swift not found: install the Xcode Command Line Tools (xcode-select --install)"

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

say "Building"
(cd "$ROOT" && swift build -c release --arch arm64 2>&1 | grep -Ev '^(\[|Building|Compiling|Write|Linking|Planning)' || true)
BUILT=$(cd "$ROOT" && swift build -c release --arch arm64 --show-bin-path)/magiclogid
[ -x "$BUILT" ] || die "build failed"
say "Testing"
TEST_OUT=$(cd "$ROOT" && swift test 2>&1) || { printf '%s\n' "$TEST_OUT" | tail -n 30; die "unit tests failed (swift test)"; }
printf '%s\n' "$TEST_OUT" | grep -E "^[[:space:]]*Executed .* tests" | tail -n 1
choose_identity
say "Signing"
codesign --force --options runtime --identifier "$LABEL" --timestamp=none --sign "$SIGN_ID" "$BUILT"
codesign --verify --strict "$BUILT"
"$BUILT" check --config "$ROOT/config/config.example.toml" >/dev/null || die "example configuration rejected"
[ "$CHECK_ONLY" = 0 ] || { say "Check OK: $BUILT"; exit 0; }

say "Installing into $BIN_DIR"
mkdir -p "$BIN_DIR" "$AGENT_DIR" "$CONFIG_DIR"
# Stop the running agent first: it removes its diversions on SIGTERM.
launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
# bootout returns before the job is fully gone: wait up to 5 s.
for _ in $(seq 1 50); do launchctl print "$SERVICE" >/dev/null 2>&1 || break; sleep 0.1; done
launchctl print "$SERVICE" >/dev/null 2>&1 && die "$LABEL is still loaded after bootout"
install -m 0755 "$BUILT" "$DAEMON.new" && mv -f "$DAEMON.new" "$DAEMON"
install -m 0755 "$ROOT/tools/magiclogictl" "$CTL.new" && mv -f "$CTL.new" "$CTL"

if [ -f "$CONFIG" ]; then
    say "Keeping existing $CONFIG"
    "$DAEMON" check --config "$CONFIG" || warn "your configuration is invalid: the agent will leave the mouse unchanged"
else
    install -m 0644 "$ROOT/config/config.example.toml" "$CONFIG"
    say "Configuration created: $CONFIG (everything native until you edit it)"
fi

ESCAPED=$(printf '%s' "$DAEMON" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
MAGICLOGI_REPL=$ESCAPED awk '{
    out = ""; line = $0; key = "@DAEMON_PATH@"
    while ((i = index(line, key)) > 0) { out = out substr(line, 1, i - 1) ENVIRON["MAGICLOGI_REPL"]; line = substr(line, i + length(key)) }
    print out line
}' "$ROOT/launchd/$LABEL.plist.in" > "$AGENT.new"
plutil -lint "$AGENT.new" >/dev/null || die "generated LaunchAgent is invalid"
mv -f "$AGENT.new" "$AGENT"

say "Starting"
launchctl bootstrap "$DOMAIN" "$AGENT"
sleep 2
"$DAEMON" status || true
if grep -q '^waiting=input-monitoring' "$HOME/.local/state/magiclogi/status" 2>/dev/null; then
    say "Grant Input Monitoring: System Settings > Privacy & Security > Input Monitoring > magiclogid"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" || true
fi
case ${PATH:-} in *"$BIN_DIR"*) ;; *) warn "$BIN_DIR is not in PATH: use $CTL" ;; esac
say "Done. Status: magiclogictl status — log: magiclogictl log"
