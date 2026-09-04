#!/usr/bin/env wish
#
# Headless gutter-line-select test for rio-gui (AGENTS.md D61). Clicking a number in the
# line-number gutter selects that whole LOGICAL line; dragging extends the selection
# line-by-line, up or down. The gutter is a canvas whose y-space equals the text widget's
# (gutter_redraw draws each number at the text's own dlineinfo y), so a click y inverts
# back through `index @0,$y`. Checks: the Button-1 binding is wired to gutter_press; a
# single select spans the full line (range end = next line start); extend is inclusive and
# direction-independent; the caret and the D60 current-line band follow; the last,
# newline-less line clamps to `end`; and — when the WM gives real geometry — a click y maps
# to the right line. Needs a DISPLAY.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/gutter_select.tcl

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

# --- the click binding is wired to gutter_press --------------------------------------
ok "Button-1 bound to gutter_press" \
	[string match "*gutter_press*" [bind [gget 0 frame].gutter <Button-1>]] 1

# Seed six lines directly in the widget (a display test needs no core round-trip).
$t insert 1.0 "l1\nl2\nl3\nl4\nl5\nl6\n"

# --- a single select spans the whole line (end reaches the next line's start) --------
gutter_select 0 3 3
ok "single line: full-width span"  [$t tag ranges sel] {3.0 4.0}

# --- extend is inclusive, and direction-independent ----------------------------------
gutter_select 0 2 5
ok "extend down: 2..5 inclusive"   [$t tag ranges sel] {2.0 6.0}
gutter_select 0 5 2
ok "extend up: same range"         [$t tag ranges sel] {2.0 6.0}

# --- the caret and the D60 current-line band follow the selection end ----------------
ok "caret at selection end line"   [expr {int([$t index insert])}] 6
ok "current-line band follows"     [expr {[llength [$t tag ranges curline]] > 0}] 1

# --- the last, newline-less line clamps to end (no index past the buffer) ------------
# Line 7 is the empty final line after the trailing newline; put text there (no newline)
# so it is a real, newline-less last line, then select it.
$t insert end "tail"
set last [expr {int([$t index end-1c])}]
gutter_select 0 $last $last
ok "last line: end clamps to end"  [lindex [$t tag ranges sel] 1] [$t index "end-1c lineend +1c"]

# --- y -> line mapping through a real click, when the WM grants geometry --------------
update ; update idletasks
set dl [$t dlineinfo 3.0]
if {$dl ne ""} {
	set y [expr {[lindex $dl 1] + [lindex $dl 3] / 2}]
	gutter_press 0 $y
	ok "click y maps to line 3"    [$t tag ranges sel] {3.0 4.0}
} else {
	puts "SKIP  click y maps to line 3 (no headless geometry)"
}

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
