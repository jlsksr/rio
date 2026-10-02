# rio-gui/menus.tcl — context menus: inputs, read-only views, the editor.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# Context menus for the widgets outside the editor (D115).
#
#   view   read-only (agent log, compare, git diff, manual)   Copy, Select All
#   input  entries and text fields                            Cut, Copy, Paste, Select All
#
# - The commands are Tk's virtual events, <<Cut>> <<Copy>> <<Paste>>
#   <<SelectAll>>: the same ones the keys send, so menu and key cannot differ.
# - A widget gets its menu where it is created: ctx_bind_view, ctx_bind_input.
# - Builder and popup are separate procs (D44), so a headless test can read
#   the entries without a grab.
# - Not for the rl_* row lists (Files, Git, Search results, the manual's
#   contents): they have row menus or none.
# ---------------------------------------------------------------------------

# "Is anything selected?" and "is there any text?", for Entry and Text alike.
proc ctx_has_sel {w} {
	if {[winfo class $w] eq "Text"} { return [expr {[llength [$w tag ranges sel]] > 0}] }
	return [expr {![catch {$w selection present} p] && $p}]
}
proc ctx_has_text {w} {
	if {[winfo class $w] eq "Text"} { return [$w compare "end -1c" > 1.0] }
	return [expr {[string length [$w get]] > 0}]
}

# A read-only view's menu. No Cut, no Paste: the widget would refuse them.
proc view_menu_build {m w} {
	set sel  [expr {[ctx_has_sel $w]  ? "normal" : "disabled"}]
	set some [expr {[ctx_has_text $w] ? "normal" : "disabled"}]
	$m add command -label "Copy"       -state $sel  -command [list event generate $w <<Copy>>]
	$m add command -label "Select All" -state $some -command [list event generate $w <<SelectAll>>]
}

# An editable widget's menu. Cut and Copy need a selection, Select All needs
# text. Paste is always enabled: probing the clipboard blocks on whichever
# application owns it (D108).
#
# A masked field (the API key, -show •) offers only Paste and Select All: a
# key is a secret (D26).
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

# What a right-click does before the menu appears (D108): a click inside the
# selection keeps it; a click outside clears it. In an editable widget the
# caret moves there too, so Paste lands where you pointed.
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

# Post a fresh menu at the pointer. Rebuilt each time, so the greys are current.
proc ctx_menu_post {w x y X Y kind} {
	ctx_click $w $x $y [expr {$kind eq "input"}]
	catch {destroy .ctxmenu}
	menu .ctxmenu -tearoff 0
	${kind}_menu_build .ctxmenu $w
	tk_popup .ctxmenu $X $Y
}

# By keyboard (Menu, Shift+F10): the selection stays. An editable widget
# posts at its caret; a read-only view at the start of its selection, or at
# its top-left corner.
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

# Give a widget its menu. `break`, so this binding wins over the class's and
# an editing mode's (D38).
proc ctx_bind_view  {w} { ctx_bind $w view }
proc ctx_bind_input {w} { ctx_bind $w input }
proc ctx_bind {w kind} {
	bind $w <<ContextMenu>> [list ctx_menu_post %W %x %y %X %Y $kind]\;break
	bind $w <Shift-F10>  [list ctx_menu_key %W $kind]\;break
	bind $w <Key-Menu>   [list ctx_menu_key %W $kind]\;break
}

# A placeholder label lies on top of its entry (the git commit bar), so a
# right-click on an empty field hits the label. Forward it.
proc ctx_bind_placeholder {lbl target kind} {
	bind $lbl <<ContextMenu>> [list ctx_menu_post $target %x %y %X %Y $kind]\;break
}

# ---------------------------------------------------------------------------
# The editor's context menu (D108), and the table it shares with the Edit
# menu. `editor_menu_items` is the Edit menu's action block; the menubar and
# the right-click menu both build from it.
#
# A row is {label command accel state}.
# - Cut, Copy and Paste show no accelerator: those keys belong to the editing
#   mode (D38).
# - Undo and Redo are always enabled: the history is in the core, and there
#   is no "can undo" query.
# - Paste is always enabled: probing the clipboard can block.
# - `w` decides the greys only. Every command acts on the focused group, so
#   a right-click focuses its group first (editor_context_click).
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

# Set the Edit menu's greys for the focused group, each time it is posted.
proc editor_menu_post {} {
	if {$::focus eq "" || ![dict exists $::grp $::focus]} return
	foreach it [editor_menu_items [gget $::focus path]] {
		lassign $it label cmd accel state
		if {$label eq "-"} continue
		catch {.m.edit entryconfigure $label -state $state}
	}
}

# What a right-click does before the menu appears (as Win98 and VSCode do): a
# click inside the selection keeps it; a click elsewhere clears it and moves
# the caret there. The group is focused first: Tk moves focus on Button-1
# only, and the menu acts on the focused group.
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
# Find, Replace and Search take their needle from the selection, if it is on
# one line. The Search label quotes it: Search for “foo”.
proc editor_context_build {m g} {
	set w [gget $g path]
	editor_menu_fill $m [editor_menu_items $w]
	$m add separator
	$m add command -label "Find…"    -accelerator [key_accel find]    -command {find_open 0}
	$m add command -label "Replace…" -accelerator [key_accel replace] -command {find_open 1}
	$m add command -label [editor_search_label $w] \
		-accelerator [key_accel search] -command search_open
	# Change with Agent… (D113), last. Shown only with a real provider and
	# unless the preference hides it. It needs a selection and no turn running.
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

# The Search entry's label for the selection, capped at 20 characters.
proc editor_search_label {w} {
	if {[catch {$w get sel.first sel.last} s]} { return "Search…" }
	if {$s eq "" || [string first "\n" $s] >= 0} { return "Search…" }
	if {[string length $s] > 20} { set s "[string range $s 0 19]…" }
	return "Search for “$s”"
}

# Right-click: settle caret and selection, then post a fresh menu.
proc editor_context_menu {g x y X Y} {
	editor_context_click $g $x $y
	catch {destroy .edmenu}
	menu .edmenu -tearoff 0
	editor_context_build .edmenu $g
	tk_popup .edmenu $X $Y
}

# By keyboard (Menu, Shift+F10): the same menu at the caret, or at the
# widget's top-left corner when the caret is scrolled out of view.
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
