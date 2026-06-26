# rio-core — socket transport / server mode (AGENTS.md D2, D11).
#
# Server mode is NOT a second codebase: it is the same dispatch (D2) behind a
# socket. A request line is parsed to a dict and handed to rio::dispatch::handle;
# the response goes back to the requesting client, while events are broadcast to
# every attached client (D3) — exactly the in-process split, with a JSON line as
# the transport. Tk-free (D1); driven by the event loop (D10).
#
# Run:    tclsh server.tcl [port]     (default 7711; port 0 = OS-assigned)
# Source: defines the procs and rio::server::listen without blocking; only the
#         direct-execution path enters the event loop.

package require json

apply {{} {
	set dir [file dirname [file normalize [info script]]]
	source [file join $dir core.tcl]   ;# loads doc/dispatch/ops + default buffer
	source [file join $dir wire.tcl]
}}

namespace eval rio::server {
	variable clients {}
}

proc rio::server::broadcast {ev} {
	variable clients
	set line [rio::wire::event $ev]
	foreach c $clients { catch {puts $c $line; flush $c} }
}

proc rio::server::drop {chan} {
	variable clients
	catch {close $chan}
	set clients [lsearch -all -inline -not -exact $clients $chan]
}

proc rio::server::on_readable {chan} {
	if {[catch {gets $chan line} n]} { drop $chan; return }
	if {$n < 0} { if {[eof $chan]} { drop $chan } ; return }
	if {[string trim $line] eq ""} return
	if {[catch {json::json2dict $line} msg]} {
		catch {puts $chan [rio::wire::response \
			{id {} ok false error {code bad_request message {bad json}}}]; flush $chan}
		return
	}
	# Same handler, same emit contract as the in-process path — events broadcast
	# to all clients, the response returns to this one.
	set resp [rio::dispatch::handle $msg rio::server::broadcast]
	catch {puts $chan [rio::wire::response $resp]; flush $chan}
}

proc rio::server::accept {chan addr port} {
	variable clients
	fconfigure $chan -buffering line -blocking 0 -translation lf -encoding utf-8
	lappend clients $chan
	fileevent $chan readable [list rio::server::on_readable $chan]
}

# Start listening; returns the actual port (so callers can use 0 for ephemeral).
proc rio::server::listen {{port 7711}} {
	set srv [socket -server rio::server::accept $port]
	return [lindex [fconfigure $srv -sockname] 2]
}

if {[info exists ::argv0] && [file normalize $::argv0] eq [file normalize [info script]]} {
	set port [expr {[llength $::argv] ? [lindex $::argv 0] : 7711}]
	set actual [rio::server::listen $port]
	puts stderr "rio-core server: listening on $actual — Tk-free, pid [pid]"
	vwait forever
}
