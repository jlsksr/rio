#!/usr/bin/env wish
#
# Headless current-line-highlight test for rio-gui (AGENTS.md D60). The editor tints the
# LOGICAL line the insert caret sits on with a `curline` background band — on by default,
# a toggle in the View menu and the Preferences window. Checks: the tag is coloured from
# the theme, the band tracks the caret and spans the full width (its range reaches the
# next line's start), the toggle clears and restores it, the setting survives prefs.json,
# and the menu + Preferences doors drive the SAME global (two-door sync). Needs a DISPLAY.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/curline.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding; re-source as UTF-8 so this file's own
# non-ASCII (if any) and the GUI's glyphs agree. The guard every entry point carries (D54).
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs (D31)
source [file join [file dirname [info script]] .. .. rio-core server.tcl]
set ::port [rio::server::listen 0]
set ::connect_to "127.0.0.1:$::port"
set argv {}
source [file join [file dirname [info script]] .. rio-gui.tcl]

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} {
		puts "PASS  $label"
	} else {
		puts "FAIL  $label\n        got:  $got\n        want: $want"
		incr ::fails
	}
}

set t [gw 0]   ;# group 0's real editor widget (the boot scratch buffer)

# --- default on, and the band is coloured from the theme -----------------------------
ok "default: highlight on"       $::highlight_current_line 1
ok "curline has a background"    [expr {[$t tag cget curline -background] ne ""}] 1

# Seed a few lines directly in the widget (a display-tag test needs no core round-trip),
# then drop the caret on line 2 and re-band.
$t insert 1.0 "alpha\nbravo\ncharlie\n"
$t mark set insert 2.3
curline_update 0
ok "band on the caret's line"    [$t tag ranges curline] {2.0 3.0}

# --- the band tracks the caret, and spans full width (range end = next line start) ---
$t mark set insert 1.1
curline_update 0
ok "band follows to line 1"      [$t tag ranges curline] {1.0 2.0}
ok "full width: end is next line" [lindex [$t tag ranges curline] 1] 2.0

# --- toggle off clears it; back on restores it (via the applier the doors call) ------
set ::highlight_current_line 0 ; apply_curline
ok "toggle off: band cleared"    [$t tag ranges curline] {}
set ::highlight_current_line 1 ; apply_curline
ok "toggle on: band restored"    [expr {[llength [$t tag ranges curline]] > 0}] 1

# --- persistence through prefs.json --------------------------------------------------
set ::highlight_current_line 0 ; prefs_save
set ::highlight_current_line 1 ; prefs_load
ok "persist: reloaded as off"    $::highlight_current_line 0
set ::highlight_current_line 1 ; prefs_save   ;# leave the default on for the doors below

# --- two doors on one global: the View menu and the Preferences window ---------------
ok "menu: toggle is a checkbutton" [.m.view type "Highlight Current Line"] checkbutton
ok "menu: drives the global"     [.m.view entrycget "Highlight Current Line" -variable] \
                                 ::highlight_current_line
preferences_window
ok "prefs: control exists"       [winfo exists .prefs.body.view.curln] 1
ok "prefs: same var as menu"     [.prefs.body.view.curln cget -variable] \
                                 [.m.view entrycget "Highlight Current Line" -variable]
destroy .prefs

puts [expr {$::fails ? "FAILED ($::fails)" : "ALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
