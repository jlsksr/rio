#!/usr/bin/env wish
#
# End-to-end REMOTE smoke for rio-gui (AGENTS.md D29): a real socket between the GUI
# (remote mode, transport seam routing every op over the wire) and an in-process
# rio-core server (the same dispatch a headless VPS would run). It proves open /
# edit / save / compare all work GUI -> remote-core over the socket — the widget only
# ever changes because a buffer.changed event round-tripped the wire, never a local
# core call. Needs a DISPLAY (Tk), but never shows a window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/remote.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs/workspace (D31)

# The "server side": load rio-core's socket server and start listening on an
# ephemeral loopback port. This is the core a remote box would run.
source [file join [file dirname [info script]] .. .. rio-core server.tcl]
set ::port [rio::server::listen 0]

# The "client side": source the real GUI in REMOTE mode. ::connect_to is pre-set, so
# the frontend loads only the wire encoder (no embedded core) and connects a socket
# back to our in-process server. argv emptied so nothing is treated as a file.
set ::connect_to "127.0.0.1:$::port"
set argv {}
source [file join [file dirname [info script]] .. rio-gui.tcl]

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} {
		puts "PASS  $label"
	} else {
		puts "FAIL  $label\n        got:  $got\n        want: $want"
		incr ::fails
	}
}
proc tmpbytes {bytes} {
	set f [file tempfile path]
	fconfigure $f -translation binary
	puts -nonewline $f $bytes ; close $f
	return $path
}
proc diskbytes {path} { set f [open $path rb] ; set b [::read $f] ; close $f ; return $b }
proc widget {} { ::rio_real_t get 1.0 end-1c }
# The SERVER's view of a buffer's text — same process, so we can inspect the core
# state the GUI is editing through the socket. This is the document of record (D29).
proc srvtext {id} { return [rio::doc::text $id] }

# --- the transport is a remote (socket) core ---------------------------------
ok "remote: core marked remote"   $::core_remote 1
ok "remote: channel open"         [expr {[info exists ::core_chan] && $::core_chan in [chan names]}] 1
# The agent runs in the core wherever it is, so it's available over a remote daemon
# too — same GUI, the turn and any key just live server-side (D26/D30). The smoke
# exercises a full agent turn over a socket; here we only confirm it isn't gated off.
ok "remote: agent chat available" $::chat_shown 1

# --- buffer.list adoption over the socket ------------------------------------
# adopt_initial_buffers ran at startup: it pulled the server's open buffers via
# buffer.list (over the wire) and activated the first — the server's default buffer.
ok "adopt: a buffer is active"    [expr {$::cur ne ""}] 1
ok "adopt: cur is server default" $::cur $rio::ops::default
ok "adopt: one tab to start"      [llength $::order] 1

# --- open a server-side file over the socket ---------------------------------
set p [tmpbytes "alpha\nbeta\n"]
do_open $p
ok "open: path recorded"          [bufget $::cur path] $p
ok "open: widget mirrors file"    [widget]             "alpha\nbeta\n"
ok "open: server core has text"   [srvtext $::cur]     "alpha\nbeta\n"
# The empty scratch buffer was pruned over the socket (buffer.text + buffer.close).
ok "open: scratch pruned"         [llength $::order]   1

# --- edit through the dumb-view proxy: the change round-trips the wire --------
# .ed.t insert -> buffer.replace request -> the server edits + broadcasts
# buffer.changed -> remote_reader applies it to the widget. The widget can only
# reflect "X" if that event crossed the socket (remote mode never calls the core
# in-process). The server's own document must agree.
.ed.t insert 1.0 "X"
ok "edit: marked modified"        [bufget $::cur modified] 1
ok "edit: server core updated"    [srvtext $::cur]         "Xalpha\nbeta\n"
ok "edit: widget updated by event" [widget]                "Xalpha\nbeta\n"

# --- undo / redo over the socket (one clean edit to revert) ------------------
do_undo
ok "undo: reverted via wire"      [srvtext $::cur] "alpha\nbeta\n"
ok "undo: widget mirrors undo"    [widget]         "alpha\nbeta\n"
do_redo
ok "redo: reapplied via wire"     [srvtext $::cur] "Xalpha\nbeta\n"

# Tricky characters survive the JSON round-trip (escaping in rio::wire::obj): a
# self-contained insert + delete that leaves the buffer as it was.
.ed.t insert 1.0 "\{\"\\z"
ok "edit: braces/quotes/backslash intact" \
	[string range [srvtext $::cur] 0 3] "\{\"\\z"
.ed.t delete 1.0 1.4
ok "edit: probe removed cleanly"  [srvtext $::cur] "Xalpha\nbeta\n"

# --- save to the server's filesystem -----------------------------------------
do_save
ok "save: not modified"           [bufget $::cur modified] 0
ok "save: bytes on server disk"   [diskbytes $p]           "Xalpha\nbeta\n"
file delete -force $p

# --- compare view: diff.lines (an array result) crosses the socket -----------
proc cmp_rows {t} { return [lindex [split [$t index end-1c] .] 0] }
compare_open "a\nb\nc\nd" "a\nB\nc\nd\ne" "left" "right"
ok "compare: shown"               $::compare_shown 1
ok "compare: panes equal length"  [expr {[cmp_rows .cmp.l.t] == [cmp_rows .cmp.r.t]}] 1
ok "compare: removed line tagged"  [expr {[llength [.cmp.l.t tag ranges del]] > 0}] 1
ok "compare: added line tagged"    [expr {[llength [.cmp.r.t tag ranges add]] > 0}] 1
compare_close
ok "compare: closed"              $::compare_shown 0

# --- a second tab + buffer.list count stays in step --------------------------
set q [tmpbytes "two\n"]
do_open $q
ok "tabs: second file opened"     [llength $::order] 2
ok "tabs: server has both bufs" \
	[expr {[llength [dict get [rio_call buffer.list {}] result buffers]] == 2}] 1
file delete -force $q

# --- a failed op surfaces the wire error, doesn't crash ----------------------
set ::captured {}
proc report_error {message {code ""}} { lappend ::captured [list $code $message] }
set resp [rio_call file.open [dict create path /nonexistent/rio-remote-xyz]]
ok "error: failed op returns ok=false" [dict get $resp ok] false
ok "error: error carries a code"       [expr {[dict get $resp error code] ne ""}] 1

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
