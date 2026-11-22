-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Jean-Christophe Baptiste

-- "Uninstall MagicLogi" applet, built by scripts/make-dmg.sh.
-- Runs the bundled scripts/uninstall.sh (same as "make uninstall"): stops the
-- agent (which gives the buttons back to the mouse) and removes it; keeps the
-- settings in ~/.config/magiclogi.

property appTitle : "MagicLogi"

on run
	set filesDir to POSIX path of (path to me) & "Contents/Resources/files"
	display dialog "Remove MagicLogi from your user account?" & return & return & ¬
		"Your settings in ~/.config/magiclogi are kept. The DPI set in the mouse stays until you switch it off and on." ¬
		buttons {"Cancel", "Remove"} default button "Remove" cancel button "Cancel" with icon caution with title appTitle
	try
		do shell script "cd " & quoted form of filesDir & " && /bin/bash scripts/uninstall.sh 2>&1"
	on error errText
		display dialog "MagicLogi could not be removed." & return & return & errText ¬
			buttons {"OK"} default button "OK" with icon stop with title appTitle
		return
	end try
	display dialog "MagicLogi has been removed." & return & return & ¬
		"You can also remove “magiclogid” from Input Monitoring and Accessibility in System Settings > Privacy & Security." ¬
		buttons {"OK"} default button "OK" with title appTitle
end run
