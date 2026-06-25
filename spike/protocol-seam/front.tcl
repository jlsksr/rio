#!/usr/bin/env wish
#
# SPIKE — throwaway Tk frontend. The deliberately *dumb* view (D3): it never
# edits its own text widget. Keystrokes become buffer.replace requests; the
# widget only changes when the core echoes a buffer.changed event back. Open two
# of these against one core and watch them stay in lockstep — that's D3 + D11 +
# D12 proven end to end, plus the Tk event loop and the socket event loop coexisting.
#
# Run (core must be up):   wish front.tcl [port]   (or: tclsh front.tcl [port])

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

# --- keystrokes -> protocol requests; `break` stops the widget self-editing --
bind .t <Key> {
	# printable single chars only; everything else handled explicitly or ignored
	if {[string length %A] == 1 && %A ne "\r" && %A ne "\t"} {
		send_replace [.t index insert] [.t index insert] %A
		break
	}
}
bind .t <Return>    { send_replace [.t index insert] [.t index insert] "\n" ; break }
bind .t <Tab>       { send_replace [.t index insert] [.t index insert] "\t" ; break }
bind .t <BackSpace> {
	if {[.t compare insert != 1.0]} {
		send_replace [.t index "insert-1c"] [.t index insert] ""
	}
	break
}
bind .t <Delete> {
	if {[.t compare insert != end-1c]} {
		send_replace [.t index insert] [.t index "insert+1c"] ""
	}
	break
}
# arrows / clicks move the (frontend-local, D515) cursor — leave them to Tk.

# --- core -> widget ---------------------------------------------------------
proc apply_change {p} {
	# .t replace takes line.col indices directly — the whole point of D12 sharing
	# the Tk text widget's index format: the view layer is nearly free.
	.t replace [dict get $p start] [dict get $p end] [dict get $p text]
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
		.t delete 1.0 end
		.t insert 1.0 [dict get [dict get $m result] text]
		.t mark set insert 1.0
	}
}
fileevent $sock readable on_sock

# initial sync: pull the canonical document from the core on attach
puts $sock "{\"id\":\"init\",\"op\":\"buffer.text\",\"params\":{}}"
flush $sock
