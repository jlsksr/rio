#!/usr/bin/env wish
#
# Headless test for the split editor (AGENTS.md D33): two editor groups side by side,
# each with its own tab strip, active buffer, and highlight cache. Drives the real
# frontend's group procs directly (split_editor, do_open, move_tab_other,
# unsplit_editor, do_close) and inspects ::groups / ::grp / the group widgets. Like
# the smoke suite, it runs a core in THIS process behind a socket and attaches the GUI
# over the real channel, so the core stays inspectable while every op crosses the wire.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/split.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs/workspace (D31)
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
proc tmpbytes {bytes} {
	set f [file tempfile path]
	fconfigure $f -translation binary
	puts -nonewline $f $bytes ; close $f
	return $path
}
# A file with a real extension (so a highlighter is selected) under the sandbox dir.
proc tmphtml {bytes} {
	file mkdir $::sandbox_dir
	set p [file join $::sandbox_dir test[incr ::htmln].html]
	set f [open $p w] ; puts -nonewline $f $bytes ; close $f
	return $p
}
proc gtext {g} { [gw $g] get 1.0 end-1c }         ;# a group's widget text (bypasses the proxy)
proc typ   {g s} { [gget $g path] insert 1.0 $s } ;# type into a group through its proxy

# --- start: a single group ---------------------------------------------------
ok "start: one group"            [llength $::groups] 1
ok "start: focus is group 0"     $::focus 0
set fileA [tmpbytes "AAA\n"]
do_open $fileA
set gA $::focus
ok "start: file A in group 0"    [gtext $gA] "AAA\n"

# --- split: a second group with its own scratch, focused ---------------------
split_editor
ok "split: two groups now"       [llength $::groups] 2
ok "split: focus moved off A"    [expr {$::focus ne $gA}] 1
set gB $::focus
ok "split: distinct group ids"   [expr {$gA ne $gB}] 1
ok "split: panedwindow has two panes" [llength [.groups panes]] 2
ok "split: new group one scratch tab" [llength [gorder $gB]] 1
ok "split: new group is empty"   [gtext $gB] ""
ok "split: group A still has A"  [gtext $gA] "AAA\n"

# --- open a file in the second group (do_open targets the focused group) -----
set fileB [tmphtml "<b>hi</b>\n"]
do_open $fileB
ok "open: file B in group B"     [gtext $gB] "<b>hi</b>\n"
ok "open: group A untouched"     [gtext $gA] "AAA\n"
ok "open: B pruned its scratch"  [llength [gorder $gB]] 1

# --- per-group highlight cache: each group scans its own buffer's type --------
ok "hl: group B is HTML"         [gget $gB hl_lang] HTML
ok "hl: group A is plain"        [gget $gA hl_lang] ""

# --- edit each group independently; content must not bleed across ------------
typ $gB "X"                              ;# type into B (focused)
ok "edit: B changed"             [gtext $gB] "X<b>hi</b>\n"
ok "edit: A unaffected"          [gtext $gA] "AAA\n"
focus_group $gA
ok "focus: switched to A"        $::focus $gA
ok "focus: ::cur mirrors A"      $::cur [gcur $gA]
typ $gA "Y"                              ;# type into A (now focused)
ok "edit: A changed"             [gtext $gA] "YAAA\n"
ok "edit: B unaffected"          [gtext $gB] "X<b>hi</b>\n"

# --- move a tab to the other group -------------------------------------------
# Give group A a second tab, then peel it across so group A survives (a real split).
set fileC [tmpbytes "CCC\n"]
do_open $fileC                           ;# opens in focused group A -> A = [A, C]
ok "move: setup A has two tabs"  [llength [gorder $gA]] 2
set movedC $::cur
move_tab_other
ok "move: still two groups"      [llength $::groups] 2
ok "move: C left group A"        [expr {[lsearch -exact [gorder $gA] $movedC] < 0}] 1
ok "move: C now in group B"      [expr {[lsearch -exact [gorder $gB] $movedC] >= 0}] 1
ok "move: follows to group B"    $::focus $gB
ok "move: C shows in B"          [gtext $gB] "CCC\n"

# --- close-to-collapse: emptying one of two groups unsplits ------------------
proc maybe_discard {} { return 1 }       ;# headless: skip the unsaved-changes modal
# group B holds [B, C]; close both so it empties and collapses into group A.
do_close ; do_close
ok "collapse: back to one group"  [llength $::groups] 1
ok "collapse: panedwindow one pane" [llength [.groups panes]] 1
set gsole [lindex $::groups 0]
ok "collapse: survivor is group A" $gsole $gA
ok "collapse: focus on survivor"   $::focus $gA
ok "collapse: A's file intact"     [gtext $gA] "YAAA\n"

# --- unsplit folds the second group's tabs back into the first ---------------
split_editor                             ;# group with a fresh scratch, focused
set gSplit $::focus
set before [llength [gorder $gA]]
unsplit_editor
ok "unsplit: one group again"      [llength $::groups] 1
ok "unsplit: scratch folded in"    [llength [gorder [lindex $::groups 0]]] [expr {$before + 1}]
ok "unsplit: focus valid"          [expr {$::focus in $::groups}] 1

puts ""
if {$::fails == 0} { puts "ALL CHECKS PASSED" } else { puts "$::fails CHECK(S) FAILED" }
exit [expr {$::fails > 0}]
