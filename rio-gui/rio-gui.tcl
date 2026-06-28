#!/usr/bin/env wish
#
# rio-gui — the Tk frontend (AGENTS.md D1). A *thin view* (D3): it never edits
# its own text widget. Keystrokes become buffer.replace requests; the widget only
# changes when the core echoes a buffer.changed event back. Open/save go through
# the fs.* ops, undo/redo through edit.*, and buffers (tabs) through buffer.new /
# buffer.close. The core is embedded IN-PROCESS (D2's default transport):
# rio::core::call runs a request and returns the response plus any events
# synchronously — so there is no round-trip lag, and the only way text appears on
# screen is the core's own change event.
#
# Multi-buffer: the core owns the buffers (D3); the frontend keeps the per-buffer
# *view* state — tab order, which one is active, and each buffer's cursor/viewport
# (frontend-local per D22). One text widget shows the active buffer; switching
# tabs swaps its contents and restores that buffer's cursor.
#
# The view stays dumb robustly by RENAMING the real text-widget command and
# proxying it: Tk's class bindings still call `.t insert`/`.t delete`, the proxy
# turns those into protocol requests and suppresses the local edit. The character
# arrives as a proper Tcl argument, so every key — brackets, quotes, backslashes,
# braces — is handled identically, and paste/cut come along for free.
#
# Run:  wish rio-gui.tcl [file ...]

package require Tk
package require json

# Embed the core (Tk-free; we are the only Tk in this process).
source [file join [file dirname [info script]] .. rio-core core.tcl]

# Load the Claude provider plugin (D26): the shared inference core + the claude-api
# face. Sourcing only DEFINES the provider; the frontend selects/activates it
# (apply_provider) and owns the key-entry UI — the face just owns the key's store.
source [file join [file dirname [info script]] .. plugins claude claude.tcl]

# Per-buffer view state. The core holds the text; we hold the rest.
set ::buffers {} ;# id -> {path <s> meta <dict> modified <0|1> cursor <idx> yview <frac>}
set ::order   {} ;# buffer ids, in tab order
set ::cur     "" ;# active buffer id

# The side dock hosts ONE of the panes at a time (files | git) and sits on one
# side of the editor (left | right). Both are user choices (View menu), not
# dictated; left + files is the default.
set ::dock_side left   ;# left | right — which edge the dock occupies
set ::dock_pane files  ;# files | git  — which pane is currently shown
set ::wrap_lines 0     ;# 0 = no wrap (horizontal scrollbar) | 1 = word wrap
set ::chat_shown 1     ;# agent chat pane visible? (View menu / Ctrl+Shift+A)
set ::chat_turn_open 0 ;# mid-stream: an assistant block is open, deltas appending
set ::pending_turn ""  ;# turn id of a proposed edit awaiting Approve/Reject (D26 s5)
set ::agent_auto_accept 0 ;# skip the approval gate for proposed edits (Settings)

proc bufget {id key} { dict get $::buffers $id $key }
proc bufset {id key val} { dict set ::buffers $id $key $val }

# ---------------------------------------------------------------------------
# Core calls: run the op, apply any buffer.changed events to the widget, and
# hand the response back. This is the single seam to the core.
# ---------------------------------------------------------------------------
proc rio_call {op params} {
	set r [rio::core::call $op $params]
	foreach ev [dict get $r events] {
		switch -- [dict get $ev event] {
			buffer.changed  { apply_change [dict get $ev params] }
			project.opened  { on_project_opened [dict get $ev params] }
		}
	}
	return [dict get $r response]
}

# Surface a core error to the user (the {code, message} taxonomy, AGENTS.md O2).
# One seam, so every failed op shows a dialog instead of crashing a caller that
# assumed success — and the headless smoke can override it to capture errors
# without a modal blocking the run.
proc report_error {message {code ""}} {
	tk_messageBox -icon error -type ok -title rio \
		-message [expr {$code eq "" ? $message : "$message  ($code)"}]
}

# Run an op that is expected to succeed and return its result, or "" after
# surfacing the error. For the internal "can't fail in normal use" calls (new,
# undo/redo): a vanished buffer or a bug becomes a dialog, not a missing-`result`
# crash. do_open/do_save inspect `ok` themselves — they have real recovery. (None
# of these ops returns an empty result on success, so "" is an unambiguous fail.)
proc rio_result {op params} {
	set resp [rio_call $op $params]
	if {[dict get $resp ok]} { return [dict get $resp result] }
	set e [dict get $resp error]
	report_error [dict get $e message] [dict get $e code]
	return ""
}

# Apply a change through the REAL widget command (bypassing the proxy). .t
# replace takes line.col indices directly — the payoff of D12 sharing the Tk
# text-widget index format: the view layer is nearly free.
proc apply_change {p} {
	::rio_real_t replace [dict get $p start] [dict get $p end] [dict get $p text]
	::rio_real_t see insert
}

# Load the active buffer's canonical text into the widget (on switch / open).
proc load_buffer {} {
	set resp [rio_call buffer.text [dict create buffer $::cur]]
	::rio_real_t delete 1.0 end
	if {[dict get $resp ok]} {
		::rio_real_t insert 1.0 [dict get $resp result text]
	} else {
		set e [dict get $resp error]
		report_error [dict get $e message] [dict get $e code]
	}
}

# ---------------------------------------------------------------------------
# Buffer / tab bookkeeping.
# ---------------------------------------------------------------------------
proc register_buffer {id path meta} {
	dict set ::buffers $id \
		[dict create path $path meta $meta modified 0 cursor 1.0 yview 0.0]
	lappend ::order $id
}

# Make `id` the active buffer: stash the outgoing buffer's cursor/viewport, swap
# the widget to `id`, and restore its cursor/viewport.
proc activate {id} {
	if {$::cur ne "" && [dict exists $::buffers $::cur]} {
		bufset $::cur cursor [::rio_real_t index insert]
		bufset $::cur yview  [lindex [::rio_real_t yview] 0]
	}
	set ::cur $id
	load_buffer
	catch {::rio_real_t mark set insert [bufget $id cursor]}
	catch {::rio_real_t yview moveto    [bufget $id yview]}
	::rio_real_t see insert
	focus .ed.t
	refresh_all
}

proc close_buffer {id} {
	rio_call buffer.close [dict create buffer $id]
	set ::buffers [dict remove $::buffers $id]
	set ::order [lsearch -all -inline -not -exact $::order $id]
}

# Drop a leftover empty, unsaved, untitled scratch buffer (so opening a file from
# a fresh launch reuses the slot instead of leaving a blank tab behind). Refresh
# the chrome if we dropped anything: close_buffer mutates ::order but doesn't
# redraw, so a pruned tab would otherwise linger on screen, orphaned.
proc prune_scratch {keep} {
	set pruned 0
	foreach id $::order {
		if {$id eq $keep} continue
		if {[bufget $id path] eq "" && ![bufget $id modified] && [rio::doc::text $id] eq ""} {
			close_buffer $id
			set pruned 1
		}
	}
	if {$pruned} refresh_all
}

# ---------------------------------------------------------------------------
# Actions. The do_* procs take explicit arguments (no dialogs) so they are
# scriptable and testable; the *_dialog wrappers add the file choosers.
# ---------------------------------------------------------------------------
proc do_new {} {
	set res [rio_result buffer.new {}]
	if {$res eq ""} return
	set id [dict get $res buffer]
	register_buffer $id "" {}
	activate $id
}

proc do_open {path} {
	# Already open? Just switch to its tab.
	foreach id $::order {
		if {$path ne "" && [bufget $id path] eq $path} { activate $id ; return 1 }
	}
	set resp [rio_call file.open [dict create path $path]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not open $path:\n[dict get $resp error message]"
		return 0
	}
	set res [dict get $resp result]
	set id  [dict get $res buffer]
	register_buffer $id $path \
		[dict create encoding [dict get $res encoding] eol [dict get $res eol]]
	activate $id
	prune_scratch $id
	if {[dict get $res mixed]} {
		tk_messageBox -icon info -type ok -title rio \
			-message "Mixed line endings; the file will be saved as [dict get $res eol]."
	}
	return 1
}

# ---------------------------------------------------------------------------
# The file pane (AGENTS.md: the file-tree pane; D9 a later reflow concern). A
# lazy directory navigator over the core's project root: it lists ONE directory
# per fs.list call and descends on demand, rather than the core walking a whole
# repo. The core owns "which folder is open" (project.*); this pane is a dumb
# view of it — opening a folder goes through project.open and the pane repaints
# from the project.opened event (D3), the same event-driven path as buffer edits.
# ::nav_dir is the directory currently shown (absolute); ::nav_rows is a parallel
# list mapping each listbox row to {type abspath} so a click knows what it hit.
# ---------------------------------------------------------------------------
proc open_folder {path} {
	set resp [rio_call project.open [dict create path $path]]
	if {![dict get $resp ok]} {
		report_error "Could not open folder $path:\n[dict get $resp error message]" \
			[dict get $resp error code]
		return 0
	}
	return 1   ;# the pane repaints via the project.opened event (on_project_opened)
}

proc on_project_opened {p} {
	set ::nav_dir [dict get $p root]
	# Refresh the visible pane now; the other refreshes when next shown.
	if {$::dock_pane eq "git"} { refresh_git } else { populate_nav }
}

# Repaint the pane with the entries of ::nav_dir: a ".." row (unless at the root),
# then directories, then files — each group dictionary-sorted by the core already.
proc populate_nav {} {
	.dock.files.list delete 0 end
	set ::nav_rows {}
	if {$::nav_dir eq ""} {
		.dock.files.head configure -text "(no folder)"
		.dock.files.list insert end "  Open a folder…"
		lappend ::nav_rows [list none ""]
		return
	}
	set root [dict get [rio_call project.get {}] result root]
	.dock.files.head configure -text [nav_header $::nav_dir $root]
	if {$::nav_dir ne $root} {
		.dock.files.list insert end "../"
		lappend ::nav_rows [list dir [file dirname $::nav_dir]]
	}
	set resp [rio_call fs.list [dict create path $::nav_dir]]
	if {![dict get $resp ok]} {
		report_error [dict get $resp error message] [dict get $resp error code]
		return
	}
	set entries [dict get $resp result entries]
	foreach grp {dir file} {
		foreach e $entries {
			if {[dict get $e type] ne $grp} continue
			set name [dict get $e name]
			.dock.files.list insert end [expr {$grp eq "dir" ? "$name/" : "  $name"}]
			lappend ::nav_rows [list $grp [file join $::nav_dir $name]]
		}
	}
}

# Header: the project name, plus the path from the root when in a subdirectory.
proc nav_header {dir root} {
	if {$dir eq $root} { return [file tail $root] }
	return "[file tail $root]/[string range $dir [expr {[string length $root] + 1}] end]"
}

# Double-click / Enter on a row: descend into a directory, or open a file in a tab.
proc nav_activate {} {
	set sel [.dock.files.list curselection]
	if {$sel eq ""} return
	lassign [lindex $::nav_rows $sel] type path
	switch -- $type {
		dir  { set ::nav_dir $path ; populate_nav }
		file { do_open $path }
	}
}

proc open_folder_dialog {} {
	set p [tk_chooseDirectory -title "Open folder"]
	if {$p ne ""} { open_folder $p }
}

# ---------------------------------------------------------------------------
# The git pane (AGENTS.md D7 read layer in a view). Shares the dock with the
# file pane — only one shows at a time. A dumb view of the core's git.* against
# the open project (git.* now defaults its cwd to the project root): git.status
# fills the branch + changed-file list, selecting a file fetches git.diff into a
# read-only diff area. No file-watching, so a Refresh button re-reads on demand.
# ::git_rows maps each list row to its change dict {path x y}.
# ---------------------------------------------------------------------------
# The diff area is collapsible (D13): hidden until a file is picked, so the
# default git pane is just a full-height change list — consistent with the file
# pane — and the diff slides in below (sharing the height) only when there is one
# to read, instead of sitting empty and looking like dead space.
proc git_show_diff {text} {
	.dock.git.diff configure -state normal
	.dock.git.diff delete 1.0 end
	.dock.git.diff insert 1.0 $text
	.dock.git.diff configure -state disabled
	if {[lsearch -exact [pack slaves .dock.git] .dock.git.diff] < 0} {
		pack .dock.git.diff -side top -fill both -expand 1
	}
}
proc git_hide_diff {} {
	.dock.git.diff configure -state normal
	.dock.git.diff delete 1.0 end
	.dock.git.diff configure -state disabled
	pack forget .dock.git.diff
}

proc refresh_git {} {
	.dock.git.list delete 0 end
	set ::git_rows {}
	git_hide_diff
	# With no folder open, git.* would fall back to rio's OWN process cwd and show
	# the wrong repo — so the pane is honest about needing a project first.
	if {[dict get [rio_call project.get {}] result root] eq ""} {
		.dock.git.hdr.branch configure -text "git"
		.dock.git.list insert end "  (open a folder)"
		lappend ::git_rows ""
		return
	}
	set resp [rio_call git.status {}]
	if {![dict get $resp ok]} {
		.dock.git.hdr.branch configure -text "git"
		set code [dict get $resp error code]
		.dock.git.list insert end \
			[expr {$code eq "bad_request" ? "  (not a git repository)" \
				: "  [dict get $resp error message]"}]
		lappend ::git_rows ""
		return
	}
	set r [dict get $resp result]
	.dock.git.hdr.branch configure -text "⎇ [dict get $r branch]"
	set changes [dict get $r changes]
	if {![llength $changes]} {
		.dock.git.list insert end "  (clean)"
		lappend ::git_rows ""
		return
	}
	foreach c $changes {
		.dock.git.list insert end \
			[format "%s%s %s" [dict get $c x] [dict get $c y] [dict get $c path]]
		lappend ::git_rows $c
	}
}

# Selecting a changed file shows its diff. A path staged but not also modified in
# the worktree (X set, Y blank) is shown via --cached; otherwise the worktree
# diff. An untracked file has no textual diff — git returns empty, said plainly.
proc git_select {} {
	set sel [.dock.git.list curselection]
	if {$sel eq ""} return
	set row [lindex $::git_rows $sel]
	if {$row eq ""} { git_hide_diff ; return }
	set x [dict get $row x] ; set y [dict get $row y]
	set staged [expr {$y eq " " && $x ne " " && $x ne "?"}]
	set resp [rio_call git.diff [dict create path [dict get $row path] staged $staged]]
	if {![dict get $resp ok]} {
		git_show_diff [dict get $resp error message]
		return
	}
	set d [dict get $resp result diff]
	git_show_diff [expr {$d eq "" ? "(no textual diff)" : $d}]
}

# An auto-hiding scrollbar: visible only when the view can't show everything.
# Wired as a widget's -yscrollcommand (Tk appends the lo/hi fractions). It re-packs
# with -before the scrolled widget so it reclaims its edge instead of being
# squeezed to zero width by that widget's -expand. Keeps the dock uncluttered
# when a short file list or change list fits — the common case.
proc autoscroll {sb widget lo hi} {
	if {$lo <= 0.0 && $hi >= 1.0} {
		pack forget $sb
	} else {
		pack $sb -side right -fill y -before $widget
	}
	$sb set $lo $hi
}

# Same idea for a grid-managed scrollbar (the editor's horizontal bar). grid remove
# keeps the cell config, so re-`grid`ing restores its row/col. Wired as the editor's
# -xscrollcommand so the bar shows only when a line runs past the right edge.
proc gridscroll {sb lo hi} {
	if {$lo <= 0.0 && $hi >= 1.0} { grid remove $sb } else { grid $sb }
	$sb set $lo $hi
}

# ---------------------------------------------------------------------------
# The dock: which pane shows, and which edge it sits on. Both are runtime choices
# driven from the View menu; place_dock and show_pane are the two seams.
# ---------------------------------------------------------------------------
# Show one pane (files | git) in the dock, hiding the other, and refresh it.
proc show_pane {which} {
	set ::dock_pane $which
	pack forget .dock.files .dock.git
	if {$which eq "git"} {
		pack .dock.git -side top -fill both -expand 1
		refresh_git
	} else {
		pack .dock.files -side top -fill both -expand 1
		populate_nav
	}
	style_selector
}

# Re-pack the dock against ::dock_side, with the editor filling the rest. Packing
# the dock first claims its edge; .t then expands into what's left, so the same
# two calls work for either side.
proc place_dock {} {
	catch {pack forget .dock .sash .chat .csash .ed}
	pack .dock -side $::dock_side -fill y
	pack .sash -side $::dock_side -fill y     ;# between the dock and the editor
	if {$::chat_shown} {
		pack .chat  -side right -fill y       ;# chat column on the right (D14)
		pack .csash -side right -fill y       ;# between the editor and the chat
	}
	pack .ed   -side left -fill both -expand 1
}

# Drag the sash to resize the dock. The dock keeps a fixed -width (propagate off),
# so we recompute it from the pointer measured against the TOPLEVEL'S stable edge
# (not the dock's own, which moves as we resize it — referencing that fed back on
# itself and made the panes jump). The toplevel also has propagation off (startup),
# so a wider dock shrinks the editor instead of widening the whole window. Clamped
# so neither side collapses; works on either edge because dock_side flips the math.
proc sash_drag {} {
	set total [winfo width .]
	set min 120
	set max [expr {$total - 200}]
	if {$::dock_side eq "left"} {
		set w [expr {[winfo pointerx .] - [winfo rootx .]}]
	} else {
		set w [expr {[winfo rootx .] + $total - [winfo pointerx .]}]
	}
	if {$w < $min} { set w $min }
	if {$max > $min && $w > $max} { set w $max }
	.dock configure -width $w
}

# Toggle line wrapping (View menu). With wrap on, lines fold at the word and the
# horizontal scrollbar is meaningless, so it is hidden; with wrap off the bar comes
# back for long lines. Configures the real widget (the proxy only guards edits).
proc apply_wrap {} {
	if {$::wrap_lines} {
		::rio_real_t configure -wrap word
		grid remove .ed.hsb
	} else {
		::rio_real_t configure -wrap none
		gridscroll .ed.hsb {*}[::rio_real_t xview]   ;# show only if a line overflows
	}
}

# Highlight the active selector label (the inactive one recedes). Guarded so it
# can run during apply_theme before the dock might be fully realized.
proc style_selector {} {
	if {![winfo exists .dock.sel.files]} return
	set c $::theme_colors
	foreach pane {files git} {
		set active [expr {$pane eq $::dock_pane}]
		.dock.sel.$pane configure -foreground [dict get $c tab.fg] -background \
			[expr {$active ? [dict get $c tab.active.bg] : [dict get $c tab.inactive.bg]}]
	}
}

# ---------------------------------------------------------------------------
# The agent chat pane (AGENTS.md D14 `chat` column; D20/D26). A dumb view (D3)
# over the agent.* event stream: a read-only transcript, a composer, and Send.
# agent.send is a STREAMING op — its reply arrives as agent.delta events that we
# append live (chat_event), so the answer builds in view; agent.message closes
# the turn, agent.error shows a classified failure (D26). The core owns the
# conversation (D3): chat_clear is agent.reset. Always on the right; toggleable.
# ---------------------------------------------------------------------------
# Insert into the read-only transcript (briefly enabled), scrolling to the end.
proc chat_log {text {tag ""}} {
	.chat.log configure -state normal
	if {$tag eq ""} { .chat.log insert end $text } else { .chat.log insert end $text $tag }
	.chat.log configure -state disabled
	.chat.log see end
}
# A speaker label opening a block (a blank line between blocks, not at the top).
proc chat_label {tag label} {
	if {[.chat.log index "end-1c"] ne "1.0"} { chat_log "\n" }
	chat_log "$label\n" $tag
}

# Send the composer's text as a turn: the user block goes in at once, the reply
# streams back through chat_event (call_stream delivers events live, D26).
proc chat_send {} {
	set text [string trim [.chat.input get 1.0 end]]
	if {$text eq ""} return
	.chat.input delete 1.0 end
	chat_label you-label "You"
	chat_log "$text\n"
	set ::chat_turn_open 0
	rio::core::call_stream agent.send [dict create text $text] agent_event
}

# The streaming sink for a turn (D26): an approved edit's buffer.changed updates
# the editor view; everything else (agent.*) goes to the chat transcript. One sink
# so the turn's editor effects and its narration ride the same event stream.
proc agent_event {ev} {
	switch -- [dict get $ev event] {
		buffer.changed {
			# The model already changed; only refresh the widget when the edited buffer
			# is the one on screen (others reload from core on tab switch).
			set p [dict get $ev params]
			if {[dict get $p buffer] eq $::cur} { apply_change $p }
		}
		default { chat_event $ev }
	}
}

# Apply one streamed agent.* event to the transcript.
proc chat_event {ev} {
	switch -- [dict get $ev event] {
		agent.delta {
			if {!$::chat_turn_open} { chat_label agent-label "Agent" ; set ::chat_turn_open 1 }
			chat_log [dict get $ev params text]
		}
		agent.message {
			# A provider that didn't stream deltas still shows its full reply.
			if {!$::chat_turn_open} {
				chat_label agent-label "Agent"
				chat_log [dict get $ev params text]
			}
			chat_log "\n"
			set ::chat_turn_open 0
		}
		agent.error {
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			approve_bar 0
			chat_label error-label "Error"
			chat_log "[dict get $ev params message] ([dict get $ev params code])\n"
		}
		agent.tool {
			# A read-only tool the agent is running (D26 slice 4) — auto-executed, so
			# this is transparency, not a prompt. Shown on its own line, mid-turn.
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			set args [dict get $ev params args]
			chat_log "· [dict get $ev params name][expr {$args eq "" ? "" : " $args"}]\n" tool
		}
		agent.propose {
			# A proposed EDIT awaiting the user's decision (D26 slice 5). Show the diff;
			# unless auto-accept is on (the core then applies without pausing), raise the
			# Approve/Reject bar.
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			chat_log "· proposes [dict get $ev params name]: [dict get $ev params path]\n" tool
			chat_diff [dict get $ev params diff]
			if {!$::agent_auto_accept} {
				set ::pending_turn [dict get $ev params turn]
				approve_bar 1
			}
		}
		agent.tool_result {
			# The outcome of a read or an applied/rejected edit (red if it failed).
			approve_bar 0
			set tag [expr {[dict get $ev params ok] ? "tool" : "tool-error"}]
			chat_log "  → [dict get $ev params summary]\n" $tag
		}
	}
}

# Render a proposed edit's diff: -removed in red, +added in green.
proc chat_diff {diff} {
	foreach line [split $diff "\n"] {
		set tag tool
		if {[string match "+*" $line]} { set tag diff-add } elseif {[string match {-*} $line]} { set tag diff-del }
		chat_log "  $line\n" $tag
	}
}

# Show/hide the Approve/Reject bar for a pending proposal.
proc approve_bar {show} {
	if {$show} {
		pack .chat.approve -side bottom -fill x -before .chat.input
	} else {
		catch {pack forget .chat.approve}
		set ::pending_turn ""
	}
}

# The user's decision on the pending edit → agent.approve resumes the turn, whose
# remaining events stream back on agent_event (the turn's original sink).
proc agent_decide {decision} {
	if {$::pending_turn eq ""} return
	set t $::pending_turn
	approve_bar 0
	catch {rio::core::call agent.approve [dict create turn $t decision $decision]}
}

# Clear the conversation: reset the core's state (agent.reset) and the transcript.
proc chat_clear {} {
	rio_call agent.reset {}
	.chat.log configure -state normal
	.chat.log delete 1.0 end
	.chat.log configure -state disabled
	set ::chat_turn_open 0
}

# Show/hide the chat pane (driven by the View-menu checkbutton's ::chat_shown).
proc apply_chat_visibility {} {
	place_dock
	if {$::chat_shown} { focus .chat.input }
}

# Drag the chat sash to resize the chat column. Chat is always on the right, so
# its width is the toplevel's right edge minus the pointer — measured against the
# toplevel's STABLE edge like sash_drag. Clamped so neither side collapses.
proc csash_drag {} {
	set total [winfo width .]
	set min 200
	set max [expr {$total - 250}]
	set w [expr {[winfo rootx .] + $total - [winfo pointerx .]}]
	if {$w < $min} { set w $min }
	if {$max > $min && $w > $max} { set w $max }
	.chat configure -width $w
}

# Drag the composer sash to resize the input box. Its height is in text lines, so we
# anchor on the press (start height + pointer y) and convert the vertical drag to a
# line delta via the font's line height — dragging up grows the input, down shrinks
# it. Clamped so it can't vanish or eat the whole transcript.
proc isash_press {y} {
	set ::isash_y0 $y
	set ::isash_h0 [.chat.input cget -height]
}
proc isash_drag {y} {
	set lh [font metrics [.chat.input cget -font] -linespace]
	if {$lh < 1} { set lh 1 }
	set h [expr {$::isash_h0 + int(double($::isash_y0 - $y) / $lh + 0.5)}]
	if {$h < 1} { set h 1 }
	set max [chat_input_max]
	if {$h > $max} { set h $max }
	.chat.input configure -height $h
}
# The most lines the input may take while leaving the sash and a few transcript
# lines on screen — otherwise a maxed input squeezes the divider out of reach.
proc chat_input_max {} {
	set lh [font metrics [.chat.input cget -font] -linespace]
	if {$lh < 1} { set lh 1 }
	set avail [expr {[winfo height .chat] - [winfo height .chat.hdr] \
		- [winfo height .chat.send] - [winfo reqheight .chat.isash] - 3 * $lh}]
	set m [expr {$avail / $lh}]
	if {$m < 1} { set m 1 }
	return $m
}
# Re-clamp on layout changes (chat shown, window resized) so the input never hides
# the sash — and a previously over-tall input shrinks back into reach on its own.
proc clamp_input_height {} {
	set m [chat_input_max]
	if {[.chat.input cget -height] > $m} { .chat.input configure -height $m }
}

# ---------------------------------------------------------------------------
# Agent provider selection + the Claude API key (AGENTS.md D26). The agent runs
# one provider at a time: the offline `echo` stub (the default — proves the
# streaming path with no network or credentials) or `claude`, the claude-api
# provider, which needs a stored Anthropic API key. Which one is live is a
# runtime choice from the Settings menu; the API key is the only DURABLE agent
# credential, kept by the face as a 0600 secret (D21). The chat header names the
# active provider so the choice is never invisible.
# ---------------------------------------------------------------------------
set ::agent_provider echo   ;# echo | claude
set ::claude_key_show 0     ;# the key dialog's reveal toggle

proc apply_provider {} {
	if {$::agent_provider eq "claude"} {
		rio::agent::set_provider rio::claude::api::provider
		catch {.chat.hdr.title configure -text "Agent · Claude"}
	} else {
		rio::agent::set_provider rio::agent::echo_provider
		catch {.chat.hdr.title configure -text "Agent · Echo"}
	}
}

# The Claude API key dialog (Settings ▸ Claude API Key…). A small modal that is a
# dumb view of the claude-api face's key store: it never holds the key itself, it
# just hands what the user types to set_key / removes it with clear_key. Selecting
# the Claude provider with no key stored isn't blocked here — the first turn then
# surfaces the face's actionable not_configured error (D26), pointing right back.
proc claude_key_dialog {} {
	set w .claudekey
	destroy $w
	toplevel $w
	wm title $w "Claude API key"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	set stored [rio::claude::api::configured]
	label $w.prompt -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-text "Anthropic API key — create one at console.anthropic.com."
	entry $w.e -show • -width 52 -font RioUIFont
	checkbutton $w.show -text "Show key" -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -selectcolor [dict get $c ui.bg] \
		-variable ::claude_key_show -command [list claude_key_reveal $w]
	set ::claude_key_show 0
	label $w.status -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-text [expr {$stored ? "A key is stored; saving one replaces it." : "No key stored yet."}]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.save   -text "Save"   -font RioUIFont -command [list claude_key_save $w]
	button $w.btns.clear  -text "Clear"  -font RioUIFont -command [list claude_key_clear $w] \
		-state [expr {$stored ? "normal" : "disabled"}]
	button $w.btns.cancel -text "Cancel" -font RioUIFont -command [list destroy $w]
	pack $w.btns.cancel $w.btns.clear $w.btns.save -side right -padx 3
	grid $w.prompt -row 0 -column 0 -sticky we -padx 8 -pady {8 2}
	grid $w.e      -row 1 -column 0 -sticky we -padx 8
	grid $w.show   -row 2 -column 0 -sticky w  -padx 6
	grid $w.status -row 3 -column 0 -sticky we -padx 8 -pady {2 4}
	grid $w.btns   -row 4 -column 0 -sticky e  -padx 5 -pady {2 8}
	bind $w.e <Return> [list $w.btns.save invoke]
	bind $w <Escape>   [list destroy $w]
	catch {grab $w}
	focus $w.e
}
proc claude_key_reveal {w} {
	$w.e configure -show [expr {$::claude_key_show ? "" : "•"}]
}
proc claude_key_save {w} {
	set key [string trim [$w.e get]]
	if {$key eq ""} {
		report_error "Enter an API key, or use Clear to remove the stored one."
		return
	}
	rio::claude::api::set_key $key
	destroy $w
}
proc claude_key_clear {w} {
	rio::claude::api::clear_key
	destroy $w
}

proc do_save_as {path} {
	set resp [rio_call file.save [dict create buffer $::cur path $path]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save $path:\n[dict get $resp error message]"
		return 0
	}
	bufset $::cur path $path
	clear_modified
	return 1
}

proc do_save {} {
	if {[bufget $::cur path] eq ""} { return [save_as_dialog] }
	set resp [rio_call file.save [dict create buffer $::cur]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save:\n[dict get $resp error message]"
		return 0
	}
	clear_modified
	return 1
}

proc do_undo {} {
	set res [rio_result edit.undo [dict create buffer $::cur]]
	if {$res ne "" && [dict get $res changed]} { mark_modified 1 }
}
proc do_redo {} {
	set res [rio_result edit.redo [dict create buffer $::cur]]
	if {$res ne "" && [dict get $res changed]} { mark_modified 1 }
}

# Close the active buffer; guard unsaved changes, and keep at least one tab.
proc do_close {} {
	if {![maybe_discard]} return
	set victim $::cur
	set idx [lsearch -exact $::order $victim]
	close_buffer $victim
	if {![llength $::order]} {
		do_new
	} else {
		set ni [expr {$idx >= [llength $::order] ? [llength $::order] - 1 : $idx}]
		activate [lindex $::order $ni]
	}
}
# Close any tab (the × button): focus it first so a discard prompt is in context.
proc close_tab {id} { activate $id ; do_close }

proc cycle {dir} {
	if {[llength $::order] < 2} return
	set i [lsearch -exact $::order $::cur]
	activate [lindex $::order [expr {($i + $dir) % [llength $::order]}]]
}

# --- dialog wrappers ---------------------------------------------------------
proc open_dialog {} {
	set p [tk_getOpenFile -title "Open file"]
	if {$p ne ""} { do_open $p }
}
proc save_as_dialog {} {
	set p [tk_getSaveFile -title "Save as"]
	if {$p eq ""} { return 0 }
	return [do_save_as $p]
}
# Returns 1 if it is safe to throw away the active buffer.
proc maybe_discard {} {
	if {![bufget $::cur modified]} { return 1 }
	switch -- [tk_messageBox -icon question -type yesnocancel -title rio \
			-message "Discard unsaved changes to [tab_name $::cur]?"] {
		yes    { return 1 }
		no     { return [do_save] }
		cancel { return 0 }
	}
}
proc do_quit {} {
	foreach id $::order {
		if {[bufget $id modified]} {
			activate $id
			if {![maybe_discard]} return
		}
	}
	exit 0
}

# ---------------------------------------------------------------------------
# Modified flag, title, status, and the tab bar.
# ---------------------------------------------------------------------------
proc mark_modified {m} {
	if {$::cur eq ""} return
	set was [bufget $::cur modified]
	bufset $::cur modified $m
	if {$m != $was} { refresh_tabs ; refresh_title }
	refresh_status
}
proc clear_modified {} { bufset $::cur modified 0 ; refresh_all }

proc tab_name {id} {
	set p [bufget $id path]
	set n [expr {$p eq "" ? "untitled" : [file tail $p]}]
	return "$n[expr {[bufget $id modified] ? { *} : {}}]"
}
proc refresh_all   {} { refresh_tabs ; refresh_title ; refresh_status }
proc refresh_title {} { wm title . "rio — [tab_name $::cur]" }
proc refresh_status {} {
	set p    [bufget $::cur path]
	set name [expr {$p eq "" ? "untitled" : $p}]
	set meta [bufget $::cur meta]
	set enc  [expr {[dict exists $meta encoding] ? [dict get $meta encoding] : "utf-8"}]
	set eol  [expr {[dict exists $meta eol] ? [dict get $meta eol] : "lf"}]
	.status configure -text [format "%s      %s  %s%s      %d buffer(s)" \
		$name $enc $eol [expr {[bufget $::cur modified] ? {      modified} : {}}] \
		[llength $::order]]
}
proc refresh_tabs {} {
	set c $::theme_colors
	set fg [dict get $c tab.fg]
	foreach w [winfo children .tabs] { destroy $w }
	foreach id $::order {
		set active [expr {$id eq $::cur}]
		set bg [expr {$active ? [dict get $c tab.active.bg] : [dict get $c tab.inactive.bg]}]
		set f [frame .tabs.b$id -background $bg -borderwidth 1 \
			-relief [expr {$active ? "raised" : "flat"}]]
		label $f.l -text [tab_name $id] -background $bg -foreground $fg \
			-font RioUIFont -padx 6 -pady 1
		label $f.x -text "×" -background $bg -foreground $fg \
			-font RioUIFont -padx 3
		bind $f.l <Button-1> [list activate $id]
		bind $f.x <Button-1> [list close_tab $id]
		pack $f.l -side left ; pack $f.x -side right
		pack $f -side left -padx 1 -pady 1
	}
}

# ---------------------------------------------------------------------------
# Theme applier (AGENTS.md D24). The core serves the theme as a role table
# (theme.get); here we map roles onto Tk. NAMED fonts are referenced by name by
# every widget, so reconfiguring one updates them all live; explicit per-widget
# config makes a colour switch live too (the option DB only reaches widgets
# created afterwards). Keeping this Tk mapping here is what lets theme files stay
# dumb data.
# ---------------------------------------------------------------------------
set ::theme_colors {} ;# active colour roles, consulted by refresh_tabs

proc ensure_fonts {fonts} {
	dict for {name spec} $fonts {
		set opts [list -family [dict get $spec family] -size [dict get $spec size]]
		if {[lsearch -exact [font names] $name] >= 0} {
			font configure $name {*}$opts
		} else {
			font create $name {*}$opts
		}
	}
}

proc apply_theme {theme} {
	set c [dict get $theme colors]
	set ::theme_colors $c
	ensure_fonts [dict get $theme fonts]
	# Editor surface.
	::rio_real_t configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor] \
		-selectbackground [dict get $c editor.selection]
	.ed configure -background [dict get $c editor.bg]   ;# the scrollbar-corner gap
	# Chrome: status bar + tab container.
	.status configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	.tabs configure -background [dict get $c tab.bar.bg]
	.sash configure -background [dict get $c tab.bar.bg]   ;# the dock divider/grip
	# The dock (file + git panes): reuse the UI role (no dedicated sidebar role
	# yet); list selections borrow the editor's selection colour so the panes
	# match the surface. The selector labels are coloured by style_selector.
	foreach w {.dock .dock.sel .dock.files .dock.git .dock.git.hdr} {
		$w configure -background [dict get $c ui.bg]
	}
	foreach w {.dock.files.head .dock.git.hdr.branch .dock.git.hdr.refresh} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	foreach w {.dock.files.list .dock.git.list} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
			-selectbackground [dict get $c editor.selection] \
			-selectforeground [dict get $c ui.fg]
	}
	# The diff area is code, so it takes the editor surface.
	.dock.git.diff configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
	# The agent chat pane (D26): the chat.* roles + RioChatFont; accent on labels.
	.chat configure -background [dict get $c chat.bg]
	.chat.hdr configure -background [dict get $c chat.bg]
	.chat.hdr.title configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.hdr.clear configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c accent]
	.chat.log configure -font RioChatFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.input configure -font RioChatFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg] \
		-insertbackground [dict get $c chat.fg]
	.chat.send configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	# Speaker headers get a full-width highlight band so each turn is easy to find in
	# the log (diffs, tool lines, replies). The label's trailing newline is in the tag
	# range, so the background fills to the right edge. Two tints keep You vs Agent apart.
	.chat.log tag configure agent-label -font RioUIFont -foreground [dict get $c accent] \
		-background [dict get $c ui.bg] -spacing1 4 -spacing3 2
	.chat.log tag configure you-label   -font RioUIFont -foreground [dict get $c chat.fg] \
		-background [dict get $c editor.selection] -spacing1 4 -spacing3 2
	.chat.log tag configure error-label -font RioUIFont -foreground "#cc0000"
	.chat.log tag configure tool        -font RioUIFont -foreground [dict get $c gutter.fg]
	.chat.log tag configure tool-error  -font RioUIFont -foreground "#cc0000"
	.chat.log tag configure diff-add    -font RioUIFont -foreground "#118811"
	.chat.log tag configure diff-del    -font RioUIFont -foreground "#cc0000"
	.chat.approve configure -background [dict get $c chat.bg]
	.chat.approve.lbl configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.approve.yes configure -font RioUIFont
	.chat.approve.no  configure -font RioUIFont
	.csash configure -background [dict get $c tab.bar.bg]
	.chat.isash configure -background [dict get $c tab.bar.bg]
	style_selector
	# Named-font defaults for widgets created later (dialogs, the future chat pane).
	option add *Text.font RioEditorFont
	option add *Label.font RioUIFont
	if {[llength $::order]} refresh_tabs
}

# Switch themes live (View menu): re-fetch from the core and re-apply.
proc do_theme {name} {
	set resp [rio_call theme.get [dict create name $name]]
	if {[dict get $resp ok]} {
		apply_theme [dict get $resp result]
	} else {
		report_error "Theme '$name': [dict get $resp error message]" \
			[dict get $resp error code]
	}
}

# ---------------------------------------------------------------------------
# Build the UI. The literal colours/fonts here are just a bootstrap; apply_theme
# (below, fed by the core's theme.get) reconfigures every widget from the role
# table — the default theme reproduces this plain white-bg "90s productivity"
# look (D24), and the View menu switches it live.
# ---------------------------------------------------------------------------
frame .tabs -background "#bbbbbb"

# The side dock: a selector row (Files | Git) above the two pane bodies, of which
# show_pane packs exactly one. place_dock decides which edge it sits on.
# propagate off so the dock keeps a STABLE width regardless of which pane shows —
# otherwise the git pane's diff (editor font) is physically wider than the file
# list (UI font) at the same column count, and the whole window jumps on switch.
frame .dock -background "#dddddd" -width 220
pack propagate .dock 0
frame .dock.sel -background "#dddddd"
label .dock.sel.files -text Files -font {monospace 9} -padx 8 -pady 1 \
	-background "#cccccc" -foreground black
label .dock.sel.git   -text Git   -font {monospace 9} -padx 8 -pady 1 \
	-background "#cccccc" -foreground black
pack .dock.sel.files .dock.sel.git -side left -padx 1 -pady 1
pack .dock.sel -side top -fill x
bind .dock.sel.files <Button-1> {show_pane files}
bind .dock.sel.git   <Button-1> {show_pane git}

# File pane body: a header + a scrollable listbox the navigator fills.
frame .dock.files -background "#dddddd"
label .dock.files.head -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-background "#dddddd" -foreground black
scrollbar .dock.files.sb -command {.dock.files.list yview}
listbox .dock.files.list -width 26 -activestyle none -exportselection 0 \
	-borderwidth 0 -highlightthickness 0 \
	-background "#dddddd" -foreground black \
	-yscrollcommand {autoscroll .dock.files.sb .dock.files.list}
pack .dock.files.head -side top -fill x
pack .dock.files.list -side left -fill both -expand 1
# .dock.files.sb is packed on demand by autoscroll (hidden when the list fits).
bind .dock.files.list <Double-Button-1> nav_activate
bind .dock.files.list <Return>          nav_activate

# Git pane body: branch header + Refresh, the changed-file list, and a read-only
# diff area below it.
frame .dock.git -background "#dddddd"
frame .dock.git.hdr -background "#dddddd"
label .dock.git.hdr.branch -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-background "#dddddd" -foreground black
label .dock.git.hdr.refresh -text "⟳" -font {monospace 9} -padx 6 \
	-background "#dddddd" -foreground black
pack .dock.git.hdr.refresh -side right
pack .dock.git.hdr.branch  -side left -fill x -expand 1
pack .dock.git.hdr -side top -fill x
bind .dock.git.hdr.refresh <Button-1> refresh_git
listbox .dock.git.list -width 26 -height 8 -activestyle none -exportselection 0 \
	-borderwidth 0 -highlightthickness 0 \
	-background "#dddddd" -foreground black
# -width 26 matches the list so the git pane does not balloon the dock (and the
# whole window) to the text widget's default 80 columns when it is shown.
text .dock.git.diff -wrap none -width 26 -height 8 -state disabled \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black
pack .dock.git.list -side top -fill both -expand 1
# .dock.git.diff is packed on demand by git_show_diff (hidden until a file is picked).
bind .dock.git.list <<ListboxSelect>> git_select

# A thin draggable divider between the dock and the editor. place_dock parks it on
# whichever edge the dock occupies; dragging it resizes the dock (the editor, which
# -expands, absorbs the difference). The resize cursor on hover advertises the grip.
frame .sash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .sash <B1-Motion> sash_drag

# The editor region: the text widget with vertical + horizontal scrollbars, gridded
# in a container so the scrollbars hug the text (not the whole window). The text is
# named .ed.t so the scrollbars can be its siblings; everything else still drives it
# through that path (proxy) and ::rio_real_t (the real command). The horizontal bar
# auto-hides (gridscroll) when no line overflows, and apply_wrap drops it entirely
# while wrapping, where horizontal scrolling is meaningless.
frame .ed
text .ed.t -wrap none -undo 0 -font {monospace 12} -width 80 -height 28 \
	-background white -foreground black -insertbackground black \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-yscrollcommand {.ed.vsb set} -xscrollcommand {gridscroll .ed.hsb}
scrollbar .ed.vsb -orient vertical   -command {.ed.t yview}
scrollbar .ed.hsb -orient horizontal -command {.ed.t xview}
grid .ed.t   -row 0 -column 0 -sticky nsew
grid .ed.vsb -row 0 -column 1 -sticky ns
grid .ed.hsb -row 1 -column 0 -sticky ew
grid rowconfigure    .ed 0 -weight 1
grid columnconfigure .ed 0 -weight 1

# The agent chat pane (built here; place_dock packs it on the right when shown,
# apply_theme colours it via the chat.* roles + RioChatFont). propagate off so a
# fixed -width holds across content, like the dock. A header (Agent + Clear) on
# top, the composer (input + Send) at the bottom, the transcript filling between.
frame .chat -width 340 -background white
pack propagate .chat 0
frame .chat.hdr -background white
label .chat.hdr.title -text "Agent" -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-background white -foreground black
label .chat.hdr.clear -text "Clear" -font {monospace 9} -padx 6 -cursor hand2 \
	-background white -foreground black
pack .chat.hdr.clear -side right
pack .chat.hdr.title -side left -fill x -expand 1
bind .chat.hdr.clear <Button-1> chat_clear
# Composer: a few-line input + a Send button. Enter sends; Shift+Enter newlines.
text .chat.input -height 3 -wrap word -undo 1 -font {monospace 11} \
	-borderwidth 1 -relief solid -highlightthickness 0 -padx 3 -pady 2 \
	-background white -foreground black -insertbackground black
button .chat.send -text "Send" -font {monospace 9} -command chat_send
bind .chat.input <Return>       { chat_send ; break }
bind .chat.input <Shift-Return> { %W insert insert "\n" ; break }
# A thin draggable divider between the transcript and the composer, so the user can
# size the input box (mirror of .sash/.csash, but horizontal).
frame .chat.isash -height 5 -cursor sb_v_double_arrow -background "#bbbbbb"
bind .chat.isash <ButtonPress-1> { isash_press %Y }
bind .chat.isash <B1-Motion>     { isash_drag %Y }
bind .chat <Configure> clamp_input_height
# Approve/Reject bar for a proposed edit (packed on demand by approve_bar; D26 s5).
frame .chat.approve -background white
label .chat.approve.lbl -text "Apply this edit?" -anchor w -font {monospace 9} \
	-padx 4 -pady 2 -background white -foreground black
button .chat.approve.yes -text "Approve" -font {monospace 9} -command {agent_decide approve}
button .chat.approve.no  -text "Reject"  -font {monospace 9} -command {agent_decide reject}
pack .chat.approve.yes -side right
pack .chat.approve.no  -side right
pack .chat.approve.lbl -side left -fill x -expand 1
# Transcript: read-only, word-wrapped, with an auto-hiding scrollbar.
text .chat.log -wrap word -state disabled -font {monospace 11} -cursor "" \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black \
	-yscrollcommand {autoscroll .chat.sb .chat.log}
scrollbar .chat.sb -command {.chat.log yview}
.chat.log tag configure you-label   -font {monospace 9} -background "#c3d9ff" \
	-spacing1 4 -spacing3 2
.chat.log tag configure agent-label -font {monospace 9} -background "#dddddd" \
	-spacing1 4 -spacing3 2
.chat.log tag configure error-label -font {monospace 9}
.chat.log tag configure tool        -font {monospace 9} -foreground "#888888"
.chat.log tag configure tool-error  -font {monospace 9} -foreground "#cc0000"
.chat.log tag configure diff-add    -font {monospace 9} -foreground "#118811"
.chat.log tag configure diff-del    -font {monospace 9} -foreground "#cc0000"
pack .chat.hdr   -side top    -fill x
pack .chat.send  -side bottom -fill x
pack .chat.input -side bottom -fill x
pack .chat.isash -side bottom -fill x
pack .chat.log   -side left   -fill both -expand 1
# .chat.sb is packed on demand by autoscroll (hidden when the transcript fits).

# A thin draggable divider between the editor and the chat pane (mirror of .sash).
frame .csash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .csash <B1-Motion> csash_drag

label .status -anchor w -font {monospace 9} -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .tabs   -side top -fill x
pack .status -side bottom -fill x
# .dock and .ed are packed by place_dock at startup (so the dock side is live).
focus .ed.t

menu .m ; . configure -menu .m
menu .m.file -tearoff 0
.m add cascade -label File -menu .m.file
.m.file add command -label "New"       -accelerator Ctrl+N       -command do_new
.m.file add command -label "Open…"    -accelerator Ctrl+O       -command open_dialog
.m.file add command -label "Open Folder…" -accelerator Ctrl+Shift+O -command open_folder_dialog
.m.file add command -label "Save"      -accelerator Ctrl+S       -command do_save
.m.file add command -label "Save As…" -accelerator Ctrl+Shift+S -command save_as_dialog
.m.file add separator
.m.file add command -label "Close Tab" -accelerator Ctrl+W       -command do_close
.m.file add command -label "Quit"      -accelerator Ctrl+Q       -command do_quit
menu .m.edit -tearoff 0
.m add cascade -label Edit -menu .m.edit
.m.edit add command -label "Undo" -accelerator Ctrl+Z       -command do_undo
.m.edit add command -label "Redo" -accelerator Ctrl+Shift+Z -command do_redo
menu .m.view -tearoff 0
.m add cascade -label View -menu .m.view
.m.view add command -label "Show Files" -accelerator Ctrl+Shift+E -command {show_pane files}
.m.view add command -label "Show Git"   -accelerator Ctrl+Shift+G -command {show_pane git}
.m.view add separator
.m.view add radiobutton -label "Dock Left"  -variable ::dock_side -value left  -command place_dock
.m.view add radiobutton -label "Dock Right" -variable ::dock_side -value right -command place_dock
.m.view add separator
.m.view add checkbutton -label "Wrap Lines" -accelerator Ctrl+Shift+W \
	-variable ::wrap_lines -command apply_wrap
.m.view add checkbutton -label "Agent Chat" -accelerator Ctrl+Shift+A \
	-variable ::chat_shown -command apply_chat_visibility
.m.view add separator
.m.view add command -label "Theme: Default"         -command {do_theme default}
.m.view add command -label "Theme: Solarized Dark"  -command {do_theme solarized-dark}
.m.view add command -label "Theme: Solarized Light" -command {do_theme solarized-light}
.m.view add command -label "Theme: Plan 9 Acme"     -command {do_theme acme}
menu .m.settings -tearoff 0
.m add cascade -label Settings -menu .m.settings
.m.settings add radiobutton -label "Agent: Echo (offline)"    -variable ::agent_provider \
	-value echo   -command apply_provider
.m.settings add radiobutton -label "Agent: Claude (API key)"  -variable ::agent_provider \
	-value claude -command apply_provider
.m.settings add separator
.m.settings add command -label "Claude API Key…" -command claude_key_dialog
.m.settings add separator
.m.settings add checkbutton -label "Agent: Auto-accept edits" -variable ::agent_auto_accept \
	-command {rio::agent::set_auto_accept $::agent_auto_accept}

# Shortcuts bound on the text widget with `break`, so the widget's own class
# bindings (e.g. Tk's built-in Ctrl+O/Ctrl+Z) don't also fire.
bind .ed.t <Control-n>         { do_new ; break }
bind .ed.t <Control-o>         { open_dialog ; break }
bind .ed.t <Control-O>         { open_folder_dialog ; break }
bind .ed.t <Control-s>         { do_save ; break }
bind .ed.t <Control-S>         { save_as_dialog ; break }
bind .ed.t <Control-w>         { do_close ; break }
bind .ed.t <Control-q>         { do_quit ; break }
bind .ed.t <Control-z>         { do_undo ; break }
bind .ed.t <Control-Z>         { do_redo ; break }
bind .ed.t <Control-y>         { do_redo ; break }
bind .ed.t <Control-Tab>       { cycle 1 ; break }
bind .ed.t <Control-Shift-Tab> { cycle -1 ; break }
bind .ed.t <Control-E>         { show_pane files ; break }
bind .ed.t <Control-G>         { show_pane git ; break }
bind .ed.t <Control-W>         { set ::wrap_lines [expr {!$::wrap_lines}] ; apply_wrap ; break }
bind .ed.t <Control-A>         { set ::chat_shown [expr {!$::chat_shown}] ; apply_chat_visibility ; break }
wm protocol . WM_DELETE_WINDOW do_quit

# --- widget proxy: edits become protocol requests, never local mutations -----
rename .ed.t ::rio_real_t
proc .ed.t {args} {
	switch -- [lindex $args 0] {
		insert {
			# .t insert <index> <chars> ?tagList chars ...?
			set idx   [::rio_real_t index [lindex $args 1]]
			set chars [lindex $args 2]
			if {$chars ne ""} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer $::cur start $idx end $idx text $chars]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		delete {
			# .t delete <index1> ?index2?  — compute i2 WITHOUT expr. A Tk text
			# index like "1.10" passed through expr is coerced to the float 1.1,
			# silently corrupting the column: backspace would then no-op at every
			# column 10, 20, 30, … (and forward/range deletes ending there too).
			set i1 [::rio_real_t index [lindex $args 1]]
			if {[llength $args] >= 3} {
				set i2 [::rio_real_t index [lindex $args 2]]
			} else {
				set i2 [::rio_real_t index "[lindex $args 1]+1c"]
			}
			if {[::rio_real_t compare $i1 < $i2]} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer $::cur start $i1 end $i2 text {}]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		default { return [::rio_real_t {*}$args] }
	}
}

# Apply the core's theme (the built-in default) before the first tab is drawn, so
# every widget — and the tab bar refresh_tabs builds — uses the role table.
apply_theme [dict get [rio_call theme.get {}] result]

# Start on the core's default buffer (an empty "untitled" tab), then process the
# command line: a directory argument opens as the project folder, a file opens in
# a tab. The file pane starts empty until a folder is opened.
set ::nav_dir ""
set ::nav_rows {}
set ::git_rows {}
register_buffer $::rio::ops::default "" {}
activate $::rio::ops::default
place_dock                 ;# pack the dock (default left) and the editor
show_pane $::dock_pane     ;# default files; also does the first populate
apply_wrap                 ;# sync wrap + the horizontal scrollbar to ::wrap_lines
apply_provider             ;# activate the default agent provider (echo) + name it
foreach f $argv {
	if {[file isdirectory $f]} { open_folder $f } else { do_open $f }
}

# Let the window settle at its natural content size, then stop child geometry from
# driving the toplevel. After this, resizing the dock (the sash) flexes the editor
# rather than resizing the whole window — which is what made sash drags feed back
# on themselves. The user can still resize the toplevel via the WM as usual.
update idletasks
pack propagate . 0

# A test harness sets RIO_GUI_HEADLESS to keep the window off-screen.
if {[info exists ::env(RIO_GUI_HEADLESS)]} { wm withdraw . }
