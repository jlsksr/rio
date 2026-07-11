#!/usr/bin/env wish
#
# Headless test for the stale-link watchdog (AGENTS.md D37): a half-open socket —
# the classic stale `ssh -L` forward — accepts writes but never answers and never
# EOFs, so the GUI must notice at the protocol layer, not wait minutes for TCP.
# A pure-Tcl black-hole server (accepts, reads, never replies) plays the stale
# tunnel; the thresholds are shrunk so detection lands in milliseconds.
#
# The watchdog arms only for a socket-attached core (::core_remote); pipe mode is
# covered by the guard at the arm site and by every suite that spawns a child core.
#
# Run:  RIO_GUI_HEADLESS=1 wish rio-gui/tests/stale.tcl

set ::env(RIO_GUI_HEADLESS) 1
source [file join [file dirname [info script]] sandbox.tcl] ;# isolate XDG prefs/workspace (D31)
source [file join [file dirname [info script]] .. .. rio-core server.tcl]
set ::port [rio::server::listen 0]
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

# Capture dialogs instead of blocking on them; flag detection for the vwaits below.
set ::errors {}
proc report_error {message {code ""}} {
	lappend ::errors [list $code $message]
	set ::err_flag 1
}

# The black-hole server: accept, drain, never reply, never close.
proc bh_accept {chan addr port} {
	fconfigure $chan -blocking 0 -buffering none
	fileevent $chan readable [list bh_drain $chan]
}
proc bh_drain {chan} { catch {read $chan} }
set ::bh [socket -server bh_accept -myaddr 127.0.0.1 0]
set ::bhport [lindex [fconfigure $::bh -sockname] 2]

# Point ::core_chan at a black-hole connection — the manual equivalent of
# reconnect_remote's step 3, minus the session reset the test doesn't need.
proc attach_blackhole {} {
	catch {fileevent $::core_chan readable {}}
	catch {close $::core_chan}
	set ::core_chan [socket 127.0.0.1 $::bhport]
	fconfigure $::core_chan -buffering line -blocking 0 -translation lf -encoding utf-8
	fileevent $::core_chan readable core_reader
	set ::core_endpoint "127.0.0.1:$::bhport"
	watch_start
}

# --- startup: socket-attached, so the watchdog armed itself ----------------------
ok "start: watchdog armed"          [expr {$::watch_timer ne ""}] 1

# Shrink the thresholds; re-arm so the new interval takes effect.
set ::watch_interval 200
set ::reply_overdue  400
set ::ping_timeout   300
watch_start

# --- a live core is never falsely disconnected (several probe rounds) ------------
after 1000 {set ::waited 1}
vwait ::waited
ok "live: no false disconnect"      $::errors {}
ok "live: still armed"              [expr {$::watch_timer ne ""}] 1
ok "live: channel still up"         [info exists ::core_chan] 1

# --- an overdue reply: a click into a stale tunnel wakes with an error -----------
attach_blackhole
set resp [rio_call session.hello {}]   ;# unbounded, as every interactive op is
ok "overdue: call woken, not hung"  [dict get $resp error code] disconnected
ok "overdue: reported once"         [llength $::errors] 1
ok "overdue: named the stale link"  [string match "*went stale*" [lindex $::errors 0 1]] 1
ok "overdue: channel torn down"     [info exists ::core_chan] 0
ok "overdue: watchdog disarmed"     $::watch_timer ""

# --- after detection, further ops fail fast instead of hanging -------------------
set resp [rio_call buffer.list {}]
ok "after: ops fail fast"           [dict get $resp error code] disconnected

# --- the idle probe: staleness noticed with no user action at all ----------------
set ::errors {}
set ::err_flag 0
attach_blackhole
after 2000 {set ::err_flag guard}      ;# never reached if the probe works
vwait ::err_flag
ok "idle: detected without a click" [expr {$::err_flag == 1}] 1
ok "idle: named the stale link"     [string match "*went stale*" [lindex $::errors 0 1]] 1
ok "idle: channel torn down"        [info exists ::core_chan] 0

puts ""
if {$::fails == 0} { puts "ALL CHECKS PASSED" } else { puts "$::fails CHECK(S) FAILED" }
exit [expr {$::fails > 0}]
