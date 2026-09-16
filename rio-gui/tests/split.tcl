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

# Tcl 8.6 decodes a script with the SYSTEM encoding (cp1252 on Windows), so this
# file's own non-ASCII expectations arrive mojibake and fail against the correctly-
# decoded values the GUI produces. The same guard the rio-gui and server entry points
# carry -- a test file is an entry point too. No-op where the system encoding is UTF-8.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}
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
set_buffer_lang $movedC HTML             ;# a hand-picked language belongs to the buffer (D112)
move_tab_other
ok "move: picked language follows" [gget $gB hl_lang] HTML
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

# --- context-menu move: a SPECIFIC, non-active tab (move_buffer_to_other) -----
set g0 $::focus
set fileD [tmpbytes "DDD\n"]
set fileE [tmpbytes "EEE\n"]
do_open $fileD ; set idD $::cur
do_open $fileE                           ;# E is now active; D is a background tab in g0
ok "ctx: D is non-active"          [expr {$idD ne [gcur $g0]}] 1
move_buffer_to_other $idD $g0            ;# what right-click ▸ Move does to tab D
ok "ctx: split created"            [llength $::groups] 2
set gOther [other_group $g0]
ok "ctx: D left its group"         [expr {[lsearch -exact [gorder $g0] $idD] < 0}] 1
ok "ctx: D moved to other group"   [expr {[lsearch -exact [gorder $gOther] $idD] >= 0}] 1
ok "ctx: source kept E active"     [gtext $g0] "EEE\n"
ok "ctx: follows the moved tab"    $::focus $gOther
ok "ctx: moved tab is shown"       [gtext $gOther] "DDD\n"

# --- drag-and-drop drop resolver (group_of_widget) ---------------------------
# The DnD gesture resolves a drop by walking up from the widget under the pointer to
# its group frame. Drive that resolver directly (no synthetic pointer events): a
# group's own text widget, tab strip, and frame all resolve to the group; an unrelated
# widget resolves to "".
ok "dnd: text widget -> its group"   [group_of_widget [gget $g0 path]] $g0
ok "dnd: tab strip -> its group"     [group_of_widget [gget $gOther tabs]] $gOther
ok "dnd: frame -> its group"         [group_of_widget [gget $g0 frame]] $g0
ok "dnd: outside any group -> none"  [group_of_widget .groups] ""

# --- within-group tab reorder (tab_reorder) ----------------------------------
# The pure splice behind a same-group drop: move `id` to the slot implied by pointer-x
# against the tabs' centres. Drive it directly with synthetic centres (no geometry).
set cen {10 100 20 200 30 300}
ok "reorder: drag to far right"    [tab_reorder {10 20 30} 20 $cen 350] {10 30 20}
ok "reorder: drag to far left"     [tab_reorder {10 20 30} 20 $cen 50]  {20 10 30}
ok "reorder: drag into middle"     [tab_reorder {10 20 30} 30 $cen 150] {10 30 20}
ok "reorder: dropped in place"     [tab_reorder {10 20 30} 20 $cen 150] {10 20 30}

# The menu builds the expected entries (swallow the real popup — it's interactive).
rename tk_popup _real_tk_popup
proc tk_popup {args} {}
tab_context_menu $gOther [gcur $gOther] 0 0
ok "menu: four entries"            [.tabmenu index end] 3   ;# Move, Copy Path, sep, Close
ok "menu: move label"              [.tabmenu entrycget 0 -label] "Move to Other Group"
ok "menu: copy-path entry"         [.tabmenu entrycget 1 -label] "Copy Path"
ok "menu: close label"             [.tabmenu entrycget 3 -label] "Close"
# Copy Path puts the moved tab's real path on the clipboard.
tab_copy_path [gcur $gOther]
ok "menu: copy path to clipboard"  [clipboard get] $fileD
# One label regardless of split state: with a single group the move creates the split.
unsplit_editor
tab_context_menu $::focus [gcur $::focus] 0 0
ok "menu: move label (1 group)"    [.tabmenu entrycget 0 -label] "Move to Other Group"
rename tk_popup ""
rename _real_tk_popup tk_popup

puts ""
if {$::fails == 0} { puts "ALL CHECKS PASSED" } else { puts "$::fails CHECK(S) FAILED" }
exit [expr {$::fails > 0}]
