#!/usr/bin/env wish
# SPIKE — automated check that Tk's event loop and a socket fileevent coexist
# (the failure mode that bit us in toolchain setup). Window withdrawn; self-asserts.
package require Tk
package require json
wm withdraw .
set PORT [expr {[llength $argv] ? [lindex $argv 0] : 7711}]
set s [socket 127.0.0.1 $PORT]
fconfigure $s -buffering line -blocking 0 -translation lf -encoding utf-8
text .t
proc on_sock {} {
	global s
	if {[catch {gets $s line} n]} { exit 1 }
	if {$n < 0} { if {[eof $s]} { exit 1 } ; return }
	if {[string trim $line] eq ""} return
	set m [json::json2dict $line]
	if {[dict exists $m event] && [dict get $m event] eq "buffer.changed"} {
		set p [dict get $m params]
		.t replace [dict get $p start] [dict get $p end] [dict get $p text]
	}
}
fileevent $s readable on_sock
after 200 { puts $s {{"id":"1","op":"buffer.replace","params":{"start":"1.0","end":"1.0","text":"abc"}}} ; flush $s }
after 700 {
	set got [.t get 1.0 "end-1c"]
	if {$got eq "abc"} { puts "TK PASS: widget reflects core broadcast via fileevent under the Tk loop" } \
	else { puts "TK FAIL: widget='$got'" }
	set ::done 1
}
vwait ::done
exit 0
