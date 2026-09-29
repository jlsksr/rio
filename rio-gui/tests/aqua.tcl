#!/usr/bin/env wish
#
# Headless test for D135: on Aqua, native controls follow the theme's lightness, and chrome
# and chat text are floored at 11pt while the editor keeps the theme's size. The pure halves
# (luma, the appearance a background asks for, the floor's arithmetic) run everywhere; the
# checks that read the native appearance run on Aqua only and are skipped elsewhere.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/aqua.tcl
#       (on macOS feed it a stdin, `: | wish …`, or its output is discarded — D133)

# Tcl 8.6 decodes a script with the SYSTEM encoding; the same guard every entry point carries (D54).
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
proc skip {label} { puts "SKIP  $label (not Aqua)" }
set aqua [expr {[tk windowingsystem] eq "aqua"}]

# --- hex_luma: the ends and the middle ----------------------------------------------
ok "luma: black"  [expr {round([hex_luma #000000])}] 0
ok "luma: white"  [expr {round([hex_luma #ffffff])}] 255
ok "luma: grey"   [expr {round([hex_luma #808080])}] 128

# --- the appearance each shipped theme asks for -------------------------------------
# Derived from the theme's own pair, not typed in: a theme is dark when its ui.bg is darker
# than its ui.fg. At least one must come out dark, or the check proves nothing.
set themes [dict get [rio_call theme.list {}] result themes]
set dark 0
foreach name $themes {
	set c [dict get [rio_call theme.get [dict create name $name]] result colors]
	set bg [dict get $c ui.bg]
	set want [expr {[hex_luma $bg] < [hex_luma [dict get $c ui.fg]] ? "darkaqua" : "aqua"}]
	if {$want eq "darkaqua"} { incr dark }
	ok "appearance for $name ($bg)" [aqua_appearance_for $bg] $want
}
ok "a shipped theme is dark" [expr {$dark > 0}] 1

# --- the font floor -----------------------------------------------------------------
if {$aqua} {
	ok "floor is 11 on Aqua"          $::ui_font_floor 11
	ok "ui_size raises 9"             [ui_size 9]  11
	ok "ui_size keeps 14"             [ui_size 14] 14
	ok "RioUIFont floored"            [font configure RioUIFont -size]   11
	ok "RioChatFont floored"          [font configure RioChatFont -size] 11
	ok "chrome_font floored"          [lindex [chrome_font 9] 1] 11
} else {
	ok "no floor off Aqua"            [ui_size 9] 9
	ok "RioUIFont at the theme's size" [font configure RioUIFont -size] 9
}
ok "editor keeps the theme's size" [font configure RioEditorFont -size] 12
# The drift guard: every font in the tree, text tags included, clears the floor. A widget
# built with a bare `{family 9}` instead of chrome_font fails here by its path.
proc fonts_below {w floor} {
	set bad {}
	if {![catch {$w cget -font} f] && $f ne "" && [font actual $f -size] < $floor} {
		lappend bad "$w ($f)"
	}
	if {[winfo class $w] eq "Text"} {
		foreach tag [$w tag names] {
			set f [$w tag cget $tag -font]
			if {$f ne "" && [font actual $f -size] < $floor} { lappend bad "$w tag $tag ($f)" }
		}
	}
	foreach k [winfo children $w] { lappend bad {*}[fonts_below $k $floor] }
	return $bad
}
if {$aqua} {
	ok "no widget font below the floor" [fonts_below . 11] {}
} else {
	skip "no widget font below the floor"
}

# --- the native appearance follows the theme ----------------------------------------
proc appearance {w} { ::tk::unsupported::MacWindowStyle appearance $w }
if {$aqua} {
	toplevel .old; wm withdraw .old; update idletasks
	do_theme solarized-dark
	ok "dark theme: . is darkaqua"          [appearance .]    darkaqua
	ok "dark theme: existing toplevel too"  [appearance .old] darkaqua
	toplevel .new; wm withdraw .new; update
	ok "dark theme: a new toplevel follows" [appearance .new] darkaqua
	do_theme default
	ok "light theme: . is aqua"             [appearance .]    aqua
	ok "light theme: existing toplevel too" [appearance .new] aqua
	destroy .old .new
} else {
	skip "native appearance follows the theme"
}

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
