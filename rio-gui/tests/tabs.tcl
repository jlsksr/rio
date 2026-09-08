#!/usr/bin/env wish
#
# Headless tab-strip overflow test for rio-gui (AGENTS.md D57). When a group has more
# tabs than fit its width, `scroll` mode (default) keeps them on one line behind ◂ ▸
# arrows that page the visible window, and `multi` mode wraps them onto several rows.
# The buffer picker lists every open buffer regardless. Checks the width math, that a wide
# strip shows every tab with no arrows while a narrow one hides some and shows arrows,
# that paging and activation move the visible window, that multi mode wraps onto rows,
# that buffer_pick_rows enumerates the buffers (the picker behind View ▸ Switch to Tab… and
# Compare ▸ Compare With Another Tab…, D74 — navigation only; the Multi-Line Tabs toggle
# lives in the View menu, D-after-57), and that the mode persists through prefs.json.
# Needs a DISPLAY (Tk) and maps the window at chosen sizes to drive real strip widths.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/tabs.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows), so this file's
# own non-ASCII expectations (the ◂ ▸ glyphs) arrive mojibake and fail against the
# correctly-decoded values the GUI produces. The same guard the other entry points
# carry -- a test file is an entry point too. No-op where the system encoding is UTF-8.
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
# A fresh core buffer, registered in group 0 under a chosen (long) display name.
proc mkbuf {name} {
	set id [dict get [rio_result buffer.new {}] buffer]
	register_buffer $id "/proj/$name" {} 0
	return $id
}
proc mgr   {id} { winfo manager [gget 0 tabs].b$id } ;# "pack"/"grid"/"" — is the tab placed?
proc shown {id} { expr {[mgr $id] ne ""} }
proc arrows_shown {} { expr {[winfo manager [gget 0 tabs].ar] ne ""} }

# The editor pane is a fixed share of the window (a stretched panedwindow pane over an
# 80-column text, the toplevel's geometry propagation off since startup), so the strip's
# width does NOT grow to fit its tabs — overflow is driven by tab COUNT, not by resizing
# the window (which the headless WM won't reliably propagate anyway). A window update
# realizes the strip so winfo width / the layout are meaningful.
proc settle {} { refresh_tabs ; update idletasks }

# --- default: scroll, and the width helpers are sane ------------------------------
ok "default layout is scroll"    $::tab_layout scroll

set short [mkbuf a.txt]
set long  [mkbuf a-very-long-document-name.txt]
ok "pixwidth grows with name"    [expr {[tab_pixwidth $long] > [tab_pixwidth $short]}] 1
# fit_last: with only a sliver, at least the starting tab; with plenty, the last index.
set two [list $short $long]
ok "fit_last: >=1 in a sliver"   [tabstrip_fit_last $two 0 1]      0
ok "fit_last: all when it fits"  [tabstrip_fit_last $two 0 100000] 1

# --- few tabs (scratch + these two): all fit, no arrows ---------------------------
set first [lindex [gorder 0] 0]      ;# the boot scratch buffer
activate $first 0
settle
set allshown 1 ; foreach id [gorder 0] { if {![shown $id]} { set allshown 0 } }
ok "few: every tab shown"        $allshown       1
ok "few: no arrows"              [arrows_shown]  0

# --- many tabs: some hidden, arrows appear, the active tab stays visible -----------
for {set i 0} {$i < 16} {incr i} { mkbuf "document-number-[format %02d $i].txt" }
set ids [gorder 0]
set n [llength $ids]
set far [lindex $ids end]
activate $first 0                    ;# active is the first tab again
settle
set hidden 0 ; foreach id $ids { if {![shown $id]} { incr hidden } }
ok "many: some tabs hidden"      [expr {$hidden > 0}] 1
ok "many: arrows shown"          [arrows_shown]       1
ok "many: active tab visible"    [shown $first]       1

# --- the arrows page the window past the active tab (reveal suppressed) ------------
set off0 [gget 0 taboff]
tab_scroll 0 1
ok "scroll right: window moved"  [expr {[gget 0 taboff] > $off0}] 1
tab_scroll 0 -1
ok "scroll left: window back"    [gget 0 taboff] $off0

# --- activating a hidden tab reveals it (reveal pulls the window to it) ------------
ok "far tab starts hidden"       [shown $far]  0
activate $far 0
ok "activate reveals far tab"    [shown $far]  1

# --- multi-line mode wraps the tabs onto more than one packed row-frame -------------
# Each visual row is a packed r<n> frame; the handles pack (not grid) into it at natural
# widths, so a short tab huddles left instead of inheriting another row's column width.
set strip [gget 0 tabs]
set ::tab_layout multi
tab_layout_apply
set rowframes [lsearch -all -inline [winfo children $strip] $strip.r*]
ok "multi: wraps onto >1 row"    [expr {[llength $rowframes] > 1}] 1
ok "multi: a tab packs in a row" [string match $strip.r* [dict get [pack info $strip.b$short] -in]] 1
ok "multi: handle uses pack"     [mgr $short] pack
# `pack -in` doesn't reparent — the handles stay SIBLINGS of the row-frames. The frames are
# created after them, so unless lowered they stack on top and their background paints over
# the tabs (an empty bar). winfo children lists siblings bottom-of-stack first, so every
# r<n> frame must sort BEFORE every b<id> handle.
set kids [winfo children $strip] ; set i 0 ; set lastrow -1 ; set firsttab 1000000
foreach w $kids {
	if {[string match $strip.r* $w]}                    { set lastrow $i }
	if {[string match $strip.b* $w] && $i < $firsttab}  { set firsttab $i }
	incr i
}
ok "multi: rows stack below tabs" [expr {$lastrow < $firsttab}] 1
# Justified like a paragraph: every row but the last expands its tabs to fill the width;
# the last row stays natural. The first tab sits on row 0 (non-last, since >1 row), the
# last tab on the last row.
ok "multi: non-last row expands"  [dict get [pack info $strip.b[lindex $ids 0]]   -expand] 1
ok "multi: non-last row fills x"  [dict get [pack info $strip.b[lindex $ids 0]]   -fill]   x
ok "multi: last row is natural"   [dict get [pack info $strip.b[lindex $ids end]] -expand] 0
set ::tab_layout scroll ; tab_layout_apply
ok "back to scroll: uses pack"   [mgr $far] pack   ;# $far is active -> visible
ok "back to scroll: rows gone"   [llength [lsearch -all -inline [winfo children $strip] $strip.r*]] 0

# --- the buffer picker enumerates every open buffer (navigation only) --------------
# View ▸ Switch to Tab… and Compare ▸ Compare With Another Tab… share buffer_pick_rows,
# which replaced the old top-level .m.tabs cascade (D74). One group here, so it lists all
# $n open buffers; each row is {id label} and the label starts with the tab name.
set rows [buffer_pick_rows]
ok "picker: lists all buffers"   [llength $rows]                    $n
ok "picker: row is {id label}"   [llength [lindex $rows 0]]         2
ok "picker: label starts w/name" [string match "[tab_name [lindex [lindex $rows 0] 0]]*" \
                                     [lindex [lindex $rows 0] 1]]   1
ok "picker: exclude drops one"   [llength [buffer_pick_rows $far]]  [expr {$n - 1}]
ok "picker: exclude omits it" \
	[expr {[lsearch -exact [lmap r [buffer_pick_rows $far] {lindex $r 0}] $far] < 0}] 1
ok "toggle: lives in View menu"  [.m.view type "Multi-Line Tabs"] checkbutton

# --- the mode persists through prefs.json, and a bogus value is rejected -----------
set ::tab_layout multi ; prefs_save
set ::tab_layout scroll ; prefs_load
ok "persist: layout reloaded"    $::tab_layout multi
set pf [prefs_path]
set f [open $pf {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
puts -nonewline $f {{"theme":"default","tab_layout":"sideways"}} ; close $f
set ::tab_layout scroll
prefs_load
ok "persist: bogus rejected"     $::tab_layout scroll

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
