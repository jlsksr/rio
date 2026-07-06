#!/usr/bin/env wish
#
# Headless test for File ▸ Connect to Remote Core… (AGENTS.md D30). The GUI starts
# in the DEFAULT transport (a spawned local child core, "A"), then reconnect_remote
# rewires THIS window onto a SECOND, real daemon core ("B") over a socket — proving
# the in-place transport swap. Also checks the safety property: a failed connect
# (dead port) leaves the current session fully intact. Needs a DISPLAY (Tk), never
# shows a window.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/reconnect.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs/workspace (D31)
set argv {}                          ;# no --connect ⇒ default: spawn local core A
source [file join [file dirname [info script]] .. rio-gui.tcl]

# Capture errors instead of popping a modal that would block a headless run.
proc report_error {msg {code ""}} { set ::last_error $msg }

set ::fails 0
proc ok {label got want} {
	if {$got eq $want} { puts "PASS  $label" } else {
		puts "FAIL  $label\n        got:  $got\n        want: $want" ; incr ::fails
	}
}
proc tmpbytes {bytes} {
	set f [file tempfile path] ; fconfigure $f -translation binary
	puts -nonewline $f $bytes ; close $f ; return $path
}
proc widget {} { ::rio_real_t get 1.0 end-1c }
proc _accept args {}
proc freeport {} {
	set s [socket -server _accept 0]
	set p [lindex [fconfigure $s -sockname] 2] ; close $s ; return $p
}
proc canconnect {hp} {
	lassign [parse_endpoint $hp] h pp
	if {[catch {socket $h $pp} s]} { return 0 } ; close $s ; return 1
}

# --- unit: parse_endpoint ----------------------------------------------------
ok "parse: good"     [parse_endpoint 127.0.0.1:7711] {127.0.0.1 7711}
ok "parse: no port"  [parse_endpoint hostonly]        ""
ok "parse: bad port" [parse_endpoint host:abc]        ""

# --- baseline: attached to local core A --------------------------------------
ok "A: starts local"  $::core_remote 0
set p [tmpbytes "alpha\nbeta\n"]
do_open $p
do_save                              ;# unmodified, so the reconnect won't prompt to save
ok "A: file open"     [buf_text $::cur] "alpha\nbeta\n"

# --- failure safety: a dead port must not cost us the live session -----------
set ::last_error ""
reconnect_remote 127.0.0.1:[freeport]
ok "fail: reported"      [expr {$::last_error ne ""}] 1
ok "fail: still local"   $::core_remote 0
ok "fail: file intact"   [buf_text $::cur] "alpha\nbeta\n"

# --- bring up a real second core B (a listening daemon) ----------------------
set portB [freeport]
set tclsh [lindex [auto_execok tclsh] 0]
set srv   [file join [file dirname [info script]] .. .. rio-core server.tcl]
set coreB [open "|[list $tclsh $srv $portB] 2>@1" r]
set bpid  [pid $coreB]
set up 0
for {set i 0} {$i < 100} {incr i} { if {[canconnect 127.0.0.1:$portB]} { set up 1 ; break } ; after 50 ; update }
ok "B: daemon listening" $up 1

# --- reconnect THIS window onto core B ---------------------------------------
reconnect_remote 127.0.0.1:$portB
ok "B: now remote"         $::core_remote 1
ok "B: endpoint recorded"  $::core_endpoint 127.0.0.1:$portB
ok "B: fresh core, no A buffers" [buf_text $::cur] ""
ok "B: one adopted buffer" [llength [gorder $::focus]] 1
ok "B: title shows endpoint" [expr {[string match "*127.0.0.1:$portB*" [wm title .]]}] 1
# The link is live to B: an edit round-trips through the new socket and back.
.ed.t insert 1.0 "Z"
ok "B: edit over new channel" [widget]         "Z"
ok "B: core B has the text"   [buf_text $::cur] "Z"

# --- cleanup -----------------------------------------------------------------
catch {close $::core_chan}            ;# drop our socket to B
catch {exec kill $bpid}               ;# stop the daemon
catch {close $coreB}
file delete -force $p

puts [expr {$::fails ? "\n$::fails CHECK(S) FAILED" : "\nALL CHECKS PASSED"}]
exit [expr {$::fails ? 1 : 0}]
