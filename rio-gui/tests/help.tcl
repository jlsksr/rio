#!/usr/bin/env wish
#
# Headless test for the in-app help viewer (AGENTS.md D99): Help ▸ Contents… / F1 opens
# rio's own manual — the contents parsed from docs/index.md on the left, the selected
# topic's text on the right. docs.tcl (check 8) holds the DATA path — the resolver points
# at the real docs/ and offers exactly the pages index.md lists. This file holds the
# WINDOW: that it builds, that its rows carry the right topics, that picking one loads it,
# that a missing topic is reported instead of thrown, and that a second open raises the
# window rather than stacking another.
#
# Needs a DISPLAY (it builds a real toplevel). No files are opened through the core: the
# viewer reads docs/ off the GUI's own tree, which is the point of it (a remote core's
# docs/ is a different machine's).
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/help.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding; re-source as UTF-8 so this file's own
# non-ASCII and the manual's agree. The guard every entry point carries (D54).
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

# --- the door: a menu entry and a remappable command ---------------------------------
#
# F1 goes through ::keymap_default like every other chord (D23) rather than a hard-coded
# binding, so it shows up in the shortcuts editor and in keyboard.md — which is what makes
# docs.tcl's keymap check cover it.
ok "menu: Help carries Contents…"   [.m.help entrycget 0 -label] "Contents…"
ok "menu: About is still there"     [.m.help entrycget end -label] "About rio"
ok "keymap: help is a command"      [dict exists $::keymap_default help] 1
ok "keymap: F1 is its default"      [lindex [dict get $::keymap_default help] 0] F1
ok "keymap: it opens the viewer"    [lindex [dict get $::keymap_default help] 1] help_window

# --- opening it ----------------------------------------------------------------------

ok "closed: no window yet"          [winfo exists .help] 0
help_window
ok "open: the window exists"        [winfo exists .help] 1
ok "open: lands on the front page"  $::help_topic index.md
ok "open: the page has text"        [expr {[string length [.help.page.text get 1.0 end]] > 200}] 1
ok "open: the page is read-only"    [.help.page.text cget -state] disabled
ok "open: the footer names the file" [.help.foot.where cget -text] [file join docs index.md]

# --- the contents list ----------------------------------------------------------------
#
# rl_* indexes rows by LINE, so every line must be a row — section headings included, as
# unselectable ones. A heading that forgot its rl_row would slide every topic below it onto
# the wrong payload, which is why the row count and the line count are checked against each
# other rather than either alone.
set b .help.nav.list
# Each row inserted its own trailing newline, so the widget's last index sits one line past
# the last row — rows are lines 1..N and `end-1c` is line N+1.
set lines [expr {[lindex [split [$b index end-1c] .] 0] - 1}]
ok "list: one row per line"         [llength $::rl_rows($b)] $lines
ok "list: the front page leads"     [rl_payload $b 0] index.md

# Every topic index.md lists is a selectable row, and every section heading is not.
set topics {}
foreach e [help_contents] { lappend topics [lindex $e 2] }
set rows {} ; set headings 0
for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
	if {[rl_selectable $b $i]} { lappend rows [rl_payload $b $i] } else { incr headings }
}
ok "list: offers every topic"       [lsort -unique [lrange $rows 1 end]] [lsort -unique $topics]
ok "list: headings are inert"       [expr {$headings > 0}] 1

# --- picking a topic ------------------------------------------------------------------

# Row indices are the list's own, headings included — so look the topic up by payload
# rather than counting, which is what a reader clicking the row effectively does.
proc row_of {b file} {
	for {set i 0} {$i < [llength $::rl_rows($b)]} {incr i} {
		if {[rl_payload $b $i] eq $file} { return $i }
	}
	return -1
}
set gi [row_of $b git.md]
ok "pick: git.md has a row"         [expr {$gi >= 0}] 1
rl_select $b $gi
ok "pick: the topic loaded"         $::help_topic git.md
ok "pick: its text is showing"      [string match "*# Git*" [.help.page.text get 1.0 end]] 1
ok "pick: the footer followed"      [.help.foot.where cget -text] [file join docs git.md]
ok "pick: the row is selected"      $::rl_sel($b) $gi

# Reaching a topic any other way still syncs the list selection, so the two halves of the
# window can never disagree about what is on screen.
help_show keyboard.md
ok "show: selection follows"        $::rl_sel($b) [row_of $b keyboard.md]

# --- a topic that isn't there ---------------------------------------------------------
#
# A partial install must not break the one window that would explain it: the failure is
# REPORTED in the page, naming the path it wanted.
help_show no-such-topic.md
ok "missing: reported, not thrown"  \
	[string match "*could not be read*no-such-topic.md*" [.help.page.text get 1.0 end]] 1
ok "missing: window still up"       [winfo exists .help] 1

# --- opening it again ------------------------------------------------------------------

help_window editor.md
ok "reopen: still one window"       [llength [lsearch -all -inline [winfo children .] .help]] 1
ok "reopen: showed the asked topic" $::help_topic editor.md

destroy .help
ok "close: window gone"             [winfo exists .help] 0
ok "close: topic cleared"           $::help_topic ""

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
