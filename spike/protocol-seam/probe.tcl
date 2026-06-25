#!/usr/bin/env tclsh
#
# SPIKE — headless protocol probe. No Tk, no display: a second proof that the
# core is a plain protocol participant (D2) reachable by *any* client (D11).
# Connects, drives a few range edits, reads the broadcast events back, and
# prints the resulting document. This is the "smoke test" half of the spike —
# it runs anywhere, no X needed.
#
# Run (core must be up):   tclsh probe.tcl [port]

package require json

set PORT [expr {[llength $argv] ? [lindex $argv 0] : 7711}]
set s [socket 127.0.0.1 $PORT]
fconfigure $s -buffering line -blocking 1 -translation lf -encoding utf-8

proc jstr {v} { return "\"[string map [list \\ \\\\ \" \\\" \n \\n] $v]\"" }
set ::id 0
proc replace {start end text} {
	global s
	puts $s "{\"id\":[jstr [incr ::id]],\"op\":\"buffer.replace\",\"params\":{\"start\":[jstr $start],\"end\":[jstr $end],\"text\":[jstr $text]}}"
	flush $s
}

# A scripted edit session, each line a range replacement (D12):
replace 1.0 1.0 "hello"          ;# insert at start          -> "hello"
replace 1.5 1.5 " world"         ;# append                   -> "hello world"
replace 1.5 1.5 ",\nbrave"       ;# insert with a newline    -> "hello,\nbrave world"
replace 2.0 2.5 "new"            ;# replace a span            -> "hello,\nnew world"

# Drain the responses/events the core sent back, then ask for the full doc.
puts $s "{\"id\":\"final\",\"op\":\"buffer.text\",\"params\":{}}"
flush $s
while {[gets $s line] >= 0} {
	set m [json::json2dict $line]
	if {[dict exists $m result] && [dict exists [dict get $m result] text]} {
		puts "--- document per core ---"
		puts [dict get [dict get $m result] text]
		puts "-------------------------"
		break
	}
}
close $s
exit 0
