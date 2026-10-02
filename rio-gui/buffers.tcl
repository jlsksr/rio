# rio-gui/buffers.tcl — buffers: open, save, close, recovery copies, stale files, quit.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Apply the core's change to group `g`'s widget, through the real widget
# command. The core's line.col indices are Tk's (D12). Only the focused group
# scrolls to its caret.
proc apply_change {g p} {
	set t [gw $g]
	$t replace [dict get $p start] [dict get $p end] [dict get $p text]
	if {$g eq $::focus} { $t see insert }
	gutter_mark $g ;# the line count may have changed
	hl_edit $g $p  ;# re-highlight from the edit (D32)
	if {$::wrap_indent} {   ;# only the lines this edit touched
		set sl [lindex [split [dict get $p start] .] 0]
		set added [expr {[llength [split [dict get $p text] "\n"]] - 1}]
		wrapind_apply $t $sl [expr {$sl + $added}]
	}
	# An open find bar's matches are stale: one recount per burst (D36).
	if {$::find_shown && !$::find_pending} {
		set ::find_pending 1
		after idle find_update
	}
}

# Load group `g`'s active buffer into its widget, through the real widget
# command, and repaint. On open and on a tab switch.
proc load_buffer {g} {
	set t [gw $g]
	set id [gcur $g]
	$t delete 1.0 end
	# Fetch the document in chunks (D126): one huge JSON string is slow to
	# parse. Chunks go in at end-1c, before the newline Tk keeps at the end.
	set line 1
	while {1} {
		set resp [rio_call buffer.text [dict create buffer $id start $line]]
		if {![dict get $resp ok]} {
			set e [dict get $resp error]
			report_error [dict get $e message] [dict get $e code]
			break
		}
		set r [dict get $resp result]
		set chunk [dict get $r text]
		if {$chunk ne ""} { $t insert end-1c $chunk }
		if {[dict get $r eof]} break
		set next [dict get $r next]
		if {$next <= $line} break   ;# no progress — refuse to spin on a bad reply
		set line $next
	}
	hl_select $g       ;# the buffer may be another language (D32)
	hl_reset $g        ;# highlight the visible window
	wrapind_group $g
	gutter_mark $g     ;# this buffer has its own line count
}

# A buffer's whole text (buffer.text). "" on failure.
proc buf_text {id} {
	set resp [rio_call buffer.text [dict create buffer $id]]
	if {[dict get $resp ok]} { return [dict get $resp result text] }
	return ""
}

# ---------------------------------------------------------------------------
# Buffer / tab bookkeeping.
# ---------------------------------------------------------------------------
# Register a newly opened buffer at the end of group `g`'s tabs (default: the
# focused group). The core owns the text; ::buffers holds the view's facts:
#   path, meta, modified, cursor, yview
#   gone_ack — the user kept the buffer though its file is gone (D94)
#   lang     — the language picked by hand (D112): "" = by file name,
#              "plain" = none, else a language name
proc register_buffer {id path meta {g ""}} {
	if {$g eq ""} { set g $::focus }
	dict set ::buffers $id \
		[dict create path $path meta $meta modified 0 cursor 1.0 yview 0.0 gone_ack 0 lang ""]
	gset $g order [linsert [gorder $g] end $id]
}

# Make `id` active and focus its group: save the outgoing buffer's cursor and
# viewport, load `id`, restore its own. `g` defaults to the group holding
# `id`, else the focused one.
proc activate {id {g ""}} {
	if {$g eq ""} {
		set g [group_of $id]
		if {$g eq ""} { set g $::focus }
	}
	set t [gw $g]
	set out [gcur $g]
	if {$out ne "" && [dict exists $::buffers $out]} {
		bufset $out cursor [$t index insert]
		bufset $out yview  [lindex [$t yview] 0]
	}
	gset $g cur $id
	load_buffer $g
	catch {$t mark set insert [bufget $id cursor]}
	catch {$t yview moveto    [bufget $id yview]}
	set ::focus $g
	set ::cur $id
	$t see insert
	focus [gget $g path]
	refresh_all
	if {$::find_shown} find_update   ;# the bar tracks the focused buffer (D36)
}

proc close_buffer {id} {
	rio_call buffer.close [dict create buffer $id]
	set g [group_of $id]
	set ::buffers [dict remove $::buffers $id]
	if {$g ne ""} { gset $g order [lsearch -all -inline -not -exact [gorder $g] $id] }
}

# Close every empty, unmodified, untitled buffer but `keep`, so opening a
# file leaves no blank tab behind.
proc prune_scratch {keep} {
	set pruned 0
	foreach id [dict keys $::buffers] {
		if {$id eq $keep} continue
		if {[bufget $id path] eq "" && ![bufget $id modified] && [buf_text $id] eq ""} {
			close_buffer $id
			set pruned 1
		}
	}
	if {$pruned} refresh_all
}

# ---------------------------------------------------------------------------
# Actions. A do_* proc takes arguments and shows no file chooser, so a test
# can call it; the *_dialog wrappers add the choosers.
# ---------------------------------------------------------------------------
proc do_new {} {
	set res [rio_result buffer.new {}]
	if {$res eq ""} return
	set id [dict get $res buffer]
	register_buffer $id "" {}
	activate $id
}

# Adopt the buffers the core already has (buffer.list) and activate the first
# (D29). If it has none, make one: there is always a tab.
proc adopt_initial_buffers {} {
	set resp [rio_call buffer.list {}]
	set buffers [expr {[dict get $resp ok] ? [dict get $resp result buffers] : {}}]
	if {![llength $buffers]} { do_new ; return }
	foreach b $buffers {
		register_buffer [dict get $b buffer] [dict get $b path] {}
	}
	activate [dict get [lindex $buffers 0] buffer]
}

# Open a file in a tab. Returns 1 if it is open. `force` is the answer
# "Open it anyway?" for a file the core declined (D125).
proc do_open {path {force 0}} {
	# Already open in some group? Just switch to its tab (activate focuses its group).
	foreach id [dict keys $::buffers] {
		if {$path ne "" && [bufget $id path] eq $path} { activate $id ; return 1 }
	}
	set req [dict create path $path]
	if {$force} { dict set req force 1 }
	set resp [rio_call file.open $req]
	if {![dict get $resp ok]} {
		set code [dict get $resp error code]
		set msg  [dict get $resp error message]
		# too_large and binary_file are questions (D125): the core states the
		# fact, the frontend asks.
		if {!$force && ($code eq "too_large" || $code eq "binary_file")} {
			if {[tk_messageBox -icon warning -type yesno -default no -title rio \
				-message "$msg\n\nOpen it anyway?"] eq "yes"} {
				return [do_open $path 1]
			}
			return 0
		}
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not open $path:\n$msg"
		return 0
	}
	set res [dict get $resp result]
	set id  [dict get $res buffer]
	register_buffer $id $path \
		[dict create encoding [dict get $res encoding] eol [dict get $res eol]]
	# A forced open starts as Plain Text: highlighting slows a huge buffer.
	# View ▸ Language… turns it back on (D112).
	if {$force} { bufset $id lang plain }
	activate $id
	prune_scratch $id
	if {[dict get $res mixed]} {
		tk_messageBox -icon info -type ok -title rio \
			-message "Mixed line endings; the file will be saved as [dict get $res eol]."
	}
	session_save   ;# the open-file set changed — record it for resume (D31)
	# A recovery copy waits for this file (D132). During boot it is only
	# noted: all of them are asked about at once, after startup.
	if {[dict exists $res recovery] && [dict get $res recovery] ne ""} {
		if {$::rio_started} {
			recover_offer [list $id] [dict get $res recovery_newer]
		} else {
			lappend ::recover_pending [list $id $path [dict get $res recovery_newer]]
		}
	}
	return 1
}

# Offer the recovery copies of these buffers (D132), in one dialog.
# - `newer` picks the default button: Yes if the copy is newer than the
#   file, No if it is older.
# - Recovering does not touch the file and is one undo step.
# - Declining leaves the copy; a save drops it.
proc recover_offer {ids newer} {
	if {![llength $ids]} return
	set names {}
	foreach id $ids { lappend names "    [tab_name $id]" }
	set when [expr {$newer ? "newer than what is on disk" : "OLDER than what is on disk"}]
	if {[llength $ids] == 1} {
		set q "“[tab_name [lindex $ids 0]]” has unsaved changes that rio kept when it last stopped — $when.\n\nTake them back? The file itself is not touched, and this can be undone."
	} else {
		set q "[llength $ids] of the files just opened have unsaved changes that rio kept when it last stopped:\n\n[join $names \n]\n\nTake them back? The files themselves are not touched, and this can be undone."
	}
	if {[recover_ask $q $newer] ne "yes"} return
	foreach id $ids {
		set r [rio_call buffers.recover [dict create buffer $id]]
		if {![dict get $r ok]} continue
		# The buffer now differs from the file: modified.
		mark_buffer_modified $id 1
	}
	refresh_all
}

# Ask about everything boot noted, as one set.
proc recover_flush {} {
	if {![llength $::recover_pending]} return
	set ids {}
	set newer 0
	foreach e $::recover_pending {
		lappend ids [lindex $e 0]
		if {[lindex $e 2]} { set newer 1 }
	}
	set ::recover_pending {}
	recover_offer $ids $newer
}

# Its own proc, so a headless test can stub it.
proc recover_ask {q newer} {
	return [tk_messageBox -icon warning -type yesno \
		-default [expr {$newer ? "yes" : "no"}] \
		-title "rio — unsaved changes were kept" -message $q]
}

# Files or folders dropped from the OS file manager (D86): a folder opens as
# the project, a file in a tab; then the window is raised. Local cores only:
# a dropped path is this machine's. No raise in a headless run.
proc dnd_open_files {paths} {
	foreach f $paths {
		if {[file isdirectory $f]} { open_folder $f } else { do_open $f }
	}
	if {[llength $paths] && ![info exists ::env(RIO_GUI_HEADLESS)]} {
		wm deiconify . ; raise . ; focus -force .
	}
}

# Re-sync the dock when rio regains OS focus: it catches changes rio did not
# make (a `git pull`, a build). fs.changed (D47) covers rio's own writes.
#
# Tk sends FocusIn and FocusOut for moves inside the window too. So wait for
# idle, then ask `focus -displayof`: empty when another application has the
# focus.
set ::app_focused 1        ;# assume focused at launch
set ::focus_settle ""      ;# pending idle callback that reads the settled focus state
proc app_focus_event {} {
	if {$::focus_settle ne ""} { after cancel $::focus_settle }
	set ::focus_settle [after idle app_focus_settle]
}
proc app_focus_settle {} {
	set ::focus_settle ""
	note_app_focus [expr {[focus -displayof .] ne ""}]
}
# Act on the settled focus state: regaining focus re-syncs the dock and
# checks for stale buffers. Only with a live core.
proc note_app_focus {has} {
	if {$has} {
		if {!$::app_focused && [info exists ::core_chan]} {
			refresh_dock
			check_stale_buffers
		}
		set ::app_focused 1
	} else {
		set ::app_focused 0
	}
}

# ---------------------------------------------------------------------------
# Stale buffers: the file changed under an open tab (D94).
#
# Two triggers: fs.changed (rio's own writes) and regaining OS focus
# (everything else). rio does not watch the filesystem.
#
# The core detects (buffers.stale): the file is on its host (D29). The GUI
# decides what to do, because that depends on `modified` (D22). The default
# button is the choice that loses nothing:
#
#   clean, changed      reload silently
#   modified, changed   ask; default No. No stamps the buffer, so the same
#                       change is not asked about again.
#   gone from disk      ask "keep it open?"; default Yes. Kept, the buffer
#                       is modified, so a Save recreates the file.
proc check_stale_buffers {} {
	# A dialog runs the event loop: a second trigger may arrive meanwhile.
	if {$::stale_checking} return
	# Not inside another op's round trip: that op may itself settle these
	# buffers, e.g. a delete that closes the file's tab right after. One
	# retry at a time.
	if {[array size ::pending]} {
		if {$::stale_retry eq ""} {
			set ::stale_retry [after $::fs_changed_delay \
				{set ::stale_retry "" ; check_stale_buffers}]
		}
		return
	}
	set ::stale_checking 1
	if {[catch {_check_stale_buffers} err opts]} {
		set ::stale_checking 0
		return -options $opts $err
	}
	set ::stale_checking 0
}
proc _check_stale_buffers {} {
	set resp [rio_call buffers.stale {}]
	if {![dict get $resp ok]} return
	set reload {} ; set conflict {} ; set gone {}
	foreach s [dict get $resp result stale] {
		set id [dict get $s buffer]
		if {![dict exists $::buffers $id]} continue   ;# not a buffer this GUI shows
		if {[dict get $s gone]} {
			if {![bufget $id gone_ack]} { lappend gone $id }
		} elseif {[bufget $id modified]} {
			lappend conflict $id
		} else {
			lappend reload $id
		}
	}
	if {[llength $reload]}   { stale_reload $reload }
	if {[llength $conflict]} { stale_conflict $conflict }
	foreach id $gone { stale_deleted $id }
}

# Reload these buffers, in one op. The text arrives as buffer.changed events
# before the reply; here only the flags are set.
proc stale_reload {ids} {
	set resp [rio_call buffers.reload [dict create buffers $ids]]
	if {![dict get $resp ok]} return
	foreach r [dict get $resp result reloaded] {
		set id [dict get $r buffer]
		if {![dict exists $::buffers $id]} continue
		bufset $id modified 0
		bufset $id gone_ack 0
		bufset $id meta [dict merge [bufget $id meta] \
			[dict create encoding [dict get $r encoding] eol [dict get $r eol]]]
	}
	refresh_all
}

# Changed on disk, with unsaved edits here: one dialog for the whole set.
proc stale_conflict {ids} {
	set names {}
	foreach id $ids { lappend names "    [tab_name $id]" }
	if {[llength $ids] == 1} {
		set q "“[tab_name [lindex $ids 0]]” has changed on disk, and you have unsaved edits here.\n\nReload it from disk? Your unsaved edits will be lost."
	} else {
		set q "[llength $ids] open files have changed on disk, and you have unsaved edits in them:\n\n[join $names \n]\n\nReload them from disk? Your unsaved edits will be lost."
	}
	if {[stale_ask $q] eq "yes"} {
		stale_reload $ids
	} else {
		# Stamp: this version has been seen. A later change asks again.
		rio_call buffers.stamp [dict create buffers $ids]
	}
}

# The file is gone: ask, as Notepad++ does. Kept, the buffer is modified, so
# a Save recreates the file.
proc stale_deleted {id} {
	set q "“[tab_name $id]” has been deleted on disk.\n\nKeep it open in the editor? Saving it later will recreate the file."
	if {[stale_ask_deleted $q] eq "yes"} {
		bufset $id gone_ack 1
		mark_buffer_modified $id 1
	} else {
		bufset $id modified 0     ;# the D48 force-close idiom: no "save before closing?"
		close_tab $id
	}
}

# The two prompts, each its own proc so a headless test can stub it. They
# differ in the default button.
proc stale_ask {q} {
	return [tk_messageBox -icon warning -type yesno -default no \
		-title "rio — changed on disk" -message $q]
}
proc stale_ask_deleted {q} {
	return [tk_messageBox -icon warning -type yesno -default yes \
		-title "rio — deleted on disk" -message $q]
}

# mark_modified works on the CURRENT buffer; a stale check speaks about any of them.
proc mark_buffer_modified {id m} {
	if {![dict exists $::buffers $id]} return
	if {$id eq $::cur} { mark_modified $m ; return }
	bufset $id modified $m
	refresh_tabs
}

proc do_save_as {path} {
	set resp [rio_call file.save [dict create buffer $::cur path $path]]
	if {![dict get $resp ok]} {
		tk_messageBox -icon error -type ok -title rio \
			-message "Could not save $path:\n[dict get $resp error message]"
		return 0
	}
	bufset $::cur path $path
	bufset $::cur gone_ack 0   ;# it is on disk again (D94)
	hl_refresh_buffer $::cur   ;# the new name may pick a highlighter (D112)
	clear_modified
	refresh_dock   ;# the new/renamed file (and its git flag) now shows in the pane
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
	bufset $::cur gone_ack 0   ;# a kept-open deleted file has just been recreated (D94)
	clear_modified
	refresh_dock   ;# saved edits are now on disk — repaint so the git flag appears
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

# Close the focused group's active buffer, after asking about unsaved
# changes. An emptied second group is folded away; the only group gets a new
# empty buffer (D33).
proc do_close {} {
	if {![maybe_discard]} return
	set g $::focus
	set victim $::cur
	set idx [lsearch -exact [gorder $g] $victim]
	close_buffer $victim
	set order [gorder $g]
	if {![llength $order]} {
		if {[llength $::groups] >= 2} { collapse_group $g } else { do_new }
	} else {
		set ni [expr {$idx >= [llength $order] ? [llength $order] - 1 : $idx}]
		activate [lindex $order $ni] $g
	}
	session_save   ;# the open-file set changed — record it for resume (D31)
}
# Close any tab (the × button): activate it first, so the prompt is about it.
proc close_tab {id {g ""}} { activate $id $g ; do_close }

proc cycle {dir} {
	set g $::focus
	set order [gorder $g]
	if {[llength $order] < 2} return
	set i [lsearch -exact $order $::cur]
	activate [lindex $order [expr {($i + $dir) % [llength $order]}]] $g
}

# May the active buffer be closed? A modified one asks "Save before closing?":
#   Yes     save; 1 if the save worked
#   No      1, unsaved
#   Cancel  0
proc maybe_discard {} {
	if {![bufget $::cur modified]} { return 1 }
	switch -- [tk_messageBox -icon question -type yesnocancel -default yes -title rio \
			-message "[tab_name $::cur] has unsaved changes. Save before closing?"] {
		yes    { return [do_save] }
		no     { return 1 }
		cancel { return 0 }
	}
}
# The user declined to save these and the core is about to go: drop their
# recovery copies (D132). Quitting closes no buffer, so otherwise the next
# launch would offer the declined edits back.
# Only with a core of our own: a daemon keeps the buffers for the next
# frontend (D30), and their copies are still needed.
proc autosave_abandon {} {
	if {$::core_remote} return
	set ids {}
	foreach id [dict keys $::buffers] {
		if {[bufget $id modified]} { lappend ids $id }
	}
	if {![llength $ids]} return
	catch {rio_call autosave.discard [dict create buffers $ids]}
}

proc do_quit {} {
	prefs_save      ;# persist view state + the workspace before we go (D31)
	session_save
	foreach id [dict keys $::buffers] {
		if {[bufget $id modified]} {
			activate $id
			if {![maybe_discard]} return
		}
	}
	autosave_abandon   ;# a "don't save" above was a decision; make it stick (D132)
	# Close the channel: a spawned core sees EOF and exits.
	catch {close $::core_chan}
	exit 0
}
