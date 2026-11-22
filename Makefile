# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Jean-Christophe Baptiste
#
# magiclogi: build, test, install. Requirements: macOS 13+, Xcode (Swift).

.PHONY: all build test check install uninstall clean help

all: build

help:
	@echo "make build      release build (.build/…/magiclogid)"
	@echo "make test       unit tests + shell syntax checks"
	@echo "make check      build, test, sign, do not install"
	@echo "make install    build, test, sign, install and start the agent"
	@echo "make uninstall  stop and remove the agent (keeps ~/.config/magiclogi)"

build:
	swift build -c release --arch arm64

test:
	swift test
	bash -n scripts/install.sh scripts/uninstall.sh tools/magiclogictl
	plutil -lint launchd/com.jcbaptiste.magiclogi.plist.in >/dev/null

check:
	bash scripts/install.sh --check

install:
	bash scripts/install.sh

uninstall:
	bash scripts/uninstall.sh

clean:
	rm -rf .build
