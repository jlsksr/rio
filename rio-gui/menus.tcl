# rio-gui/menus.tcl — context menus: inputs, read-only views, the editor.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The menu Tk leaves bare (D115) — the half D108 named and deferred.
#
# D108 gave the editor text its context menu and stopped there, deliberately: the
# READ-ONLY views (agent log, compare panes, git diff, the manual, a plan) and every
# entry/text widget OUTSIDE the editor were left for "its own later change". In all
# of them Ctrl+C already works, through Tk's own class bindings — only the door was
# missing, on surfaces where every neighbour in rio has one.
#
# THE COMMANDS ARE TK'S OWN VIRTUAL EVENTS. Unlike the editor, whose edits must
# travel to the core through the group proxy (D3), these are ordinary local Tk
# widgets whose Ctrl+X/C/V *is* the Entry/Text class binding. So the menu generates
# that same event: <<Cut>> <<Copy>> <<Paste>> <<SelectAll>>. The menu and the
# keystroke are then one implementation by construction — D38's anti-drift rule,
# reached from the other side — and there is no second clipboard code path to keep
# in step. (`-state disabled` blocks neither selection nor `tag add sel`; see the
# rl_init note above. A disabled text takes <<Copy>> and <<SelectAll>> and ignores
# <<Paste>>, which is exactly the behaviour these menus want.)
#
# Two families, because the widgets differ in what they can honestly offer:
#   view   read-only  — Copy, Select All
#   input  editable   — Cut, Copy, Paste, Select All
# Both are applied at the widget's CREATION SITE via ctx_bind_view / ctx_bind_input,
# the way every other binding in this file is, and both follow the D44 popup idiom:
# a builder split from the popup so a headless test can read the entries without a
# global grab nobody is there to dismiss.
#
# NOT here: the rl_* row lists (Files, Git, Search results, the manual's contents).
# The first two have real row menus already; the other two have the right button
# bound to an empty callback, and filling it means deciding what Copy or Open MEAN for a result
# row — a Search and Help feature, not the missing door this change is about. And
# rl_init kills text selection in those panes outright, so a Copy there could not be
# the copy this menu offers anyway.
# ---------------------------------------------------------------------------

# Entry and Text answer "is anything selected?" and "is there anything at all?"
# differently, and both families need both answers. One switch, in one place.
proc ctx_has_sel {w} {
	if {[winfo class $w] eq "Text"} { return [expr {[llength [$w tag ranges sel]] > 0}] }
	return [expr {![catch {$w selection present} p] && $p}]
}
proc ctx_has_text {w} {
	if {[winfo class $w] eq "Text"} { return [$w compare "end -1c" > 1.0] }
	return [expr {[string length [$w get]] > 0}]
}

# A read-only view's menu: what you can do to text you cannot edit. No Cut and no
# Paste — the widget would refuse them, and an entry that cannot work should not be
# drawn (D108 greys only what it can compute honestly; here the honest answer is to
# leave them out entirely).
proc view_menu_build {m w} {
	set sel  [expr {[ctx_has_sel $w]  ? "normal" : "disabled"}]
	set some [expr {[ctx_has_text $w] ? "normal" : "disabled"}]
	$m add command -label "Copy"       -state $sel  -command [list event generate $w <<Copy>>]
	$m add command -label "Select All" -state $some -command [list event generate $w <<SelectAll>>]
}

# An editable widget's menu. Cut and Copy follow the selection and Select All follows
# the content; PASTE STAYS ENABLED for D108's reason — probing the clipboard is a
# blocking X round-trip to whichever application owns the selection, and an
# unresponsive owner would stall the menu on its way up. An empty clipboard already
# does nothing, silently.
#
# A MASKED field (the provider API key, -show •) offers Paste and Select All only.
# Pasting a key is the thing people actually do; lifting plaintext out of a field
# drawn as bullets is a surprise, and D26 treats a key as a secret.
proc input_menu_build {m w} {
	set sel    [expr {[ctx_has_sel $w]  ? "normal" : "disabled"}]
	set some   [expr {[ctx_has_text $w] ? "normal" : "disabled"}]
	set masked [expr {![catch {$w cget -show} s] && $s ne ""}]
	if {!$masked} {
		$m add command -label "Cut"  -state $sel -command [list event generate $w <<Cut>>]
		$m add command -label "Copy" -state $sel -command [list event generate $w <<Copy>>]
	}
	$m add command -label "Paste" -state normal -command [list event generate $w <<Paste>>]
	$m add separator
	$m add command -label "Select All" -state $some -command [list event generate $w <<SelectAll>>]
}

# What a right-click settles before either menu appears. D108's convention, minus the
# half a read-only view cannot keep: a click INSIDE the selection leaves it alone, so
# Copy acts on what you can see is highlighted; a click outside clears it. The caret
# does NOT move in a read-only view — a disabled text draws no insertion cursor, so
# moving it would be a promise nothing on screen keeps. In an editable widget it does
# move, exactly as in the editor, so Paste lands where you pointed.
proc ctx_click {w x y editable} {
	if {$editable} { focus $w }
	set text [expr {[winfo class $w] eq "Text"}]
	set idx [expr {$text ? [$w index @$x,$y] : [$w index @$x]}]
	set inside 0
	if {$text} {
		foreach {from to} [$w tag ranges sel] {
			if {[$w compare $idx >= $from] && [$w compare $idx < $to]} { set inside 1 ; break }
		}
	} elseif {[ctx_has_sel $w]} {
		set inside [expr {$idx >= [$w index sel.first] && $idx < [$w index sel.last]}]
	}
	if {$inside} return
	if {$text} { $w tag remove sel 1.0 end } else { $w selection clear }
	if {$editable} {
		if {$text} { $w mark set insert $idx } else { $w icursor $idx }
	}
}

# Post a fresh menu at the pointer (the D44 idiom: rebuilt every time, so the greys
# are current by construction).
proc ctx_menu_post {w x y X Y kind} {
	ctx_click $w $x $y [expr {$kind eq "input"}]
	catch {destroy .ctxmenu}
	menu .ctxmenu -tearoff 0
	${kind}_menu_build .ctxmenu $w
	tk_popup .ctxmenu $X $Y
}

# The keyboard route (Menu, Shift+F10). Nothing about the selection changes. An
# editable widget posts at its caret, like the editor does; a read-only view has no
# visible caret, so it posts at the start of the selection — the thing the menu is
# about — and falls back to its own top-left corner when there is none.
proc ctx_menu_key {w kind} {
	set X [winfo rootx $w] ; set Y [winfo rooty $w]
	set at [expr {$kind eq "input" ? "insert" : ""}]
	if {$at eq "" && [ctx_has_sel $w]} {
		set at [expr {[winfo class $w] eq "Text" ? "sel.first" : "insert"}]
	}
	if {$at ne "" && ![catch {$w bbox $at} bb] && [llength $bb] >= 4} {
		lassign $bb bx by bw bh
		set X [expr {$X + $bx}] ; set Y [expr {$Y + $by + $bh}]
	}
	catch {destroy .ctxmenu}
	menu .ctxmenu -tearoff 0
	${kind}_menu_build .ctxmenu $w
	tk_popup .ctxmenu $X $Y
}

# Give a widget its menu. Called at the creation site. `break` so the widget binding
# wins over anything the class or an editing mode puts on the right button, the same
# precedence the editor's own binding takes (D38).
proc ctx_bind_view  {w} { ctx_bind $w view }
proc ctx_bind_input {w} { ctx_bind $w input }
proc ctx_bind {w kind} {
	bind $w <<ContextMenu>> [list ctx_menu_post %W %x %y %X %Y $kind]\;break
	bind $w <Shift-F10>  [list ctx_menu_key %W $kind]\;break
	bind $w <Key-Menu>   [list ctx_menu_key %W $kind]\;break
}

# A placeholder label sits PLACED ON TOP of its entry (the git commit bar's two), so
# a right-click on an empty field hits the label and never reaches the widget below.
# Forward it, the same way the label already forwards Button-1.
proc ctx_bind_placeholder {lbl target kind} {
	bind $lbl <<ContextMenu>> [list ctx_menu_post $target %x %y %X %Y $kind]\;break
}

# ---------------------------------------------------------------------------
# The editor's context menu (D108), and the table it shares with the
# Edit menu.
#
# D38's rule — one implementation behind the menu and the mode keys, so they
# cannot drift — applied one level up, to the two MENUS. `editor_menu_items`
# is the whole of the Edit menu's action block; the menubar builds from it and
# so does the right-click menu, which then appends the find group of its own.
#
# Each row is {label command accel state}. No accelerators on the clipboard
# three: those keys belong to the editing mode (Ctrl+X/C/V in the Windows mode;
# emacs and vi have their own ideas), so a fixed label here could lie — the same
# reason the Edit menu has shown none since D38.
#
# The greys are only the ones rio can compute HONESTLY:
#   • Undo/Redo stay enabled — the history lives in the core and there is no
#     "can undo" query to ask (ops-undo.tcl registers edit.undo/edit.redo and
#     nothing else). A grey we cannot compute would be a guess.
#   • Paste stays enabled — probing the clipboard means a blocking X round-trip
#     to whichever application owns the selection, and an unresponsive owner
#     would stall the menu on its way up. An empty clipboard already does
#     nothing, silently, in editor_paste.
#
# `w` decides the GREYS only. Every command is late-bound — editor_cut and its
# neighbours resolve [gget $::focus path] when they are invoked — so both menus act
# on the focused group, and the right-click's own job is to make the group you
# clicked the focused one before the menu is built (editor_context_click).
# ---------------------------------------------------------------------------
proc editor_menu_items {w} {
	set sel  [expr {[llength [$w tag ranges sel]] ? "normal" : "disabled"}]
	set some [expr {[$w compare "end -1c" > 1.0] ? "normal" : "disabled"}]
	return [list \
		[list "Undo"       do_undo             [key_accel undo] normal] \
		[list "Redo"       do_redo             [key_accel redo] normal] \
		[list "-"          {}                  {}               {}] \
		[list "Cut"        editor_cut          {}               $sel] \
		[list "Copy"       editor_copy         {}               $sel] \
		[list "Paste"      editor_paste        {}               normal] \
		[list "-"          {}                  {}               {}] \
		[list "Select All" editor_select_all   {}               $some]]
}

# Append the rows to a menu (a separator for the "-" rows).
proc editor_menu_fill {m items} {
	foreach it $items {
		lassign $it label cmd accel state
		if {$label eq "-"} { $m add separator ; continue }
		$m add command -label $label -command $cmd -accelerator $accel -state $state
	}
}

# Re-derive the Edit menu's greys for the focused group each time it is posted.
# Only -state: the labels and accelerators stay as built, so keymap_refresh_menus
# keeps addressing them by label.
proc editor_menu_post {} {
	if {$::focus eq "" || ![dict exists $::grp $::focus]} return
	foreach it [editor_menu_items [gget $::focus path]] {
		lassign $it label cmd accel state
		if {$label eq "-"} continue
		catch {.m.edit entryconfigure $label -state $state}
	}
}

# What a right-click does BEFORE the menu appears (the Win98/VSCode convention):
# click inside the selection and it survives untouched, so Cut/Copy/Search act on
# what you can see is highlighted; click anywhere else and the selection is
# cleared and the caret moves to the character you pointed at, so Paste lands
# there. Tk moves keyboard focus on Button-1 only, and Undo/Find/Search all act on
# the FOCUSED group (::focus / ::cur) — so a right-click in the other half of a
# split has to focus it first, or the menu would quietly act on the other pane.
proc editor_context_click {g x y} {
	set w [gget $g path]
	focus_group $g
	focus $w
	set idx [$w index @$x,$y]
	set inside 0
	foreach {from to} [$w tag ranges sel] {
		if {[$w compare $idx >= $from] && [$w compare $idx < $to]} { set inside 1 ; break }
	}
	if {!$inside} {
		$w tag remove sel 1.0 end
		$w mark set insert $idx
	}
	cursor_moved $g
}

# Fill menu `m` for group `g`: the shared Edit block, then the find group.
#
# The find items are the context menu's own (D75 lifted them out of Edit into
# their own top-level menu) because they are the ones that act on the selection
# you just right-clicked: find_open and search_open ALREADY seed their entry from
# the focused group's selection, single-line only. The Search label says so —
# with a usable selection it quotes it; with none, or one spanning lines (the two
# cases search_open will not seed from), it is the plain "Search…" the Find menu
# carries. Rebuilt on every popup, so the quoted text and every accelerator are
# current by construction.
proc editor_context_build {m g} {
	set w [gget $g path]
	editor_menu_fill $m [editor_menu_items $w]
	$m add separator
	$m add command -label "Find…"    -accelerator [key_accel find]    -command {find_open 0}
	$m add command -label "Replace…" -accelerator [key_accel replace] -command {find_open 1}
	$m add command -label [editor_search_label $w] \
		-accelerator [key_accel search] -command search_open
	# Change with Agent… (D113), last and behind its own separator. An AI entry must not
	# get in the way of people who don't use one, so it appears only while a real provider
	# is selected (Echo can't change anything) and the preference hasn't hidden it. The
	# grey is honest: it needs a selection, and a turn that isn't already under way.
	if {$::agent_selection_menu && $::agent_provider ne "echo"} {
		set ok [expr {[agent_selection_scope $g] ne "" && !$::chat_busy && $::pending_turn eq ""}]
		$m add separator
		$m add command -label "Change with Agent…" -state [expr {$ok ? "normal" : "disabled"}] \
			-command [list agent_change_dialog $g]
	}
}

# Group `g`'s selection as agent.send's scope {buffer start end} (D113), or "" when
# there is none. Indices are the widget's own — the core's line.col is the same form (D12).
proc agent_selection_scope {g} {
	set w [gget $g path]
	if {[catch {list [$w index sel.first] [$w index sel.last]} r]} { return "" }
	lassign $r a b
	if {[$w compare $a >= $b]} { return "" }
	return [dict create buffer [gcur $g] start $a end $b]
}

# "foo.tcl, lines 12–20" — where a scope is, as the dialog and the transcript say it.
# A selection ending at column 0 doesn't count that last line (the D38 block rule).
proc agent_scope_label {scope} {
	set l1 [lindex [split [dict get $scope start] .] 0]
	lassign [split [dict get $scope end] .] l2 c2
	if {$l2 > $l1 && $c2 == 0} { incr l2 -1 }
	return "[tab_name [dict get $scope buffer]], [expr {$l1 == $l2 ? "line $l1" : "lines $l1–$l2"}]"
}

# Send the instruction as a turn scoped to `scope`: the Agent pane comes into view,
# because the review bar and the transcript live there.
proc agent_change_send {text scope} {
	set text [string trim $text]
	if {$text eq ""} return
	if {![rio::layout::shown chat]} { panel_reveal chat }
	chat_send_text $text $scope "on the selection in [agent_scope_label $scope]"
}

# The small dialog behind the entry: where the selection is, what to do with it, Send.
# The scope is taken when the dialog opens, so the request is about what was selected
# when the user asked; the core checks it again before anything changes.
proc agent_change_dialog {g} {
	set scope [agent_selection_scope $g]
	if {$scope eq ""} { bell ; return }
	set w .agentchg
	destroy $w
	toplevel $w
	wm title $w "Change with Agent"
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.where -text "Selection: [agent_scope_label $scope]" -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	label $w.hint -text "Enter sends · Shift+Enter starts a new line" -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c gutter.fg]
	text $w.input -width 56 -height 5 -wrap word -undo 1 -font RioUIFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.fg] -highlightthickness 1
	ctx_bind_input $w.input   ;# (D115)
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.send   -text Send   -font RioUIFont -default active \
		-command [list agent_change_submit $w $scope]
	button $w.btns.cancel -text Cancel -font RioUIFont -command [list destroy $w]
	pack $w.btns.cancel $w.btns.send -side right -padx 3
	grid $w.where -row 0 -column 0 -sticky w  -padx 8 -pady {8 2}
	grid $w.input -row 1 -column 0 -sticky nsew -padx 8 -pady 2
	grid $w.hint  -row 2 -column 0 -sticky w  -padx 8 -pady {0 2}
	grid $w.btns  -row 3 -column 0 -sticky e  -padx 5 -pady {2 8}
	grid rowconfigure $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	bind $w.input <Return>       "[list agent_change_submit $w $scope] ; break"
	bind $w.input <Shift-Return> { %W insert insert "\n" ; break }
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.input
}
proc agent_change_submit {w scope} {
	set text [$w.input get 1.0 end]
	if {[string trim $text] eq ""} { bell ; return }
	destroy $w
	agent_change_send $text $scope
}

# The Search entry's label for the current selection (see above). 20 characters
# is the cap: long enough to recognise the needle, short enough that the menu
# keeps its shape.
proc editor_search_label {w} {
	if {[catch {$w get sel.first sel.last} s]} { return "Search…" }
	if {$s eq "" || [string first "\n" $s] >= 0} { return "Search…" }
	if {[string length $s] > 20} { set s "[string range $s 0 19]…" }
	return "Search for “$s”"
}

# Right-click: place the caret/selection, then post a fresh menu — the D44 idiom,
# with the builder split from the popup so a headless test can read the entries
# without a global grab nobody is there to dismiss.
proc editor_context_menu {g x y X Y} {
	editor_context_click $g $x $y
	catch {destroy .edmenu}
	menu .edmenu -tearoff 0
	editor_context_build .edmenu $g
	tk_popup .edmenu $X $Y
}

# The keyboard route (the Menu key, Shift+F10): the same menu at the caret. No
# click, so nothing about the selection changes. The caret's bbox is empty when it
# has been scrolled out of view — then the widget's top-left corner stands in.
proc editor_context_key {g} {
	set w [gget $g path]
	focus_group $g
	set X [winfo rootx $w] ; set Y [winfo rooty $w]
	if {[set bb [$w bbox insert]] ne ""} {
		lassign $bb bx by bw bh
		set X [expr {$X + $bx}] ; set Y [expr {$Y + $by + $bh}]
	}
	catch {destroy .edmenu}
	menu .edmenu -tearoff 0
	editor_context_build .edmenu $g
	tk_popup .edmenu $X $Y
}
