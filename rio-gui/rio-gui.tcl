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
set ::theme_name default ;# active colour theme — a persisted preference; do_theme records it (D31)
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
proc rio_call {op params} {
	return [core_call $op $params]
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
proc core_call {op params} {
	set id r[incr ::reply_seq]
	set ::pending($id) 1
	if {[catch {
		puts $::core_chan "{\"id\":[rio::wire::str $id],\"op\":[rio::wire::str $op],\"params\":[rio::wire::obj $params]}"
		flush $::core_chan
	}]} {
		unset -nocomplain ::pending($id)
		core_lost
		return [dict create id $id ok false \
			error [dict create code disconnected message "no connection to the core"]]
	}
	vwait ::reply($id)
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
	if {[string trim $line] eq ""} return
	if {[catch {json::json2dict $line} msg]} return
	if {[dict exists $msg event]} {
		dispatch_event $msg
	} elseif {[dict exists $msg id]} {
		set ::reply([dict get $msg id]) $msg
	}
}

# The channel closed. Report it once, stop reading, and wake any call blocked on a
# reply (with a disconnected error) so the GUI never hangs. The editor stays up so
# nothing in view is lost; further ops fail fast through core_call.
proc core_lost {} {
	if {![info exists ::core_chan]} return
	catch {fileevent $::core_chan readable {}}
	catch {close $::core_chan}
	unset -nocomplain ::core_chan
	foreach id [array names ::pending] {
		set ::reply($id) [dict create id $id ok false \
			error [dict create code disconnected message "lost the connection to the core"]]
	}
	report_error "Lost the connection to the core (it exited or the link dropped)." disconnected
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
# Runs whenever a channel becomes live: at startup and after an in-place reconnect.
# Not fatal — the user chose this core; they get a clear diagnostic, not a lockout.
proc hello_core {} {
	set resp [rio_call session.hello {}]
	if {![dict get $resp ok]} {
		report_error "The core didn't answer session.hello: [dict get $resp error message]" \
			[dict get $resp error code]
		return
	}
	set ::core_protocol [dict get $resp result protocol]
	if {$::core_protocol ne $::rio_protocol} {
		report_error "This core speaks wire protocol $::core_protocol, but this GUI expects $::rio_protocol — mixed versions may misbehave. Update the older side." protocol_mismatch
	}
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
	# Rebuild exactly as at startup.
	hello_core                   ;# a daemon can be any age — check the protocol first
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

proc tab_name {id} {
	set p [bufget $id path]
	set n [expr {$p eq "" ? "untitled" : [file tail $p]}]
	return "$n[expr {[bufget $id modified] ? { *} : {}}]"
}
proc refresh_all   {} { refresh_tabs ; refresh_title ; refresh_status }
proc refresh_title {} {
	set suffix [expr {$::core_remote ? " — $::core_endpoint" : ""}]
	wm title . "rio — [tab_name $::cur]$suffix"
}
proc refresh_status {} {
	set p    [bufget $::cur path]
	set name [expr {$p eq "" ? "untitled" : $p}]
	set meta [bufget $::cur meta]
	set enc  [expr {[dict exists $meta encoding] ? [dict get $meta encoding] : "utf-8"}]
	set eol  [expr {[dict exists $meta eol] ? [dict get $meta eol] : "lf"}]
	set lang [expr {[gget $::focus hl_lang] ne "" ? [gget $::focus hl_lang] : "plain text"}]
	.status configure -text [format "%s      %s  %s%s      %s      %d buffer(s)" \
		$name $enc $eol [expr {[bufget $::cur modified] ? {      modified} : {}}] \
		$lang [dict size $::buffers]]
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
# that tab). Rebuilt on each popup so the split item and Copy Path reflect the current
# state. The split action is the same move whether or not a second group exists yet —
# the label just reads honestly ("Split with This Tab" when unsplit, "Move to Other
# Group" once split).
proc tab_context_menu {g id X Y} {
	catch {destroy .tabmenu}
	menu .tabmenu -tearoff 0
	if {[llength $::groups] >= 2} {
		.tabmenu add command -label "Move to Other Group" -command [list move_buffer_to_other $id $g]
	} else {
		.tabmenu add command -label "Split with This Tab" -command [list move_buffer_to_other $id $g]
	}
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
			label $f.l -text [tab_name $id] -background $bg -foreground $tfg \
				-font RioUIFont -padx 6 -pady 1
			label $f.x -text "×" -background $bg -foreground $fg \
				-font RioUIFont -padx 3
			bind $f.l <Button-1> [list activate $id $g]
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
		apply_theme [dict get $resp result]
		prefs_save
	} else {
		report_error "Theme '$name': [dict get $resp error message]" \
			[dict get $resp error code]
	}
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
			chat_shown $::chat_shown]]
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
		default { return [$rc {*}$args] }
	}
}

# Editor keyboard shortcuts, bound on a group's text widget with `break` so the
# widget's own class bindings (Tk's built-in Ctrl+O/Ctrl+Z etc.) don't also fire.
# Bound per group so a shortcut acts on whichever group has keyboard focus.
proc editor_bindings {w} {
	bind $w <Control-n>         { do_new ; break }
	bind $w <Control-o>         { open_dialog ; break }
	bind $w <Control-O>         { open_folder_dialog ; break }
	bind $w <Control-s>         { do_save ; break }
	bind $w <Control-S>         { save_as_dialog ; break }
	bind $w <Control-w>         { do_close ; break }
	bind $w <Control-q>         { do_quit ; break }
	bind $w <Control-z>         { do_undo ; break }
	bind $w <Control-Z>         { do_redo ; break }
	bind $w <Control-y>         { do_redo ; break }
	bind $w <Control-Tab>       { cycle 1 ; break }
	bind $w <Control-Shift-Tab> { cycle -1 ; break }
	bind $w <Control-E>         { show_pane files ; break }
	bind $w <Control-G>         { show_pane git ; break }
	bind $w <Control-W>         { set ::wrap_lines [expr {!$::wrap_lines}] ; apply_wrap ; break }
	bind $w <Control-A>         { set ::chat_shown [expr {!$::chat_shown}] ; apply_chat_visibility ; break }
	bind $w <Control-backslash> { toggle_split ; break }
	bind $w <Control-bracketright> { move_tab_other ; break }
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
button .chat.send -text "Send" -font {monospace 9} -command chat_send
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

label .status -anchor w -font {monospace 9} -padx 4 -pady 1 \
	-background "#dddddd" -foreground black
pack .status -side bottom -fill x
# .dock and .groups are packed by place_dock at startup (so the dock side is live);
# each group's tab strip lives inside its own frame (D33), not in a global top bar.
focus [gget 0 path]

menu .m ; . configure -menu .m
menu .m.file -tearoff 0
.m add cascade -label File -menu .m.file
.m.file add command -label "New"       -accelerator Ctrl+N       -command do_new
.m.file add command -label "Open…"    -accelerator Ctrl+O       -command open_dialog
.m.file add command -label "Open Folder…" -accelerator Ctrl+Shift+O -command open_folder_dialog
.m.file add command -label "Save"      -accelerator Ctrl+S       -command do_save
.m.file add command -label "Save As…" -accelerator Ctrl+Shift+S -command save_as_dialog
.m.file add separator
.m.file add command -label "Connect to Remote Core…" -command connect_remote_dialog
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
.m.view add command -label "Split Editor"          -accelerator "Ctrl+\\" -command split_editor
.m.view add command -label "Unsplit Editor"        -command unsplit_editor
.m.view add command -label "Move Tab to Other Group" -accelerator "Ctrl+]" -command move_tab_other
.m.view add separator
.m.view add command -label "Compare With File…" -command compare_with_file_dialog
.m.view add command -label "Close Compare" -accelerator Esc -command compare_close
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
	-command {rio_result agent.autoaccept.set [dict create on $::agent_auto_accept]; chat_status_update}
.m.settings add checkbutton -label "Agent: Compare complex edits" \
	-variable ::agent_compare_complex

# The editor keyboard shortcuts and the edit-proxy are installed per group by
# make_editor_group (editor_bindings + editor_proxy). Only the window-manager close
# needs binding here.
wm protocol . WM_DELETE_WINDOW do_quit

# Load the syntax highlighters before the first apply_theme (which configures a
# text tag per token type from the theme's syntax.* roles) and before any buffer
# loads (which re-tokenises it) — D32.
hl_load

# Load saved preferences (theme, wrap, dock, chat) over the defaults, then apply the
# theme before the first tab is drawn, so every widget — and the tab bar refresh_tabs
# builds — uses the role table. A persisted theme that no longer exists falls back to
# the default rather than erroring at startup (D31).
prefs_load
set _boot_theme [rio_call theme.get [dict create name $::theme_name]]
if {![dict get $_boot_theme ok]} {
	set ::theme_name default
	set _boot_theme [rio_call theme.get {}]
}
apply_theme [dict get $_boot_theme result]

# Adopt the core's existing buffer(s), then process the command line. In-process: a
# directory argument opens as the project folder, a file opens in a tab. Remote: the
# path lives on the SERVER, so we can't stat it from here — open each as a project
# folder (project.open) and let the core judge; files are reached via the tree (D29).
set ::nav_dir ""
set ::nav_rows {}
set ::git_rows {}
hello_core                 ;# greet the core; warn on a wire-protocol mismatch (O2)
adopt_initial_buffers      ;# take over the core's existing buffer(s) (D29)
place_dock                 ;# pack the dock (default left) and the editor
show_pane $::dock_pane     ;# default files; also does the first populate
apply_wrap                 ;# sync wrap + the horizontal scrollbar to ::wrap_lines
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
