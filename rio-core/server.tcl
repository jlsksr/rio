# rio-core — out-of-process transports / server mode (D2, D11, D30).
#
# One JSON line in, one out. A request goes to rio::dispatch::handle; the
# response returns to the requester, events go to every client (D3). No Tk.
#
#   --stdio   requests on stdin, responses and events on stdout. A frontend
#             spawns a private core this way: no listening socket (D30).
#             EOF on stdin ends the core.
#   [port]    a TCP socket (default 7711, 0 = any free port): a daemon for
#             several frontends. Loopback unless --any (D29).
#
# Run:    tclsh server.tcl --stdio        |  tclsh server.tcl [port] [--any]
# Source: defines the procs; only a direct run enters the event loop.

# The UTF-8 source guard (D54). Tcl 8.6 reads scripts in the system encoding,
# which is cp1252 on Windows. Setting it covers every file sourced below; the
# re-read covers this one.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}

# tcllib, through the gate that names the missing OS package (D116).
source [file join [file dirname [info script]] deps.tcl]
rio::deps::require json

apply {{} {
	set dir [file dirname [file normalize [info script]]]
	source [file join $dir core.tcl]   ;# loads doc/dispatch/ops + default buffer
	source [file join $dir wire.tcl]
	# The provider-api runtime (D66): the rio::llm::* helpers every provider
	# builds on. Loaded before any provider.
	source [file join $dir .. plugins lib json.tcl]
	source [file join $dir .. plugins lib transport.tcl]
	# `echo` is the only built-in provider (D69). Every other one is installed
	# in the store and sourced here, once, at start.
	rio::provider::load_all
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
	# Events to all clients, the response to this one.
	set resp [rio::dispatch::handle $msg rio::server::broadcast]
	catch {puts $chan [rio::wire::response $resp]; flush $chan}
}

proc rio::server::accept {chan addr port} {
	variable clients
	fconfigure $chan -buffering line -blocking 0 -translation lf -encoding utf-8
	lappend clients $chan
	fileevent $chan readable [list rio::server::on_readable $chan]
}

# --- stdio transport (D30) ----------------------------------------
#
# The same dispatch over one pipe: requests on stdin, responses and events on
# stdout. EOF on stdin means the parent is gone: exit.
proc rio::server::stdio_emit {ev} {
	catch {puts stdout [rio::wire::event $ev]; flush stdout}
}

proc rio::server::stdio_readable {} {
	if {[catch {gets stdin line} n]} { exit 0 }
	if {$n < 0} { if {[eof stdin]} { exit 0 } ; return }
	if {[string trim $line] eq ""} return
	if {[catch {json::json2dict $line} msg]} {
		catch {puts stdout [rio::wire::response \
			{id {} ok false error {code bad_request message {bad json}}}]; flush stdout}
		return
	}
	# Events and the response both go to stdout; their shape tells them apart (D11).
	set resp [rio::dispatch::handle $msg rio::server::stdio_emit]
	catch {puts stdout [rio::wire::response $resp]; flush stdout}
}

proc rio::server::serve_stdio {} {
	fconfigure stdin  -buffering line -blocking 0 -translation lf -encoding utf-8
	fconfigure stdout -buffering line              -translation lf -encoding utf-8
	fileevent stdin readable rio::server::stdio_readable
}

# --- socket transport (optional daemon mode) --------------------------------
#
# Start listening; returns the actual port (pass 0 for any free one).
# Loopback by default: the core has no auth and no encryption (D29). `addr`
# "any" or "" binds all interfaces.
proc rio::server::listen {{port 7711} {addr 127.0.0.1}} {
	if {$addr eq "" || $addr eq "any"} {
		set srv [socket -server rio::server::accept $port]
	} else {
		set srv [socket -server rio::server::accept -myaddr $addr $port]
	}
	return [lindex [fconfigure $srv -sockname] 2]
}

if {[info exists ::argv0] && [file normalize $::argv0] eq [file normalize [info script]]} {
	# --version: print and exit, before any transport starts (D123).
	if {[lsearch -exact $::argv --version] >= 0} {
		puts "rio $rio::version"
		exit 0
	}
	# The autosave timer (D132), for both transports. Here and not at source
	# time, so a test that sources this file has no timer.
	rio::autosave::start
	# --stdio: serve over the pipe (D30). The banner goes to stderr; stdout is
	# the protocol.
	if {[lsearch -exact $::argv --stdio] >= 0} {
		rio::server::serve_stdio
		puts stderr "rio-core: serving on stdio — Tk-free, pid [pid]"
		vwait forever   ;# blocks until EOF on stdin makes stdio_readable exit
	} else {
		# Otherwise a TCP socket: loopback, or all interfaces with --any or
		# RIO_BIND=0.0.0.0.
		set args $::argv
		set addr [expr {[info exists ::env(RIO_BIND)] ? $::env(RIO_BIND) : "127.0.0.1"}]
		set ai [lsearch -exact $args --any]
		if {$ai >= 0} { set addr any ; set args [lreplace $args $ai $ai] }
		set port [expr {[llength $args] ? [lindex $args 0] : 7711}]
		set actual [rio::server::listen $port $addr]
		set shown [expr {$addr in {any ""} ? "0.0.0.0" : $addr}]
		puts stderr "rio-core server: listening on $shown:$actual — Tk-free, pid [pid]"
		if {$shown eq "0.0.0.0"} {
			puts stderr "  WARNING: bound to ALL interfaces with no auth — front it with an SSH tunnel or a firewall."
		}
		vwait forever
	}
}
