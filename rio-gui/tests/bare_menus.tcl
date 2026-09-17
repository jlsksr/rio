#!/usr/bin/env wish
#
# Headless test for the menus Tk leaves bare (AGENTS.md D115) — the half D108 named and
# deferred: the read-only views (agent log, compare panes, git diff, the manual, a plan)
# and every entry/text widget outside the editor. Ctrl+C already worked in all of them
# through Tk's own class bindings; only the door was missing.
#
# Checks: both builders' entries, order and greys; the deliberate non-greys; a masked
# field withholding Cut and Copy; the commands actually acting when invoked; what a
# right-click settles before the menu appears, which differs between a read-only view
# (no caret to move) and an editable one; and the DRIFT GUARD — every Entry and Text in
# the main window carries a Button-3 binding, so a widget added later without a menu
# fails here rather than shipping bare.
#
# It builds the menus, it never POSTS them: tk_popup takes a global grab on X11 and
# there is nobody here to dismiss it. That split — a builder beside the popup wrapper —
# is the D44 idiom every pane menu follows.
#
# Needs a DISPLAY.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/bare_menus.tcl

# Tcl 8.6 decodes a script with the SYSTEM encoding; re-source as UTF-8 so this file's
# own non-ASCII and the GUI's agree. The guard every entry point carries (D54).
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

# Build a menu with one of the two builders and read it back as {label state ...}.
# Never posted — see the header.
proc menu_of {kind w} {
	catch {destroy .tm}
	menu .tm -tearoff 0
	${kind}_menu_build .tm $w
	set out {}
	for {set i 0} {$i <= [.tm index end]} {incr i} {
		if {[.tm type $i] eq "separator"} { lappend out "-" "-" ; continue }
		lappend out [.tm entrycget $i -label] [.tm entrycget $i -state]
	}
	return $out
}
proc labels_of {kind w} {
	set out {}
	foreach {l s} [menu_of $kind $w] { lappend out $l }
	return $out
}
# Invoke an entry by label.
proc invoke_entry {kind w label} {
	catch {destroy .tm}
	menu .tm -tearoff 0
	${kind}_menu_build .tm $w
	for {set i 0} {$i <= [.tm index end]} {incr i} {
		if {[.tm type $i] eq "separator"} continue
		if {[.tm entrycget $i -label] eq $label} { .tm invoke $i ; return 1 }
	}
	return 0
}

# Fixtures of our own, so a check never depends on what some pane happens to hold.
text  .fxview -state disabled          ;# stands in for a read-only view
entry .fxin                            ;# stands in for a bare entry
entry .fxmask -show •                  ;# the provider key field's shape
text  .fxtext                          ;# an editable text outside the editor
proc fxview_set {s} {
	.fxview configure -state normal
	.fxview delete 1.0 end
	if {$s ne ""} { .fxview insert 1.0 $s }
	.fxview configure -state disabled
}

# ---------------------------------------------------------------------------
# The read-only view's menu
# ---------------------------------------------------------------------------
fxview_set "hello world\nsecond line\n"
.fxview tag remove sel 1.0 end
ok "view: entries and order" [labels_of view .fxview] {Copy {Select All}}
ok "view: no Cut or Paste — the widget would refuse them, so they are not drawn" \
	[expr {"Cut" in [labels_of view .fxview] || "Paste" in [labels_of view .fxview]}] 0
ok "view: Copy greyed with no selection" [menu_of view .fxview] {Copy disabled {Select All} normal}
.fxview tag add sel 1.0 1.5
ok "view: Copy live with a selection"    [menu_of view .fxview] {Copy normal {Select All} normal}
fxview_set ""
ok "view: Select All greyed when empty"  [menu_of view .fxview] {Copy disabled {Select All} disabled}

# …and the entries do what they say, on a widget that is genuinely disabled.
fxview_set "copy me please\n"
.fxview tag remove sel 1.0 end
.fxview tag add sel 1.0 1.7
clipboard clear
invoke_entry view .fxview "Copy"
ok "view: Copy really copies from a disabled widget" [clipboard get] "copy me"
.fxview tag remove sel 1.0 end
invoke_entry view .fxview "Select All"
ok "view: Select All really selects" [expr {[llength [.fxview tag ranges sel]] > 0}] 1
ok "view: the widget is still read-only afterwards" [.fxview cget -state] disabled

# ---------------------------------------------------------------------------
# The editable widget's menu
# ---------------------------------------------------------------------------
.fxin delete 0 end ; .fxin insert 0 "some text"
.fxin selection clear
ok "input: entries and order" [labels_of input .fxin] {Cut Copy Paste - {Select All}}
ok "input: Cut/Copy greyed with no selection, Paste never" \
	[menu_of input .fxin] {Cut disabled Copy disabled Paste normal - - {Select All} normal}
.fxin selection range 0 4
ok "input: Cut/Copy live with a selection" \
	[menu_of input .fxin] {Cut normal Copy normal Paste normal - - {Select All} normal}
.fxin delete 0 end
ok "input: Select All greyed when empty, Paste STILL live (an empty clipboard is silent,\
	and probing it is a blocking X round-trip — D108's reason)" \
	[menu_of input .fxin] {Cut disabled Copy disabled Paste normal - - {Select All} disabled}

# A masked field: Paste is what people do with an API key; lifting the plaintext back
# out of a field drawn as bullets is not (D26).
.fxmask delete 0 end ; .fxmask insert 0 "sk-secret"
.fxmask selection range 0 9
ok "input: a masked field offers no Cut and no Copy" [labels_of input .fxmask] {Paste - {Select All}}
ok "input: …even with a live selection" \
	[menu_of input .fxmask] {Paste normal - - {Select All} normal}
ok "input: an unmasked field still offers them" \
	[expr {"Copy" in [labels_of input .fxin]}] 1

# …and they act.
.fxin delete 0 end ; .fxin insert 0 "cut this"
.fxin selection range 0 3
clipboard clear
invoke_entry input .fxin "Cut"
ok "input: Cut really cuts"   [list [.fxin get] [clipboard get]] {{ this} cut}
.fxin delete 0 end ; .fxin insert 0 "AB" ; .fxin icursor 1
clipboard clear ; clipboard append "-X-"
invoke_entry input .fxin "Paste"
ok "input: Paste really pastes at the caret" [.fxin get] "A-X-B"
.fxtext delete 1.0 end ; .fxtext insert 1.0 "in a text widget"
invoke_entry input .fxtext "Select All"
ok "input: Select All works on a Text too, not just an Entry" \
	[expr {[llength [.fxtext tag ranges sel]] > 0}] 1

# ---------------------------------------------------------------------------
# What the click settles before the menu appears (D108's convention, adapted)
# ---------------------------------------------------------------------------
fxview_set "0123456789\n"
# @0,0 is index 1.0, so a selection that STARTS there is the one a click lands inside.
.fxview tag add sel 1.0 1.5
ctx_click .fxview 0 0 0   ;# a read-only view: not editable
ok "click: a selection survives a right-click inside it" [.fxview tag ranges sel] {1.0 1.5}

.fxview tag remove sel 1.0 end
.fxview tag add sel 1.6 1.9
# The caret starts AWAY from where the click lands (@0,0 is 1.0), or a caret that moved
# and one that did not would read the same.
.fxview mark set insert 1.5
ctx_click .fxview 0 0 0   ;# @0,0 is outside the selection
ok "click: a selection is cleared by a right-click outside it" [.fxview tag ranges sel] {}
ok "click: the caret does NOT move in a read-only view — a disabled text draws no\
	insertion cursor, so moving it would promise something nothing shows" \
	[.fxview index insert] 1.5

.fxtext delete 1.0 end ; .fxtext insert 1.0 "0123456789"
.fxtext mark set insert 1.8
ctx_click .fxtext 0 0 1   ;# editable: the caret follows the pointer, so Paste lands there
ok "click: the caret DOES move in an editable widget" [.fxtext index insert] 1.0

.fxin delete 0 end ; .fxin insert 0 "0123456789"
.fxin selection range 4 8
ctx_click .fxin 0 0 1
ok "click: an entry's selection is cleared outside it too" \
	[expr {![catch {.fxin index sel.first}] ? "kept" : "cleared"}] cleared

# ---------------------------------------------------------------------------
# The bindings, and the drift guard
# ---------------------------------------------------------------------------
foreach {w kind} {.chat.log view .cmp.l.t view .cmp.r.t view .pgit.diff view .plan.text view
                  .chat.input input .find.e input .find.re input .results.hdr.e input
                  .results.rep.e input .pgit.commit.msg input .pgit.commit.body input} {
	ok "bound: $w is a $kind menu" \
		[expr {[string match "*ctx_menu_post*$kind*" [bind $w <Button-3>]] ? $kind : [bind $w <Button-3>]}] $kind
}
foreach w {.chat.log .find.e} {
	ok "bound: $w answers the keyboard route too (Shift+F10 and Menu)" \
		[expr {[bind $w <Shift-F10>] ne "" && [bind $w <Key-Menu>] ne ""}] 1
}
# The commit bar's placeholders are PLACED ON TOP of their fields, so a right-click on an
# empty bar hits the label and never reaches the widget below.
foreach {lbl target} {.pgit.commit.msg.ph .pgit.commit.msg .pgit.commit.body.ph .pgit.commit.body} {
	ok "bound: the placeholder $lbl forwards to $target" \
		[string match "*ctx_menu_post $target*" [bind $lbl <Button-3>]] 1
}

# THE DRIFT GUARD. Not a list of what we bound — a sweep of what exists. Every Entry and
# Text in the main window must have a Button-3 binding, whether it got one here, from
# D108 (the editor) or from rl_init (the row panes). A new bare widget added later fails
# this check by existing.
proc all_text_widgets {w} {
	set out {}
	if {[winfo class $w] in {Entry Text TEntry}} { lappend out $w }
	foreach c [winfo children $w] { lappend out {*}[all_text_widgets $c] }
	return $out
}
set bare {}
foreach w [all_text_widgets .] {
	if {[string match ".fx*" $w]} continue   ;# this suite's own fixtures
	if {[bind $w <Button-3>] eq ""} { lappend bare $w }
}
ok "drift guard: no Entry or Text in the main window is left without a menu" $bare {}
ok "drift guard: …and it actually looked at something" \
	[expr {[llength [all_text_widgets .]] >= 15}] 1

puts ""
if {$::fails} { puts "$::fails CHECK(S) FAILED" ; exit 1 }
puts "ALL CHECKS PASSED"
exit 0
