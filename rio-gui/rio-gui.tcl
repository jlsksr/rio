#!/usr/bin/env wish
#
# rio-gui — the Tk frontend (AGENTS.md D1). A *thin view* (D3): it never edits
# its own text widget. Keystrokes become buffer.replace requests; the widget only
# changes when the core echoes a buffer.changed event back. Open/save go through
# the fs.* ops, undo/redo through edit.*, and buffers (tabs) through buffer.new /
# buffer.close. The frontend is ALWAYS a client to a core at the far end of a
# channel (D30): by default it spawns a private core as a child and talks over its
# stdio pipe; --connect attaches to a listening core over a socket. There is no
# in-process path — local and remote are the same code — so the only way text
# appears on screen is the core's own change event, arriving over the channel.
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

# ---------------------------------------------------------------------------
# Transport (AGENTS.md D30): the GUI is ALWAYS a client to a core at the far end of
# a channel — it never embeds the core. Two channel kinds, one client code path:
#   default        spawn a private core as a child and talk over its stdio pipe.
#                  Local: its filesystem is ours, and its agent runs as us (D30).
#                  No listening socket ⇒ nothing on a shared host to connect to.
#   --connect h:p  attach to a listening core over TCP — the optional daemon mode
#                  (D29). Its filesystem may be elsewhere (e.g. SSH-forwarded), so
#                  file access goes through typed server-side paths (::core_remote).
# A test may pre-set ::connect_to (a host:port) to attach to an in-process server.
# Only the wire encoder is sourced here (Tk-free); the core lives in its own process.
# ---------------------------------------------------------------------------
set ::rio_dir [file dirname [info script]]
set ::rio_self [file normalize [info script]]   ;# this script, for spawning a new window
source [file join $::rio_dir .. rio-core wire.tcl]
source [file join $::rio_dir .. rio-core conf.tcl]  ;# repository manifests are conf DATA (D21/D39)

set ::core_endpoint "" ;# host:port when attached to a daemon (remote); "" when local (D30)
set ::last_connect  "" ;# last host:port typed into "Connect to Remote Core…" (dialog seed)

if {![info exists ::connect_to]} { set ::connect_to "" }
set ci [lsearch -exact $argv --connect]
if {$ci >= 0} {
	set ::connect_to [lindex $argv [expr {$ci + 1}]]
	set argv [lreplace $argv $ci [expr {$ci + 1}]]   ;# don't treat it as a file arg
}
if {$::connect_to eq "" && [info exists ::env(RIO_CONNECT)]} {
	set ::connect_to $::env(RIO_CONNECT)
}

set ::reply_seq 0
if {$::connect_to ne ""} {
	# Attach to a listening core (daemon mode). Its filesystem may not be ours.
	set ::core_remote 1
	lassign [split $::connect_to :] host port
	if {$host eq "" || ![string is integer -strict $port]} {
		puts stderr "rio-gui: --connect expects host:port, got '$::connect_to'"
		exit 2
	}
	# A failed connect must not dump a Tcl stack trace: usually the core isn't running,
	# or — for a remote daemon, loopback-bound (D29) — there's no SSH tunnel yet.
	if {[catch {socket $host $port} ::core_chan]} {
		puts stderr "rio-gui: cannot reach a rio core at $::connect_to ($::core_chan)."
		puts stderr "  • Is a core listening there?     tclsh rio-core/server.tcl $port"
		puts stderr "  • If it's remote, tunnel first:  ssh -L $port:127.0.0.1:$port <server>"
		exit 1
	}
	set ::core_endpoint $::connect_to
	set ::last_connect  $::connect_to
} else {
	# Default: spawn a private local core and talk over its stdio (D30). We run under
	# wish, so find a Tk-free tclsh — in PATH, else one beside our own interpreter.
	set ::core_remote 0
	set _tclsh [lindex [auto_execok tclsh] 0]
	if {$_tclsh eq ""} {
		set _me [info nameofexecutable]
		set _g [file join [file dirname $_me] [string map {wish tclsh} [file tail $_me]]]
		set _tclsh [expr {[file executable $_g] ? $_g : "tclsh"}]
	}
	set ::core_cmd [list $_tclsh [file join $::rio_dir .. rio-core server.tcl] --stdio]
	if {[catch {open |$::core_cmd r+} ::core_chan]} {
		puts stderr "rio-gui: could not start a local core ($::core_chan)."
		exit 1
	}
}
fconfigure $::core_chan -buffering line -blocking 0 -translation lf -encoding utf-8
fileevent $::core_chan readable core_reader

# Per-buffer view state. The core holds the text; we hold the rest. `cursor`/`yview`
# are per-buffer (a buffer lives in exactly one editor group in v1, D33), while tab
# order and the active buffer are per-GROUP — see ::grp below.
set ::buffers {} ;# id -> {path <s> meta <dict> modified <0|1> cursor <idx> yview <frac>}

# Editor groups (AGENTS.md D33). The center holds one or two editor groups side by
# side; each is an independent text widget with its own tab strip, active buffer,
# and highlight cache. In v1 a buffer belongs to exactly one group. Phase 2 runs a
# SINGLE group (group 0), so the behaviour is identical to the pre-split editor;
# phase 3 adds the second group and the split layout.
#   ::grp   id -> a dict of the group's state:
#     w       real text-widget command (the renamed Tk widget, edits bypass the proxy)
#     path    the Tk widget path (the proxy) — for winfo/focus/bind
#     frame   the group's container frame (.eg<id>)
#     tabs    the group's tab-strip frame (.eg<id>.tabs)
#     cur     active buffer id in this group
#     order   buffer ids in this group, in tab order
#     hl_*    the per-group incremental-highlight cache (was the ::hl_* globals, D32)
set ::grp    {} ;# group id -> group-state dict (above)
set ::groups {} ;# group ids, left-to-right
set ::focus  "" ;# the focused group id (::cur mirrors its active buffer)
set ::cur    "" ;# active buffer of the FOCUSED group — a mirror, kept by activate/focus_group

# The side dock hosts ONE of the panes at a time (files | git) and sits on one
# side of the editor (left | right). Both are user choices (View menu), not
# dictated; left + files is the default.
set ::dock_side left   ;# left | right — which edge the dock occupies
set ::dock_pane files  ;# files | git  — which pane is currently shown
set ::wrap_lines 0     ;# 0 = no wrap (horizontal scrollbar) | 1 = word wrap
set ::chat_shown 1     ;# agent chat pane visible? (View menu / Ctrl+Shift+A)
set ::edit_mode windows   ;# active editing mode (D38): windows | emacs | vi | a drop-in's name
set ::editmode_active ""  ;# the mode currently attached to the RioMode tag ("" before boot)
set ::editmode_status ""  ;# the mode's status-bar segment ("-- INSERT --" in vi; "" otherwise)
set ::theme_name default ;# active colour theme — a persisted preference; do_theme records it (D31)
set ::theme_choice default ;# the View ▸ Theme radio: tracks theme_name, snaps back on a failed switch (D39)
set ::chat_turn_open 0 ;# mid-stream: an assistant block is open, deltas appending
set ::pending_turn ""  ;# turn id of a proposed edit awaiting Approve/Reject (D26 s5)
set ::agent_auto_accept 0 ;# skip the approval gate for proposed edits (Settings)
set ::compare_shown 0     ;# compare/diff view active? (.cmp shown instead of .ed; D28)
set ::agent_compare_complex 1 ;# open complex agent edits in the compare view (Settings; D28)
set ::compare_threshold 8 ;# diff lines above which an agent edit counts as "complex"
set ::cmp_syncing 0       ;# guard against re-entrant scroll sync between the compare panes
set ::rio_started 0       ;# false during boot: view-state/workspace writes wait until startup finishes (D31)
# The per-group highlight cache (D32) now lives in ::grp under these keys, one set per
# editor group (see new_group_state): hl_scan, hl_lang, hl_pending, hl_enter, hl_dirty,
# hl_lastchanged, hl_scanned. Same meanings as the old ::hl_* globals, keyed per widget.

proc bufget {id key} { dict get $::buffers $id $key }
proc bufset {id key val} { dict set ::buffers $id $key $val }

# ---------------------------------------------------------------------------
# Editor-group accessors (AGENTS.md D33). A group is a dict in ::grp; these keep the
# editor procs terse — most take a group id defaulting to the focused one, resolve
# its widget/cache through here, and never touch ::grp directly.
# ---------------------------------------------------------------------------
proc fg {}         { return $::focus }                 ;# the focused group id
proc gget {g k}    { dict get $::grp $g $k }
proc gset {g k v}  { dict set ::grp $g $k $v }
proc gw {g}        { dict get $::grp $g w }            ;# real widget command (bypasses the proxy)
proc gcur {g}      { dict get $::grp $g cur }          ;# active buffer id in group g
proc gorder {g}    { dict get $::grp $g order }        ;# tab order in group g
proc fgw {}        { gw $::focus }                     ;# the focused group's real widget

# Which group currently shows buffer `id`, or "" if none (v1: at most one group).
proc group_of {id} {
	foreach g $::groups { if {[lsearch -exact [gorder $g] $id] >= 0} { return $g } }
	return ""
}

# A fresh group-state dict: no buffer yet, an empty tab order, a clean highlight cache.
# `w`/`path`/`frame`/`tabs` are filled in by make_editor_group once the widgets exist.
proc new_group_state {} {
	return [dict create w "" path "" frame "" tabs "" cur "" order {} \
		hl_scan "" hl_lang "" hl_pending 0 hl_enter {} \
		hl_dirty 0 hl_lastchanged 0 hl_scanned 0]
}

# ---------------------------------------------------------------------------
# The single seam to the core (AGENTS.md D2/D30). One op call, one response; any
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
# Stale-link watchdog (AGENTS.md D37). A half-open socket — the classic stale
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

# The wire protocol version this GUI speaks (AGENTS.md O2: the integer
# session.hello reports; it bumps on a breaking change). Checked against every
# core we attach to — a spawned child can't realistically mismatch (same repo),
# but a daemon reached over --connect or an in-place reconnect (D30) can be any
# age, and a version skew otherwise surfaces as ops quietly misparsing.
set ::rio_protocol  2
set ::core_protocol ""   ;# what the attached core reported (for the title of a bug report)

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
		if {$code eq "timeout"} {
			set msg [expr {$::core_remote \
				? "Connected to $::core_endpoint, but no rio core answered.\n\nThe socket opened — most likely a stale SSH tunnel, or no core is running behind it. Check that the tunnel is still up (ssh -L …) and a core is listening on the server." \
				: "The local core started but never answered — the install may be broken."}]
		} else {
			set msg "The core didn't answer session.hello: [dict get $resp error message]"
		}
		if {$fatal} { catch {wm withdraw .} ; report_error $msg $code ; exit 1 }
		report_error $msg $code
		return 0
	}
	set ::core_protocol [dict get $resp result protocol]
	if {$::core_protocol ne $::rio_protocol} {
		report_error "This core speaks wire protocol $::core_protocol, but this GUI expects $::rio_protocol — mixed versions may misbehave. Update the older side." protocol_mismatch
	}
	return 1
}

# Apply a change to group `g`'s widget through the REAL widget command (bypassing the
# proxy). .t replace takes line.col indices directly — the payoff of D12 sharing the Tk
# text-widget index format: the view layer is nearly free. `see insert` only follows
# the caret in the focused group (the caret in a background group isn't the user's).
proc apply_change {g p} {
	set t [gw $g]
	$t replace [dict get $p start] [dict get $p end] [dict get $p text]
	if {$g eq $::focus} { $t see insert }
	hl_edit $g $p ;# the text changed — re-tokenise from the edit, incrementally (coalesced; D32)
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
	set resp [rio_call buffer.text [dict create buffer [gcur $g]]]
	$t delete 1.0 end
	if {[dict get $resp ok]} {
		$t insert 1.0 [dict get $resp result text]
	} else {
		set e [dict get $resp error]
		report_error [dict get $e message] [dict get $e code]
	}
	hl_select $g   ;# the file type may have changed with the buffer (D32)
	hl_full $g     ;# repaint the whole buffer now and build the line-state cache (on switch/open)
}

# A buffer's whole text via the protocol (buffer.text), so the frontend never reads
# the core's document model directly — the one path that works the same in-process
# and remote (AGENTS.md D29). "" on failure (a vanished buffer): callers only use
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
	dict set ::buffers $id \
		[dict create path $path meta $meta modified 0 cursor 1.0 yview 0.0]
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
# (AGENTS.md D29). Replaces reaching into $::rio::ops::default, which exists only in
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

proc do_open {path} {
	# Already open in some group? Just switch to its tab (activate focuses its group).
	foreach id [dict keys $::buffers] {
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
	session_save   ;# the open-file set changed — record it for resume (D31)
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
	if {$::core_remote} {
		set p [remote_browse_dialog "Open folder (remote)" dir]
	} else {
		set p [tk_chooseDirectory -title "Open folder"]
	}
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
	prefs_save
}

# Re-pack the dock against ::dock_side, with the editor filling the rest. Packing
# the dock first claims its edge; the center then expands into what's left, so the
# same two calls work for either side.
proc place_dock {} {
	catch {pack forget .dock .sash .chat .csash .groups .cmp}
	pack .dock -side $::dock_side -fill y
	pack .sash -side $::dock_side -fill y     ;# between the dock and the editor
	if {$::chat_shown} {
		pack .chat  -side right -fill y       ;# chat column on the right (D14)
		pack .csash -side right -fill y       ;# between the editor and the chat
	}
	# The center is the editor-group container, or the compare view in its place
	# while comparing (D28). The container itself holds one or two groups (D33).
	if {$::compare_shown} {
		pack .cmp -side left -fill both -expand 1
	} else {
		pack .groups -side left -fill both -expand 1
	}
	prefs_save
}

# Lay the editor groups left-to-right inside the .groups panedwindow. In v1 there are
# at most two; each pane -stretches so they share the width, and the panedwindow gives
# a draggable divider between them. Called after a split/unsplit changes ::groups; with
# one group it just fills the center.
proc relayout_groups {} {
	foreach p [.groups panes] { .groups forget $p }
	foreach g $::groups {
		.groups add [gget $g frame] -stretch always -minsize 120
	}
}

# Centre the sash so a fresh split opens 50/50 (Tk otherwise sizes the new pane from its
# requested width, leaving it a sliver). Called only when a split is *created* (add_group)
# — moving tabs between two existing panes never re-lays-out, so a user who has since
# dragged the sash keeps their layout. Runs after idle so the panedwindow has its width.
proc even_split {} {
	if {[llength [.groups panes]] != 2} return
	set w [winfo width .groups]
	if {$w <= 1} return                       ;# not mapped yet (e.g. headless) — skip
	.groups sash place 0 [expr {$w / 2}] 0
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
# back for long lines. Configures every group's real widget (the proxy only guards
# edits) and its own horizontal scrollbar.
proc apply_wrap {} {
	set mode [expr {$::wrap_lines ? "word" : "none"}]
	foreach g $::groups {
		set t [gw $g] ; set hsb [gget $g frame].hsb
		$t configure -wrap $mode
		if {$::wrap_lines} {
			grid remove $hsb
		} else {
			gridscroll $hsb {*}[$t xview]   ;# show only if a line overflows
		}
	}
	cmp_apply_wrap
	prefs_save
}

# The compare panes have no horizontal scrollbar, so wrap is the only way to read
# long lines there; keep them in step with the editor's View ▸ Wrap Lines.
proc cmp_apply_wrap {} {
	set w [expr {$::wrap_lines ? "word" : "none"}]
	.cmp.l.t configure -wrap $w
	.cmp.r.t configure -wrap $w
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
# The agent chat pane (AGENTS.md D14 `chat` column; D20/D26/D30). A dumb view (D3)
# over the agent.* event stream: a read-only transcript, a composer, and Send.
# agent.send is a STREAMING op — its reply is an ack, and the turn's content arrives
# as agent.delta events the core broadcasts over the channel (D30), routed here by
# dispatch_event and appended live (chat_event), so the answer builds in view;
# agent.message closes the turn, agent.error shows a classified failure (D26). The
# core owns the conversation (D3): chat_clear is agent.reset. Right side; toggleable.
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

# Send the composer's text as a turn (D26). agent.send is a streaming op: its reply
# is just an ack — the turn's content streams back afterward as agent.* events the
# core broadcasts over the channel, landing in chat_event via dispatch_event (D30).
proc chat_send {} {
	set text [string trim [.chat.input get 1.0 end]]
	if {$text eq ""} return
	.chat.input delete 1.0 end
	# Sending a new message abandons any proposal still awaiting a decision; the core
	# seals the dangling tool call, so dismiss its review UI here to match (D28).
	if {$::pending_turn ne ""} { approve_bar 0 ; compare_close }
	chat_label you-label "You"
	chat_log "$text\n"
	set ::chat_turn_open 0
	set resp [rio_call agent.send [dict create text $text]]
	if {![dict get $resp ok]} {
		set e [dict get $resp error]
		chat_label error-label "Error"
		chat_log "[dict get $e message] ([dict get $e code])\n"
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
			# A proposed EDIT awaiting the user's decision (D26 s5). Show the diff and,
			# unless auto-accept is on, raise the Approve/Reject bar. A *complex* edit (more
			# than ::compare_threshold diff lines) opens in the side-by-side compare view
			# instead of dumping the whole diff inline — unless the user turned that off
			# (Settings ▸ Compare complex edits) (D28).
			if {$::chat_turn_open} { chat_log "\n" ; set ::chat_turn_open 0 }
			set turn [dict get $ev params turn]
			set diff [dict get $ev params diff]
			chat_log "· proposes [dict get $ev params name]: [dict get $ev params path]\n" tool
			set complex [expr {[llength [split $diff "\n"]] > $::compare_threshold}]
			if {$::agent_compare_complex && $complex && !$::agent_auto_accept \
					&& [compare_proposal $turn]} {
				chat_log "  (opened in compare view)\n" tool
			} else {
				chat_diff $diff
			}
			if {!$::agent_auto_accept} {
				set ::pending_turn $turn
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
# remaining events stream back as broadcast agent.* events (dispatch_event → chat).
proc agent_decide {decision} {
	if {$::pending_turn eq ""} return
	set t $::pending_turn
	approve_bar 0
	compare_close
	catch {rio_call agent.approve [dict create turn $t decision $decision]}
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
		- [winfo height .chat.status] - [winfo height .chat.send] \
		- [winfo reqheight .chat.isash] - 3 * $lh}]
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
# The compare / diff view (AGENTS.md D28; D13/D14 anticipated it). Two read-only
# panes side by side with line-level diff coloring, shown in the center INSTEAD
# of the editor while comparing (place_dock swaps .ed <-> .cmp). A dumb view
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
	place_dock
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
	place_dock
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

# Compare the active buffer against a file the user picks (View menu). The other
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

# Tell the core which provider to run (agent.provider.set, D30). The agent lives in
# the core wherever it runs, so this is an op, not an in-process swap; the chat
# header then names the live choice. Only ever called from a user action (the
# Settings radio) — see adopt_agent_status for why we don't write at attach time.
proc apply_provider {} {
	rio_result agent.provider.set [dict create name $::agent_provider]
	chat_status_update
}

# Adopt the core's LIVE agent settings into our menus instead of imposing ours.
# The agent — provider, auto-accept, stored key — lives in the core (D26/D30), and
# a daemon we attach to over --connect or an in-place reconnect may already have a
# provider chosen and auto-accept set by whoever configured it. Writing our boot
# default (echo, gated) over that at attach time would silently reset that core, so
# at startup and after a reconnect we READ agent.status and mirror it into the
# radio/checkbutton; a WRITE (apply_provider / autoaccept.set) happens only when the
# user actually picks something.
proc adopt_agent_status {} {
	set st [rio_result agent.status {}]
	if {$st eq ""} return   ;# error already surfaced; keep the current menu state
	set ::agent_provider    [dict get $st provider]
	set ::agent_auto_accept [dict get $st auto_accept]
	chat_status_update
}

# The chat status strip (under the Send button): which agent is live and whether
# proposed edits auto-apply or wait for review. A spot for context-window usage
# later. Called on provider change and on the auto-accept toggle.
proc chat_status_update {} {
	set agent [expr {$::agent_provider eq "claude" ? "Claude" : "Echo"}]
	set mode  [expr {$::agent_auto_accept ? "auto-accept edits" : "review edits"}]
	catch {.chat.status configure -text "$agent   ·   $mode"}
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
	set stored [dict get [rio_result agent.status {}] key_set]
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
	rio_result agent.key.set [dict create key $key]
	destroy $w
}
proc claude_key_clear {w} {
	rio_result agent.key.clear {}
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

# ---------------------------------------------------------------------------
# Find / Replace (AGENTS.md D36). The bar is a thin view: the MATCHING runs in
# the core (buffer.find / buffer.matches — the core owns the canonical text,
# D3), and the bar carries only the frontend-local state those ops are
# stateless about (D22): the needle, the options, and the caret it passes as
# `from`. Replace is the existing edit path — a found range plus a
# buffer.replace; Replace All is one op and ONE undo step. The bar always acts
# on the FOCUSED group; matches are painted with the `findmatch` tag
# (editor.findmatch role, D24), the current match with the native selection.
# ---------------------------------------------------------------------------
set ::find_shown   0  ;# find bar visible? (Ctrl+F / Ctrl+H; Esc hides it)
set ::find_case    0  ;# Match case checkbox (off = fold case, the familiar default)
set ::find_starts  {} ;# match starts from the last find_update ("i of n" lookup)
set ::find_pending 0  ;# a coalesced find_update is queued (see apply_change)

# Show the bar (packing it above the status bar), with or without the Replace
# row — Ctrl+F and Ctrl+H open the same bar in the two shapes. A single-line
# editor selection pre-fills the needle (the 90s convention); the needle entry
# gets focus with its text selected, so typing starts a fresh search.
proc find_open {withReplace} {
	set ::find_shown 1
	pack .find -after .status -side bottom -fill x
	if {$withReplace} {
		grid .find.rl ; grid .find.re ; grid .find.rep ; grid .find.repall
	} else {
		grid remove .find.rl .find.re .find.rep .find.repall
	}
	set t [gw $::focus]
	if {![catch {$t get sel.first sel.last} s] && $s ne "" \
			&& [string first "\n" $s] < 0} {
		.find.e delete 0 end
		.find.e insert 0 $s
	}
	focus .find.e
	.find.e selection range 0 end
	.find.e icursor end
	find_update
}

# Hide the bar, clear the match paint everywhere, and hand focus back.
proc find_close {} {
	if {!$::find_shown} return
	set ::find_shown 0
	pack forget .find
	foreach g $::groups { [gw $g] tag remove findmatch 1.0 end }
	set ::find_starts {}
	focus [gget $::focus path]
}

# The count/status label at the bar's right ("12 matches", "3 of 12", …).
proc find_status {msg} { .find.count configure -text $msg }

# Recompute the matches for the focused group's buffer: repaint the findmatch
# tag and refresh the count. Runs on every needle keystroke, on the case
# toggle, on a tab switch, and (coalesced) after any buffer change — one
# buffer.matches round-trip, the same cost as one typed character. Painting is
# capped so a one-letter needle in a huge file cannot stall the view; the
# count stays exact.
proc find_update {} {
	set ::find_pending 0
	if {!$::find_shown} return
	set g $::focus ; set t [gw $g]
	$t tag remove findmatch 1.0 end
	set ::find_starts {}
	set needle [.find.e get]
	if {$needle eq ""} { find_status "" ; return }
	set resp [rio_call buffer.matches [dict create buffer [gcur $g] \
		needle $needle nocase [expr {!$::find_case}]]]
	if {![dict get $resp ok]} { find_status "" ; return }
	set n [dict get $resp result count]
	set painted 0
	foreach m [dict get $resp result matches] {
		lappend ::find_starts [dict get $m start]
		if {[incr painted] <= 1000} {
			$t tag add findmatch [dict get $m start] [dict get $m end]
		}
	}
	find_status [expr {$n == 0 ? "No matches" : "$n match[expr {$n==1 ? "" : "es"}]"}]
}

# Jump to the next (or previous) match: ask the core for the match after the
# current one — after the selection's edge, else the caret — select it, put
# the caret on its far side, and scroll it into view. Search wraps around; the
# label says so.
proc find_step {backwards} {
	if {!$::find_shown} { find_open 0 ; return }
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	if {$backwards} {
		if {[catch {$t index sel.first} from]} { set from [$t index insert] }
	} else {
		if {[catch {$t index sel.last} from]} { set from [$t index insert] }
	}
	set resp [rio_call buffer.find [dict create buffer [gcur $g] needle $needle \
		from $from nocase [expr {!$::find_case}] backwards $backwards]]
	if {![dict get $resp ok]} return
	set r [dict get $resp result]
	if {![dict get $r found]} { find_status "No matches" ; return }
	set s [dict get $r start] ; set e [dict get $r end]
	$t tag remove sel 1.0 end
	$t tag add sel $s $e
	# No expr here: an index like 1.10 would coerce to the float 1.1 (see
	# editor_proxy's delete arm for the original bite of this).
	if {$backwards} { $t mark set insert $s } else { $t mark set insert $e }
	$t see $s
	set i [lsearch -exact $::find_starts $s]
	set n [llength $::find_starts]
	if {$i >= 0} {
		set msg "[expr {$i + 1}] of $n"
		if {[dict get $r wrapped]} { append msg " · wrapped" }
		find_status $msg
	}
}
proc find_next {} { find_step 0 }
proc find_prev {} { find_step 1 }

# Replace the current match, then jump to the next: if the selection IS a
# match of the needle, replace it through the ordinary edit op; otherwise this
# first click just selects the next match and the next click replaces it (the
# classic two-step, so a replace is always visible before it happens).
proc find_replace_one {} {
	if {!$::find_shown} return
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	if {![catch {list [$t index sel.first] [$t index sel.last]} range]} {
		lassign $range s e
		set cur [$t get $s $e]
		set same [expr {$::find_case ? [string equal $cur $needle] \
		                             : [string equal -nocase $cur $needle]}]
		if {$same} {
			if {[dict get [rio_call buffer.replace [dict create buffer [gcur $g] \
				start $s end $e text [.find.re get]]] ok]} { mark_modified 1 }
		}
	}
	find_step 0
}

# Replace every match in one op (buffer.replace_all): one round-trip, one undo
# step. The buffer.changed event repaints the widget before the reply lands
# (events precede replies on the channel), so only the caret needs restoring.
proc find_replace_all {} {
	if {!$::find_shown} return
	set needle [.find.e get]
	if {$needle eq ""} { focus .find.e ; return }
	set g $::focus ; set t [gw $g]
	set at [$t index insert]
	set resp [rio_call buffer.replace_all [dict create buffer [gcur $g] \
		needle $needle text [.find.re get] nocase [expr {!$::find_case}]]]
	if {![dict get $resp ok]} return
	set n [dict get $resp result count]
	if {$n > 0} { mark_modified 1 }
	catch { $t mark set insert $at ; $t see insert }
	find_update
	find_status "Replaced $n"
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

# ---------------------------------------------------------------------------
# Editor split (AGENTS.md D33): create/destroy the second group and move tabs across.
# v1 is at most two groups; ids are the free slot in {0,1} so a collapsed group's slot
# is reused on the next split.
# ---------------------------------------------------------------------------
# The other group (v1: at most two), or "" if `g` is the only one.
proc other_group {g} {
	foreach o $::groups { if {$o ne $g} { return $o } }
	return ""
}

# Which group's pane does widget `w` live under? Walk up from `w` to a group frame
# (.eg<g>) and return its id, or "" if `w` is outside every group. `group_at` layers
# the screen-coordinate lookup on top for drag-and-drop; the widget walk is split out
# so it can be unit-tested without real pointer geometry (split.tcl).
proc group_of_widget {w} {
	while {$w ne ""} {
		foreach g $::groups { if {$w eq [gget $g frame]} { return $g } }
		set w [winfo parent $w]
	}
	return ""
}
proc group_at {X Y} { group_of_widget [winfo containing $X $Y] }

# Tear down group `g`'s widgets and its leftover proxy proc, and drop it from ::grp.
# (Destroying the frame removes the real widget command; the proxy at .eg<g>.t is a
# plain proc, so it must be renamed away or the slot can't be rebuilt on a re-split.)
proc destroy_editor_group {g} {
	set path [gget $g path] ; set w [gw $g]
	catch {destroy [gget $g frame]}
	catch {rename $path ""}
	catch {rename $w ""}
	dict unset ::grp $g
}

# Bring up an empty second editor group in the free slot, styled and wrap-synced to
# match. Returns its id. Callers give it a buffer (split_editor) or move one in.
proc add_group {} {
	set g [expr {[lsearch -exact $::groups 0] < 0 ? 0 : 1}]
	make_editor_group $g
	lappend ::groups $g
	relayout_groups
	restyle_group $g
	apply_wrap        ;# sync the new group's wrap mode + horizontal scrollbar
	# The shared RioMode tag already covers the new widget's keys; re-attaching
	# (idempotent by contract, D38) lets the active mode set up its per-group
	# state too — vi's cursor shape and normal/insert state for the new half.
	if {$::editmode_active ne ""} { catch {rio::modes::attach $::editmode_active RioMode} }
	after idle even_split   ;# a new split opens 50/50; later user sash drags are kept
	return $g
}

# Fold group `g` into the other one: its tabs move over (appended), its widgets are
# destroyed, and focus lands on the survivor. Never collapses the sole group.
proc collapse_group {g} {
	set o [other_group $g]
	if {$o eq ""} return
	foreach id [gorder $g] { gset $o order [linsert [gorder $o] end $id] }
	set ::groups [lsearch -all -inline -not -exact $::groups $g]
	destroy_editor_group $g
	relayout_groups
	set ::focus $o
	set ::cur [gcur $o]
	refresh_all
}

# Split the editor: open a second group with a fresh scratch buffer and focus it. A
# no-op if already split. (Use Move Tab to Other Group to send an open file across.)
proc split_editor {} {
	if {[llength $::groups] >= 2} return
	set g [add_group]
	set res [rio_result buffer.new {}]
	if {$res eq ""} { collapse_group $g ; return }
	register_buffer [dict get $res buffer] "" {} $g
	activate [dict get $res buffer] $g
	prefs_save
}

# Unsplit: fold the second group back into the first.
proc unsplit_editor {} {
	if {[llength $::groups] < 2} return
	collapse_group [lindex $::groups end]
	prefs_save
}

# View ▸ Split / Unsplit toggle (Ctrl+\).
proc toggle_split {} {
	if {[llength $::groups] >= 2} { unsplit_editor } else { split_editor }
}

# Move buffer `id` out of group `src` into the other group (creating the split if
# needed) and follow it there. If `src` empties it collapses — so moving the only tab
# is a harmless no-op round-trip, and peeling one off a multi-tab group gives a real
# side-by-side (D33: a buffer lives in exactly one group). `id` need not be src's
# active tab (the context menu can move any tab).
proc move_buffer_to_other {id src} {
	if {[lsearch -exact [gorder $src] $id] < 0} return
	if {[llength $::groups] < 2} { add_group }
	set dst [other_group $src]
	gset $src order [lsearch -all -inline -not -exact [gorder $src] $id]
	gset $dst order [linsert [gorder $dst] end $id]
	if {![llength [gorder $src]]} {
		set ::groups [lsearch -all -inline -not -exact $::groups $src]
		destroy_editor_group $src
		relayout_groups
	} elseif {[gcur $src] eq $id} {
		# the moved buffer was src's active tab — pick a new active for src
		gset $src cur [lindex [gorder $src] 0]
		load_buffer $src
	}
	activate $id $dst
	prefs_save
}

# View ▸ Move Tab to Other Group (Ctrl+]): move the focused group's active buffer.
proc move_tab_other {} {
	if {[gcur $::focus] ne ""} { move_buffer_to_other [gcur $::focus] $::focus }
}

# A protocol-native remote file/folder browser (AGENTS.md D29/D30). In remote mode
# the filesystem of record is the CORE's, but tk_getOpenFile / tk_getSaveFile /
# tk_chooseDirectory browse the CLIENT's disk — wrong for a remote core. So those
# choosers give way to this browser, which walks the REMOTE tree over `fs.list` —
# the very op the docked file pane uses (populate_nav) — point-and-click, not typed.
# An editable Location bar still lets you jump straight to a known path, so it also
# subsumes the old typed-path prompt (remote_path_dialog).
#
#   mode = open -> pick an existing file    -> returns its abs path
#          save -> pick a dir + type a name -> returns dir/name
#          dir  -> pick a directory         -> returns the shown dir
#
# Returns the chosen absolute path, or "" if cancelled.

# The row model for one remote directory: a ".." row (unless at "/"), then dirs,
# then files — each {type abspath display}, already dictionary-sorted by the core.
# Split out from the widget code so the fs.list walk is testable headlessly.
proc rbrowse_rows_for {dir} {
	set resp [rio_call fs.list [dict create path $dir]]
	if {![dict get $resp ok]} {
		return [dict create ok 0 error [dict get $resp error message]]
	}
	set abs [dict get $resp result path]   ;# the core's normalized dir
	set rows {}
	if {$abs ne "/"} { lappend rows [list dir [file dirname $abs] "../"] }
	foreach grp {dir file} {
		foreach e [dict get $resp result entries] {
			if {[dict get $e type] ne $grp} continue
			set name [dict get $e name]
			lappend rows [list $grp [file join $abs $name] \
				[expr {$grp eq "dir" ? "$name/" : "  $name"}]]
		}
	}
	return [dict create ok 1 dir $abs rows $rows]
}

# Where the browser opens: the seed's directory if it names an absolute path, else
# the open project's root, else "/" (the Location bar reaches anywhere from there).
proc rbrowse_start {seed} {
	if {$seed ne "" && [file pathtype $seed] eq "absolute"} {
		return [file dirname $seed]
	}
	set root [dict get [rio_call project.get {}] result root]
	return [expr {$root ne "" ? $root : "/"}]
}

# Re-list $dir into the browser: fill the Location bar and the listbox from
# rbrowse_rows_for, dropping files in dir mode. A bad path just beeps (the old
# listing stays), so a mistyped Location can't strand the dialog.
proc rbrowse_go {dir} {
	set info [rbrowse_rows_for $dir]
	# rbrowse_rows_for pumps the event loop (an fs.list round-trip). If the dialog was
	# cancelled meanwhile — Escape, WM close, a slow remote listing the user gave up on
	# — its widgets are gone; bail rather than crash on a stale ".rbrowse.loc".
	if {![winfo exists .rbrowse.loc]} return
	if {![dict get $info ok]} { bell ; return }
	set ::rbrowse_dir [dict get $info dir]
	.rbrowse.loc delete 0 end
	.rbrowse.loc insert end $::rbrowse_dir
	.rbrowse.body.list delete 0 end
	set ::rbrowse_rows {}
	foreach row [dict get $info rows] {
		lassign $row type abs display
		if {$::rbrowse_mode eq "dir" && $type eq "file"} continue
		.rbrowse.body.list insert end $display
		lappend ::rbrowse_rows $row
	}
}

# Double-click / Enter a row: descend into a dir; on a file, choose it (open mode)
# or copy its name into the Name field (save mode).
proc rbrowse_activate {} {
	set sel [.rbrowse.body.list curselection]
	if {$sel eq ""} return
	lassign [lindex $::rbrowse_rows $sel] type abs display
	if {$type eq "dir"} { rbrowse_go $abs ; return }
	switch -- $::rbrowse_mode {
		open { set ::rbrowse_result $abs ; destroy .rbrowse }
		save { .rbrowse.name delete 0 end ; .rbrowse.name insert end [file tail $abs] }
	}
}

# The Choose button: a directory (dir mode), the shown dir + typed Name (save), or
# the selected file (open). An empty Name / no file selection just beeps.
proc rbrowse_choose {} {
	switch -- $::rbrowse_mode {
		dir  { set ::rbrowse_result $::rbrowse_dir }
		save {
			set name [string trim [.rbrowse.name get]]
			if {$name eq ""} { bell ; return }
			set ::rbrowse_result [expr {[file pathtype $name] eq "absolute" \
				? $name : [file join $::rbrowse_dir $name]}]
		}
		open {
			set sel [.rbrowse.body.list curselection]
			if {$sel eq ""} { bell ; return }
			lassign [lindex $::rbrowse_rows $sel] type abs display
			if {$type ne "file"} { bell ; return }
			set ::rbrowse_result $abs
		}
	}
	if {$::rbrowse_result ne ""} { destroy .rbrowse }
}

proc remote_browse_dialog {title mode {seed ""}} {
	set w .rbrowse
	destroy $w
	toplevel $w
	wm title $w $title
	wm transient $w .
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	# Location bar — the current remote dir, editable to jump anywhere.
	label $w.loclbl -anchor w -font RioUIFont -text "Location:" \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	entry $w.loc -font RioUIFont -width 54
	bind $w.loc <Return> { rbrowse_go [string trim [.rbrowse.loc get]] }

	# The listing (an auto-hiding scrollbar, like the dock file pane).
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.rbrowse.body.list yview}
	listbox $w.body.list -height 16 -width 54 -activestyle none -exportselection 0 \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c editor.selection] \
		-selectforeground [dict get $c ui.fg] \
		-yscrollcommand {autoscroll .rbrowse.body.sb .rbrowse.body.list}
	pack $w.body.list -side left -fill both -expand 1

	frame $w.btns -background [dict get $c ui.bg]
	set oklbl [dict get {open Open save {Save here} dir {Choose folder}} $mode]
	button $w.btns.ok     -text $oklbl -font RioUIFont -command rbrowse_choose
	button $w.btns.cancel -text Cancel -font RioUIFont \
		-command {set ::rbrowse_result "" ; destroy .rbrowse}
	pack $w.btns.cancel $w.btns.ok -side right -padx 3

	grid $w.loclbl -row 0 -column 0 -sticky w    -padx 8 -pady {8 0}
	grid $w.loc    -row 1 -column 0 -sticky we   -padx 8
	grid $w.body   -row 2 -column 0 -sticky nsew -padx 8 -pady 4
	set btnrow 3
	if {$mode eq "save"} {
		label $w.namelbl -anchor w -font RioUIFont -text "Name:" \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		entry $w.name -font RioUIFont -width 54
		$w.name insert end [file tail $seed]
		grid $w.namelbl -row 3 -column 0 -sticky w  -padx 8
		grid $w.name    -row 4 -column 0 -sticky we -padx 8
		set btnrow 5
	}
	grid $w.btns -row $btnrow -column 0 -sticky e -padx 5 -pady {2 8}
	grid rowconfigure $w 2 -weight 1
	grid columnconfigure $w 0 -weight 1

	bind $w.body.list <Double-Button-1> rbrowse_activate
	bind $w.body.list <Return>          rbrowse_activate
	bind $w <Escape> {set ::rbrowse_result "" ; destroy .rbrowse}

	set ::rbrowse_mode   $mode
	set ::rbrowse_result ""
	set ::rbrowse_rows   {}
	rbrowse_go [rbrowse_start $seed]

	# The first rbrowse_go may have been cancelled mid-flight (an Escape during its
	# fs.list), taking the dialog with it — only grab/focus/wait if it's still here.
	if {[winfo exists $w]} {
		catch {grab $w}
		focus $w.body.list
		tkwait window $w
	}
	return $::rbrowse_result
}

# --- dialog wrappers ---------------------------------------------------------
# Each picks a path then calls a do_* action. The native chooser browses the local
# disk; when the core is remote (its FS isn't ours) it gives way to the remote file
# browser (remote_browse_dialog), which walks the server's tree over fs.list.
proc open_dialog {} {
	if {$::core_remote} {
		set p [remote_browse_dialog "Open file (remote)" open]
	} else {
		set p [tk_getOpenFile -title "Open file"]
	}
	if {$p ne ""} { do_open $p }
}
proc save_as_dialog {} {
	if {$::core_remote} {
		set p [remote_browse_dialog "Save as (remote)" save [bufget $::cur path]]
	} else {
		set p [tk_getSaveFile -title "Save as"]
	}
	if {$p eq ""} { return 0 }
	return [do_save_as $p]
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
proc do_quit {} {
	prefs_save      ;# persist view state + the workspace before we go (D31)
	session_save
	foreach id [dict keys $::buffers] {
		if {[bufget $id modified]} {
			activate $id
			if {![maybe_discard]} return
		}
	}
	# Close the channel so a spawned child core sees EOF on stdin and exits with us
	# (a daemon socket just drops the connection); then go.
	catch {close $::core_chan}
	exit 0
}

# ---------------------------------------------------------------------------
# Connect to a remote (listening) rio-core over a socket — the daemon mode of the
# one channel transport (AGENTS.md D30). The core there is loopback-bound, so this
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
	set ::chat_turn_open 0
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
	set ::nav_dir ""
	set ::nav_rows {}
	set ::git_rows {}
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

# The bare display name of a buffer — no modified marker. The unsaved-changes
# dot (●, D27) is a rendering concern added by the tab strip and the title only;
# keeping it out of here means the compare picker and the save prompt show a
# clean filename.
proc tab_name {id} {
	set p [bufget $id path]
	return [expr {$p eq "" ? "untitled" : [file tail $p]}]
}
# The ● (U+25CF) unsaved marker, or "" — appended after the name in the tab and
# the window title (D27).
proc tab_dot {id} {
	return [expr {[bufget $id modified] ? " ●" : ""}]
}
proc refresh_all   {} { refresh_tabs ; refresh_title ; refresh_status }
proc refresh_title {} {
	set suffix [expr {$::core_remote ? " — $::core_endpoint" : ""}]
	wm title . "rio — [tab_name $::cur][tab_dot $::cur]$suffix"
}
proc refresh_status {} {
	set p    [bufget $::cur path]
	set name [expr {$p eq "" ? "untitled" : $p}]
	set meta [bufget $::cur meta]
	set enc  [expr {[dict exists $meta encoding] ? [dict get $meta encoding] : "utf-8"}]
	set eol  [expr {[dict exists $meta eol] ? [dict get $meta eol] : "lf"}]
	set lang [expr {[gget $::focus hl_lang] ne "" ? [gget $::focus hl_lang] : "plain text"}]
	set mode ""   ;# the editing mode's segment (vi's "-- INSERT --"), when it has one
	if {$::editmode_status ne ""} { set mode "      $::editmode_status" }
	.status configure -text [format "%s      %s  %s%s      %s      %d buffer(s)%s" \
		$name $enc $eol [expr {[bufget $::cur modified] ? {      modified} : {}}] \
		$lang [dict size $::buffers] $mode]
}
# Copy a tab's file path to the clipboard (context menu). A no-op for an untitled
# buffer, which has no path — the menu disables the item in that case.
proc tab_copy_path {id} {
	set path [bufget $id path]
	if {$path eq ""} return
	clipboard clear
	clipboard append $path
}

# Right-click a tab handle: a context menu of actions ABOUT THIS TAB (id, g) — nothing
# about other tabs or regions (D33; the UI-design bar: a tab's menu stays scoped to
# that tab). Rebuilt on each popup so Copy Path reflects the current state. "Move to
# Other Group" is one label in both states: with one group the move creates the other
# group, so the label still describes what happens — no context-sensitive wording.
proc tab_context_menu {g id X Y} {
	catch {destroy .tabmenu}
	menu .tabmenu -tearoff 0
	.tabmenu add command -label "Move to Other Group" -command [list move_buffer_to_other $id $g]
	if {[bufget $id path] ne ""} {
		.tabmenu add command -label "Copy Path" -command [list tab_copy_path $id]
	} else {
		.tabmenu add command -label "Copy Path" -state disabled
	}
	.tabmenu add separator
	.tabmenu add command -label "Close" -command [list close_tab $id $g]
	tk_popup .tabmenu $X $Y
}

# The tab strips (D33): each group draws its OWN tabs into its own strip
# (.eg<g>.tabs). A tab's group is where it lives, so clicking it activates that buffer
# IN that group and focuses the group. The focused group's active tab is emphasised
# with the accent colour, so which pane has focus is visible at a glance. Right-click
# a tab for a context menu (move to the other group / close).
# Drag a tab (AGENTS.md D33 follow-on) — a second input gesture onto the move/reorder
# paths. Press a tab and drag it: onto the OTHER group's pane it moves across (the same
# path as the context menu's "Move to Other Group"); back onto its OWN pane it reorders,
# dropping into the slot under the pointer. Below a ~5px threshold it stays a plain click
# (activate). Tk's implicit pointer grab keeps motion/release flowing to the origin tab
# while the button is down, so `winfo containing` sees across both panes. Feedback while
# dragging: the held tab gets a pressed accent look (mark_dragged) and the cursor becomes
# a hand, and a cross-group drag also tints the OTHER group's tab strip.
proc tab_drag_start {id g X Y} {
	set ::tabdrag [dict create id $id g $g x $X y $Y active 0 tint ""]
}
proc tab_drag_motion {X Y} {
	if {![info exists ::tabdrag]} return
	if {![dict get $::tabdrag active]} {
		if {abs($X - [dict get $::tabdrag x]) < 5 && abs($Y - [dict get $::tabdrag y]) < 5} return
		dict set ::tabdrag active 1
		. configure -cursor hand2
		mark_dragged [dict get $::tabdrag g] [dict get $::tabdrag id]
	}
	set src  [dict get $::tabdrag g]
	set over [group_at $X $Y]
	set want [expr {($over ne "" && $over ne $src) ? $over : ""}]
	set now  [dict get $::tabdrag tint]
	if {$want ne $now} {
		if {$now  ne ""} { tint_strip $now  0 }
		if {$want ne ""} { tint_strip $want 1 }
		dict set ::tabdrag tint $want
	}
}
proc tab_drag_end {id g X Y} {
	if {![info exists ::tabdrag]} { activate $id $g ; return }
	set active [dict get $::tabdrag active]
	set tint   [dict get $::tabdrag tint]
	unset ::tabdrag
	. configure -cursor ""
	if {$tint ne ""} { tint_strip $tint 0 }
	if {!$active} { activate $id $g ; return }   ;# a click, not a drag
	set dst [group_at $X $Y]
	if {$dst eq $g} {
		reorder_tab $g $id $X                    ;# dropped on its own pane -> reorder
	} elseif {$dst ne ""} {
		move_buffer_to_other $id $g              ;# dropped on the other pane -> move across
	}
	refresh_tabs                                 ;# clear the drag mark (no-op if a drop already repainted)
}
# Give the dragged tab a clear "held" look — a pressed (sunken) handle tinted with the
# accent — so an in-group reorder has feedback too (a between-groups drag also tints the
# target strip). One-way styling: the refresh_tabs at drag-end repaints it back to normal.
proc mark_dragged {g id} {
	set w [gget $g tabs].b$id
	if {![winfo exists $w]} return
	set c $::theme_colors
	set a [dict get $c accent] ; set fg [dict get $c tab.active.bg]
	$w configure -relief sunken -background $a
	foreach sub [list $w.l $w.x] { catch {$sub configure -background $a -foreground $fg} }
}
# Highlight (`on`=1) or restore (`on`=0) group `g`'s tab strip as a drop target.
proc tint_strip {g on} {
	set c $::theme_colors
	set bg [expr {$on ? [dict get $c accent] : [dict get $c tab.bar.bg]}]
	catch {[gget $g tabs] configure -background $bg}
}

# Reorder tab `id` within its own group `g` to the slot under pointer-x `X`. The new
# index is "how many OTHER tabs have their centre left of X" — drop-where-the-cursor-is.
# `tab_reorder` does the pure list splice (unit-tested: no geometry); this reads the live
# tab centres and applies. Order is a view concern, so only the strip repaints — the
# active buffer and its text are untouched.
proc reorder_tab {g id X} {
	set centers [dict create]
	foreach t [gorder $g] {
		set w [gget $g tabs].b$t
		if {[winfo exists $w]} { dict set centers $t [expr {[winfo rootx $w] + [winfo width $w] / 2}] }
	}
	set new [tab_reorder [gorder $g] $id $centers $X]
	if {$new eq [gorder $g]} return              ;# dropped in place
	gset $g order $new
	refresh_tabs
	prefs_save
}
# Pure splice: move `id` within `order` to the slot implied by `X` against tab `centers`
# (a dict id->centre-x). Insertion index = count of OTHER tabs whose centre is left of X.
proc tab_reorder {order id centers X} {
	set k 0
	foreach t $order {
		if {$t eq $id} continue
		if {[dict exists $centers $t] && $X > [dict get $centers $t]} { incr k }
	}
	return [linsert [lsearch -all -inline -not -exact $order $id] $k $id]
}

proc refresh_tabs {} {
	set c $::theme_colors
	set fg [dict get $c tab.fg]
	foreach g $::groups {
		set strip [gget $g tabs]
		$strip configure -background [dict get $c tab.bar.bg]
		foreach w [winfo children $strip] { destroy $w }
		set focused [expr {$g eq $::focus}]
		foreach id [gorder $g] {
			set active [expr {$id eq [gcur $g]}]
			set bg [expr {$active ? [dict get $c tab.active.bg] : [dict get $c tab.inactive.bg]}]
			set tfg [expr {$active && $focused ? [dict get $c accent] : $fg}]
			set f [frame $strip.b$id -background $bg -borderwidth 1 \
				-relief [expr {$active ? "raised" : "flat"}]]
			label $f.l -text "[tab_name $id][tab_dot $id]" -background $bg -foreground $tfg \
				-font RioUIFont -padx 6 -pady 1
			label $f.x -text "×" -background $bg -foreground $fg \
				-font RioUIFont -padx 3
			# Press/drag/release on the handle body: a plain click activates, a
			# drag past the threshold moves the tab to the group under the pointer.
			foreach w [list $f $f.l] {
				bind $w <ButtonPress-1>   [list tab_drag_start $id $g %X %Y]
				bind $w <B1-Motion>       [list tab_drag_motion %X %Y]
				bind $w <ButtonRelease-1> [list tab_drag_end $id $g %X %Y]
			}
			bind $f.x <Button-1> [list close_tab $id $g]
			# Right-click anywhere on the handle (frame, label, ×) for the context menu.
			foreach w [list $f $f.l $f.x] {
				bind $w <Button-3> [list tab_context_menu $g $id %X %Y]
			}
			pack $f.l -side left ; pack $f.x -side right
			pack $f -side left -padx 1 -pady 1
		}
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

# Apply the active theme's colours/fonts to one editor group: its text surface,
# scrollbar-corner frame, tab strip, and the D32 syntax tags. Shared by apply_theme
# (all groups on a theme switch) and add_group (a freshly-split group). Reads the
# role table from ::theme_colors, which apply_theme sets before calling this.
proc restyle_group {g} {
	set c $::theme_colors
	set t [gw $g]
	$t configure -font RioEditorFont \
		-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
		-insertbackground [dict get $c editor.cursor] \
		-selectbackground [dict get $c editor.selection]
	[gget $g frame] configure -background [dict get $c editor.bg]
	[gget $g tabs]  configure -background [dict get $c tab.bar.bg]
	if {[info procs rio::syntax::tokens] ne ""} {
		foreach tok [rio::syntax::tokens] {
			set role syntax.$tok
			set col [expr {[dict exists $c $role] ? [dict get $c $role] : [dict get $c editor.fg]}]
			$t tag configure syn:$tok -foreground $col
		}
	}
	# The find bar's match paint (D36); the selection stays on top so the
	# current match reads over the findmatch band.
	set fm [expr {[dict exists $c editor.findmatch] \
		? [dict get $c editor.findmatch] : [dict get $c editor.selection]}]
	$t tag configure findmatch -background $fm
	$t tag raise sel
}

proc apply_theme {theme} {
	set c [dict get $theme colors]
	set ::theme_colors $c
	ensure_fonts [dict get $theme fonts]
	# Editor surface — every group's widget, frame, tab strip, and syntax tags (D33).
	# Reconfiguring here recolours existing highlighting live on a theme switch; the
	# highlight passes raise the sel tag so a selection stays legible over the colours.
	foreach _g $::groups { restyle_group $_g }
	# Chrome: status bar + dock divider. The tab strips live inside each group and are
	# recoloured by refresh_tabs (called at the end of apply_theme).
	.status configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
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
	.chat.status configure -font RioUIFont \
		-background [dict get $c tab.bar.bg] -foreground [dict get $c ui.fg]
	# Speaker headers get a full-width highlight band so each turn is easy to find in
	# the log (diffs, tool lines, replies). The label's trailing newline is in the tag
	# range, so the background fills to the right edge. Two tints keep You vs Agent apart.
	.chat.log tag configure agent-label -font RioUIFont -foreground [dict get $c accent] \
		-background [dict get $c ui.bg] -spacing1 4 -spacing3 2
	.chat.log tag configure you-label   -font RioUIFont -foreground [dict get $c chat.fg] \
		-background [dict get $c editor.selection] -spacing1 4 -spacing3 2
	.chat.log tag configure error-label -font RioUIFont -foreground [dict get $c error]
	.chat.log tag configure tool        -font RioUIFont -foreground [dict get $c gutter.fg]
	.chat.log tag configure tool-error  -font RioUIFont -foreground [dict get $c error]
	.chat.log tag configure diff-add    -font RioUIFont -foreground [dict get $c diff.added]
	.chat.log tag configure diff-del    -font RioUIFont -foreground [dict get $c diff.removed]
	.chat.approve configure -background [dict get $c chat.bg]
	.chat.approve.lbl configure -font RioUIFont \
		-background [dict get $c chat.bg] -foreground [dict get $c chat.fg]
	.chat.approve.yes configure -font RioUIFont
	.chat.approve.no  configure -font RioUIFont
	.chat.approve.cmp configure -font RioUIFont
	.csash configure -background [dict get $c tab.bar.bg]
	.chat.isash configure -background [dict get $c tab.bar.bg]
	# The find/replace bar (D36): UI chrome, entries on the editor surface.
	.find configure -background [dict get $c ui.bg]
	foreach w {.find.fl .find.rl .find.count .find.close .find.case} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	.find.case configure -activebackground [dict get $c ui.bg] \
		-activeforeground [dict get $c ui.fg]
	foreach w {.find.next .find.prev .find.rep .find.repall} {
		$w configure -font RioUIFont
	}
	foreach w {.find.e .find.re} {
		$w configure -font RioChatFont \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg] \
			-insertbackground [dict get $c editor.cursor]
	}
	# The compare/diff view (D28): the panes take the editor surface, the headers the
	# UI chrome (like the dock); row tags tint removed/added lines and grey the
	# fillers so a changed line reads as a coloured band (VSCode-style).
	foreach w {.cmp.l.hdr .cmp.r.hdr} {
		$w configure -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	}
	foreach w {.cmp.l.t .cmp.r.t} {
		$w configure -font RioEditorFont \
			-background [dict get $c editor.bg] -foreground [dict get $c editor.fg]
		$w tag configure del    -background [dict get $c diff.removed.bg] -foreground [dict get $c diff.removed]
		$w tag configure add    -background [dict get $c diff.added.bg] -foreground [dict get $c diff.added]
		$w tag configure filler -background [dict get $c ui.bg]
	}
	.cmp.sb configure -background [dict get $c ui.bg]
	.cmp.bar configure -background [dict get $c ui.bg]
	.cmp.bar.close configure -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	style_selector
	# Named-font defaults for widgets created later (dialogs, the future chat pane).
	option add *Text.font RioEditorFont
	option add *Label.font RioUIFont
	if {[dict size $::buffers]} refresh_tabs
}

# Switch themes live (View menu): re-fetch from the core and re-apply.
proc do_theme {name} {
	set resp [rio_call theme.get [dict create name $name]]
	if {[dict get $resp ok]} {
		set ::theme_name $name
		set ::theme_choice $name
		apply_theme [dict get $resp result]
		prefs_save
	} else {
		# The menu radio moved before we knew (a radiobutton sets its variable,
		# then runs its command): snap it back to the theme still applied, so the
		# menu never claims a theme the editor isn't wearing.
		set ::theme_choice $::theme_name
		report_error "Theme '$name': [dict get $resp error message]" \
			[dict get $resp error code]
	}
}

# Fill the View ▸ Theme cascade from the core's theme.list — one radio per
# loadable theme, so a theme installed from a repository (D39) appears with no
# menu wiring of its own (the modes_menu_fill pattern). An older remote core
# without theme.list keeps the shipped four.
proc themes_menu_fill {} {
	if {![winfo exists .m.view.theme]} return
	set names {default solarized-dark solarized-light acme}
	set resp [rio_call theme.list {}]
	if {[dict get $resp ok]} { set names [dict get $resp result themes] }
	.m.view.theme delete 0 end
	foreach name $names {
		.m.view.theme add radiobutton -label [theme_label $name] \
			-variable ::theme_choice -value $name -command [list do_theme $name]
	}
}

# "solarized-dark" -> "Solarized Dark": menu labels derive from theme file names.
proc theme_label {name} {
	set words {}
	foreach w [split $name -] { lappend words [string totitle $w] }
	return [join $words " "]
}

# ---------------------------------------------------------------------------
# Syntax highlighting (AGENTS.md D32). Highlighting is PRESENTATION, so the GUI
# owns it: pure, swappable per-line scanner modules live in syntax/ (Tk-free — a
# future TUI reuses them), and the GUI is the *applier*. It maps each token TYPE
# onto the theme's syntax.* colour role as a text tag (apply_theme), and re-tokenises
# the active buffer after edits.
#
# Re-highlighting is INCREMENTAL. A full pass (hl_full) runs only on open/switch: it
# scans every line and, as it goes, caches the scan state ENTERING each line in
# ::hl_enter. After an edit (hl_edit) only the changed line's state can differ, so
# hl_incremental re-scans from the first dirty line DOWNWARD and stops as soon as a
# line's freshly-computed entry state matches the cached one (past the edit) — the
# state has re-converged, so every line below is unchanged. Typing thus re-tags a
# handful of lines, not the whole file, while multi-line context (open comments,
# script bodies, quoted values that carry state across lines) stays correct. Edits
# are coalesced on the idle handler so a burst of keystrokes paints once.
#
# Viewport scoping (painting only the visible window, extending on scroll) is a
# further refinement, still deferred: incremental already removes the per-edit
# whole-buffer scan; viewport would only cap the one-time open scan on very large
# files, at the cost of scroll-event machinery the editor doesn't yet need.
# ---------------------------------------------------------------------------

# Load the tokeniser modules: the registry (the contract) then every language
# module. Shipped modules load first, then the user's own from
# $XDG_CONFIG_HOME/rio/syntax/, so a drop-in file re-registering an extension
# replaces the shipped highlighter (the same override idea as user themes, D24). A
# broken module is reported, not fatal — it must never stop the editor from starting.
proc hl_load {} {
	set base [file join $::rio_dir .. syntax]
	if {[catch {source [file join $base registry.tcl]} err]} {
		puts stderr "rio-gui: syntax registry failed to load: $err" ; return
	}
	foreach dir [list $base [hl_user_dir]] {
		if {$dir eq "" || ![file isdirectory $dir]} continue
		foreach f [lsort [glob -nocomplain -directory $dir *.tcl]] {
			if {[file tail $f] eq "registry.tcl"} continue
			if {[catch {source $f} err]} {
				puts stderr "rio-gui: syntax module [file tail $f] failed to load: $err"
			}
		}
	}
}

# The user's drop-in highlighter dir (beside the user themes dir, D21 locations).
proc hl_user_dir {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio syntax]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio syntax]
	}
	return ""
}

# ---------------------------------------------------------------------------
# Editing modes (AGENTS.md D38): windows / emacs / vi, loaded exactly like the
# syntax highlighters — registry first, shipped modules, then user drop-ins that
# shadow by re-registering. The active mode lives on the shared RioMode bind tag,
# which make_editor_group slots between each text widget and Tk's Text class:
#
#     .eg<g>.t   RioMode   Text   .   all
#
# so the precedence is fixed by construction: app keymap chords (on the widget
# path, D23) always beat the mode; mode bindings that `break` beat Tk's Text
# defaults; mode bindings that don't fall through to them.
# ---------------------------------------------------------------------------
proc modes_load {} {
	set base [file join $::rio_dir .. modes]
	if {[catch {source [file join $base registry.tcl]} err]} {
		puts stderr "rio-gui: modes registry failed to load: $err" ; return
	}
	foreach dir [list $base [modes_user_dir]] {
		if {$dir eq "" || ![file isdirectory $dir]} continue
		foreach f [lsort [glob -nocomplain -directory $dir *.tcl]] {
			if {[file tail $f] eq "registry.tcl"} continue
			if {[catch {source $f} err]} {
				puts stderr "rio-gui: mode module [file tail $f] failed to load: $err"
			}
		}
	}
}

# The user's drop-in modes dir (a sibling of the syntax and themes dirs, D21).
proc modes_user_dir {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio modes]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio modes]
	}
	return ""
}

# The one applier for ::edit_mode (the D31 pattern: menu radio and boot both land
# here). Detach the outgoing mode, wipe the tag centrally — a mode can never leak
# a binding — then attach the new one. A persisted mode that no longer exists
# falls back to the default rather than erroring at startup (same spirit as the
# theme fallback).
proc apply_editmode {} {
	if {[info commands rio::modes::exists] eq ""} return
	if {![rio::modes::exists $::edit_mode]} {
		if {![rio::modes::exists windows]} return
		set ::edit_mode windows
	}
	if {$::editmode_active ne ""} {
		catch { rio::modes::detach $::editmode_active RioMode }
	}
	foreach seq [bind RioMode] { bind RioMode $seq "" }
	set ::editmode_status ""
	rio::modes::attach $::edit_mode RioMode
	set ::editmode_active $::edit_mode
	refresh_status
	prefs_save
}

# Fill the Settings ▸ Editing Mode cascade from the registry — one radio per
# registered mode, so a user drop-in shows up with no menu wiring of its own.
proc modes_menu_fill {} {
	if {![winfo exists .m.settings.editmode]} return
	.m.settings.editmode delete 0 end
	if {[info commands rio::modes::names] eq ""} return
	foreach name [rio::modes::names] {
		.m.settings.editmode add radiobutton -label [rio::modes::label $name] \
			-variable ::edit_mode -value $name -command apply_editmode
	}
}

# Pick the scanner for group `g`'s active buffer by its file extension ("" = no
# highlighter, e.g. a scratch buffer or a plain-text file). Runs on open / switch.
# The scanner + language name live in the group's cache, one per editor widget (D33).
proc hl_select {g} {
	gset $g hl_scan "" ; gset $g hl_lang ""
	if {[info procs rio::syntax::for_path] eq ""} return
	set id [gcur $g]
	if {$id eq "" || ![dict exists $::buffers $id]} return
	set path [bufget $id path]
	if {$path ne ""} {
		gset $g hl_scan [rio::syntax::for_path $path]
		gset $g hl_lang [rio::syntax::lang_for_path $path]
	}
}

# Widget `t`'s current line count (1-based; a Tk text widget always has at least line
# 1). A group's hl_enter is kept the same length, so index i-1 is line i's state.
proc hl_linecount {t} {
	return [lindex [split [$t index "end-1c"] .] 0]
}

# Re-tag one line L of widget `t` with scanner `scan`, from its already-known entry
# `state`/`param`: scan it, clear the old syntax tags on just that line, repaint, and
# return the state ENTERING line L+1.
proc hl_paint_line {t scan L state param} {
	set line [$t get $L.0 "$L.0 lineend"]
	lassign [rio::syntax::scan_line $scan $line $state $param] spans state param
	foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok $L.0 "$L.0 lineend" }
	foreach {c0 c1 type} $spans { $t tag add syn:$type $L.$c0 $L.$c1 }
	return [list $state $param]
}

# Full (re)highlight of group `g`'s whole buffer, rebuilding its line-state cache from
# the start state. Runs on open / switch; with no scanner it just leaves the text
# plain. Reads text from the widget (which already holds the canonical content) — no
# core call.
proc hl_full {g} {
	gset $g hl_pending 0 ; gset $g hl_dirty 0 ; gset $g hl_lastchanged 0 ; gset $g hl_enter {}
	set t [gw $g]
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	foreach tok [rio::syntax::tokens] { $t tag remove syn:$tok 1.0 end }
	set scan [gget $g hl_scan]
	if {$scan eq ""} return
	set last [hl_linecount $t]
	lassign [rio::syntax::start] state param
	set enter {}
	for {set L 1} {$L <= $last} {incr L} {
		lappend enter [list $state $param]            ;# state entering line L
		lassign [hl_paint_line $t $scan $L $state $param] state param
	}
	gset $g hl_enter $enter
	catch {$t tag raise sel}   ;# keep a selection legible over the colours
}

# Record an edit in group `g` for its next incremental pass. The core echoes every
# change as {start end text}; from that we know the first line touched (sl) and the net
# change in line count (delta). We splice the group's hl_enter by delta so the cached
# entry states BELOW the edit stay index-aligned with the widget — that alignment is
# what lets hl_incremental trust the cache when testing for state convergence. Then we
# widen the dirty range and queue a coalesced pass.
proc hl_edit {g p} {
	set scan [gget $g hl_scan] ; set enter [gget $g hl_enter]
	if {$scan eq "" || $enter eq ""} { hl_schedule $g ; return }
	set sl [lindex [split [dict get $p start] .] 0]
	set el [lindex [split [dict get $p end]   .] 0]
	set added [expr {[llength [split [dict get $p text] "\n"]] - 1}]
	set delta [expr {$added - ($el - $sl)}]
	if {$delta > 0} {
		set pad {} ; for {set i 0} {$i < $delta} {incr i} { lappend pad [list "￿dirty" ""] }
		set enter [linsert $enter $sl {*}$pad]
	} elseif {$delta < 0} {
		set enter [lreplace $enter $sl [expr {$sl - $delta - 1}]]
	}
	gset $g hl_enter $enter
	set dirty [gget $g hl_dirty]
	if {$dirty < 1 || $sl < $dirty} { gset $g hl_dirty $sl }
	set lc [expr {$sl + $added}]
	if {$lc > [gget $g hl_lastchanged]} { gset $g hl_lastchanged $lc }
	hl_schedule $g
}

# Incremental re-highlight of group `g` (the idle handler). Re-scan from the first
# dirty line down, repainting each line and updating its cached entry state, and stop
# as soon as — past the edited region — a line's fresh entry state matches the one
# already cached: the scan state has re-converged, so everything below is unaffected.
proc hl_incremental {g} {
	gset $g hl_pending 0
	set t [gw $g]
	if {![winfo exists [gget $g path]] || [info procs rio::syntax::tokens] eq ""} return
	set scan [gget $g hl_scan]
	if {$scan eq ""} { gset $g hl_dirty 0 ; return }
	set enter [gget $g hl_enter]
	if {$enter eq ""} { hl_full $g ; return }
	set start [gget $g hl_dirty] ; set last [gget $g hl_lastchanged]
	gset $g hl_dirty 0 ; gset $g hl_lastchanged 0
	if {$start < 1} return
	set nlines [hl_linecount $t]
	if {$start > $nlines} return
	if {[llength $enter] != $nlines} { hl_full $g ; return }  ;# cache drifted — rebuild safely
	set scanned 0
	lassign [lindex $enter [expr {$start - 1}]] state param
	for {set L $start} {$L <= $nlines} {incr L} {
		lassign [hl_paint_line $t $scan $L $state $param] state param
		incr scanned
		if {$L == $nlines} break            ;# no line below to carry state into
		set next [list $state $param]
		set old [lindex $enter $L]           ;# cached state entering line L+1
		lset enter $L $next
		if {$L >= $last && $next eq $old} break   ;# past the edit and re-converged
	}
	gset $g hl_enter $enter
	gset $g hl_scanned $scanned
	catch {$t tag raise sel}
}

# Queue a coalesced incremental pass on group `g`'s idle handler, so a run of
# keystrokes triggers a single re-scan rather than one pass per character.
proc hl_schedule {g} {
	if {[gget $g hl_pending]} return
	gset $g hl_pending 1
	after idle [list hl_incremental $g]
}

# ---------------------------------------------------------------------------
# Sessions & preferences (AGENTS.md D31). Two halves, split by owner:
#
#   * PREFERENCES — how the editor looks: theme, wrap, dock side/pane, chat
#     visibility. Pure view state the core knows nothing about, so the GUI owns it,
#     in $XDG_CONFIG_HOME/rio/prefs.json (beside the user themes dir). Plain JSON
#     data, parsed never executed (D21); loaded at startup, saved on each change.
#
#   * WORKSPACE — which files were open in a project + the active tab. Document
#     state, so the CORE owns it (workspace.* ops, keyed by project root, kept OUT
#     OF TREE under its data dir). That is why a resume Just Works over a remote
#     core: the session lives WITH the project, on the server (D30/D31).
#
# Neither ever holds a secret (the API key stays in the 0600 store, D26). Writes are
# gated on ::rio_started so the appliers that also run during boot don't persist the
# defaults back over what was just loaded.
# ---------------------------------------------------------------------------
proc prefs_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio prefs.json]
}

# Load saved preferences over the defaults. A missing or corrupt file leaves the
# defaults intact — a bad prefs file must never stop the editor starting. Only known
# keys with valid values are honoured; anything else is ignored.
proc prefs_load {} {
	set path [prefs_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {
		set f [open $path r] ; fconfigure $f -encoding utf-8
		set d [json::json2dict [::read $f]] ; close $f
	}]} return
	if {[dict exists $d theme]}      { set ::theme_name [dict get $d theme] }
	if {[dict exists $d wrap]}       { set ::wrap_lines [expr {[dict get $d wrap] ? 1 : 0}] }
	if {[dict exists $d chat_shown]} { set ::chat_shown [expr {[dict get $d chat_shown] ? 1 : 0}] }
	if {[dict exists $d dock_side] && [dict get $d dock_side] in {left right}} {
		set ::dock_side [dict get $d dock_side]
	}
	if {[dict exists $d dock_pane] && [dict get $d dock_pane] in {files git}} {
		set ::dock_pane [dict get $d dock_pane]
	}
	if {[dict exists $d editmode]} { set ::edit_mode [dict get $d editmode] }
}

# Persist the current preferences. Called from each view-state applier (do_theme,
# apply_wrap, place_dock, show_pane) — the single choke point per setting — so any
# menu or keyboard toggle records itself. Values are flat strings (rio::wire::obj);
# 0/1 flags read back cleanly through expr.
proc prefs_save {} {
	if {!$::rio_started} return
	set path [prefs_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set json [rio::wire::obj [dict create \
			theme      $::theme_name \
			wrap       $::wrap_lines \
			dock_side  $::dock_side \
			dock_pane  $::dock_pane \
			chat_shown $::chat_shown \
			editmode   $::edit_mode]]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f $json ; close $f
	}
}

# Save the open project's workspace: the paths of the open tabs (untitled/unsaved
# tabs, which have no path, are omitted) and the active tab's path. The core keys it
# by the open project root and no-ops when none is open, so this is safe to call
# unconditionally. `open` rides the wire as a newline-joined string (workspace.*).
proc session_save {} {
	if {!$::rio_started} return
	set paths {}
	foreach id [dict keys $::buffers] {
		set p [bufget $id path]
		if {$p ne ""} { lappend paths $p }
	}
	set active [expr {$::cur ne "" ? [bufget $::cur path] : ""}]
	catch {rio_call workspace.save [dict create open [join $paths "\n"] active $active]}
}

# Restore the open project's workspace: reopen each saved file (the core has already
# pruned any that vanished) and focus the saved active tab. do_open dedups against
# open tabs and prunes the empty scratch buffer, so restoring onto a fresh launch
# leaves exactly the saved set. Runs during boot only, while ::rio_started is still 0
# — so the do_opens here don't each trigger a save.
proc session_restore {} {
	set resp [rio_call workspace.get {}]
	if {![dict get $resp ok]} return
	set res [dict get $resp result]
	foreach p [dict get $res open] { do_open $p }
	set active [dict get $res active]
	if {$active ne ""} {
		foreach id [dict keys $::buffers] {
			if {[bufget $id path] eq $active} { activate $id ; break }
		}
	}
}

# ---------------------------------------------------------------------------
# Extension repositories (AGENTS.md D39). The apt-sources model, over plain
# HTTP: sources.list holds base URLs, each pointing at a webdir that hosts
# rio-repository.conf (the marker+manifest), an optional `index`, and one
# subdirectory per extension carrying rio-extension.conf + its payload files.
# No central index, no accounts — provenance (source URL + version) is
# recorded per installed extension in a local ledger, and same-name extensions
# from different sources coexist in listings for the USER to choose between.
#
# The split of labour: the CORE fetches (repo.fetch — bounded, plain http, so
# a remote core uses ITS network) and stores themes (theme.put/delete — theme
# files are the core's to read); the GUI interprets — parses manifests (conf
# DATA, never executed), asks consent, installs syntax/mode payloads into its
# own drop-in dirs (they run in the FRONTEND), and keeps the ledger. Remote
# caveat, recorded honestly: the ledger says "this GUI installed X onto its
# core" — a second frontend on the same daemon doesn't see it (ROADMAP).
#
# Every REMOTE-SUPPLIED name (extension dir, name, kind, payload filename)
# must pass ext_safe_name before it is joined into a URL or a path — that one
# rule kills traversal and percent-encoding games at the format level.
# ---------------------------------------------------------------------------

set ::ext_ledger {}     ;# "kind/name" -> {source dir version files installed} (ledger_load)
set ::repo_variants {}  ;# every installable variant found by the last scan
set ::repo_dead {}      ;# {url error} per unreachable/non-repository source
set ::repo_srcinfo {}   ;# source url -> {name description} from its manifest

proc ext_safe_name {s} {
	return [regexp {^[A-Za-z0-9][A-Za-z0-9._-]*$} $s]
}

# --- sources.list -------------------------------------------------------------
proc sources_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio sources.list]
}

# One base URL per line, # comments — hand-editable; the Repositories… editor
# writes the same format back.
proc sources_load {} {
	set path [sources_path]
	if {$path eq "" || ![file exists $path]} { return {} }
	set urls {}
	if {[catch {
		set f [open $path r] ; fconfigure $f -encoding utf-8
		set text [::read $f] ; close $f
	}]} { return {} }
	foreach line [split $text "\n"] {
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		if {$t ni $urls} { lappend urls $t }
	}
	return $urls
}

proc sources_save {urls} {
	set path [sources_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts $f "# rio extension repositories — one http:// base URL per line (D39)."
		foreach u $urls { puts $f $u }
		close $f
	}
}

# --- the provenance ledger ----------------------------------------------------
proc ledger_path {} {
	if {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne ""} {
		set base $::env(XDG_DATA_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .local share]
	} else { return "" }
	return [file join $base rio extensions.json]
}

# Machine-written JSON: {"kind/name": {source, dir, version, installed,
# files:[…]}, …}. Corrupt or missing -> an empty ledger, never fatal — the
# worst outcome is "rio forgot where an extension came from", not a crash.
proc ledger_load {} {
	set ::ext_ledger {}
	set path [ledger_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {
		set f [open $path r] ; fconfigure $f -encoding utf-8
		set d [json::json2dict [::read $f]] ; close $f
		dict for {key e} $d {
			foreach k {source dir version files installed} {
				if {![dict exists $e $k]} { error "entry $key missing $k" }
			}
		}
		set ::ext_ledger $d
	}]} { set ::ext_ledger {} }
}

proc ledger_entry_json {e} {
	set parts {}
	foreach k {source dir version installed} {
		lappend parts "[rio::wire::str $k]:[rio::wire::str [dict get $e $k]]"
	}
	lappend parts "\"files\":[rio::wire::strarr [dict get $e files]]"
	return "{[join $parts ,]}"
}

proc ledger_save {} {
	set path [ledger_path]
	if {$path eq ""} return
	catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f [rio::wire::objmap $::ext_ledger ledger_entry_json]
		close $f
	}
}

# --- fetching & scanning ------------------------------------------------------

# The one fetch seam: repo.fetch through the core, never throwing — the return
# is {ok 1 status <n> text <t>} or {ok 0 error <msg>}. Tests stub THIS proc
# with a fixture table (no network in tests, D39).
proc repo_fetch {url} {
	set resp [rio_call repo.fetch [dict create url $url]]
	if {[dict get $resp ok]} {
		return [dict create ok 1 status [dict get $resp result status] \
			text [dict get $resp result text]]
	}
	return [dict create ok 0 error [dict get $resp error message]]
}

# The `index` file: one extension-subdir name per line, # comments. A line
# that fails the safe-name rule is skipped, not fatal — one bad entry must not
# hide the rest of a repository.
proc repo_parse_index {text} {
	set dirs {}
	foreach line [split $text "\n"] {
		set t [string trim $line]
		if {$t eq "" || [string index $t 0] eq "#"} continue
		if {[ext_safe_name $t] && $t ni $dirs} { lappend dirs $t }
	}
	return $dirs
}

# The autoindex fallback: when a repository omits `index`, the server's own
# directory listing stands in. One tolerant pass — every href ending in "/"
# whose name passes the safe-name rule is a candidate subdirectory; that one
# filter drops ../, absolute URLs, query links (Apache's ?C=N;O=D), and any
# percent-encoded name in a single stroke. Verified against canned Apache,
# nginx, and OpenBSD-httpd listings in the test suite.
proc repo_parse_autoindex {html} {
	set dirs {}
	foreach {m name} [regexp -all -inline -nocase {href="([^"]+)/"} $html] {
		if {[ext_safe_name $name] && $name ni $dirs} { lappend dirs $name }
	}
	return $dirs
}

# Scan ONE source: the marker manifest (required — anything without a parseable
# rio-repository.conf carrying name= is "not a rio repository"), then the
# extension list (index, else autoindex), then each extension's manifest.
# Returns {ok 1 name <n> description <d> exts {<variant>…}} or {ok 0 error <e>};
# a malformed extension manifest skips that extension, never the source.
# A variant dict: {source dir name kind version author description files}.
proc repo_source_scan {base} {
	set base [string trimright $base /]
	set r [repo_fetch $base/rio-repository.conf]
	if {![dict get $r ok]} {
		return [dict create ok 0 error [dict get $r error]]
	}
	if {[dict get $r status] != 200
			|| [catch {rio::conf::parse [dict get $r text]} conf]
			|| ![dict exists $conf "" name]} {
		return [dict create ok 0 error "not a rio repository (no usable rio-repository.conf)"]
	}
	set srcname [dict get $conf "" name]
	set srcdesc [expr {[dict exists $conf "" description] ? [dict get $conf "" description] : ""}]
	set dirs {}
	set ir [repo_fetch $base/index]
	if {[dict get $ir ok] && [dict get $ir status] == 200} {
		set dirs [repo_parse_index [dict get $ir text]]
	} else {
		set ar [repo_fetch $base/]
		if {[dict get $ar ok] && [dict get $ar status] == 200} {
			set dirs [repo_parse_autoindex [dict get $ar text]]
		}
	}
	set exts {}
	foreach d $dirs {
		set mr [repo_fetch $base/$d/rio-extension.conf]
		if {![dict get $mr ok] || [dict get $mr status] != 200} continue
		if {[catch {rio::conf::parse [dict get $mr text]} mc]} continue
		set top [expr {[dict exists $mc ""] ? [dict get $mc ""] : {}}]
		set ok 1
		foreach k {name kind version files} {
			if {![dict exists $top $k]} { set ok 0 }
		}
		if {!$ok} continue
		set name [dict get $top name]
		set kind [dict get $top kind]
		if {![ext_safe_name $name] || ![ext_safe_name $kind]} continue
		set files {}
		foreach f [split [dict get $top files]] {
			if {$f eq ""} continue
			if {![ext_safe_name $f]} { set ok 0 ; break }
			lappend files $f
		}
		if {!$ok || ![llength $files]} continue
		lappend exts [dict create \
			source $base dir $d name $name kind $kind \
			version [dict get $top version] \
			author [expr {[dict exists $top author] ? [dict get $top author] : "unknown"}] \
			description [expr {[dict exists $top description] ? [dict get $top description] : ""}] \
			files $files]
	}
	return [dict create ok 1 name $srcname description $srcdesc exts $exts]
}

# Scan every configured source into ::repo_variants / ::repo_dead /
# ::repo_srcinfo. A dead source is one honest row, never a failed scan.
# `progress` (optional command prefix) is told each source URL as it starts —
# the Extensions window's status line.
proc repo_scan_all {{progress ""}} {
	set ::repo_variants {}
	set ::repo_dead {}
	set ::repo_srcinfo {}
	set srcs [sources_load]
	set n 0
	foreach src $srcs {
		incr n
		if {$progress ne ""} { {*}$progress $src $n [llength $srcs] }
		set s [repo_source_scan $src]
		if {![dict get $s ok]} {
			lappend ::repo_dead [list $src [dict get $s error]]
			continue
		}
		dict set ::repo_srcinfo $src [dict create \
			name [dict get $s name] description [dict get $s description]]
		foreach v [dict get $s exts] { lappend ::repo_variants $v }
	}
}

# --- installing & removing ----------------------------------------------------

# The kind -> install-target map: the ONLY version-specific piece of the whole
# format (D39's forward-compatibility contract). A kind not listed here still
# LISTS in the window — greyed "(needs a newer rio)" — it just can't install.
proc ext_kind_known {kind} {
	return [expr {$kind in {syntax mode theme}}]
}

proc ext_kind_dir {kind} {
	switch -- $kind {
		syntax { return [hl_user_dir] }
		mode   { return [modes_user_dir] }
	}
	return ""
}

# Does any OTHER ledger entry of this kind own one of these payload filenames?
# Payloads of one kind share a flat drop-in dir, so a name collision would let
# extension B silently overwrite extension A's file — refuse instead.
proc ext_file_owner {kind name files} {
	dict for {key e} $::ext_ledger {
		lassign [split $key /] ekind ename
		if {$ekind ne $kind || $ename eq $name} continue
		foreach f $files {
			if {$f in [dict get $e files]} { return $ename }
		}
	}
	return ""
}

# Install one variant (a dict out of ::repo_variants): consent -> fetch ALL
# payloads -> write -> activate -> ledger. Returns 1 installed / 0 not.
# Nothing is written until every payload arrived intact, and a half-failed
# write rolls the files back — an install is all-or-nothing on disk.
proc ext_install {variant} {
	dict with variant {}  ;# source dir name kind version author description files
	if {![ext_kind_known $kind]} {
		report_error "'$name' has kind '$kind', which this rio doesn't know — it needs a newer rio."
		return 0
	}
	set key $kind/$name
	# Consent, stated honestly: code is code, data is data, and the source URL
	# is the provenance the user is trusting.
	if {$kind eq "theme"} {
		set what "'$name' is a THEME: colour/font data, parsed and never executed."
	} else {
		set what "'$name' is Tcl CODE that will run inside your editor with your permissions."
	}
	set msg "Install $kind '$name' $version by $author?\n\n$what\n\nFrom: $source"
	if {[dict exists $::ext_ledger $key]} {
		set old [dict get $::ext_ledger $key]
		set msg "$msg\n\nReplaces the installed '$name' [dict get $old version] from [dict get $old source]."
	}
	if {[tk_messageBox -icon warning -type yesno -title "rio — install extension" \
			-message $msg] ne "yes"} { return 0 }
	set owner [ext_file_owner $kind $name $files]
	if {$owner ne ""} {
		report_error "Cannot install '$name': its payload would overwrite files owned by the installed $kind '$owner'."
		return 0
	}
	# Fetch everything first; only then touch disk.
	set payload {}
	foreach f $files {
		set r [repo_fetch $source/$dir/$f]
		if {![dict get $r ok] || [dict get $r status] != 200} {
			set why [expr {[dict get $r ok] ? "HTTP [dict get $r status]" : [dict get $r error]}]
			report_error "Install of '$name' aborted: $f could not be fetched ($why). Nothing was changed."
			return 0
		}
		dict set payload $f [dict get $r text]
	}
	if {$kind eq "theme"} {
		if {![ext_install_theme $name $payload]} { return 0 }
	} else {
		if {![ext_install_files $kind $name $payload]} { return 0 }
	}
	dict set ::ext_ledger $key [dict create \
		source $source dir $dir version $version files $files \
		installed [clock format [clock seconds] -format %Y-%m-%d]]
	ledger_save
	return 1
}

# Write syntax/mode payloads into the kind's drop-in dir, then reload that
# machinery so the extension is live at once — install is drop-the-file, the
# same act as D32/D38 by hand, just performed by rio. Failure rolls back:
# previously-existing files are restored, fresh ones removed.
proc ext_install_files {kind name payload} {
	set dstdir [ext_kind_dir $kind]
	if {$dstdir eq ""} { report_error "No user $kind directory resolvable (no HOME?)." ; return 0 }
	set undo {}
	if {[catch {
		file mkdir $dstdir
		dict for {f text} $payload {
			set p [file join $dstdir $f]
			if {[file exists $p]} {
				set old [open $p r] ; fconfigure $old -encoding utf-8
				lappend undo restore $p [::read $old] ; close $old
			} else {
				lappend undo delete $p ""
			}
			set out [open $p {WRONLY CREAT TRUNC}] ; fconfigure $out -encoding utf-8
			puts -nonewline $out $text ; close $out
		}
	} err]} {
		foreach {what p text} $undo {
			catch {
				if {$what eq "delete"} { file delete $p } else {
					set out [open $p {WRONLY CREAT TRUNC}] ; fconfigure $out -encoding utf-8
					puts -nonewline $out $text ; close $out
				}
			}
		}
		report_error "Install of '$name' failed writing files: $err. Rolled back."
		return 0
	}
	ext_reload $kind
	return 1
}

# Themes install CORE-side through theme.put — each payload file becomes the
# theme named by its rootname (night.theme -> night), validated by the core
# before anything lands. On a partial failure the already-put files of this
# install are deleted again (best effort — the core validated them going in,
# so in practice the first failure is also the last).
proc ext_install_theme {name payload} {
	set put {}
	dict for {f text} $payload {
		set tname [file rootname $f]
		set resp [rio_call theme.put [dict create name $tname text $text]]
		if {![dict get $resp ok]} {
			foreach t $put { catch {rio_call theme.delete [dict create name $t]} }
			report_error "Install of theme '$name' failed at $f: [dict get $resp error message]" \
				[dict get $resp error code]
			return 0
		}
		lappend put $tname
	}
	ext_reload theme
	return 1
}

# Remove an installed extension by ledger key parts. Files (or core-side
# themes) go first, the ledger entry last — a failed delete leaves the entry,
# so Remove can be retried; a vanished file is already what delete wanted.
proc ext_remove {kind name} {
	set key $kind/$name
	if {![dict exists $::ext_ledger $key]} { return 0 }
	set e [dict get $::ext_ledger $key]
	if {$kind eq "theme"} {
		foreach f [dict get $e files] {
			catch {rio_call theme.delete [dict create name [file rootname $f]]}
		}
	} else {
		set dstdir [ext_kind_dir $kind]
		foreach f [dict get $e files] {
			catch {file delete [file join $dstdir $f]}
		}
	}
	dict unset ::ext_ledger $key
	ledger_save
	ext_reload $kind
	return 1
}

# Re-arm the machinery a kind plugs into, after an install or a removal:
#   syntax — reload the scanner registry, re-pick and re-paint every group;
#   mode   — reload, refill the menu, re-attach (apply_editmode falls back to
#            windows if the active mode was just removed);
#   theme  — refill the View menu; if the ACTIVE theme changed under us,
#            re-apply it — or fall back to default if it was removed.
proc ext_reload {kind} {
	switch -- $kind {
		syntax {
			hl_load
			foreach g $::groups { hl_select $g ; hl_full $g }
		}
		mode {
			modes_load
			modes_menu_fill
			apply_editmode
		}
		theme {
			themes_menu_fill
			if {$::theme_name ne "default"} {
				set resp [rio_call theme.get [dict create name $::theme_name]]
				if {[dict get $resp ok]} {
					apply_theme [dict get $resp result]
				} else {
					do_theme default
				}
			}
		}
	}
}

# ---------------------------------------------------------------------------
# The Extensions window (AGENTS.md D39): View ▸ Extensions… — where the user
# browses every configured repository, chooses BETWEEN same-name extensions
# (different authors, different versions — each variant its own line with its
# provenance), installs, and removes. Naming: the WINDOW is "Extensions" (what
# you browse); the SOURCES are "Repositories" (where they come from) — the
# header's `Repositories…` button edits sources.list.
#
# Deliberately a NON-MODAL toplevel (no grab, no tkwait): browsing repositories
# is a side activity, not a question blocking the editor — and this is rio's
# first D35-style tool window, to be re-hosted into a dock site when D35 lands.
# Non-modal means re-entry is real: ::repo_busy guards it — one scan or install
# at a time, action buttons disabled meanwhile (the sequential core_calls pump
# the event loop, so the editor itself stays live throughout).
#
# The list aggregates ONE row per (kind, name); the detail below it lists every
# VARIANT of the selected row. Unknown kinds are listed greyed ("needs a newer
# rio" — the forward-compat contract), dead sources get one honest `!!` row
# each, and an installed extension whose source vanished is synthesized from
# the ledger so Remove always works.
# ---------------------------------------------------------------------------

set ::repo_busy 0     ;# a scan or install is running: action buttons disabled
set ::extw_rows {}    ;# row dicts, index-aligned with the window's listbox

proc host_of {url} {
	if {[regexp -nocase {^http://([^/]+)} $url -> h]} { return $h }
	return $url
}

proc extensions_window {} {
	set w .extw
	if {[winfo exists $w]} { raise $w ; focus $w.body.list ; return }
	toplevel $w
	wm title $w "Extensions"
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	# Header: sources editor, refresh, filter.
	frame $w.hdr -background [dict get $c ui.bg]
	button $w.hdr.repos   -text "Repositories…" -font RioUIFont -command extw_sources_dialog
	button $w.hdr.refresh -text "⟳" -font RioUIFont -command extw_refresh  ;# ⟳ rescan (D27)
	label $w.hdr.flbl -text "Filter:" -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	entry $w.hdr.filter -font RioUIFont -width 18
	pack $w.hdr.repos $w.hdr.refresh -side left -padx {0 4}
	pack $w.hdr.filter $w.hdr.flbl -side right
	bind $w.hdr.filter <KeyRelease> extw_fill

	# The aggregated list: one row per (kind, name), plus the honest failures.
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.extw.body.list yview}
	listbox $w.body.list -height 12 -width 72 -activestyle none -exportselection 0 \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c editor.selection] \
		-selectforeground [dict get $c ui.fg] \
		-yscrollcommand {autoscroll .extw.body.sb .extw.body.list}
	pack $w.body.list -side left -fill both -expand 1
	bind $w.body.list <<ListboxSelect>> extw_select

	# The detail section: every variant of the selected row, with its own
	# Install/Remove — where the user CHOOSES between authors and versions.
	frame $w.det -background [dict get $c ui.bg]

	frame $w.foot -background [dict get $c ui.bg]
	label $w.foot.status -anchor w -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	button $w.foot.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.foot.close  -side right
	pack $w.foot.status -side left -fill x -expand 1

	grid $w.hdr  -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body -row 1 -column 0 -sticky nsew -padx 8
	grid $w.det  -row 2 -column 0 -sticky we   -padx 8 -pady 4
	grid $w.foot -row 3 -column 0 -sticky we   -padx 8 -pady {2 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	bind $w <Escape> [list destroy $w]

	extw_refresh
	focus $w.body.list
}

proc extw_status {text} {
	if {[winfo exists .extw.foot.status]} { .extw.foot.status configure -text $text }
}

# Toggle the busy guard: while a scan or install runs, every action button in
# the window is disabled — re-entry through a second click is the non-modal
# window's real hazard, and this is its one gate.
proc extw_busy {on} {
	set ::repo_busy $on
	if {![winfo exists .extw]} return
	set st [expr {$on ? "disabled" : "normal"}]
	foreach b {.extw.hdr.repos .extw.hdr.refresh} { $b configure -state $st }
	foreach f [winfo children .extw.det] {
		foreach ch [winfo children $f] {
			if {[winfo class $ch] eq "Button"} { $ch configure -state $st }
		}
	}
}

proc extw_refresh {} {
	if {$::repo_busy} return
	extw_busy 1
	repo_scan_all {apply {{src n total} {
		extw_status "fetching [host_of $src] ($n/$total)…"
		update idletasks
	}}}
	extw_busy 0
	extw_status "[llength $::repo_variants] extension(s) from [dict size $::repo_srcinfo] repositories"
	extw_fill
}

# Aggregate the scan + ledger into display rows: one per (kind, name), sorted;
# ledger-only entries (source offline or de-configured) synthesized so Remove
# still works; one `!!` row per dead source at the bottom.
proc extw_rows_build {} {
	set bykey {}
	foreach v $::repo_variants {
		dict lappend bykey "[dict get $v kind]/[dict get $v name]" $v
	}
	dict for {key e} $::ext_ledger {
		if {[dict exists $bykey $key]} continue
		lassign [split $key /] kind name
		dict set bykey $key [list [dict create \
			source [dict get $e source] dir [dict get $e dir] name $name kind $kind \
			version [dict get $e version] author "" \
			description "installed; its repository is not configured or unreachable" \
			files [dict get $e files] offline 1]]
	}
	set rows {}
	foreach key [lsort [dict keys $bykey]] {
		lassign [split $key /] kind name
		set vars [dict get $bykey $key]
		set desc ""
		foreach v $vars {
			if {[dict get $v description] ne ""} { set desc [dict get $v description] ; break }
		}
		lappend rows [dict create kind $kind name $name key $key \
			variants $vars desc $desc]
	}
	foreach d $::repo_dead {
		lappend rows [dict create dead 1 url [lindex $d 0] error [lindex $d 1]]
	}
	return $rows
}

# Fill the listbox from the rows, applying the filter; keep the selection on
# the same (kind, name) across a refill if it survived it.
proc extw_fill {} {
	if {![winfo exists .extw.body.list]} return
	set filter [string tolower [string trim [.extw.hdr.filter get]]]
	set keep ""
	set sel [.extw.body.list curselection]
	if {$sel ne "" && [dict exists [lindex $::extw_rows $sel] key]} {
		set keep [dict get [lindex $::extw_rows $sel] key]
	}
	set ::extw_rows {}
	.extw.body.list delete 0 end
	set c $::theme_colors
	foreach row [extw_rows_build] {
		if {[dict exists $row dead]} {
			if {$filter ne "" && ![string match *$filter* [string tolower [dict get $row url]]]} continue
			lappend ::extw_rows $row
			.extw.body.list insert end "!! [dict get $row url] — unreachable"
			.extw.body.list itemconfigure end -foreground [dict get $c error]
			continue
		}
		if {$filter ne "" && ![string match *$filter* \
			[string tolower "[dict get $row name] [dict get $row kind] [dict get $row desc]"]]} continue
		lappend ::extw_rows $row
		set vars [dict get $row variants]
		if {[llength $vars] > 1} {
			set from "[llength $vars] sources"
		} else {
			set from [host_of [dict get [lindex $vars 0] source]]
			if {[dict exists [lindex $vars 0] offline]} { append from " (offline)" }
		}
		set marks ""
		if {[dict exists $::ext_ledger [dict get $row key]]} { append marks " \[installed\]" }
		if {![ext_kind_known [dict get $row kind]]} { append marks " (needs a newer rio)" }
		.extw.body.list insert end \
			[format "%-16s %-7s %s%s" [dict get $row name] [dict get $row kind] $from $marks]
		if {![ext_kind_known [dict get $row kind]]} {
			.extw.body.list itemconfigure end -foreground [dict get $c gutter.fg]
		}
	}
	if {$keep ne ""} {
		for {set i 0} {$i < [llength $::extw_rows]} {incr i} {
			if {[dict exists [lindex $::extw_rows $i] key]
					&& [dict get [lindex $::extw_rows $i] key] eq $keep} {
				.extw.body.list selection set $i
				break
			}
		}
	}
	extw_select
}

# Rebuild the detail section for the selected row: the extension's header line,
# then one line per variant — `version by author — source-host` with Install,
# or [installed] + Remove on the variant the ledger says is in place. An
# installed version no longer listed by its source gets its own honest line.
proc extw_select {} {
	set det .extw.det
	if {![winfo exists $det]} return
	foreach ch [winfo children $det] { destroy $ch }
	set c $::theme_colors
	set sel [.extw.body.list curselection]
	if {$sel eq "" || $sel >= [llength $::extw_rows]} return
	set row [lindex $::extw_rows $sel]
	if {[dict exists $row dead]} {
		label $det.err -anchor w -justify left -font RioUIFont \
			-text "[dict get $row url]\n[dict get $row error]" \
			-background [dict get $c ui.bg] -foreground [dict get $c error]
		pack $det.err -fill x
		return
	}
	set head "[dict get $row name] — [dict get $row kind]"
	if {[dict get $row desc] ne ""} { append head " — [dict get $row desc]" }
	label $det.head -anchor w -font RioUIFont -text $head \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	pack $det.head -fill x -pady {0 2}
	set entry ""
	if {[dict exists $::ext_ledger [dict get $row key]]} {
		set entry [dict get $::ext_ledger [dict get $row key]]
	}
	set st [expr {$::repo_busy ? "disabled" : "normal"}]
	set i 0
	set matched 0
	foreach v [dict get $row variants] {
		set f [frame $det.v$i -background [dict get $c ui.bg]]
		set line "  [dict get $v version]"
		if {[dict get $v author] ne ""} { append line " by [dict get $v author]" }
		append line " — [host_of [dict get $v source]]"
		label $f.l -anchor w -font RioUIFont -text $line \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		set this_installed [expr {$entry ne "" \
			&& [dict get $v source]  eq [dict get $entry source] \
			&& [dict get $v version] eq [dict get $entry version]}]
		if {$this_installed} {
			set matched 1
			label $f.mark -font RioUIFont -text "\[installed\]" \
				-background [dict get $c ui.bg] -foreground [dict get $c accent]
			button $f.rm -text Remove -font RioUIFont -state $st \
				-command [list extw_remove [dict get $row kind] [dict get $row name]]
			pack $f.rm $f.mark -side right -padx 2
		} elseif {[dict exists $v offline]} {
			button $f.rm -text Remove -font RioUIFont -state $st \
				-command [list extw_remove [dict get $row kind] [dict get $row name]]
			pack $f.rm -side right -padx 2
		} elseif {[ext_kind_known [dict get $row kind]]} {
			button $f.in -text Install -font RioUIFont -state $st \
				-command [list extw_install $sel $i]
			pack $f.in -side right -padx 2
		}
		pack $f.l -side left -fill x -expand 1
		pack $f -fill x
		incr i
	}
	if {$entry ne "" && !$matched && ![dict exists [lindex [dict get $row variants] 0] offline]} {
		set f [frame $det.inst -background [dict get $c ui.bg]]
		label $f.l -anchor w -font RioUIFont \
			-text "  installed: [dict get $entry version] — [host_of [dict get $entry source]] (no longer listed there)" \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		button $f.rm -text Remove -font RioUIFont -state $st \
			-command [list extw_remove [dict get $row kind] [dict get $row name]]
		pack $f.rm -side right -padx 2
		pack $f.l -side left -fill x -expand 1
		pack $f -fill x
	}
}

proc extw_install {rowidx vidx} {
	if {$::repo_busy} return
	set row [lindex $::extw_rows $rowidx]
	set v [lindex [dict get $row variants] $vidx]
	extw_busy 1
	extw_status "installing [dict get $row name]…"
	set done [ext_install $v]
	extw_busy 0
	extw_status [expr {$done ? "installed [dict get $row name] [dict get $v version]" : "not installed"}]
	extw_fill
}

proc extw_remove {kind name} {
	if {$::repo_busy} return
	extw_busy 1
	extw_status "removing $name…"
	ext_remove $kind $name
	extw_busy 0
	extw_status "removed $name"
	extw_fill
}

# The compact sources editor behind `Repositories…`: the URLs of sources.list
# in a listbox, Remove for the selected one, an entry + Add below. Writes
# sources.list on every change (it IS the hand-editable file — this dialog is
# just a convenience over it). Modal is fine here: it's a small focused edit,
# not a browsing surface. Closing refreshes the Extensions window's scan.
proc extw_sources_dialog {} {
	set w .extsrc
	destroy $w
	toplevel $w
	wm title $w "Repositories"
	wm transient $w .extw
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]
	label $w.hint -anchor w -justify left -font RioUIFont \
		-text "Each repository is a plain http:// directory (see CONTRIBUTING.md to host one)." \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
	frame $w.body -background [dict get $c ui.bg]
	scrollbar $w.body.sb -command {.extsrc.body.list yview}
	listbox $w.body.list -height 8 -width 60 -activestyle none -exportselection 0 \
		-borderwidth 0 -highlightthickness 0 -font RioUIFont \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-selectbackground [dict get $c editor.selection] \
		-selectforeground [dict get $c ui.fg] \
		-yscrollcommand {autoscroll .extsrc.body.sb .extsrc.body.list}
	pack $w.body.list -side left -fill both -expand 1
	frame $w.add -background [dict get $c ui.bg]
	entry $w.add.url -font RioUIFont -width 44
	button $w.add.add -text Add -font RioUIFont -command extw_source_add
	pack $w.add.url -side left -fill x -expand 1
	pack $w.add.add -side left -padx {4 0}
	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.rm    -text "Remove selected" -font RioUIFont -command extw_source_remove
	button $w.btns.close -text Close -font RioUIFont -command [list destroy $w]
	pack $w.btns.close -side right
	pack $w.btns.rm    -side left
	grid $w.hint -row 0 -column 0 -sticky we   -padx 8 -pady {8 4}
	grid $w.body -row 1 -column 0 -sticky nsew -padx 8
	grid $w.add  -row 2 -column 0 -sticky we   -padx 8 -pady 4
	grid $w.btns -row 3 -column 0 -sticky we   -padx 8 -pady {2 8}
	grid rowconfigure    $w 1 -weight 1
	grid columnconfigure $w 0 -weight 1
	foreach u [sources_load] { $w.body.list insert end $u }
	bind $w.add.url <Return> extw_source_add
	bind $w <Escape> [list destroy $w]
	catch {grab $w}
	focus $w.add.url
	tkwait window $w
	extw_refresh
}

proc extw_source_add {} {
	set url [string trim [.extsrc.add.url get]]
	if {$url eq ""} return
	if {[regexp -nocase {^https://} $url]} {
		report_error "https is not supported yet — repositories are plain http:// (an operator can front a webdir with a proxy; see CONTRIBUTING.md)."
		return
	}
	if {![regexp -nocase {^http://} $url]} {
		report_error "A repository URL starts with http:// — got: $url"
		return
	}
	set urls [sources_load]
	if {$url ni $urls} {
		lappend urls $url
		sources_save $urls
		.extsrc.body.list insert end $url
	}
	.extsrc.add.url delete 0 end
}

proc extw_source_remove {} {
	set sel [.extsrc.body.list curselection]
	if {$sel eq ""} return
	set url [.extsrc.body.list get $sel]
	sources_save [lsearch -all -inline -not -exact [sources_load] $url]
	.extsrc.body.list delete $sel
}

# ---------------------------------------------------------------------------
# Build the UI. The literal colours/fonts here are just a bootstrap; apply_theme
# (below, fed by the core's theme.get) reconfigures every widget from the role
# table — the default theme reproduces this plain white-bg "90s productivity"
# look (D24), and the View menu switches it live.
# ---------------------------------------------------------------------------
# (Tabs are no longer a single top bar; each editor group draws its own strip, D33.)

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

# The editor region (AGENTS.md D33). The center is a .groups panedwindow that holds one
# or two editor GROUPS side by side with a draggable divider; each group is an
# independent text widget (with its own tab strip, scrollbars, and highlight cache)
# built by make_editor_group. Each text widget is renamed to a real command (::real<g>)
# and driven through a proxy proc at its Tk path so class bindings still call
# `.eg<g>.t insert`, which the proxy turns into protocol requests (the D3 dumb-view
# discipline, now per group). The horizontal bar auto-hides (gridscroll) when no line
# overflows, and apply_wrap drops it entirely while wrapping.
panedwindow .groups -orient horizontal -borderwidth 0 \
	-sashwidth 6 -sashrelief raised -opaqueresize 1

# The per-widget proxy: an insert/delete becomes a buffer.replace on THIS group's
# active buffer; everything else passes straight through to the real widget command.
proc editor_proxy {g args} {
	set rc [gw $g]
	switch -- [lindex $args 0] {
		insert {
			# .t insert <index> <chars> ?tagList chars ...?
			set idx   [$rc index [lindex $args 1]]
			set chars [lindex $args 2]
			if {$chars ne ""} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $idx end $idx text $chars]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		delete {
			# .t delete <index1> ?index2?  — compute i2 WITHOUT expr. A Tk text index
			# like "1.10" passed through expr is coerced to the float 1.1, silently
			# corrupting the column: backspace would then no-op at every column 10, 20,
			# 30, … (and forward/range deletes ending there too).
			set i1 [$rc index [lindex $args 1]]
			if {[llength $args] >= 3} {
				set i2 [$rc index [lindex $args 2]]
			} else {
				set i2 [$rc index "[lindex $args 1]+1c"]
			}
			if {[$rc compare $i1 < $i2]} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $i1 end $i2 text {}]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		replace {
			# .t replace <index1> <index2> <chars> — one edit, one undo step
			# (paste over a selection). Same index discipline as delete: no expr.
			set i1    [$rc index [lindex $args 1]]
			set i2    [$rc index [lindex $args 2]]
			set chars [lindex $args 3]
			if {[$rc compare $i1 < $i2] || $chars ne ""} {
				if {[dict get [rio_call buffer.replace \
					[dict create buffer [gcur $g] start $i1 end $i2 text $chars]] ok]} {
					mark_modified 1
				}
			}
			return ""
		}
		default { return [$rc {*}$args] }
	}
}

# ---------------------------------------------------------------------------
# Shared clipboard actions on an editor widget (D38). One implementation serves
# the Edit menu and whichever editing mode binds keys to them (the Windows mode
# does), so menu and keyboard can never drift apart. `w` is a group's PROXY path:
# the cut/paste edits run through editor_proxy and reach the core; copy only
# reads. Paste REPLACES a selection (the Windows/VSCode convention — Tk's own
# x11 <<Paste>> leaves it in place) as a single replace, i.e. one undo step.
# ---------------------------------------------------------------------------
proc editor_select_all {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	$w tag remove sel 1.0 end
	$w tag add sel 1.0 "end -1c"
}

proc editor_copy {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[llength [$w tag ranges sel]] == 0} return
	clipboard clear
	clipboard append [$w get sel.first sel.last]
}

proc editor_cut {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[llength [$w tag ranges sel]] == 0} return
	clipboard clear
	clipboard append [$w get sel.first sel.last]
	$w delete sel.first sel.last
}

proc editor_paste {{w ""}} {
	if {$w eq ""} { set w [gget $::focus path] }
	if {[catch {clipboard get} txt] || $txt eq ""} return
	if {[llength [$w tag ranges sel]] > 0} {
		$w replace sel.first sel.last $txt
	} else {
		$w insert insert $txt
	}
	$w see insert
}

# ---------------------------------------------------------------------------
# Keymap (AGENTS.md D23): ONE table maps a logical command -> {chord action}. It is
# the single source of truth for the editor's keyboard shortcuts AND for the
# accelerator labels shown in the menus, so a remap moves both together. Users remap
# by dropping a keys.json in the config dir (D21) — {"command":"chord", ...} overrides
# the default chord per command; "" unbinds one. Chords are Tk event syntax minus the
# <>: modifiers Control/Shift/Alt joined by '-', then the key (a letter, or a keysym
# like Tab/backslash/bracketright). A capital letter carries an implicit Shift, the Tk
# convention: Control-S is Ctrl+Shift+S. New commands slot in here as one line each —
# the binder and the menus pick them up with no further wiring.
# ---------------------------------------------------------------------------
# Each entry is {chord action label}: `action` is the KEY behaviour (a menu item may run
# a different -command — split-editor's key toggles, its menu only splits — and just
# borrows this chord for its accelerator); `label` is the human name the shortcuts editor
# shows. An override changes only the chord; action and label are fixed in code here.
set ::keymap_default {
	new            {Control-n            do_new                                                        "New tab"}
	open           {Control-o            open_dialog                                                   "Open file…"}
	open-folder    {Control-O            open_folder_dialog                                            "Open folder…"}
	save           {Control-s            do_save                                                       "Save"}
	save-as        {Control-S            save_as_dialog                                                "Save As…"}
	close-tab      {Control-w            do_close                                                      "Close tab"}
	quit           {Control-q            do_quit                                                       "Quit"}
	undo           {Control-z            do_undo                                                       "Undo"}
	redo           {Control-Z            do_redo                                                       "Redo"}
	redo-alt       {Control-y            do_redo                                                        "Redo (alternate)"}
	find           {Control-f            {find_open 0}                                                 "Find…"}
	replace        {Control-h            {find_open 1}                                                 "Replace…"}
	find-next      {F3                   find_next                                                     "Find next"}
	find-prev      {Shift-F3             find_prev                                                     "Find previous"}
	next-tab       {Control-Tab          {cycle 1}                                                     "Next tab"}
	prev-tab       {Control-Shift-Tab    {cycle -1}                                                    "Previous tab"}
	show-files     {Control-E            {show_pane files}                                             "Show files pane"}
	show-git       {Control-G            {show_pane git}                                               "Show git pane"}
	toggle-wrap    {Control-W            {set ::wrap_lines [expr {!$::wrap_lines}] ; apply_wrap}        "Toggle line wrap"}
	toggle-chat    {Control-A            {set ::chat_shown [expr {!$::chat_shown}] ; apply_chat_visibility} "Toggle agent chat"}
	split-editor   {Control-backslash    toggle_split                                                  "Toggle editor split"}
	move-tab-other {Control-bracketright move_tab_other                                                "Move tab to other group"}
}
set ::keymap     $::keymap_default ;# resolved map (defaults + user overrides); keymap_resolve fills it
set ::keymap_bad {}                ;# entries keys.json got wrong, for one post-startup notice
set ::keymap_live_chords {}        ;# chords currently bound on the group widgets (to clear on a live remap)

proc keys_path {} {
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		set base $::env(XDG_CONFIG_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .config]
	} else { return "" }
	return [file join $base rio keys.json]
}

# Is `chord` a usable binding? (An empty chord is a deliberate unbind.) Tk's `bind`
# accepts almost any string — it treats unknown tokens as modifiers/keysyms that simply
# never fire — so a probe-bind can't flag a typo. We instead check the shape ourselves:
# every token before the key must be a known modifier. That catches the likely mistake
# (a misspelled modifier); we don't try to enumerate every keysym, so a bogus *key*
# still binds harmlessly and just never triggers.
proc keymap_valid {chord} {
	if {$chord eq ""} { return 1 }
	set mods {Control Ctrl Shift Alt Meta Command Option \
		Mod1 Mod2 Mod3 Mod4 Mod5 Lock Extended}
	set parts [split $chord -]
	foreach m [lrange $parts 0 end-1] { if {$m ni $mods} { return 0 } }
	return [expr {[lindex $parts end] ne ""}]
}

# Merge user overrides (keys.json: command -> chord) over the defaults into ::keymap.
# Only known commands with a Tk-valid chord are honoured; a missing/corrupt file, an
# unknown command, or a bad chord is ignored (a broken keys.json must never stop the
# editor). What was ignored is collected in ::keymap_bad for a single startup notice.
proc keymap_resolve {} {
	set ::keymap $::keymap_default
	set ::keymap_bad {}
	set path [keys_path]
	if {$path eq "" || ![file exists $path]} return
	if {[catch {
		set f [open $path r] ; fconfigure $f -encoding utf-8
		set over [json::json2dict [::read $f]] ; close $f
	}]} { lappend ::keymap_bad "keys.json is not valid JSON — ignored" ; return }
	dict for {cmd chord} $over {
		if {![dict exists $::keymap_default $cmd]} {
			lappend ::keymap_bad "unknown command \"$cmd\"" ; continue
		}
		if {![keymap_valid $chord]} {
			lappend ::keymap_bad "\"$cmd\": invalid chord \"$chord\"" ; continue
		}
		# Replace only the chord; keep the command's action and label (set in code).
		dict set ::keymap $cmd [lreplace [dict get $::keymap $cmd] 0 0 $chord]
	}
}

# The chord bound to `cmd` in the resolved keymap ("" if unbound / unknown).
proc key_chord {cmd} {
	if {![dict exists $::keymap $cmd]} { return "" }
	return [lindex [dict get $::keymap $cmd] 0]
}

# The human name of `cmd` (the shortcuts editor's row label); falls back to the id.
proc key_label {cmd} {
	if {![dict exists $::keymap_default $cmd]} { return $cmd }
	set l [lindex [dict get $::keymap_default $cmd] 2]
	return [expr {$l eq "" ? $cmd : $l}]
}

# A human accelerator label for `cmd`, derived from its resolved chord so a remap
# updates the menu automatically. "" when unbound (the menu then shows no accelerator).
proc key_accel {cmd} { return [chord_label [key_chord $cmd]] }

# Turn a Tk chord (Control-Shift-e, Control-backslash, Control-S) into a display label
# (Ctrl+Shift+E, Ctrl+\, Ctrl+Shift+S). A lone capital letter carries an implicit Shift.
proc chord_label {chord} {
	if {$chord eq ""} { return "" }
	set parts [split $chord -]
	set key   [lindex $parts end]
	set out {} ; set shift 0
	foreach m [lrange $parts 0 end-1] {
		switch -- $m {
			Control - Ctrl    { lappend out Ctrl }
			Shift             { set shift 1 }
			Alt - Mod1 - Meta { lappend out Alt }
			default           { lappend out $m }
		}
	}
	if {[string length $key] == 1 && [string is upper $key]} { set shift 1 }
	if {$shift} { lappend out Shift }
	set order {}
	foreach want {Ctrl Alt Shift} { if {$want in $out} { lappend order $want } }
	lappend order [key_glyph $key]
	return [join $order +]
}

# Display glyph for a single key: letters upper-cased, common keysyms to their symbol.
proc key_glyph {key} {
	set map [dict create \
		backslash "\\" bracketright "]" bracketleft "\[" slash "/" grave "`" \
		semicolon ";" comma "," period "." minus "-" equal "=" space "Space"]
	if {[dict exists $map $key]}        { return [dict get $map $key] }
	if {[string length $key] == 1}      { return [string toupper $key] }
	return $key   ;# Tab, Escape, Return, F5, … shown as-is
}

# Editor keyboard shortcuts, bound on a group's text widget with `break` so the
# widget's own class bindings (Tk's built-in Ctrl+O/Ctrl+Z etc.) don't also fire.
# Bound per group so a shortcut acts on whichever group has keyboard focus — driven
# entirely by the resolved ::keymap, so nothing here changes when a command is added.
proc editor_bindings {w} {
	dict for {cmd spec} $::keymap {
		lassign $spec chord action
		if {$chord eq ""} continue   ;# a deliberately unbound command
		catch { bind $w <$chord> "$action ; break" }
	}
}

# The non-empty chords in the resolved keymap.
proc keymap_chords {} {
	set out {}
	dict for {cmd spec} $::keymap { set c [lindex $spec 0] ; if {$c ne ""} { lappend out $c } }
	return $out
}

# Re-apply the resolved keymap to every live editor group WITHOUT a restart: clear the
# chords bound last time (so a changed/unbound chord actually goes away — `bind` never
# removes, only overwrites), then bind the current set. ::keymap_live_chords tracks what
# is on the widgets so we know what to clear next time.
proc keymap_rebind_all {} {
	foreach g $::groups {
		set w [gget $g path]
		foreach c $::keymap_live_chords { catch {bind $w <$c> ""} }
		editor_bindings $w
	}
	set ::keymap_live_chords [keymap_chords]
}

# Re-derive every menu accelerator from the current keymap (so a remap updates the labels
# shown in the menus, not just the bindings). Indexed by the exact menu labels.
proc keymap_refresh_menus {} {
	.m.file entryconfigure "New"          -accelerator [key_accel new]
	.m.file entryconfigure "Open…"        -accelerator [key_accel open]
	.m.file entryconfigure "Open Folder…" -accelerator [key_accel open-folder]
	.m.file entryconfigure "Save"         -accelerator [key_accel save]
	.m.file entryconfigure "Save As…"     -accelerator [key_accel save-as]
	.m.file entryconfigure "Close Tab"    -accelerator [key_accel close-tab]
	.m.file entryconfigure "Quit"         -accelerator [key_accel quit]
	.m.edit entryconfigure "Undo"          -accelerator [key_accel undo]
	.m.edit entryconfigure "Redo"          -accelerator [key_accel redo]
	.m.edit entryconfigure "Find…"         -accelerator [key_accel find]
	.m.edit entryconfigure "Replace…"      -accelerator [key_accel replace]
	.m.edit entryconfigure "Find Next"     -accelerator [key_accel find-next]
	.m.edit entryconfigure "Find Previous" -accelerator [key_accel find-prev]
	.m.view entryconfigure "Show Files"   -accelerator [key_accel show-files]
	.m.view entryconfigure "Show Git"     -accelerator [key_accel show-git]
	.m.view entryconfigure "Wrap Lines"   -accelerator [key_accel toggle-wrap]
	.m.view entryconfigure "Agent Chat"   -accelerator [key_accel toggle-chat]
	.m.view entryconfigure "Split Editor" -accelerator [key_accel split-editor]
	.m.view entryconfigure "Move Tab to Other Group" -accelerator [key_accel move-tab-other]
}

# One entry point after the keymap changes at runtime: re-read keys.json, then push the
# new bindings and menu labels to the live UI. The shortcuts editor calls this after it
# saves; everything routes through keymap_resolve so file and UI never diverge.
proc keymap_apply_live {} {
	keymap_resolve
	keymap_rebind_all
	keymap_refresh_menus
}

# ---- Pure helpers for the shortcuts editor (unit-tested; no widgets) --------------

# Turn a key event (keysym + state bitmask, from %K/%s) into a chord string, or "" if it
# isn't a usable shortcut: a bare modifier press, or a bare printable key with no modifier
# (binding a lone letter would hijack typing — a named key like F5/Delete is allowed).
# Modifiers are emitted Control/Alt/Shift; a letter is lower-cased with Shift kept explicit.
proc event_to_chord {keysym state} {
	if {[string match *_L $keysym] || [string match *_R $keysym] \
		|| $keysym in {Caps_Lock Num_Lock Shift Control Alt Meta ISO_Level3_Shift}} { return "" }
	set mods {}
	if {$state & 0x4} { lappend mods Control }
	if {$state & 0x8} { lappend mods Alt }      ;# Mod1
	if {$state & 0x1} { lappend mods Shift }
	set key $keysym
	if {[string length $key] == 1 && [string is alpha $key]} { set key [string tolower $key] }
	if {[llength $mods] == 0 && [string length $key] == 1} { return "" }  ;# bare printable: refuse
	return [join [concat $mods [list $key]] -]
}

# Which OTHER command in `chords` (a command -> chord dict) already uses `chord`, or "" if
# none — the shortcuts editor's live conflict check. An empty chord never conflicts.
proc keys_conflict {chords cmd chord} {
	if {$chord eq ""} { return "" }
	dict for {c ch} $chords {
		if {$c ne $cmd && $ch eq $chord} { return $c }
	}
	return ""
}

# The minimal overrides to persist from a command -> chord dict: keep only commands whose
# chord differs from its default (including "" for one the user unbound). Commands left at
# their default are omitted, so keys.json stays a small diff, not a full copy.
proc keymap_overrides {chords} {
	set out {}
	dict for {cmd chord} $chords {
		set dflt [lindex [dict get $::keymap_default $cmd] 0]
		if {$chord ne $dflt} { dict set out $cmd $chord }
	}
	return $out
}

# Write the overrides dict to keys.json (deleting it when empty, so a full reset removes
# the file). Returns 1 on success. Mirrors prefs_save: plain JSON, best-effort.
proc keys_save {overrides} {
	set path [keys_path]
	if {$path eq ""} { return 0 }
	if {[dict size $overrides] == 0} { catch {file delete $path} ; return 1 }
	if {[catch {
		file mkdir [file dirname $path]
		set f [open $path {WRONLY CREAT TRUNC}] ; fconfigure $f -encoding utf-8
		puts -nonewline $f [rio::wire::obj $overrides] ; close $f
	}]} { return 0 }
	return 1
}

# ---------------------------------------------------------------------------
# Keyboard-shortcuts editor (AGENTS.md D23). A modal listing every command with its
# current chord; the user re-records (press-to-capture, like a modern IDE), clears, or
# resets. Editing happens in a working copy ::keys_work (command -> chord); Cancel
# discards it, Save writes keys.json (overrides only) and applies live via
# keymap_apply_live — no restart — so file and UI never diverge.
# ---------------------------------------------------------------------------
proc keys_refresh_buttons {} {
	dict for {cmd chord} $::keys_work {
		if {![winfo exists .keys.body.k$cmd]} continue
		set lbl [chord_label $chord]
		.keys.body.k$cmd configure -text [expr {$lbl eq "" ? "(unbound)" : $lbl}]
	}
}
proc keys_status {msg} { catch {.keys.status configure -text $msg} }

# Begin recording a chord for `cmd`. Any capture in progress is cancelled first; focus
# moves to the toplevel so keypresses land on our <KeyPress> handler, not a button.
proc keys_capture {cmd} {
	if {$::keys_capturing ne ""} { keys_capture_cancel }
	set ::keys_capturing $cmd
	.keys.body.k$cmd configure -text "Press keys…"
	keys_status "Recording “[key_label $cmd]” — press a shortcut, or Esc to cancel."
	focus .keys
}
proc keys_capture_cancel {} {
	if {$::keys_capturing eq ""} return
	set ::keys_capturing ""
	keys_refresh_buttons
	keys_status ""
}

# A key arrived while recording: ignore unusable keys (bare modifier / lone printable) and
# conflicts, keep recording; otherwise set the chord and stop.
proc keys_on_key {keysym state} {
	if {$::keys_capturing eq ""} return
	set chord [event_to_chord $keysym $state]
	if {$chord eq ""} {
		keys_status "That key can’t be a shortcut on its own — add Ctrl / Alt / Shift."
		return
	}
	set cmd $::keys_capturing
	set other [keys_conflict $::keys_work $cmd $chord]
	if {$other ne ""} {
		keys_status "[chord_label $chord] is already “[key_label $other]” — clear that first."
		return
	}
	dict set ::keys_work $cmd $chord
	set ::keys_capturing ""
	keys_refresh_buttons
	keys_status "Set “[key_label $cmd]” to [chord_label $chord]. Save to apply."
}
proc keys_clear {cmd} { dict set ::keys_work $cmd "" ; keys_refresh_buttons ; keys_status "" }
# Restore one command to its shipped default chord (the per-row counterpart of Reset all).
# We note if the restored chord now duplicates another command's, but still apply it — it's
# a deliberate "put it back" and the user can sort out the collision.
proc keys_default {cmd} {
	set chord [lindex [dict get $::keymap_default $cmd] 0]
	dict set ::keys_work $cmd $chord
	keys_refresh_buttons
	set other [keys_conflict $::keys_work $cmd $chord]
	if {$other ne ""} {
		keys_status "Restored “[key_label $cmd]” to [chord_label $chord] — now also on “[key_label $other]”."
	} else {
		keys_status "Restored “[key_label $cmd]” to [chord_label $chord]."
	}
}
proc keys_reset_all {} {
	set ::keys_work {}
	dict for {cmd spec} $::keymap_default { dict set ::keys_work $cmd [lindex $spec 0] }
	keys_refresh_buttons
	keys_status "Reset to defaults — Save to apply."
}
proc keys_dialog_save {} {
	keys_save [keymap_overrides $::keys_work]
	keymap_apply_live         ;# re-read the file and push new bindings + menu labels live
	destroy .keys
}

proc keybindings_dialog {} {
	set w .keys
	destroy $w
	toplevel $w
	wm title $w "Keyboard Shortcuts"
	wm transient $w .
	wm resizable $w 0 0
	set c $::theme_colors
	$w configure -background [dict get $c ui.bg]

	set ::keys_capturing ""
	set ::keys_work {}
	dict for {cmd spec} $::keymap { dict set ::keys_work $cmd [lindex $spec 0] }

	label $w.hint -anchor w -font RioUIFont -justify left \
		-background [dict get $c ui.bg] -foreground [dict get $c ui.fg] \
		-text "Click a shortcut, then press the keys you want. Clear unbinds; Default restores the original.\nThese app shortcuts always win over the editing mode's keys (Settings ▸ Editing Mode)."
	grid $w.hint -row 0 -column 0 -sticky we -padx 8 -pady {8 4}

	frame $w.body -background [dict get $c ui.bg]
	set r 0
	dict for {cmd spec} $::keymap_default {
		label $w.body.l$cmd -text [key_label $cmd] -anchor w -font RioUIFont \
			-background [dict get $c ui.bg] -foreground [dict get $c ui.fg]
		button $w.body.k$cmd -width 20 -font RioUIFont -command [list keys_capture $cmd]
		button $w.body.c$cmd -text "Clear"   -font RioUIFont -command [list keys_clear $cmd]
		button $w.body.d$cmd -text "Default" -font RioUIFont -command [list keys_default $cmd]
		grid $w.body.l$cmd -row $r -column 0 -sticky w  -padx {2 12} -pady 1
		grid $w.body.k$cmd -row $r -column 1 -sticky we -padx 2      -pady 1
		grid $w.body.c$cmd -row $r -column 2 -sticky w  -padx {2 2}  -pady 1
		grid $w.body.d$cmd -row $r -column 3 -sticky w  -padx {2 2}  -pady 1
		incr r
	}
	grid $w.body -row 1 -column 0 -sticky nwe -padx 8

	label $w.status -anchor w -font RioUIFont -text "" \
		-background [dict get $c ui.bg] -foreground [dict get $c accent]
	grid $w.status -row 2 -column 0 -sticky we -padx 8 -pady {4 2}

	frame $w.btns -background [dict get $c ui.bg]
	button $w.btns.reset  -text "Reset all to defaults" -font RioUIFont -command keys_reset_all
	button $w.btns.cancel -text "Cancel" -font RioUIFont -command {destroy .keys}
	button $w.btns.save   -text "Save"   -font RioUIFont -command keys_dialog_save
	pack $w.btns.reset -side left
	pack $w.btns.save $w.btns.cancel -side right -padx 3
	grid $w.btns -row 3 -column 0 -sticky we -padx 5 -pady {2 8}

	# Capture keys only while recording; otherwise let them drive normal focus/buttons.
	bind $w <KeyPress> {if {$::keys_capturing ne ""} { keys_on_key %K %s ; break }}
	bind $w <Escape>   {if {$::keys_capturing ne ""} { keys_capture_cancel } else { destroy .keys }}
	keys_refresh_buttons
	catch {grab $w}
	focus $w
	tkwait window $w
}

# Build editor group `g`: its frame (.eg<g>) with a tab strip on top and the text
# widget + scrollbars below, the renamed real command, the proxy, and the key/focus
# bindings. Registers the group in ::grp. The literal font is replaced by
# RioEditorFont in the next apply_theme. Each group owns its OWN tab strip (D33) — a
# tab lives in exactly one group — so the strip is gridded inside the group frame,
# spanning the text + scrollbar columns, with refresh_tabs filling it per group.
proc make_editor_group {g} {
	set f .eg$g
	frame $f
	frame $f.tabs -background "#bbbbbb"
	text $f.t -wrap none -undo 0 -font {monospace 12} -width 80 -height 28 \
		-background white -foreground black -insertbackground black \
		-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
		-yscrollcommand [list $f.vsb set] -xscrollcommand [list gridscroll $f.hsb]
	scrollbar $f.vsb -orient vertical   -command [list $f.t yview]
	scrollbar $f.hsb -orient horizontal -command [list $f.t xview]
	grid $f.tabs -row 0 -column 0 -columnspan 2 -sticky ew
	grid $f.t   -row 1 -column 0 -sticky nsew
	grid $f.vsb -row 1 -column 1 -sticky ns
	grid $f.hsb -row 2 -column 0 -sticky ew
	grid rowconfigure    $f 1 -weight 1
	grid columnconfigure $f 0 -weight 1
	rename $f.t ::real$g
	dict set ::grp $g [dict merge [new_group_state] \
		[dict create w ::real$g path $f.t frame $f tabs $f.tabs]]
	proc $f.t {args} "editor_proxy $g {*}\$args"
	editor_bindings $f.t
	# Slot the editing-mode tag between the widget (app chords) and the Text class
	# (Tk defaults) — the D38 precedence order. The tag is SHARED, so whatever mode
	# is attached covers this group with no per-widget rebinding.
	bindtags $f.t [linsert [bindtags $f.t] 1 RioMode]
	bind $f.t <Button-1> [list focus_group $g]   ;# clicking a group focuses it
	return $g
}

# Make group `g` the focused one (::cur mirrors its active buffer). Tk moves keyboard
# focus on a click itself; this just repoints our state and repaints the chrome.
proc focus_group {g} {
	if {$g eq $::focus} return
	set ::focus $g
	set ::cur [gcur $g]
	refresh_all
}

# Resolve the keymap (defaults + the user's keys.json) before any binding or menu is
# built, so both the editor shortcuts and the menu accelerators read the same table.
keymap_resolve
set ::keymap_live_chords [keymap_chords] ;# what the first group's editor_bindings will bind

# Create the first editor group; the split adds a second (phase 3).
make_editor_group 0
set ::groups {0}
set ::focus 0
relayout_groups

# The compare / diff view (AGENTS.md D28): two read-only text panes side by side
# with a single shared vertical scrollbar, packed in the center INSTEAD of .ed
# while comparing (place_dock). Built here with bootstrap colours; apply_theme
# recolours them and configures the del/add/filler row tags. cmp_fill renders the
# core diff.lines alignment into the panes.
frame .cmp
frame .cmp.l ; frame .cmp.r
label .cmp.l.hdr -anchor w -font {monospace 9} -padx 4 -pady 2 -background "#dddddd" -foreground black
label .cmp.r.hdr -anchor w -font {monospace 9} -padx 4 -pady 2 -background "#dddddd" -foreground black
text .cmp.l.t -wrap none -state disabled -font {monospace 12} -width 40 -height 28 \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black -yscrollcommand {cmp_yscroll l}
text .cmp.r.t -wrap none -state disabled -font {monospace 12} -width 40 -height 28 \
	-borderwidth 0 -highlightthickness 0 -padx 4 -pady 2 \
	-background white -foreground black -yscrollcommand {cmp_yscroll r}
scrollbar .cmp.sb -orient vertical -command cmp_yview
# A top bar with a clear way out — the Esc binding alone isn't discoverable, so the
# button names the shortcut (D27: a plain × glyph, widely covered).
frame .cmp.bar
button .cmp.bar.close -text "× Close compare (Esc)" -font {monospace 9} -command compare_close
pack .cmp.bar.close -side right -padx 2 -pady 1
pack .cmp.bar -side bottom -fill x
pack .cmp.l.hdr -side top -fill x ; pack .cmp.l.t -side left -fill both -expand 1
pack .cmp.r.hdr -side top -fill x ; pack .cmp.r.t -side left -fill both -expand 1
pack .cmp.l  -side left  -fill both -expand 1
pack .cmp.sb -side right -fill y
pack .cmp.r  -side left  -fill both -expand 1
foreach w {.cmp.l.t .cmp.r.t} {
	bind $w <MouseWheel> {cmp_yview scroll [expr {%D > 0 ? -1 : 1}] units ; break}
	bind $w <Button-4>   {cmp_yview scroll -1 units ; break}
	bind $w <Button-5>   {cmp_yview scroll 1 units ; break}
	bind $w <Escape>     {compare_close ; break}
}

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
button .chat.send -text "▶" -font {monospace 9} -command chat_send  ;# ▶ send (D27)
# Status strip at the pane's very bottom: live agent + edit mode (filled by
# chat_status_update; room for context-window usage later).
label .chat.status -anchor w -font {monospace 9} -padx 4 -pady 2 \
	-background "#eeeeee" -foreground "#444444"
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
button .chat.approve.cmp -text "Compare" -font {monospace 9} -command {compare_proposal $::pending_turn}
pack .chat.approve.yes -side right
pack .chat.approve.no  -side right
pack .chat.approve.cmp -side right
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
pack .chat.hdr    -side top    -fill x
pack .chat.status -side bottom -fill x
pack .chat.send   -side bottom -fill x
pack .chat.input  -side bottom -fill x
pack .chat.isash  -side bottom -fill x
pack .chat.log    -side left   -fill both -expand 1
# .chat.sb is packed on demand by autoscroll (hidden when the transcript fits).

# A thin draggable divider between the editor and the chat pane (mirror of .sash).
frame .csash -width 5 -cursor sb_h_double_arrow -background "#bbbbbb"
bind .csash <B1-Motion> csash_drag

# The find/replace bar (D36): built hidden; find_open packs it above the status
# bar. Row 0 finds, row 1 replaces (gridded away in find-only mode). Plain
# labelled controls and a × to close (D27) — the bar reads at a glance. Colours
# are bootstrap; apply_theme restyles (entries take the editor surface).
frame .find -borderwidth 1 -relief raised -background "#dddddd"
label .find.fl -text "Find:"    -font {monospace 9} -anchor e -background "#dddddd"
label .find.rl -text "Replace:" -font {monospace 9} -anchor e -background "#dddddd"
entry .find.e  -font {monospace 11} -width 24
entry .find.re -font {monospace 11} -width 24
# ↓/↑ (U+2193/U+2191) step forward/backward through matches (top-to-bottom),
# the find-widget idiom (D27); F3 / Shift+F3 are the keyboard path.
button .find.next -text "↓" -width 2 -font {monospace 9} -command find_next
button .find.prev -text "↑" -width 2 -font {monospace 9} -command find_prev
checkbutton .find.case -text "Match case" -font {monospace 9} \
	-variable ::find_case -command find_update -background "#dddddd"
label .find.count -font {monospace 9} -anchor w -background "#dddddd"
label .find.close -text "×" -font {monospace 9} -padx 6 -cursor hand2 \
	-background "#dddddd"
button .find.rep    -text "Replace"     -font {monospace 9} -command find_replace_one
button .find.repall -text "Replace All" -font {monospace 9} -command find_replace_all
grid .find.fl     -row 0 -column 0 -sticky e  -padx {6 2} -pady 2
grid .find.e      -row 0 -column 1 -sticky ew -pady 2
grid .find.next   -row 0 -column 2 -padx 2
grid .find.prev   -row 0 -column 3 -padx 2
grid .find.case   -row 0 -column 4 -padx 4
grid .find.count  -row 0 -column 5 -sticky ew -padx 4
grid .find.close  -row 0 -column 6 -sticky e  -padx {2 6}
grid .find.rl     -row 1 -column 0 -sticky e  -padx {6 2} -pady {0 2}
grid .find.re     -row 1 -column 1 -sticky ew -pady {0 2}
grid .find.rep    -row 1 -column 2 -padx 2 -pady {0 2}
grid .find.repall -row 1 -column 3 -columnspan 2 -sticky w -padx 2 -pady {0 2}
grid columnconfigure .find 1 -weight 1
grid columnconfigure .find 5 -weight 1
bind .find.close <Button-1> find_close
# Both entries: Enter steps (Shift-Enter steps back), Esc closes, F3 works too.
# In the Replace entry, Enter replaces instead — you are aiming at a replace.
foreach _w {.find.e .find.re} {
	bind $_w <Return>       {find_next ; break}
	bind $_w <Shift-Return> {find_prev ; break}
	bind $_w <Escape>       {find_close ; break}
	bind $_w <F3>           {find_next ; break}
	bind $_w <Shift-F3>     {find_prev ; break}
}
bind .find.re <Return> {find_replace_one ; break}
bind .find.e  <KeyRelease> find_update
unset _w

label .status -anchor w -font {monospace 9} -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .status -side bottom -fill x
# .dock and .groups are packed by place_dock at startup (so the dock side is live);
# each group's tab strip lives inside its own frame (D33), not in a global top bar.
focus [gget 0 path]

menu .m ; . configure -menu .m
menu .m.file -tearoff 0
.m add cascade -label File -menu .m.file
.m.file add command -label "New"       -accelerator [key_accel new]         -command do_new
.m.file add command -label "Open…"    -accelerator [key_accel open]        -command open_dialog
.m.file add command -label "Open Folder…" -accelerator [key_accel open-folder] -command open_folder_dialog
.m.file add command -label "Save"      -accelerator [key_accel save]        -command do_save
.m.file add command -label "Save As…" -accelerator [key_accel save-as]     -command save_as_dialog
.m.file add separator
.m.file add command -label "Connect to Remote Core…" -command connect_remote_dialog
.m.file add separator
.m.file add command -label "Close Tab" -accelerator [key_accel close-tab]   -command do_close
.m.file add command -label "Quit"      -accelerator [key_accel quit]        -command do_quit
menu .m.edit -tearoff 0
.m add cascade -label Edit -menu .m.edit
.m.edit add command -label "Undo" -accelerator [key_accel undo] -command do_undo
.m.edit add command -label "Redo" -accelerator [key_accel redo] -command do_redo
.m.edit add separator
# The clipboard block (Win98 canon). No accelerators shown: the keys belong to the
# editing mode (Ctrl+X/C/V in Windows mode; emacs and vi have their own ideas), so
# a fixed label here could lie. The commands work in every mode.
.m.edit add command -label "Cut"        -command editor_cut
.m.edit add command -label "Copy"       -command editor_copy
.m.edit add command -label "Paste"      -command editor_paste
.m.edit add command -label "Select All" -command editor_select_all
.m.edit add separator
.m.edit add command -label "Find…"         -accelerator [key_accel find]      -command {find_open 0}
.m.edit add command -label "Replace…"      -accelerator [key_accel replace]   -command {find_open 1}
.m.edit add command -label "Find Next"     -accelerator [key_accel find-next] -command find_next
.m.edit add command -label "Find Previous" -accelerator [key_accel find-prev] -command find_prev
menu .m.view -tearoff 0
.m add cascade -label View -menu .m.view
.m.view add command -label "Show Files" -accelerator [key_accel show-files] -command {show_pane files}
.m.view add command -label "Show Git"   -accelerator [key_accel show-git]   -command {show_pane git}
.m.view add separator
.m.view add radiobutton -label "Dock Left"  -variable ::dock_side -value left  -command place_dock
.m.view add radiobutton -label "Dock Right" -variable ::dock_side -value right -command place_dock
.m.view add separator
.m.view add checkbutton -label "Wrap Lines" -accelerator [key_accel toggle-wrap] \
	-variable ::wrap_lines -command apply_wrap
.m.view add checkbutton -label "Agent Chat" -accelerator [key_accel toggle-chat] \
	-variable ::chat_shown -command apply_chat_visibility
.m.view add separator
.m.view add command -label "Split Editor"          -accelerator [key_accel split-editor] -command split_editor
.m.view add command -label "Unsplit Editor"        -command unsplit_editor
.m.view add command -label "Move Tab to Other Group" -accelerator [key_accel move-tab-other] -command move_tab_other
.m.view add separator
.m.view add command -label "Compare With File…" -command compare_with_file_dialog
.m.view add command -label "Close Compare" -accelerator Esc -command compare_close
.m.view add separator
# The Theme cascade is filled from the core (themes_menu_fill) once the channel
# is up — installed themes (D39) appear here like shipped ones.
menu .m.view.theme -tearoff 0
.m.view add cascade -label "Theme" -menu .m.view.theme
.m.view add separator
.m.view add command -label "Extensions…" -command extensions_window
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
	-command {rio_result agent.autoaccept.set [dict create on $::agent_auto_accept]; chat_status_update}
.m.settings add checkbutton -label "Agent: Compare complex edits" \
	-variable ::agent_compare_complex
.m.settings add separator
# Keyboard behaviour clusters here: the editing mode decides what keys do inside
# the text area (D38), the shortcuts editor remaps the app chords (D23).
menu .m.settings.editmode -tearoff 0
.m.settings add cascade -label "Editing Mode" -menu .m.settings.editmode
.m.settings add command -label "Keyboard Shortcuts…" -command keybindings_dialog

# The editor keyboard shortcuts and the edit-proxy are installed per group by
# make_editor_group (editor_bindings + editor_proxy). Only the window-manager close
# needs binding here.
wm protocol . WM_DELETE_WINDOW do_quit

# Load the syntax highlighters before the first apply_theme (which configures a
# text tag per token type from the theme's syntax.* roles) and before any buffer
# loads (which re-tokenises it) — D32.
hl_load

# Load the editing modes the same way (D38): registry, shipped modules, user
# drop-ins. Loaded before prefs so a persisted mode name can resolve; attached by
# apply_editmode in the boot applier block below.
modes_load
modes_menu_fill

# Load saved preferences (theme, wrap, dock, chat) over the defaults, then apply the
# theme before the first tab is drawn, so every widget — and the tab bar refresh_tabs
# builds — uses the role table. A persisted theme that no longer exists falls back to
# the default rather than erroring at startup (D31).
prefs_load
ledger_load   ;# which extensions this GUI installed, with their provenance (D39)
# Greet the core before any other op. This is the first exchange over the channel, so
# it's also where a stale connection surfaces: a dead `ssh -L` forward accepts the
# socket but never answers, and without this bounded handshake the GUI would hang with
# a blank window (a real bug report). fatal → a clear dialog, then exit.
hello_core 1
# The greeting bounded only the first exchange; the watchdog (D37) extends that
# cover to the whole session. Socket-attached cores only — a pipe EOFs on its own.
if {$::core_remote} watch_start
set _boot_theme [rio_call theme.get [dict create name $::theme_name]]
if {![dict get $_boot_theme ok]} {
	set ::theme_name default
	set _boot_theme [rio_call theme.get {}]
}
apply_theme [dict get $_boot_theme result]
set ::theme_choice $::theme_name
themes_menu_fill           ;# View ▸ Theme radios from the core's theme.list (D39)

# Adopt the core's existing buffer(s), then process the command line. In-process: a
# directory argument opens as the project folder, a file opens in a tab. Remote: the
# path lives on the SERVER, so we can't stat it from here — open each as a project
# folder (project.open) and let the core judge; files are reached via the tree (D29).
set ::nav_dir ""
set ::nav_rows {}
set ::git_rows {}
adopt_initial_buffers      ;# take over the core's existing buffer(s) (D29)
place_dock                 ;# pack the dock (default left) and the editor
show_pane $::dock_pane     ;# default files; also does the first populate
apply_wrap                 ;# sync wrap + the horizontal scrollbar to ::wrap_lines
apply_editmode             ;# attach the editing mode (windows default) to the RioMode tag (D38)
adopt_agent_status         ;# mirror the core's live provider/auto-accept; don't overwrite it (D30)
foreach f $argv {
	if {$::core_remote} {
		open_folder $f
	} elseif {[file isdirectory $f]} {
		open_folder $f
	} else {
		do_open $f
	}
}

# Resume the project's workspace: reopen the files that were open last time (D31).
# Only meaningful once a project is open (argv opened one — or none, then this is a
# no-op); the core prunes vanished paths, so a restore never errors on stale entries.
# Still guarded by ::rio_started=0, so the do_opens here don't each re-save.
session_restore

# Let the window settle at its natural content size, then stop child geometry from
# driving the toplevel. After this, resizing the dock (the sash) flexes the editor
# rather than resizing the whole window — which is what made sash drags feed back
# on themselves. The user can still resize the toplevel via the WM as usual.
update idletasks
pack propagate . 0

# Startup is done: from here, view-state and workspace changes persist (D31).
set ::rio_started 1

# A test harness sets RIO_GUI_HEADLESS to keep the window off-screen.
if {[info exists ::env(RIO_GUI_HEADLESS)]} { wm withdraw . }

# If keys.json had entries we couldn't use, say so once — a silent skip would leave the
# user's remap mysteriously ineffective. The editor still ran on the valid rest.
if {[llength $::keymap_bad] && ![info exists ::env(RIO_GUI_HEADLESS)]} {
	report_error "Some shortcuts in [keys_path] were ignored:\n  • [join $::keymap_bad "\n  • "]"
}
