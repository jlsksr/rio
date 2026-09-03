#!/usr/bin/env wish
#
# Headless test for the menu affordance override (AGENTS.md D59). Tk's MenuInvoke, on a
# mouse-button release over a cascade, posts the dropdown AND activates its first entry
# (menu.tcl), while a hover-slide posts with nothing highlighted — a click/hover mismatch.
# rio suppresses that one activation on the mouse path (a ::rio_menu_click flag set around
# the Menu <ButtonRelease> binding) while leaving keyboard traversal, which also routes
# through MenuFirstEntry, untouched. Checks the override is installed, that the flag
# suppresses the click-path activation, and that the keyboard path still activates.
# X11 only: on Windows/macOS the menubar is native and the override is inert, so the body
# degrades to a trivial pass there.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/menubar.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows); re-source under
# UTF-8 so this file's own non-ASCII arrives intact — the guard every entry point carries.
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

if {[tk windowingsystem] eq "x11"} {
	# --- the override is installed --------------------------------------------------
	ok "override: renamed original"  [expr {[info commands ::tk::MenuFirstEntry_rio] ne ""}] 1

	# --- the click path (flag set) posts without highlighting the first entry -------
	.m.file activate none
	set ::rio_menu_click 1
	tk::MenuFirstEntry .m.file
	set ::rio_menu_click 0
	ok "click: no entry activated"   [.m.file index active] none

	# --- the keyboard path (flag clear) still activates the first entry -------------
	.m.file activate none
	tk::MenuFirstEntry .m.file
	ok "keyboard: first activated"   [expr {[.m.file index active] ne "none"}] 1
	.m.file activate none
} else {
	ok "not x11: override inert"     1 1
}

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
