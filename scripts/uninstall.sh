#!/bin/bash
# magiclogi uninstaller.
#
#   scripts/uninstall.sh          stop and remove the agent (keeps the config)
#   scripts/uninstall.sh --purge  also remove ~/.config/magiclogi
#
# Stopping the agent (SIGTERM) gives the buttons back to the mouse. The DPI
# and wheel inversion set in the mouse stay until `magiclogictl reset` (run
# it BEFORE uninstalling) or a factory default from another tool.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
set -euo pipefail

LABEL=com.jcbaptiste.magiclogi
SERVICE=gui/$(id -u)/$LABEL
PURGE=0
case ${1:-} in --purge) PURGE=1 ;; "") ;; *) echo "usage: $0 [--purge]" >&2; exit 64 ;; esac
[ "$(id -u)" -ne 0 ] || { echo "error: do not run as root" >&2; exit 1; }

launchctl bootout "$SERVICE" >/dev/null 2>&1 && echo "==> Agent stopped (diversions removed)" || true
launchctl bootout "gui/$(id -u)/$LABEL.oneshot" >/dev/null 2>&1 || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" \
      "$HOME/.local/bin/magiclogid" "$HOME/.local/bin/magiclogictl"
rm -rf "$HOME/.local/state/magiclogi"
if [ "$PURGE" = 1 ]; then rm -rf "$HOME/.config/magiclogi"; echo "==> Configuration removed"; fi
# Privacy grants: the user's own TCC entries can be reset without admin rights.
tccutil reset ListenEvent "$LABEL" >/dev/null 2>&1 || true
tccutil reset Accessibility "$LABEL" >/dev/null 2>&1 || true
echo "==> Removed. If magiclogid is still listed in System Settings > Privacy & Security"
echo "    (Input Monitoring, Accessibility), remove it there with the − button."
