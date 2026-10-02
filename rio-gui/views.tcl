# rio-gui/views.tcl — the compare view and the plan view.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The compare view (D28): two read-only panes, shown in place of the
# editor. The core aligns the lines (diff.lines); this renders them.
#
#     a           |    a
#   - old line    |                 delete: filler on the right
#                 |  + new line     insert: filler on the left
#     b           |    b
# ---------------------------------------------------------------------------
# Compare `ltext` (left) with `rtext` (right), under the two labels.
proc compare_open {ltext rtext llabel rlabel} {
	.cmp.l.hdr configure -text $llabel
	.cmp.r.hdr configure -text $rlabel
	set resp [rio_call diff.lines [dict create a $ltext b $rtext]]
	set ops [expr {[dict get $resp ok] ? [dict get $resp result ops] : {}}]
	cmp_fill $ops [split $ltext "\n"] [split $rtext "\n"]
	cmp_apply_wrap
	set ::compare_shown 1
	apply_layout
	.cmp.l.t yview moveto 0
	.cmp.r.t yview moveto 0
}

# Fill both panes from the diff ops. Every op adds one row to each pane,
# so equal lines stay level.
proc cmp_fill {ops La Lb} {
	foreach t {.cmp.l.t .cmp.r.t} { $t configure -state normal ; $t delete 1.0 end }
	foreach o $ops {
		set a [dict get $o a] ; set b [dict get $o b]
		switch -- [dict get $o tag] {
			equal  { cmp_put .cmp.l.t "  " [lindex $La [expr {$a-1}]] "" ; cmp_put .cmp.r.t "  " [lindex $Lb [expr {$b-1}]] "" }
			delete { cmp_put .cmp.l.t "- " [lindex $La [expr {$a-1}]] del ; cmp_put .cmp.r.t "  " "" filler }
			insert { cmp_put .cmp.l.t "  " "" filler ; cmp_put .cmp.r.t "+ " [lindex $Lb [expr {$b-1}]] add }
		}
	}
	foreach t {.cmp.l.t .cmp.r.t} { $t configure -state disabled }
}
proc cmp_put {t marker text tag} {
	if {$tag eq ""} { $t insert end "$marker$text\n" } else { $t insert end "$marker$text\n" $tag }
}

# Scroll both panes together. The scrollbar drives both (cmp_yview); a
# pane's own scroll moves the bar and the other pane (cmp_yscroll).
# ::cmp_syncing stops the feedback loop.
proc cmp_yview {args} {
	.cmp.l.t yview {*}$args
	.cmp.r.t yview {*}$args
}
proc cmp_yscroll {which lo hi} {
	.cmp.sb set $lo $hi
	if {$::cmp_syncing} return
	set ::cmp_syncing 1
	[expr {$which eq "l" ? {.cmp.r.t} : {.cmp.l.t}}] yview moveto $lo
	set ::cmp_syncing 0
}

# Leave the compare view: the editor is back.
proc compare_close {} {
	if {!$::compare_shown} return
	set ::compare_shown 0
	apply_layout
	focus [gget $::focus path]
}

# Compare a pending agent proposal: original | proposed (D28). Returns 0
# if there is none; the caller then shows the inline diff.
proc compare_proposal {turn} {
	if {$turn eq ""} { return 0 }
	set resp [rio_call agent.proposal [dict create turn $turn]]
	if {![dict get $resp ok]} { return 0 }
	set r [dict get $resp result]
	set path [dict get $r path]
	compare_open [dict get $r original] [dict get $r proposed] \
		"$path (original)" "$path (proposed)"
	return 1
}

# Compare the active buffer with a file the user picks. The file is read
# with fs.read: it need not be open, nor inside the project.
proc compare_with_file_dialog {} {
	if {$::core_remote} {
		set path [remote_browse_dialog "Compare with file (remote)" open]
	} else {
		set path [tk_getOpenFile -title "Compare active buffer with file"]
	}
	if {$path eq ""} return
	set resp [rio_call fs.read [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	compare_open [buf_text $::cur] [dict get $resp result text] \
		"[tab_name $::cur] (buffer)" "[file tail $path] (file)"
}

# ---------------------------------------------------------------------------
# The plan view (D101). In plan mode the agent changes nothing; it presents
# a plan (`present_plan`), which arrives as an agent.propose of kind `plan`
# with Markdown. It is shown in place of the editor, like the compare view;
# the decision stays on the chat's Approve/Reject bar. Rendered by the
# manual's renderer (D100); links are styled but do nothing.
# ---------------------------------------------------------------------------
set ::plan_shown 0   ;# plan view active? (.plan shown instead of .ed)
set ::plan_title ""
set ::plan_path  ""  ;# where the core filed this plan, project-relative ("" = nowhere)

# Show a plan in place of the editor.
proc plan_open {title md path} {
	set ::plan_title $title
	set ::plan_path  $path
	plan_paint $md
	plan_show
}

# Render Markdown into the plan pane. Read-only; plan_edit changes a plan.
proc plan_paint {md} {
	.plan.hdr configure -text [plan_header]
	set t .plan.text
	$t configure -state normal
	$t delete 1.0 end
	help_paint $t [help_blocks $md]
	$t configure -state disabled
	$t yview moveto 0
	plan_restyle
}

# Show the plan again after it was closed, repainted from its current
# text: the user may have edited it (D102).
proc plan_reopen {} {
	if {$::plan_title eq ""} return
	set md [plan_current_text]
	if {$md ne ""} { plan_paint $md }
	plan_show
}

# Give the plan the center. It closes the compare view: there is one center.
proc plan_show {} {
	set ::compare_shown 0
	set ::plan_shown 1
	apply_layout
}

# The plan's absolute path, or "" without a filed plan or a project.
proc plan_abs {} {
	if {$::plan_path eq ""} { return "" }
	set pr [rio_result project.get {}]
	if {$pr eq "" || [dict get $pr root] eq ""} { return "" }
	return [file join [dict get $pr root] $::plan_path]
}

# The plan's current text: the open buffer's, unsaved edits included, as
# the core reads it at approval; else the file's; else "".
proc plan_current_text {} {
	set abs [plan_abs]
	if {$abs eq ""} { return "" }
	foreach id [dict keys $::buffers] {
		if {[bufget $id path] eq $abs} { return [buf_text $id] }
	}
	set r [rio_result fs.read [dict create path $::plan_path]]
	if {$r eq ""} { return "" }
	return [dict get $r text]
}

# Open the plan's file as a buffer, to change it before approving (D102).
# The view closes; the turn stays pending.
proc plan_edit {} {
	set abs [plan_abs]
	if {$abs eq ""} return
	plan_close
	do_open $abs
}

# The header: "Plan — <title>   ·   <path>"; the path only if filed.
proc plan_header {} {
	set h "Plan — $::plan_title"
	if {$::plan_path ne ""} { append h "   ·   $::plan_path" }
	return $h
}

# Leave the plan view: the editor is back.
proc plan_close {} {
	if {!$::plan_shown} return
	set ::plan_shown 0
	apply_layout
	focus [gget $::focus path]
}

# Colour the plan view from the theme.
proc plan_restyle {} {
	if {![winfo exists .plan]} return
	set c $::theme_colors
	.plan configure -background [dict get $c ui.bg]
	.plan.bar configure -background [dict get $c ui.bg]
	.plan.bar.close configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.plan.hdr configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.plan.sb configure -background [dict get $c ui.bg]
	help_style .plan.text
}

# Compare the active buffer with buffer `id`: live text on both sides,
# unsaved edits included (D74).
proc compare_with_tab {id} {
	compare_open [buf_text $::cur] [buf_text $id] \
		"[tab_name $::cur] (current)" "[tab_name $id]"
}
proc compare_with_tab_dialog {} {
	set id [buffer_pick_dialog "Compare with another tab" $::cur]
	if {$id ne ""} { compare_with_tab $id }
}
