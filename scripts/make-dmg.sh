#!/bin/bash
# Build the release disk image dist/MagicLogi-<version>.dmg.
#
#   scripts/make-dmg.sh              build, test, sign, package, sign the image
#   scripts/make-dmg.sh --notarize   same, then notarize with Apple and staple
#
# The image holds the agent signed with a "Developer ID Application"
# certificate (hardened runtime, secure timestamp) and the install/uninstall
# scripts, packed in two double-clickable applets. Installing from it needs no
# Xcode tools. The image is signed too; with --notarize it is submitted to
# Apple's notary service, stapled and checked with Gatekeeper (spctl).
#
# Environment (optional):
#   MAGICLOGI_DEVELOPER_ID    signing identity, SHA-1 or name. Default: the
#                             first "Developer ID Application:" identity.
#   MAGICLOGI_NOTARY_PROFILE  notarytool keychain profile (default: magiclogi),
#                             created once with:
#                               xcrun notarytool store-credentials magiclogi \
#                                 --apple-id <your Apple ID> --team-id <your team ID>
#
# Network: signing contacts Apple's timestamp server; --notarize uploads the
# image to Apple. Nothing else.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
set -euo pipefail

LABEL=com.jcbaptiste.magiclogi
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$ROOT/Sources/magiclogid/Info.plist")
PROFILE=${MAGICLOGI_NOTARY_PROFILE:-magiclogi}
NAME=MagicLogi-$VERSION
DIST=$ROOT/dist
STAGE=$DIST/stage/$NAME
DMG=$DIST/$NAME.dmg

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

NOTARIZE=0
for arg in "$@"; do
    case $arg in
        --notarize) NOTARIZE=1 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        *) die "unknown argument: $arg (see --help)" ;;
    esac
done
case $VERSION in [0-9]*.[0-9]*.[0-9]*) ;; *) die "bad version in Info.plist: '$VERSION'" ;; esac

# --- Signing identity: Developer ID Application only -------------------------
if [ -n "${MAGICLOGI_DEVELOPER_ID:-}" ]; then
    ID=$MAGICLOGI_DEVELOPER_ID
else
    ID=$(security find-identity -v -p codesigning 2>/dev/null \
         | awk '/"Developer ID Application:/ { print $2; exit }')
    [ -n "$ID" ] || die "no \"Developer ID Application\" certificate in the keychain.
A release image must be signed with one. To install on this Mac only: make install"
fi
say "Signing identity: $(security find-identity -v -p codesigning | grep -F -- "$ID" | head -n 1 | sed 's/^ *[0-9]*) //')"

if [ "$NOTARIZE" = 1 ]; then
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
        || die "notarytool profile \"$PROFILE\" not found or not working. Create it once with:
  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id <your team ID>
or reuse an existing one: make release NOTARY_PROFILE=<name>"
fi

# --- Build, test, sign the agent ----------------------------------------------
say "Clean build and tests"
make -C "$ROOT" clean build test >/dev/null
BIN=$(cd "$ROOT" && swift build -c release --arch arm64 --show-bin-path)/magiclogid
[ -x "$BIN" ] || die "build failed"
[ "$("$BIN" --version)" = "$VERSION" ] || die "binary version differs from Info.plist"

say "Signing the agent (hardened runtime, secure timestamp)"
codesign --force --options runtime --timestamp --identifier "$LABEL" --sign "$ID" "$BIN"
codesign --verify --strict --verbose=2 "$BIN"
REQ="=anchor apple generic and identifier \"$LABEL\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
codesign --verify --strict -R "$REQ" "$BIN" || die "the agent signature is not a Developer ID signature"
sig=$(codesign -dvv "$BIN" 2>&1)   # captured: grep -q in a pipe would SIGPIPE codesign
case $sig in *$'\n'Timestamp=*) ;; *) die "the agent signature has no secure timestamp" ;; esac
TEAM=$(printf '%s\n' "$sig" | sed -n 's/^TeamIdentifier=//p')
case $TEAM in [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
    *) die "unexpected team identifier: '$TEAM'" ;; esac
say "Release team: $TEAM"

# --- Stage the image contents ------------------------------------------------
# Two applets (real applications, so the notarization covers them; a .command
# script would be blocked by Gatekeeper). Each bundle carries the files it
# needs in Contents/Resources/files, so it works from a translocated copy.
say "Staging $STAGE"
rm -rf "$DIST/stage"
mkdir -p "$STAGE"

make_applet() {
    local app="$STAGE/$1.app" files="$STAGE/$1.app/Contents/Resources/files"
    osacompile -o "$app" "$ROOT/packaging/$2" >/dev/null
    mkdir -p "$files/scripts"
    case $3 in
        install)
            mkdir -p "$files/bin" "$files/tools" "$files/launchd" "$files/config"
            cp "$BIN" "$files/bin/"
            # The installer only accepts the team that signed this image.
            sed "s/^RELEASE_TEAM=.*/RELEASE_TEAM=$TEAM/" "$ROOT/scripts/install.sh" > "$files/scripts/install.sh"
            grep -qx "RELEASE_TEAM=$TEAM" "$files/scripts/install.sh" \
                || die "could not set the release team in install.sh"
            cp "$ROOT/tools/magiclogictl" "$files/tools/"
            cp "$ROOT/launchd/$LABEL.plist.in" "$files/launchd/"
            cp "$ROOT/config/config.example.toml" "$files/config/"
            chmod 755 "$files/bin/magiclogid" "$files/tools/magiclogictl" ;;
        uninstall)
            cp "$ROOT/scripts/uninstall.sh" "$files/scripts/" ;;
    esac
    chmod 755 "$files/scripts/"*.sh
    local plist="$app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "$LABEL.$3" "$plist"
    plutil -replace CFBundleName -string "$1" "$plist"
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$plist"
    plutil -replace LSMinimumSystemVersion -string "13.0" "$plist"
    # osacompile signs ad hoc; re-sign the whole bundle (it seals Resources,
    # the agent inside keeps its own Developer ID signature).
    codesign --force --options runtime --timestamp --identifier "$LABEL.$3" --sign "$ID" "$app"
    codesign --verify --strict --deep --verbose=1 "$app"
    codesign --verify --strict -R "=anchor apple generic and identifier \"$LABEL.$3\" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]" "$app" \
        || die "$1.app is not signed with a Developer ID"
}
make_applet "Install MagicLogi" Install.applescript install
make_applet "Uninstall MagicLogi" Uninstall.applescript uninstall
cp "$ROOT/LICENSE" "$STAGE/"

cat > "$STAGE/README.txt" <<EOF
MagicLogi $VERSION
==================

Minimal replacement for Logi Options+ for the Logitech MX Anywhere 2S
connected directly over Bluetooth, on macOS 13+ (Apple silicon): hardware DPI,
wheel direction, button remapping and the Options+ gesture button.
Not affiliated with Logitech.

INSTALL
  1. Double-click "Install MagicLogi". No administrator password needed.
  2. Click Continue to grant Input Monitoring (and Accessibility if you remap
     a button): System Settings opens on the right page, turn on
     "magiclogid", come back and click Continue until it says
     "All permissions granted".
  3. Edit ~/.config/magiclogi/config.toml (commented; everything is native
     until you change it), then run: ~/.local/bin/magiclogictl reload
  4. Eject this disk image. Nothing else is needed from it.

Files installed (your user account only, no administrator rights):
  ~/.local/bin/magiclogid             the background agent
  ~/.local/bin/magiclogictl           control command (status, reload, ...)
  ~/Library/LaunchAgents/$LABEL.plist starts it at login
  ~/.config/magiclogi/config.toml     your settings

UNINSTALL
  Double-click "Uninstall MagicLogi" (your settings are kept).

The two installers are small AppleScript applications. Their scripts and the
agent are inside them (right-click > Show Package Contents > Contents >
Resources > files) and are the same as in the source repository.

Full documentation: https://github.com/phocean/MagicLogi
EOF

# --- Image --------------------------------------------------------------------
say "Creating $DMG"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -quiet -volname "MagicLogi $VERSION" -srcfolder "$STAGE" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
codesign --force --timestamp --sign "$ID" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
rm -rf "$DIST/stage"

if [ "$NOTARIZE" = 1 ]; then
    say "Submitting to Apple's notary service (usually a few minutes)"
    out=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json) \
        || { printf '%s\n' "$out" >&2; die "notarytool submit failed"; }
    id=$(printf '%s' "$out" | plutil -extract id raw -o - - 2>/dev/null || true)
    status=$(printf '%s' "$out" | plutil -extract status raw -o - - 2>/dev/null || true)
    say "Notarization $id: $status"
    if [ "$status" != Accepted ]; then
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
        die "notarization was not accepted"
    fi
    say "Stapling the notarization ticket"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    say "Gatekeeper assessment"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

(cd "$DIST" && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")
say "Done: $DMG"
cat "$DMG.sha256"
[ "$NOTARIZE" = 1 ] || echo "Not notarized. For a public release: make release"
