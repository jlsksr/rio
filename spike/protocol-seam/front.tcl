#!/usr/bin/env wish
#
# SPIKE — throwaway Tk frontend. The deliberately *dumb* view (D3): it never
# edits its own text widget. Edits become buffer.replace requests; the widget
# only changes when the core echoes a buffer.changed event back. Open two of
# these against one core and watch them stay in lockstep — that's D3 + D11 + D12
# proven end to end, plus the Tk event loop and the socket event loop coexisting.
#
# How it stays dumb, robustly: instead of intercepting keystrokes (Tk's %A
# substitution is textual and breaks on `[ " \ {` — anything that isn't a bare
# word), we rename the real widget command and *proxy* it. Tk's own class
# bindings still run and call `.t insert insert <char>` / `.t delete ...`; the
# proxy turns those into protocol requests and suppresses the local edit. The
# character arrives as a proper Tcl argument, so every key — brackets, quotes,
# backslashes, braces — is handled the same way, and paste/cut come along free.
#
# Run (core must be up):   wish front.tcl [port]

package require Tk
package require json

set PORT [expr {[llength $argv] ? [lindex $argv 0] : 7711}]
set sock [socket 127.0.0.1 $PORT]
fconfigure $sock -buffering line -blocking 0 -translation lf -encoding utf-8

wm title . "rio spike — view [pid]"
text .t -wrap none -undo 0 -font {monospace 12} -width 60 -height 18
pack .t -fill both -expand 1
focus .t

proc jstr {v} { return "\"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $v]\"" }
set ::id 0
proc send_replace {start end text} {
	global sock
	puts $sock "{\"id\":[jstr [incr ::id]],\"op\":\"buffer.replace\",\"params\":{\"start\":[jstr $start],\"end\":[jstr $end],\"text\":[jstr $text]}}"
	flush $sock
}

# --- widget proxy: edits become protocol requests, never local mutations -----
rename .t ::rio_real_t
proc .t {args} {
	switch -- [lindex $args 0] {
		insert {
			# .t insert <index> <chars> ?tagList chars ...?
			set idx [::rio_real_t index [lindex $args 1]]
			set chars [lindex $args 2]
			if {$chars ne ""} { send_replace $idx $idx $chars }
			return ""
		}
		delete {
			# .t delete <index1> ?index2?
			set i1 [::rio_real_t index [lindex $args 1]]
			set i2 [expr {[llength $args] >= 3
				? [::rio_real_t index [lindex $args 2]]
				: [::rio_real_t index "[lindex $args 1]+1c"]}]
			if {[::rio_real_t compare $i1 < $i2]} { send_replace $i1 $i2 "" }
			return ""
		}
		default { return [::rio_real_t {*}$args] }
	}
}

# --- core -> widget (applied through the *real* command, not the proxy) -------
proc apply_change {p} {
	# .t replace takes line.col indices directly — the point of D12 sharing the
	# Tk text widget's index format: the view layer is nearly free.
	::rio_real_t replace [dict get $p start] [dict get $p end] [dict get $p text]
}
proc on_sock {} {
	global sock
	if {[catch {gets $sock line} n]} { exit 0 }
	if {$n < 0} { if {[eof $sock]} { puts stderr "core closed"; exit 0 } ; return }
	if {[string trim $line] eq ""} return
	set m [json::json2dict $line]
	if {[dict exists $m event] && [dict get $m event] eq "buffer.changed"} {
		apply_change [dict get $m params]
	} elseif {[dict exists $m result] && [dict exists [dict get $m result] text]} {
		::rio_real_t delete 1.0 end
		::rio_real_t insert 1.0 [dict get [dict get $m result] text]
		::rio_real_t mark set insert 1.0
	}
}
fileevent $sock readable on_sock

# initial sync: pull the canonical document from the core on attach
puts $sock "{\"id\":\"init\",\"op\":\"buffer.text\",\"params\":{}}"
flush $sock
