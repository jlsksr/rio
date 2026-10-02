# rio-gui/buffers.tcl — buffers: open, save, close, recovery copies, stale files, quit.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# Apply a change to group `g`'s widget through the REAL widget command (bypassing the
# proxy). .t replace takes line.col indices directly — the payoff of D12 sharing the Tk
# text-widget index format: the view layer is nearly free. `see insert` only follows
# the caret in the focused group (the caret in a background group isn't the user's).
proc apply_change {g p} {
	set t [gw $g]
	$t replace [dict get $p start] [dict get $p end] [dict get $p text]
	if {$g eq $::focus} { $t see insert }
	gutter_mark $g ;# the line count may have changed — repaint the numbers (an edit that
	               ;# adds/removes lines without moving the view won't trip -yscrollcommand)
	hl_edit $g $p ;# the text changed — re-tokenise from the edit, incrementally (coalesced; D32)
	if {$::wrap_indent} {   ;# re-size the wrap indent for just the lines this edit touched
		set sl [lindex [split [dict get $p start] .] 0]
		set added [expr {[llength [split [dict get $p text] "\n"]] - 1}]
		wrapind_apply $t $sl [expr {$sl + $added}]
	}
	# An open find bar's matches just went stale — recount/repaint, coalesced
	# like the highlight pass so a run of keystrokes costs one update (D36).
	if {$::find_shown && !$::find_pending} {
		set ::find_pending 1
		after idle find_update
	}
}

# Load the active buffer's canonical text into the widget (on switch / open).
# Load group `g`'s active buffer text into its widget (bypassing the proxy) and
# repaint. Runs on open / tab switch within the group.
proc load_buffer {g} {
	set t [gw $g]
	set id [gcur $g]
	$t delete 1.0 end
	# Pull the document a chunk at a time rather than as one enormous reply (D126).
	# The channel was never the problem: tcllib's json2dict is quadratic in the
	# length of a single JSON string, so an 8 MB document cost ~1.9 s to PARSE and
	# ~0.26 s in 256 KB pieces. A document that fits in one chunk is still one round
	# trip, exactly as before. Chunks concatenate to the document byte for byte, so
	# they go in at end-1c — before the newline Tk keeps at the end of every widget.
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
	hl_select $g   ;# the file type may have changed with the buffer (D32)
	hl_reset $g    ;# repaint the visible window now and start the line-state cache (on switch/open)
	wrapind_group $g   ;# size the wrapped-line indents to this buffer's leading whitespace
	gutter_mark $g ;# the swapped-in buffer has its own line count — repaint the numbers
	               ;# (a same-height swap won't trip -yscrollcommand, so the old ones would linger)
}

# A buffer's whole text via the protocol (buffer.text), so the frontend never reads
# the core's document model directly — the one path that works the same in-process
# and remote (D29). "" on failure (a vanished buffer): callers only use
# this to test emptiness or seed a compare, where "" is a safe miss.
proc buf_text {id} {
	set resp [rio_call buffer.text [dict create buffer $id]]
	if {[dict get $resp ok]} { return [dict get $resp result text] }
	return ""
}

# ---------------------------------------------------------------------------
# Buffer / tab bookkeeping.
# ---------------------------------------------------------------------------
# Register a newly-opened buffer into group `g` (default: the focused group), at the
# end of its tab order. The core owns the text; ::buffers holds the per-buffer view
# facts, ::grp the group's tab order.
proc register_buffer {id path meta {g ""}} {
	if {$g eq ""} { set g $::focus }
	# gone_ack: "the user said to keep this buffer though the file is gone" (D94). It lives
	# here rather than in the core because a deleted file cannot be re-stamped core-side —
	# there is nothing to stat — and because it is exactly the kind of view-local answer
	# `modified` already is (D22). lang: the language picked by hand (D112) — "" detects
	# by file name, "plain" turns highlighting off, else a registered language name.
	dict set ::buffers $id \
		[dict create path $path meta $meta modified 0 cursor 1.0 yview 0.0 gone_ack 0 lang ""]
	gset $g order [linsert [gorder $g] end $id]
}

# Make `id` active and focus its group: stash the outgoing buffer's cursor/viewport,
# swap that group's widget to `id`, restore its cursor/viewport, and mark the group
# focused (::cur mirrors it). `g` defaults to whichever group already holds `id`
# (clicking a tab), falling back to the focused group.
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

# Drop a leftover empty, unsaved, untitled scratch buffer (so opening a file from
# a fresh launch reuses the slot instead of leaving a blank tab behind). Refresh
# the chrome if we dropped anything: close_buffer mutates a group's order but doesn't
# redraw, so a pruned tab would otherwise linger on screen, orphaned. Scans every
# buffer (across groups) — a scratch may sit in either.
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

# Adopt whatever buffers the core already has — its startup default in-process, or
# the server's open buffers in remote mode — via buffer.list, activating the first
# (D29). Replaces reaching into $::rio::ops::default, which exists only in
# the embedded core. If the core reports none, mint one so there is always a tab.
proc adopt_initial_buffers {} {
	set resp [rio_call buffer.list {}]
	set buffers [expr {[dict get $resp ok] ? [dict get $resp result buffers] : {}}]
	if {![llength $buffers]} { do_new ; return }
	foreach b $buffers {
		register_buffer [dict get $b buffer] [dict get $b path] {}
	}
	activate [dict get [lindex $buffers 0] buffer]
}

# `force` re-asks for a file the core declined as too large or binary (D125) — it is
# how the "Open it anyway?" answer travels, and is never passed by a caller directly.
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
		# too_large and binary_file are not failures but QUESTIONS (D125): the core
		# declined to read a file that would make rio crawl, and this is the asking.
		# The core's message states the fact; the frontend owns the question.
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
	# Opened against rio's advice: the highlighter is the other half of what makes a
	# huge buffer crawl, so such a buffer starts as Plain Text — D112's own `lang`
	# value, so *View ▸ Language…* turns it back on if the file proves fine.
	if {$force} { bufset $id lang plain }
	activate $id
	prune_scratch $id
	if {[dict get $res mixed]} {
		tk_messageBox -icon info -type ok -title rio \
			-message "Mixed line endings; the file will be saved as [dict get $res eol]."
	}
	session_save   ;# the open-file set changed — record it for resume (D31)
	# A recovery copy is waiting for this file (D132). The core reported the fact; the
	# question is ours (D125). During boot it is only NOTED: a session restore can reopen a
	# dozen files, and a dozen modals in a row is not an answer to anything — the same
	# reasoning stale_conflict already carries — so they are asked about together once
	# startup is done.
	if {[dict exists $res recovery] && [dict get $res recovery] ne ""} {
		if {$::rio_started} {
			recover_offer [list $id] [dict get $res recovery_newer]
		} else {
			lappend ::recover_pending [list $id $path [dict get $res recovery_newer]]
		}
	}
	return 1
}

# Offer to take back what autosave kept for these buffers (D132). ONE dialog for the whole
# set, like stale_conflict.
#
# `newer` picks the default button, and the rule is D94's: default to the choice that loses
# nothing. Recovering loses nothing either way — the file on disk is not touched and the
# recovery is one undo step — but when the copy is OLDER than the file, defaulting to "show
# me the older text" would be an odd thing to nod through, so that case defaults to No.
#
# Declining leaves the copy alone: it is not ours to delete on a shrug, and a save of that
# buffer will drop it anyway.
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
		# The buffer now differs from the file, and only a save may change that — so it is
		# modified, exactly as after any other edit.
		mark_buffer_modified $id 1
	}
	refresh_all
}

# Ask about everything boot queued, as one set. Split out from the boot sequence so the
# suite drives the same code a launch does, rather than a copy of it.
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

# Its own one-line proc so a headless test can stub it (the stale_ask idiom).
proc recover_ask {q newer} {
	return [tk_messageBox -icon warning -type yesno \
		-default [expr {$newer ? "yes" : "no"}] \
		-title "rio — unsaved changes were kept" -message $q]
}

# A file (or several, or a folder) dropped onto the window from the OS file manager (D86).
# tkdnd hands DND_Files as a ready-made Tcl list of local paths; we reuse the very same
# dir-vs-file dispatch the argv startup loop uses, then raise the window so the freshly
# opened buffer is in view. Only ever reached with a LOCAL core: drop targets register
# solely when !$::core_remote (a dropped path is local to this machine, which a remote core
# could not resolve), so the handler needs no remote guard of its own. The raise is skipped
# under the test harness — deiconify would un-withdraw the headless window.
proc dnd_open_files {paths} {
	foreach f $paths {
		if {[file isdirectory $f]} { open_folder $f } else { do_open $f }
	}
	if {[llength $paths] && ![info exists ::env(RIO_GUI_HEADLESS)]} {
		wm deiconify . ; raise . ; focus -force .
	}
}

# Re-sync the dock when rio regains OS input focus. The fs.changed auto-refresh (D47)
# only fires for writes rio's own core makes; this catches changes rio *didn't* make — a
# file created in a terminal, a `git pull`, a build artifact — at the moment the user
# alt-tabs back. One refresh_dock per app-return, not a poll, so it stays cheap.
#
# Tk delivers FocusIn/FocusOut on the toplevel for internal widget-to-widget moves too,
# so we debounce onto an idle callback and then consult `focus -displayof` — empty exactly
# when another application holds focus. A within-app move leaves it non-empty, so only a
# genuine app-level return flips the flag and refreshes.
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
# The testable core: act on a settled focus state. A false→true edge (the app regained
# focus) re-syncs the dock; within-app churn and focus loss only record the flag. Guarded
# on a live core so a refresh never runs while disconnected.
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
# Two triggers, and between them they cover both kinds of change. fs.changed is the write
# rio's own core made — an agent's fs.write, a discard, a rename; regaining OS focus is
# everything rio did NOT do — a `git pull`, a build, an editor in another window. Same as
# the file pane's two triggers (D47), and for the same reason: rio does not watch the
# filesystem, so these are the two moments it can honestly re-ask.
#
# The DETECTION is core-side (buffers.stale): over a remote core the file is on the
# server, so a GUI-side [file mtime] would answer about the wrong machine (D29). The GUI
# decides only what to DO about it, because that turns on `modified` — view-local state
# the core does not have (D22).
#
# Three outcomes, one rule behind the wording: the default button is whichever choice
# loses nothing.
#   clean, still there  -> reload silently. There is nothing to lose and nothing to ask.
#   modified, changed   -> ASK. Reloading would throw away unsaved edits, so No is the
#                          default, and No re-stamps ("I have seen this") so the same
#                          conflict is not raised again on every focus return.
#   gone from disk      -> ASK, Notepad++'s question: keep it in the editor? Yes is the
#                          default (it is the only copy left) and marks the buffer
#                          modified, so a later Save recreates the file.
proc check_stale_buffers {} {
	# A modal runs the event loop, so a second trigger can arrive while one is up.
	if {$::stale_checking} return
	# And never ask in the middle of another op's round trip. Both triggers can land
	# there — a settled fs.changed burst, or an idle focus callback firing inside a
	# vwait — and the op still in flight may be the very thing that settles these
	# buffers: fs_apply_delete closes the tabs of the file it just deleted, right after
	# the op returns. Asking first would report rio's own deliberate change as a surprise
	# ("deleted on disk, keep it?" about a file the user just chose to delete). One
	# pending retry at a time, so repeated triggers don't stack up callbacks.
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

# Take the new text for these buffers — one op for the whole set, because a discard-all
# or a `git pull` stales many tabs at once and a round trip per tab over a socket is the
# cost D93 went to git to avoid. The TEXT needs no work here: the core emits one
# buffer.changed per buffer and dispatch_event already applies that to whichever group
# shows it — and the events land before this reply, so by the time we set the flags the
# text is already on screen.
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

# The unsaved-edits conflict. ONE dialog for the whole set: discard-all can stale every
# open tab, and twelve modals in a row is not an answer to anything.
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
		# "I have seen this version" — so the same change is not raised again every time
		# rio regains focus. A LATER change stales it again, which is right: that is a
		# version they have not seen.
		rio_call buffers.stamp [dict create buffers $ids]
	}
}

# The file is gone. jka's call, and Notepad++'s shape: ask rather than decide. Keeping it
# marks the buffer modified — the text now exists only here, so Save must offer to write
# it back, which is exactly how the file gets recreated.
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

# The two prompts, each in its own one-line proc so a headless test can stub them — the
# idiom split.tcl already uses for maybe_discard. They differ only in their default
# button, and that difference is the whole rule: default to the choice that loses nothing.
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

# Close the active buffer of the focused group; guard unsaved changes. If this empties
# one of two groups, the group collapses (unsplit); the sole group instead keeps at
# least one tab by minting a scratch (D33).
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
# Close any tab (the × button): activate it in its group first so a discard prompt is
# in context and do_close acts on the right group.
proc close_tab {id {g ""}} { activate $id $g ; do_close }

proc cycle {dir} {
	set g $::focus
	set order [gorder $g]
	if {[llength $order] < 2} return
	set i [lsearch -exact $order $::cur]
	activate [lindex $order [expr {($i + $dir) % [llength $order]}]] $g
}

# Returns 1 if it is safe to close the active buffer. On a modified buffer we ask
# to save (Yes), not to discard: Yes saves then closes (abort if the save fails),
# No closes without saving, Cancel keeps the buffer open.
proc maybe_discard {} {
	if {![bufget $::cur modified]} { return 1 }
	switch -- [tk_messageBox -icon question -type yesnocancel -default yes -title rio \
			-message "[tab_name $::cur] has unsaved changes. Save before closing?"] {
		yes    { return [do_save] }
		no     { return 1 }
		cancel { return 0 }
	}
}
# The user has just declined to save these, and the core holding them is about to go: their
# recovery copies are spent, so drop them before the channel closes (D132).
#
# Without this, "don't save" would not stick. Quitting does NOT close the buffers — it asks
# about each one and goes — so the copies would survive, and the next launch would restore
# those files (D31) and offer back the very edits just declined. Answering a question twice,
# the second time a day later, is not what No means.
#
# Only with a core of OUR OWN. A daemon KEEPS those modified buffers for the next frontend
# (D30), so there nothing has been abandoned and the copy is still exactly what a crash would
# need — dropping it would take away protection from work that is still live.
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
	# Close the channel so a spawned child core sees EOF on stdin and exits with us
	# (a daemon socket just drops the connection); then go.
	catch {close $::core_chan}
	exit 0
}
