#!/usr/bin/env wish
#
# Headless test for syntax highlighting (AGENTS.md D32): opens (X)HTML in the real
# frontend (window withdrawn) and checks that the GUI applier paints the right
# `syn:*` text tags from the pure tokeniser, that plain files get none, that a live
# edit re-highlights, and that a theme switch recolours the tags. Needs a DISPLAY
# (Tk) but never shows a window.
#
# Like the smoke, the core runs in THIS process behind a socket and the GUI attaches
# over the real channel (D30). Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/highlight.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG (D31)
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

# A throwaway dir to hold files with real extensions (do_open keys off the suffix).
set ::hldir [file join [file dirname [file tempfile _t]] rio-hl-[clock clicks]]
file delete $_t ; file mkdir $::hldir
proc spit {name bytes} {
	set p [file join $::hldir $name]
	set f [open $p w] ; fconfigure $f -translation binary
	puts -nonewline $f $bytes ; close $f
	return $p
}
# Tag ranges on the editor for one syntax token type.
proc ranges {tok} { ::rio_real_t tag ranges syn:$tok }
proc has_tag_at {tok idx} { expr {[lsearch -exact [::rio_real_t tag names $idx] syn:$tok] >= 0} }

# --- the modules loaded, and the vocabulary is wired to tags -----------------
ok "load: registry available"    [expr {[info procs rio::syntax::tokens] ne ""}] 1
ok "load: html registered"       [rio::syntax::for_path a.html]  rio::syntax::html::scan
ok "theme: a tag is configured"  [expr {[::rio_real_t tag cget syn:comment -foreground] ne ""}] 1
ok "theme: default comment hue"  [::rio_real_t tag cget syn:comment -foreground] "#6a737d"

# --- open an HTML file: the applier paints tags ------------------------------
set hp [spit index.html {<!-- top --><p class="x">hi &amp; bye</p>}]
do_open $hp
ok "open: tokeniser selected"    [expr {$::hl_scan ne ""}] 1
ok "open: element name tagged"   [has_tag_at tag 1.12]        1 ;# the '<' of <p
ok "open: attribute tagged"      [has_tag_at attribute 1.15] 1 ;# 'class'
ok "open: value string tagged"   [has_tag_at string 1.21]    1 ;# inside "x"
ok "open: entity tagged"         [expr {[llength [ranges entity]] > 0}] 1
ok "open: comment tagged"        [has_tag_at comment 1.0]    1
ok "open: text left un-tagged"   [has_tag_at tag 1.25]       0 ;# the 'h' of "hi"

# --- multi-line context: a comment spanning lines colours both lines ---------
set mp [spit multi.html "<!-- line one\nstill comment -->\n<b>x</b>"]
do_open $mp
ok "multiline: comment on line 1" [expr {[llength [ranges comment]] > 0}] 1
ok "multiline: comment on line 2" [has_tag_at comment 2.0] 1
ok "multiline: real tag after"    [has_tag_at tag 3.0]     1

# --- a plain-text file gets no highlighter and no tags -----------------------
set tp [spit notes.txt "<p>this is not html</p>\n"]
do_open $tp
ok "plain: no tokeniser"          $::hl_scan ""
ok "plain: no syntax tags"        [expr {[llength [ranges tag]] + [llength [ranges string]]}] 0

# --- a live edit re-highlights (coalesced on idle) ---------------------------
do_open [spit edit.html "<p>x</p>"]
ok "edit: before, one line tagged" [expr {[llength [ranges tag]] > 0}] 1
.ed.t insert end-1c "\n<b>y</b>"     ;# add a second line via the dumb-view proxy
update ; update idletasks             ;# flush the async change + the idle re-highlight
ok "edit: idle re-highlight ran"   $::hl_pending 0
ok "edit: new line's tag painted"  [has_tag_at tag 2.0] 1

# --- incremental scope: a local edit re-scans only a line or two, not the file
set many "<a>1</a>"
for {set i 2} {$i <= 8} {incr i} { append many "\n<a>$i</a>" }   ;# 8 lines
do_open [spit many.html $many]
ok "incr: cache one entry per line" [llength $::hl_enter] 8
.ed.t insert 8.3 "X"                  ;# edit the LAST line (no state change below)
update ; update idletasks
ok "incr: local edit re-scans few"  [expr {$::hl_scanned <= 2}] 1
ok "incr: still one entry per line"  [llength $::hl_enter] 8
.ed.t insert 1.0 "Z"                  ;# edit the FIRST line; state doesn't propagate
update ; update idletasks
ok "incr: top edit converges fast"  [expr {$::hl_scanned <= 2}] 1
ok "incr: untouched line 5 intact"  [has_tag_at tag 5.0] 1

# --- state that OPENS at the top must propagate down until it re-converges ----
.ed.t insert 1.0 "<!--"               ;# open a comment on line 1, never closed
update ; update idletasks
ok "incr: open comment reaches end" [has_tag_at comment 8.0] 1
ok "incr: propagated to all lines"  [expr {$::hl_scanned >= 8}] 1
.ed.t insert 1.4 "-->"                ;# close it again on line 1
update ; update idletasks
ok "incr: closing clears line 8"    [has_tag_at comment 8.0] 0
ok "incr: line 8 tag restored"      [has_tag_at tag 8.0] 1

# --- deleting a line keeps the cache aligned (later edits still correct) ------
.ed.t delete 4.0 5.0                  ;# remove one whole line
update ; update idletasks
ok "incr: cache shrank with buffer" [llength $::hl_enter] [expr {[lindex [split [::rio_real_t index end-1c] .] 0]}]
ok "incr: line after delete tagged" [has_tag_at tag 4.0] 1

# --- switching back to a plain buffer clears the tags ------------------------
do_open $tp
ok "switch: tags cleared on plain" [expr {[llength [ranges tag]] == 0}] 1

# --- a theme switch recolours the tags live ----------------------------------
do_open $hp
do_theme solarized-dark
ok "theme: dark recolours comment" [::rio_real_t tag cget syn:comment -foreground] "#586e75"
ok "theme: dark keeps tag placed"  [has_tag_at comment 1.0] 1
do_theme acme
ok "theme: acme recolours comment" [::rio_real_t tag cget syn:comment -foreground] "#6a6a3a"
do_theme default

file delete -force $::hldir
puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
