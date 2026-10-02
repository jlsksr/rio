# rio-gui/views.tcl — the compare view and the plan view.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The compare / diff view (D28; D13/D14 anticipated it). Two read-only
# panes side by side with line-level diff coloring, shown in the center INSTEAD
# of the editor while comparing (apply_layout swaps .ed <-> .cmp). A dumb view
# (D3): the line alignment comes from the core diff.lines op; this only renders
# it. Filler rows keep equal lines level across the panes (VSCode-style). The
# right/proposed side is read-only for now — an editable temp buffer and a real
# tabbed second editor group are later enrichments.
# ---------------------------------------------------------------------------
# Compare text `ltext` (left) against `rtext` (right), labelled and shown.
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

# Fill both panes in one pass over the diff ops so equal lines stay aligned: an
# equal op emits a real line on each side; a delete emits the left line (tagged
# del) opposite a blank filler row; an insert a filler opposite the right line
# (tagged add). Adjacent delete+insert runs read as a change (red beside green).
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

# Scroll both panes together: the shared scrollbar drives both (cmp_yview); each
# pane's own scroll keeps the bar and the OTHER pane in step (cmp_yscroll, guarded
# against the feedback loop). Equal row counts (fillers) make the lockstep exact.
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

# Leave the compare view, restoring the editor as the center.
proc compare_close {} {
	if {!$::compare_shown} return
	set ::compare_shown 0
	apply_layout
	focus [gget $::focus path]
}

# Open the side-by-side review for a pending agent proposal (D28): pull both full
# versions (agent.proposal) and show original | proposed. Returns 1 on success, 0
# if there is nothing to pull (the caller then falls back to the inline diff).
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

# Compare the active buffer against a file the user picks (Compare menu). The other
# side is read-only via fs.read (D28) (an absolute path is taken as-is, D11), so it
# need not be open or even inside the project.
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
# The plan view (D101). In plan mode the agent may not change anything; what
# it may do is say what it WOULD do, through the core's `present_plan` tool. The plan
# arrives as an `agent.propose` of kind `plan` carrying Markdown, and lands here — in the
# center, instead of the editor, exactly as a complex proposed edit lands in the compare
# view (D28). The two views are the same idea: a proposal too big to read in the chat
# column gets the width of the document area, while the decision stays on the chat's
# Approve/Reject bar where every other agent decision is made.
#
# It renders with the manual's renderer (help_blocks → help_paint, D100), so a plan reads
# like a page of the manual rather than like a text dump. Links inside a plan are STYLED
# BUT INERT: the renderer's click binding follows a manual topic, which is not what a path
# in a plan means — a wrong door is worse than no door.
# ---------------------------------------------------------------------------
set ::plan_shown 0   ;# plan view active? (.plan shown instead of .ed)
set ::plan_title ""
set ::plan_path  ""  ;# where the core filed this plan, project-relative ("" = nowhere)

# Show a plan, replacing the editor as the center. Mutually exclusive with the compare
# view — there is one center, and whichever proposal arrived last is the one being read.
proc plan_open {title md path} {
	set ::plan_title $title
	set ::plan_path  $path
	plan_paint $md
	plan_show
}

# Render one Markdown document into the plan pane, from the top. Read-only: the pane is a
# view of the plan, and the place to CHANGE a plan is its file (plan_edit).
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

# Put the plan back in the center after the user closed it. Repainted from the plan as it
# stands NOW, because the user may have opened and changed it in between (D102) — a view
# that still showed the model's draft would be showing a plan nobody is about to approve.
# Mutually exclusive with the compare view: there is one center, one thing being reviewed.
proc plan_reopen {} {
	if {$::plan_title eq ""} return
	set md [plan_current_text]
	if {$md ne ""} { plan_paint $md }
	plan_show
}

# Give the plan the center. Mutually exclusive with the compare view: there is one center,
# and whichever proposal arrived last is the one being read.
proc plan_show {} {
	set ::compare_shown 0
	set ::plan_shown 1
	apply_layout
}

# The plan's absolute path, or "" when it was filed nowhere (no project) or the core has
# no project to resolve it against.
proc plan_abs {} {
	if {$::plan_path eq ""} { return "" }
	set pr [rio_result project.get {}]
	if {$pr eq "" || [dict get $pr root] eq ""} { return "" }
	return [file join [dict get $pr root] $::plan_path]
}

# The filed plan as it stands: the open buffer's text when the user has it open (so an
# unsaved edit shows, matching what the core will read at approval), else the disk copy,
# else "" — the caller then keeps what is already painted.
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

# Open the filed plan as an ordinary buffer so the user can change it before approving
# (D102). The plan view and the editor both want the center, so the view steps aside; the
# turn stays pending and the bar stays up, because approving is still the next thing.
proc plan_edit {} {
	set abs [plan_abs]
	if {$abs eq ""} return
	plan_close
	do_open $abs
}

# The header line: the plan's title, and where it was filed so the reader can go back to
# it after the window is closed (a plan with no project behind it names no file).
proc plan_header {} {
	set h "Plan — $::plan_title"
	if {$::plan_path ne ""} { append h "   ·   $::plan_path" }
	return $h
}

# Leave the plan view, restoring the editor as the center.
proc plan_close {} {
	if {!$::plan_shown} return
	set ::plan_shown 0
	apply_layout
	focus [gget $::focus path]
}

# Colour the plan view from the live theme: its own chrome, then the renderer's tags.
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

# Compare the active buffer against another open buffer `id` — both sides are live
# buffer text (buffer.text), so unsaved edits on either tab are what you see (D74).
# Split from the picker so the compare itself is testable without opening the dialog.
proc compare_with_tab {id} {
	compare_open [buf_text $::cur] [buf_text $id] \
		"[tab_name $::cur] (current)" "[tab_name $id]"
}
proc compare_with_tab_dialog {} {
	set id [buffer_pick_dialog "Compare with another tab" $::cur]
	if {$id ne ""} { compare_with_tab $id }
}
