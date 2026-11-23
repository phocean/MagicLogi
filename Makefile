# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
#
# MagicLogi: build, test, install, package. Requirements: macOS 13+, Apple
# silicon, Xcode (Swift). Run "make help" for the list of targets.

VERSION := $(shell plutil -extract CFBundleShortVersionString raw -o - Sources/magiclogid/Info.plist 2>/dev/null)
NOTARY_PROFILE ?= magictrackpoint

.PHONY: all build test check install uninstall dmg release clean help

all: build

help:
	@echo "MagicLogi $(VERSION)"
	@echo ""
	@echo "Install on this Mac:"
	@echo "  make install     build, test, sign with your best certificate, install, start"
	@echo "  make uninstall   stop and remove it (keeps ~/.config/magiclogi)"
	@echo ""
	@echo "Develop:"
	@echo "  make             release build (.build/…/magiclogid)"
	@echo "  make test        unit tests, script syntax, LaunchAgent lint"
	@echo "  make check       build, test, sign; install nothing"
	@echo "  make clean       remove .build/ and dist/"
	@echo ""
	@echo "Release (needs a Developer ID Application certificate):"
	@echo "  make dmg         dist/MagicLogi-$(VERSION).dmg, signed, not notarized"
	@echo "  make release     same, then notarized by Apple and stapled"
	@echo "                   (NOTARY_PROFILE=<notarytool profile>, default magictrackpoint)"

build:
	swift build -c release --arch arm64

test:
	swift test
	bash -n scripts/install.sh scripts/uninstall.sh scripts/make-dmg.sh tools/magiclogictl
	plutil -lint launchd/com.jcbaptiste.magiclogi.plist.in Sources/magiclogid/Info.plist >/dev/null
	osacompile -o /dev/null packaging/Install.applescript
	osacompile -o /dev/null packaging/Uninstall.applescript

check:
	bash scripts/install.sh --check

install:
	bash scripts/install.sh

uninstall:
	bash scripts/uninstall.sh

dmg:
	bash scripts/make-dmg.sh

release:
	MAGICLOGI_NOTARY_PROFILE="$(NOTARY_PROFILE)" bash scripts/make-dmg.sh --notarize

clean:
	rm -rf .build dist
