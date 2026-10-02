# rio-gui/link.tcl — the one seam to the core: calls, events, the watchdog, reconnecting.
# A part of the GUI, sourced by rio-gui.tcl; not run on its own.

# ---------------------------------------------------------------------------
# The single seam to the core (D2/D30). One op call, one response; any
# events the op produced arrive asynchronously on the channel and are fed to
# dispatch_event. The core is always at the far end of ::core_chan (a pipe to a
# spawned core, or a daemon socket) — there is no in-process path, so local and
# remote are the same code.
# ---------------------------------------------------------------------------
proc rio_call {op params {timeout_ms 0}} {
	return [core_call $op $params $timeout_ms]
}

# Apply one core event to the view. Every event the core broadcasts arrives here
# over the channel (D30) — including the agent's live stream (D26): an agent turn
# is now ordinary broadcast traffic, so agent.* events route to the chat transcript
# and a turn's approved-edit buffer.changed lands in the same buffer.changed case.
# buffer.changed redraws whichever editor group is showing the changed buffer (D33):
# an edit — a keystroke echo or an agent edit — lands in the group displaying that
# buffer, even if it is not the focused one. A buffer no group shows (closed, or
# never opened here) is ignored safely; it reloads from the core when next activated.
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

# A file appeared or changed on disk outside the editor's own save — an agent fs.write
# (D26), which is not backed by an open buffer so no buffer.changed fires (D47). Repaint
# the dock so the new file, and any git-status shift, shows without a manual reload. The
# files pane is a tree from the project root (D87), so it repaints when the change lands in
# a directory currently on screen (the root or an unfolded dir — nav_dir_visible); the git
# pane's status is project-wide, so it always repaints.
# The user's own Save needs nothing here: it refreshes locally via do_save and goes
# through file.save, which emits no fs.changed — so there is no double repaint.
# One op can announce many changed paths in one go — a discard-all rewrites every changed
# file (D94), a rename announces both ends. A repaint is itself a nested core call, so
# repainting per event would cost one round trip PER PATH — the very N-round-trip price D93
# went to git to avoid. So collect the paths and repaint ONCE, a beat later.
# A *timer*, not `after idle`: core_reader takes one line per readable event, and Tcl runs
# idle handlers between two of those, so an idle callback splits a burst instead of
# coalescing it (measured: 2 repaints for 3 paths). The delay has to clear the gap a socket
# can put between two lines of the SAME burst — a delayed ACK inserts ~40ms, which is what
# a 25ms window kept tripping over — while staying under the eye's notice.
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
	# Never land in the middle of another op's round trip: a repaint is itself a core call,
	# and nesting one inside another's vwait buys nothing — the op in flight may well
	# change what we would paint. Re-arm and land between ops. (check_stale_buffers below
	# defers for its own, sharper reason.)
	if {[array size ::pending]} {
		set ::fs_changed_after [after $::fs_changed_delay fs_changed_settle]
		return
	}
	set paths $::fs_changed_paths
	set ::fs_changed_paths {}
	set ::fs_changed_after ""
	# An open tab may be looking at one of those paths (D94). Asked once for the whole
	# burst, and before the repaint, so a reload's own buffer.changed events are applied
	# while the pane work is still ahead of us rather than interleaved with it.
	check_stale_buffers
	if {$::dock_pane eq "git"} {
		refresh_git
		return
	}
	if {$::nav_root eq ""} return
	# Compare the core's paths as strings: both sides came FROM the core, already
	# normalized there, so a client-side [file normalize] adds nothing — and on a
	# Windows client against a POSIX core it rewrites "/home/jka" to "C:/home/jka".
	# It matched only because both operands were mangled identically.
	foreach path $paths {
		if {[nav_dir_visible [file dirname $path]]} { populate_nav ; return }
	}
}

# An op call over the channel: write {id, op, params} as one JSON line (the same
# escaping the server replies with, rio::wire), then run the event loop until the
# reply with our id lands. Ids are unique per call, so a keystroke typed while we
# wait — itself a nested rio_call — resolves on its own id without disturbing this one.
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
	# A half-open link (a stale `ssh -L` forward: the socket is up, but nothing answers
	# and no EOF ever arrives) would leave this vwait blocked forever. An optional
	# deadline lets the caller bound the first exchange: on expiry we synthesise a
	# `timeout` reply so the vwait returns and the caller can report it, not hang.
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

# The channel reader: each line is either an event — dispatched to the view at once —
# or a reply, handed to the rio_call waiting on its id. Junk lines are ignored; EOF
# means the core went away (a crashed child, or a dropped daemon).
proc core_reader {} {
	if {[catch {gets $::core_chan line} n]} { core_lost ; return }
	if {$n < 0} { if {[eof $::core_chan]} { core_lost } ; return }
	set ::last_rx [clock milliseconds] ;# any received line proves the link alive (D37)
	if {[string trim $line] eq ""} return
	if {[catch {json::json2dict $line} msg]} return
	if {[dict exists $msg event]} {
		dispatch_event $msg
	} elseif {[dict exists $msg id]} {
		# Only wake a call still waiting: a reply arriving after its call already
		# timed out (see core_call) is dropped, not left as a stale ::reply entry.
		set id [dict get $msg id]
		if {[info exists ::pending($id)]} { set ::reply($id) $msg }
	}
}

# The channel closed (`eof`) — or the watchdog below declared it dead (`stale`).
# Report it once, stop reading, and wake any call blocked on a reply (with a
# disconnected error) so the GUI never hangs. The editor stays up so nothing in
# view is lost; further ops fail fast through core_call.
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
# Stale-link watchdog (D37). A half-open socket — the classic stale
# `ssh -L` forward — accepts writes and never EOFs, so without this the GUI only
# learns the link is dead when TCP gives up, minutes later. hello_core already
# bounds the FIRST exchange for exactly that reason; this extends the same idea
# to the whole session, purely at the protocol layer (`after` timers + one cheap
# op — no socket options, no keepalive). Armed only for a socket-attached core:
# a spawned child is a pipe, and a pipe delivers EOF the moment the core dies.
# Every watch_interval it checks, in order:
#   1. a reply pending longer than reply_overdue — no op legitimately waits that
#      long (streaming ops ack at once and stream as events), so the link is dead;
#   2. nothing pending and nothing received for a full interval — probe with a
#      bounded session.hello; only a `timeout` counts (a write failure already
#      went through core_lost inside core_call).
# The thresholds are globals so the headless suite can shrink them. reply_overdue
# is generous on purpose: the core is single-threaded and a big reply on a slow
# tunnel counts its transfer time.
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

# Surface a core error to the user (the {code, message} taxonomy, ADR-0113).
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

# The wire protocol version this GUI speaks (D123: the integer
# session.hello reports; it bumps on a breaking change). Checked against every
# core we attach to — a spawned child can't realistically mismatch (same repo),
# but a daemon reached over --connect or an in-place reconnect (D30) can be any
# age, and a version skew otherwise surfaces as ops quietly misparsing.
set ::rio_protocol  2
set ::core_protocol ""   ;# what the attached core reported (for the title of a bug report)

# The RELEASE version of the attached core (its session.hello `version`, D123). Distinct
# from $rio::version, which is THIS checkout's: a spawned core is always the same tree,
# but one reached over --connect can be any build, and then the two differ and About says
# so. "" for a core too old to report it — the D19 rule, so absence is a fallback, never
# an error.
set ::core_version ""

# The root of the CORE's filesystem, from its session.hello (re-read on reconnect).
# The GUI must not compute this: it browses the core's disk (D30), and the core may be
# a different platform — "/" is right for a POSIX core and unlistable on a Windows one.
# "/" is only the pre-greeting default and the fallback for a core too old to say.
set ::core_fsroot "/"

# Greet the core (session.hello) and warn once if it speaks a different protocol.
# Runs as the FIRST op on a live channel — at startup and after an in-place reconnect
# — so it doubles as the liveness gate: socket(2) to a stale `ssh -L` forward succeeds
# with nothing behind it, and an unbounded op would then hang on a blank window. We
# bound the greeting (8 s); if the core never answers we say why instead of freezing.
# `fatal` (startup) exits after the message — there's nothing to fall back to; reconnect
# leaves the old session up. Returns 1 if the core greeted us, 0 otherwise.
proc hello_core {{fatal 0}} {
	set resp [rio_call session.hello {} 8000]
	if {![dict get $resp ok]} {
		set code [dict get $resp error code]
		if {$::core_remote} {
			set msg [expr {$code eq "timeout" \
				? "Connected to $::core_endpoint, but no rio core answered.\n\nThe socket opened — most likely a stale SSH tunnel, or no core is running behind it. Check that the tunnel is still up (ssh -L …) and a core is listening on the server." \
				: "The core didn't answer session.hello: [dict get $resp error message]"}]
		} else {
			# A SPAWNED core that never greets did not survive its own start-up — it
			# exited (an `eof`, so `disconnected`) or wedged before the handshake. The
			# generic "lost the connection" told the user nothing they could act on,
			# and the child's stderr goes to a console that `wish` on Windows does not
			# have. So hand them the command: run it themselves and the core's own
			# complaint — a missing package, most often — is right there. (Capturing
			# the child's stderr into the dialog was weighed and refused: it would put
			# a temp file and its lifecycle on the spawn path that runs every start.)
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
	# Additive since protocol 2, so a core that predates it simply omits the key and we
	# keep the POSIX default rather than treating its absence as an error.
	if {[dict exists $resp result fsroot] && [dict get $resp result fsroot] ne ""} {
		set ::core_fsroot [dict get $resp result fsroot]
	}
	# The core's release version (D123), additive on the same terms — a core that predates
	# it omits the key and About simply has nothing extra to say. Re-read on every greeting,
	# so a reconnect to a DIFFERENT core replaces it rather than keeping a stale claim.
	set ::core_version [expr {[dict exists $resp result version] \
		? [dict get $resp result version] : ""}]
	if {$::core_protocol ne $::rio_protocol} {
		report_error "This core speaks wire protocol $::core_protocol, but this GUI expects $::rio_protocol — mixed versions may misbehave. Update the older side." protocol_mismatch
	}
	return 1
}

# ---------------------------------------------------------------------------
# Connect to a remote (listening) rio-core over a socket — the daemon mode of the
# one channel transport (D30). The core there is loopback-bound, so this
# is normally the local end of an `ssh -L` tunnel. Reached from File ▸ Connect to
# Remote Core…. By default THIS window rewires to the remote core; ticking "Open in
# a new window" launches a second rio-gui instead, leaving this session untouched.
# ---------------------------------------------------------------------------

# Validate a "host:port" string. Returns {host port}, or "" if malformed (same rule
# the --connect startup path uses).
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

# Rewire THIS window to a remote core. Order is chosen for safety: open the new
# socket FIRST, then save-check the outgoing tabs — only once both succeed do we
# drop the current (local) core and swap. A failure or a cancel at either earlier
# step leaves the existing session fully intact.
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

# Reset all per-session view state and rebuild from whatever core ::core_chan now
# points at (used after an in-place reconnect). Mirrors the startup tail: the new
# core owns its own buffers, project, and conversation, so we forget ours and adopt.
proc reset_session_state {} {
	if {$::compare_shown} { compare_close }
	catch {pack forget .chat.approve}
	set ::pending_turn ""
	set ::chat_turn_open 0 ; set ::chat_thinking_open 0
	# Collapse any split back to a single group — the new core is a fresh session — then
	# forget the old buffers/tabs and blank the surviving group; the new core has its own.
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
	# Rebuild exactly as at startup. hello_core also gates liveness (bounded): if the
	# new core is silent (a stale tunnel), it has already told the user — stop here
	# rather than hang the next op, leaving a blank-but-responsive session to retry.
	if {![hello_core]} return    ;# a daemon can be any age — check protocol + reachability
	adopt_initial_buffers
	show_pane $::dock_pane
	apply_wrap
	adopt_agent_status           ;# take the new core's provider/auto-accept, don't reset it
	refresh_all
}
