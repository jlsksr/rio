# rio-gui/link.tcl — the one seam to the core: calls, events, the watchdog, reconnecting.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The one way to the core (D2, D30): one op call, one response. Events arrive
# on the channel by themselves and go to dispatch_event. The core is at the
# far end of ::core_chan, a pipe or a socket.
# ---------------------------------------------------------------------------
proc rio_call {op params {timeout_ms 0}} {
	return [core_call $op $params $timeout_ms]
}

# Apply one core event to the view.
#   agent.*          the chat
#   buffer.changed   the editor group showing that buffer, focused or not
#                    (D33); ignored if no group shows it
#   project.opened, fs.changed   the panes
proc dispatch_event {ev} {
	set name [dict get $ev event]
	if {[string match agent.* $name]} { chat_event $ev ; return }
	switch -- $name {
		buffer.changed {
			set p [dict get $ev params]
			set g [group_of [dict get $p buffer]]
			if {$g ne ""} { apply_change $g $p }
		}
		project.opened { on_project_opened [dict get $ev params] }
		fs.changed     { on_fs_changed [dict get $ev params] }
	}
}

# fs.changed (D47): a file changed on disk outside a save, e.g. an agent
# write or a git discard. Repaint the dock.
# - The files pane repaints if the path's directory is on screen
#   (nav_dir_visible); the git pane always.
# - The user's Save emits no fs.changed; do_save refreshes by itself.
# - One op can announce many paths (D94), and a repaint is a core call. So
#   the paths are collected and painted once, after ::fs_changed_delay.
# - A timer, not `after idle`: idle handlers run between two lines of one
#   burst and would split it. 60 ms clears a socket's ~40 ms delayed ACK.
set ::fs_changed_paths {}   ;# paths announced since the last repaint
set ::fs_changed_after  ""  ;# pending repaint timer; "" while none is armed
set ::fs_changed_delay  60  ;# ms; > a socket's ~40ms delayed-ACK gap, < a noticeable lag
set ::stale_checking    0   ;# a stale check is running (its modals run the event loop)
set ::stale_retry       ""  ;# a deferred stale check, waiting for the channel to go quiet
proc on_fs_changed {p} {
	if {![dict exists $p path]} return
	lappend ::fs_changed_paths [dict get $p path]
	if {$::fs_changed_after eq ""} {
		set ::fs_changed_after [after $::fs_changed_delay fs_changed_settle]
	}
}
proc fs_changed_settle {} {
	# Not inside another op's round trip: the op in flight may change what
	# would be painted. Try again later.
	if {[array size ::pending]} {
		set ::fs_changed_after [after $::fs_changed_delay fs_changed_settle]
		return
	}
	set paths $::fs_changed_paths
	set ::fs_changed_paths {}
	set ::fs_changed_after ""
	# An open tab may show one of those paths (D94): check once for the
	# burst, before the repaint.
	check_stale_buffers
	if {$::dock_pane eq "git"} {
		refresh_git
		return
	}
	if {$::nav_root eq ""} return
	# Compare the core's paths as strings. [file normalize] here would turn
	# a POSIX core's "/home/x" into "C:/home/x" on a Windows client.
	foreach path $paths {
		if {[nav_dir_visible [file dirname $path]]} { populate_nav ; return }
	}
}

# One op call: write {id, op, params} as a JSON line, then run the event loop
# until the reply with that id arrives. Ids are unique, so a call made while
# this one waits (a keystroke) resolves on its own.
proc core_call {op params {timeout_ms 0}} {
	set id r[incr ::reply_seq]
	set ::pending($id) [clock milliseconds] ;# when it was sent — watch_tick ages it (D37)
	if {[catch {
		puts $::core_chan "{\"id\":[rio::wire::str $id],\"op\":[rio::wire::str $op],\"params\":[rio::wire::obj $params]}"
		flush $::core_chan
	}]} {
		unset -nocomplain ::pending($id)
		core_lost
		return [dict create id $id ok false \
			error [dict create code disconnected message "no connection to the core"]]
	}
	# A half-open link (a stale `ssh -L` forward) never answers and never
	# closes. With a deadline, a `timeout` reply is made up so the vwait ends.
	set timer ""
	if {$timeout_ms > 0} {
		set timer [after $timeout_ms [list set ::reply($id) [dict create id $id ok false \
			error [dict create code timeout message "the core did not respond in time"]]]]
	}
	vwait ::reply($id)
	if {$timer ne ""} { after cancel $timer }
	unset -nocomplain ::pending($id)
	set resp $::reply($id)
	unset ::reply($id)
	return $resp
}

# The channel reader. A line is an event, dispatched at once, or a reply for
# the call waiting on its id. Junk is ignored. EOF: the core is gone.
proc core_reader {} {
	if {[catch {gets $::core_chan line} n]} { core_lost ; return }
	if {$n < 0} { if {[eof $::core_chan]} { core_lost } ; return }
	set ::last_rx [clock milliseconds] ;# any received line proves the link alive (D37)
	if {[string trim $line] eq ""} return
	if {[catch {json::json2dict $line} msg]} return
	if {[dict exists $msg event]} {
		dispatch_event $msg
	} elseif {[dict exists $msg id]} {
		# A reply for a call that already timed out is dropped.
		set id [dict get $msg id]
		if {[info exists ::pending($id)]} { set ::reply($id) $msg }
	}
}

# The channel closed (`eof`) or the watchdog declared it dead (`stale`).
# Report it once, stop reading, and wake every waiting call with a
# `disconnected` error. The editor stays up; later ops fail at once.
proc core_lost {{why eof}} {
	if {![info exists ::core_chan]} return
	watch_stop
	catch {fileevent $::core_chan readable {}}
	catch {close $::core_chan}
	unset -nocomplain ::core_chan
	foreach id [array names ::pending] {
		set ::reply($id) [dict create id $id ok false \
			error [dict create code disconnected message "lost the connection to the core"]]
	}
	if {$why eq "stale"} {
		report_error "The link to the core at $::core_endpoint went stale — the socket is open but nothing answers (usually a dropped SSH tunnel).\n\nRe-establish the tunnel, then reconnect via File ▸ Connect to Remote Core…" disconnected
	} else {
		report_error "Lost the connection to the core (it exited or the link dropped)." disconnected
	}
}

# ---------------------------------------------------------------------------
# The stale-link watchdog (D37). A half-open socket accepts writes and never
# closes, so the GUI would learn of a dead link minutes later. For a socket
# only: a pipe reports EOF when the core dies. Timers and one cheap op; no
# socket options.
# Every watch_interval, in order:
#   1. A reply pending longer than reply_overdue: the link is dead.
#   2. Nothing pending and nothing received for an interval: probe with
#      session.hello and a timeout. Only a `timeout` counts.
# The thresholds are globals so a test can shrink them. reply_overdue is
# generous: a big reply over a slow tunnel takes time.
set ::watch_interval 10000 ;# ms between checks
set ::reply_overdue  25000 ;# a reply pending longer than this means a dead link
set ::ping_timeout    8000 ;# bound on the idle probe (same as hello_core's greeting)
set ::watch_timer ""       ;# pending `after` id; "" while disarmed
set ::last_rx 0            ;# [clock milliseconds] of the last line core_reader saw

proc watch_start {} {
	watch_stop
	set ::last_rx [clock milliseconds]
	set ::watch_timer [after $::watch_interval watch_tick]
}
proc watch_stop {} {
	if {$::watch_timer ne ""} { after cancel $::watch_timer ; set ::watch_timer "" }
}
proc watch_tick {} {
	set ::watch_timer ""
	if {![info exists ::core_chan]} return
	set now [clock milliseconds]
	foreach id [array names ::pending] {
		if {$now - $::pending($id) > $::reply_overdue} { core_lost stale ; return }
	}
	if {[array size ::pending] == 0 && $now - $::last_rx >= $::watch_interval} {
		set resp [core_call session.hello {} $::ping_timeout]
		if {![dict get $resp ok] && [dict get $resp error code] eq "timeout"} {
			core_lost stale ; return
		}
	}
	if {[info exists ::core_chan]} {
		set ::watch_timer [after $::watch_interval watch_tick]
	}
}

# Show a core error {code, message} (ADR-0113). One proc, so a test can
# override it to capture errors.
proc report_error {message {code ""}} {
	tk_messageBox -icon error -type ok -title rio \
		-message [expr {$code eq "" ? $message : "$message  ($code)"}]
}

# Run an op expected to succeed and return its result, or "" after showing
# the error. For calls like new and undo. None of them returns "" on success.
proc rio_result {op params} {
	set resp [rio_call $op $params]
	if {[dict get $resp ok]} { return [dict get $resp result] }
	set e [dict get $resp error]
	report_error [dict get $e message] [dict get $e code]
	return ""
}

# The protocol version this GUI speaks (D123). Checked against every core it
# attaches to: a daemon reached with --connect can be any age.
set ::rio_protocol  2
set ::core_protocol ""   ;# what the attached core reported (for the title of a bug report)

# The attached core's release version (D123), for About. "" for a core too
# old to report it.
set ::core_version ""

# The root of the core's filesystem, from session.hello. The GUI browses the
# core's disk (D30) and must not guess it. "/" until the greeting.
set ::core_fsroot "/"

# Greet the core and warn if it speaks another protocol. The first op on a
# channel, with an 8 s timeout: a stale `ssh -L` forward accepts the socket
# and never answers. `fatal` (startup) exits after the message. Returns 1 if
# the core answered.
proc hello_core {{fatal 0}} {
	set resp [rio_call session.hello {} 8000]
	if {![dict get $resp ok]} {
		set code [dict get $resp error code]
		if {$::core_remote} {
			set msg [expr {$code eq "timeout" \
				? "Connected to $::core_endpoint, but no rio core answered.\n\nThe socket opened — most likely a stale SSH tunnel, or no core is running behind it. Check that the tunnel is still up (ssh -L …) and a core is listening on the server." \
				: "The core didn't answer session.hello: [dict get $resp error message]"}]
		} else {
			# A spawned core that never greets died at start-up. Give the user
			# the command: run by hand, it prints why.
			set msg "rio could not start its core.\n\nThe core exited or stopped\
				responding while starting up. To see why, run it by hand:\n\n \
				[join $::core_cmd { }]\n\nA missing dependency is the usual cause —\
				see INSTALL.md §1."
		}
		if {$fatal} { catch {wm withdraw .} ; report_error $msg $code ; exit 1 }
		report_error $msg $code
		return 0
	}
	set ::core_protocol [dict get $resp result protocol]
	# An older core omits fsroot and version: keep the defaults.
	if {[dict exists $resp result fsroot] && [dict get $resp result fsroot] ne ""} {
		set ::core_fsroot [dict get $resp result fsroot]
	}
	set ::core_version [expr {[dict exists $resp result version] \
		? [dict get $resp result version] : ""}]
	if {$::core_protocol ne $::rio_protocol} {
		report_error "This core speaks wire protocol $::core_protocol, but this GUI expects $::rio_protocol — mixed versions may misbehave. Update the older side." protocol_mismatch
	}
	return 1
}

# ---------------------------------------------------------------------------
# File ▸ Connect to Remote Core…: attach to a listening core over a socket
# (D30), normally the local end of an `ssh -L` tunnel. This window switches
# to that core, or "Open in a new window" starts a second rio-gui.
# ---------------------------------------------------------------------------

# "host:port" -> {host port}, or "" if malformed.
proc parse_endpoint {hp} {
	lassign [split $hp :] host port
	if {$host eq "" || ![string is integer -strict $port]} { return "" }
	return [list $host $port]
}

# The endpoint prompt: a host:port entry + an "open in a new window" checkbox.
# Returns {hostport newwin}, or "" if cancelled. A themed modal like the others.
proc connect_remote_dialog {} {
	set w .connd
	destroy $w
	toplevel $w
	wm title $w "Connect to remote core"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.prompt -anchor w -font RioUIFont -text "Remote core address (host:port):" \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	entry $w.e -width 40 -font RioUIFont
	ctx_bind_input $w.e   ;# (D115)
	$w.e insert end [expr {$::last_connect ne "" ? $::last_connect : "127.0.0.1:7711"}]
	set ::connd_new 0
	checkbutton $w.new -text "Open in a new window (keep this session)" \
		-variable ::connd_new -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-activebackground [dict get $c ui.bg] -selectcolor [dict get $c ui.bg]
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.ok     -text Connect -font RioUIFont \
		-command {set ::connd_result [list [.connd.e get] $::connd_new] ; destroy .connd}
	button $w.btns.cancel -text Cancel  -font RioUIFont \
		-command {set ::connd_result "" ; destroy .connd}
	pack $w.btns.cancel $w.btns.ok -side right -padx 3
	grid $w.prompt -row 0 -column 0 -sticky we -padx 8 -pady {8 2}
	grid $w.e      -row 1 -column 0 -sticky we -padx 8
	grid $w.new    -row 2 -column 0 -sticky w  -padx 8 -pady {4 0}
	grid $w.btns   -row 3 -column 0 -sticky e  -padx 5 -pady {2 8}
	bind $w.e <Return> {set ::connd_result [list [.connd.e get] $::connd_new] ; destroy .connd}
	bind $w <Escape>   {set ::connd_result "" ; destroy .connd}
	set ::connd_result ""
	catch {grab $w}
	focus $w.e
	tkwait window $w
	if {$::connd_result eq ""} return
	lassign $::connd_result hp newwin
	if {[parse_endpoint $hp] eq ""} {
		report_error "Expected host:port, e.g. 127.0.0.1:7711 — got '$hp'." bad_request
		return
	}
	if {$newwin} { spawn_remote_window $hp } else { reconnect_remote $hp }
}

# Launch a second rio-gui already attached to the remote core (reuses the --connect
# startup path). This session is left running and untouched.
proc spawn_remote_window {hp} {
	set ::last_connect $hp
	if {[catch {exec [info nameofexecutable] $::rio_self --connect $hp &} err]} {
		report_error "Could not launch a new window: $err"
	}
}

# Switch this window to a remote core. In this order, so a failure or a
# cancel leaves the session as it was: open the new socket, ask about unsaved
# tabs, and only then drop the old core.
proc reconnect_remote {hp} {
	lassign [parse_endpoint $hp] host port
	# 1. Open the new channel first, so a failed connect never costs us the core.
	if {[catch {socket $host $port} newchan]} {
		report_error "Cannot reach a rio core at $hp.\nIs one listening there — and, if it's remote, is the SSH tunnel up?" disconnected
		return
	}
	# 2. Offer to save unsaved work on the outgoing session; Cancel aborts cleanly.
	foreach id [dict keys $::buffers] {
		if {[bufget $id modified]} {
			activate $id
			if {![maybe_discard]} { catch {close $newchan} ; return }
		}
	}
	autosave_abandon   ;# same as at quit: the outgoing core is about to go (D132)
	# 3. Commit: drop the old channel (a spawned child core sees EOF and exits), swap.
	catch {fileevent $::core_chan readable {}}
	catch {close $::core_chan}
	set ::core_chan $newchan
	set ::core_remote 1
	set ::core_endpoint $hp
	set ::last_connect $hp
	fconfigure $::core_chan -buffering line -blocking 0 -translation lf -encoding utf-8
	fileevent $::core_chan readable core_reader
	watch_start ;# a fresh socket link — re-arm the stale-link watchdog (D37)
	reset_session_state
}

# After a reconnect: forget the view state and adopt the new core's buffers,
# project and conversation, as at startup.
proc reset_session_state {} {
	if {$::compare_shown} { compare_close }
	catch {pack forget .chat.approve}
	set ::pending_turn ""
	set ::chat_turn_open 0 ; set ::chat_thinking_open 0
	# Back to one editor group, emptied.
	while {[llength $::groups] > 1} {
		set g [lindex $::groups end]
		set ::groups [lrange $::groups 0 end-1]
		destroy_editor_group $g
	}
	relayout_groups
	set ::focus [lindex $::groups 0]
	set ::buffers {}
	gset $::focus order {} ; gset $::focus cur ""
	[gw $::focus] delete 1.0 end
	set ::cur ""
	# Project/panes: the new core starts with no folder open unless it reports one.
	set ::nav_root ""
	set ::nav_expanded [dict create]
	rl_reset .pfiles.well.body
	rl_reset .pgit.well.body
	# A different core means a fresh conversation — clear the transcript.
	.chat.log configure -state normal
	.chat.log delete 1.0 end
	.chat.log configure -state disabled
	# Rebuild as at startup. If the new core is silent, hello_core has said
	# so: stop here.
	if {![hello_core]} return    ;# a daemon can be any age — check protocol + reachability
	adopt_initial_buffers
	show_pane $::dock_pane
	apply_wrap
	adopt_agent_status           ;# take the new core's provider/auto-accept, don't reset it
	refresh_all
}
