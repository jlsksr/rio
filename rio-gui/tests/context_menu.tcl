#!/usr/bin/env wish
#
# Headless test for the editor's right-click menu (AGENTS.md D108). Right-clicking the
# text places the caret or keeps the selection (the Win98/VSCode convention), focuses the
# group that was clicked, and posts a menu built from ONE table — the same one the Edit
# menu is built from, so the two doors cannot drift — plus the find group that acts on the
# selection. Checks: the three bindings; what the click does to the caret and the
# selection; the entries and their order; the greys rio computes and the ones it refuses
# to guess; the Search entry's label rule; the shared table behind Edit; and that invoking
# an entry really acts.
#
# It builds the menu, it never POSTS it: tk_popup takes a global grab on X11, and there is
# nobody here to dismiss it. That split — a builder beside the popup wrapper — is the D44
# idiom the pane menus already follow.
#
# Needs a DISPLAY.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/context_menu.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding; re-source as UTF-8 so this file's own
# non-ASCII (the “ ” in the Search label, the …) and the GUI's agree. The guard every entry
# point carries (D54) — a test file is an entry point too.
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

set t [gw 0]             ;# group 0's real editor widget (the boot scratch buffer)
set p [gget 0 path]      ;# the same widget by path (the proxy, what the menus are given)

# Build the context menu for group `g` into .tm, the way a right-click would, and answer
# questions about it. Nothing is posted.
proc build {g} {
	catch {destroy .tm}
	menu .tm -tearoff 0
	editor_context_build .tm $g
}
proc labels {} {
	set out {}
	for {set i 0} {$i <= [.tm index end]} {incr i} {
		if {[.tm type $i] eq "separator"} { lappend out "-" ; continue }
		lappend out [.tm entrycget $i -label]
	}
	return $out
}
proc state {label} { return [.tm entrycget $label -state] }

# --- the bindings are on the editor widget -------------------------------------------

ok "Button-3 opens the menu"    [string match "*editor_context_menu 0 *" [bind $p <Button-3>]] 1
ok "Button-3 breaks the chain"  [string match "*break*" [bind $p <Button-3>]] 1
ok "Menu key opens the menu"    [string match "*editor_context_key 0*" [bind $p <Key-Menu>]] 1
ok "Shift+F10 opens the menu"   [string match "*editor_context_key 0*" [bind $p <Shift-F10>]] 1

# --- the entries, and their order -----------------------------------------------------

build 0
ok "the entries, in order" [labels] \
	{Undo Redo - Cut Copy Paste - {Select All} - Find… Replace… Search…}

# --- the greys rio can compute, and the ones it refuses to guess ----------------------

# The boot buffer is empty and nothing is selected.
ok "empty buffer: Select All off" [state "Select All"] disabled
ok "no selection: Cut off"        [state "Cut"]        disabled
ok "no selection: Copy off"       [state "Copy"]       disabled
ok "Paste is always offered"      [state "Paste"]      normal
ok "Undo is always offered"       [state "Undo"]       normal
ok "Redo is always offered"       [state "Redo"]       normal

$t insert 1.0 "alpha beta\ngamma delta\n"
build 0
ok "with text: Select All on"     [state "Select All"] normal
ok "still no selection: Cut off"  [state "Cut"]        disabled

$t tag add sel 1.0 1.5            ;# "alpha"
build 0
ok "with a selection: Cut on"     [state "Cut"]        normal
ok "with a selection: Copy on"    [state "Copy"]       normal

# --- the Search entry names what it will actually search for --------------------------
# find_open / search_open seed their entry from a SINGLE-LINE selection only; the label
# is the promise, so it has to follow the same rule.

ok "selection: quoted in the label" [lindex [labels] end] "Search for “alpha”"

$t tag remove sel 1.0 end
$t tag add sel 1.0 2.5            ;# across the line break
build 0
ok "multi-line selection: plain"    [lindex [labels] end] "Search…"

$t tag remove sel 1.0 end
build 0
ok "no selection: plain"            [lindex [labels] end] "Search…"

$t insert end "0123456789012345678901234567890\n"
$t tag add sel 3.0 3.31            ;# 31 characters, one line
build 0
ok "a long selection is elided"     [lindex [labels] end] "Search for “01234567890123456789…”"
$t tag remove sel 1.0 end

# --- what the click itself does -------------------------------------------------------

update ; update idletasks
if {[$t bbox 2.3] ne "" && [$t bbox 1.2] ne ""} {
	proc click_at {g idx} {
		lassign [[gw $g] bbox $idx] bx by bw bh
		editor_context_click $g [expr {$bx + $bw / 2}] [expr {$by + $bh / 2}]
	}

	# Outside a selection: the selection is dropped and the caret lands where you pointed.
	$t tag add sel 1.0 1.5
	click_at 0 2.3
	ok "click outside: caret moves"    [$t index insert] 2.3
	ok "click outside: selection gone" [$t tag ranges sel] {}

	# Inside it: both survive, so Cut/Copy/Search act on what is highlighted.
	$t tag add sel 1.0 1.5
	$t mark set insert 1.5
	click_at 0 1.2
	ok "click inside: selection kept"  [$t tag ranges sel] {1.0 1.5}
	ok "click inside: caret kept"      [$t index insert]   1.5
	$t tag remove sel 1.0 end
} else {
	puts "SKIP  click placement (no headless geometry)"
}

# --- a right-click in the OTHER half of a split focuses it first ----------------------
# Undo, Find and Search all act on the focused group, so the click has to move the focus
# there or the menu would quietly act on the other pane.

split_editor
set other [expr {$::focus == 0 ? 1 : 0}]
ok "split: two groups"             [llength $::groups] 2
editor_context_click $other 0 0
ok "click focuses that group"      $::focus $other
ok "and ::cur follows it"          $::cur   [gcur $other]
unsplit_editor
ok "unsplit: back to one group"    [llength $::groups] 1

# --- two doors, one table -------------------------------------------------------------

set edit {}
for {set i 0} {$i <= [.m.edit index end]} {incr i} {
	if {[.m.edit type $i] eq "separator"} { lappend edit "-" ; continue }
	lappend edit [.m.edit entrycget $i -label]
}
ok "Edit menu comes from the table" $edit {Undo Redo - Cut Copy Paste - {Select All}}

set w [gget $::focus path]
$w tag remove sel 1.0 end
editor_menu_post
ok "Edit menu: no selection, Cut off" [.m.edit entrycget "Cut" -state] disabled
$w tag add sel 1.0 1.3
editor_menu_post
ok "Edit menu: a selection, Cut on"   [.m.edit entrycget "Cut" -state] normal

# --- invoking an entry really acts -----------------------------------------------------

set w [gget 0 path]
$w tag remove sel 1.0 end
build 0
.tm invoke "Select All"
ok "Select All selects the buffer" [$w tag ranges sel] [list 1.0 [$w index "end -1c"]]

$w tag remove sel 1.0 end
$w tag add sel 1.0 1.5
build 0
if {[catch {clipboard clear ; clipboard append "x" ; clipboard get}]} {
	puts "SKIP  Copy fills the clipboard (no clipboard on this display)"
} else {
	.tm invoke "Copy"
	ok "Copy fills the clipboard" [clipboard get] "alpha"
}

# --- Change with Agent… (D113) ---------------------------------------------------------
# The one AI entry: absent unless a real provider is selected AND the preference allows
# it, greyed unless there is a selection and no turn under way. Sending goes over the real
# channel to the core, which runs its built-in Echo provider — offline — so the checks see
# the scoped message the core recorded, not a stub's idea of it.

# A fresh buffer, typed through the proxy the way keystrokes arrive: the core reads
# the range from ITS copy, so the widget and the core must agree on the text.
do_new
set w [gget 0 path]
$w insert 1.0 "alpha beta\n"
update ; update idletasks
set ::agent_selection_menu 1
set ::agent_provider echo
build 0
ok "agent: hidden with Echo"          [lsearch -exact [labels] "Change with Agent…"] -1
set ::agent_provider claude            ;# only the entry's rule reads this; nothing is called
build 0
ok "agent: shown with a real provider" [lrange [labels] end-1 end] {- {Change with Agent…}}
ok "agent: no selection, greyed"      [state "Change with Agent…"] disabled
$w tag add sel 1.0 1.5                 ;# "alpha"
build 0
ok "agent: a selection, offered"      [state "Change with Agent…"] normal
set ::chat_busy 1 ; build 0
ok "agent: a turn working, greyed"    [state "Change with Agent…"] disabled
set ::chat_busy 0 ; set ::pending_turn 7 ; build 0
ok "agent: a turn waiting, greyed"    [state "Change with Agent…"] disabled
set ::pending_turn ""
set ::agent_selection_menu 0 ; build 0
ok "agent: the preference hides it"   [lsearch -exact [labels] "Change with Agent…"] -1
ok "agent: and the rest is unchanged" [lrange [labels] 0 end] \
	{Undo Redo - Cut Copy Paste - {Select All} - Find… Replace… {Search for “alpha”}}
set ::agent_selection_menu 1

ok "agent: scope of the selection"    [agent_selection_scope 0] [dict create buffer [gcur 0] start 1.0 end 1.5]
ok "agent: a line label"              [agent_scope_label [dict create buffer [gcur 0] start 1.0 end 1.5]] "[tab_name [gcur 0]], line 1"
ok "agent: a trailing column 0 drops" [agent_scope_label [dict create buffer [gcur 0] start 1.0 end 3.0]] "[tab_name [gcur 0]], lines 1–2"

$w tag add sel 1.0 1.5
build 0
.tm invoke "Change with Agent…"
ok "agent: the dialog opens"          [winfo exists .agentchg] 1
ok "agent: it says where"             [.agentchg.where cget -text] "Selection: [tab_name [gcur 0]], line 1"
catch {grab release .agentchg}
agent_change_submit .agentchg [agent_selection_scope 0]
ok "agent: empty instruction stays"   [winfo exists .agentchg] 1
.agentchg.input insert 1.0 "shout it"
.agentchg.btns.send invoke
ok "agent: Send closes the dialog"    [winfo exists .agentchg] 0
set deadline [expr {[clock milliseconds] + 3000}]
while {$::chat_busy && [clock milliseconds] < $deadline} { update ; after 20 }
set msgs [dict get [rio_result agent.history {}] messages]
set asked ""
foreach m $msgs { if {[dict get $m role] eq "user"} { set asked [dict get $m text] } }
ok "agent: the core scoped the turn"  [string match "shout it\n\n*line 1)*\n```\nalpha\n```" $asked] 1
ok "agent: the pane came into view"   [rio::layout::shown chat] 1
ok "agent: the transcript says where" [string match "*· on the selection in [tab_name [gcur 0]], line 1*" [.chat.log get 1.0 end]] 1
set ::agent_provider echo

catch {destroy .tm}
puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
