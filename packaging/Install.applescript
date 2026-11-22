-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Jean-Christophe Baptiste

-- "Install MagicLogi" applet, built by scripts/make-dmg.sh.
--
-- A double-clickable script (.command) on a downloaded disk image is blocked
-- by Gatekeeper: Apple's notary service does not cover scripts. This applet is
-- a real, signed and notarized application. Its bundle carries the files to
-- install (Contents/Resources/files), so it also works when macOS runs it from
-- a temporary location (App Translocation).
--
-- It runs the same install script as "make install" (with --prebuilt: no
-- build, no administrator password), then guides through the macOS
-- permissions with "magiclogictl permissions".

property appTitle : "MagicLogi"

on run
	set filesDir to POSIX path of (path to me) & "Contents/Resources/files"
	set homeDir to POSIX path of (path to home folder)
	set ctl to homeDir & ".local/bin/magiclogictl"
	set daemon to homeDir & ".local/bin/magiclogid"

	display dialog "Install MagicLogi for your user account?" & return & return & ¬
		"It adds a small background helper for the Logitech MX Anywhere 2S (Bluetooth). No administrator password is needed." ¬
		buttons {"Cancel", "Install"} default button "Install" cancel button "Cancel" with title appTitle
	try
		do shell script "cd " & quoted form of filesDir & ¬
			" && /bin/bash scripts/install.sh --prebuilt bin/magiclogid 2>&1"
	on error errText
		display dialog "MagicLogi was not installed." & return & return & my lastLines(errText) ¬
			buttons {"OK"} default button "OK" with icon stop with title appTitle
		return
	end try

	set msg to "MagicLogi is installed and running." & return & return & ¬
		"It needs the macOS permission Input Monitoring (and Accessibility if you remap a button). Click Continue: System Settings opens on the right page."
	repeat
		activate
		set answer to button returned of (display dialog msg buttons {"Later", "Continue"} ¬
			default button "Continue" with title appTitle)
		if answer is "Later" then
			display dialog "You can grant them later. In Terminal, run:" & return & return & ¬
				"~/.local/bin/magiclogictl permissions" ¬
				buttons {"OK"} default button "OK" with title appTitle
			return
		end if
		try
			-- Restarts the agent, reports the permissions, opens the first
			-- missing pane. Exit status 3: a permission is still missing.
			do shell script quoted form of ctl & " permissions 2>&1"
			activate
			display dialog "All permissions granted. MagicLogi is working." & return & return & ¬
				"You can eject the disk image. Settings: ~/.config/magiclogi/config.toml — commands: ~/.local/bin/magiclogictl help" ¬
				buttons {"OK"} default button "OK" with title appTitle
			return
		on error errText number errNum
			if errNum is not 3 then
				activate
				display dialog "Could not check the permissions." & return & return & my lastLines(errText) ¬
					buttons {"OK"} default button "OK" with icon stop with title appTitle
				return
			end if
		end try
		set msg to "A permission is still missing (" & my missingName(errText) & ")." & return & return & ¬
			"In System Settings, turn on “magiclogid”. If it is not listed, click +, press Cmd+Shift+G, type:" & return & ¬
			daemon & return & "then Return and Open." & return & return & ¬
			"Then click Continue to check again."
	end repeat
end run

on missingName(t)
	repeat with p in paragraphs of t
		if p starts with "System Settings is open on " then
			set s to text 28 thru -1 of p
			set AppleScript's text item delimiters to ":"
			set n to text item 1 of s
			set AppleScript's text item delimiters to ""
			return n
		end if
	end repeat
	return "Input Monitoring or Accessibility"
end missingName

on lastLines(t)
	set ps to paragraphs of t
	set n to count of ps
	if n > 8 then set ps to items (n - 7) thru n of ps
	set AppleScript's text item delimiters to return
	set r to ps as text
	set AppleScript's text item delimiters to ""
	return r
end lastLines
