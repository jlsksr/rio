# rio-core — out-of-process transports / server mode (AGENTS.md D2, D11, D30).
#
# Server mode is NOT a second codebase: it is the same dispatch (D2) behind a pipe
# or socket. A request line is parsed to a dict and handed to rio::dispatch::handle;
# the response goes back to the requester, while events are broadcast to every
# attached view (D3) — exactly the in-process split, with a JSON line as the
# transport. Tk-free (D1); driven by the event loop (D10).
#
# Two transports, one dispatch:
#   --stdio  the core IS the far end of a pipe — requests on stdin, response + events
#            on stdout. This is how a frontend spawns a PRIVATE core (locally, or via
#            `ssh host … --stdio`): no listening socket ⇒ no shared-host exposure, and
#            SSH / process-ownership do auth (D30). EOF on stdin ⇒ the core exits.
#   [port]   a listening TCP socket (default 7711; 0 = OS-assigned) — the optional
#            persistent-daemon mode for several frontends on one core; loopback by
#            default (D29).
#
# Run:    tclsh server.tcl --stdio        |  tclsh server.tcl [port] [--any]
# Source: defines the procs without blocking; only the direct-execution path enters
#         the event loop.

# The core is a process of its own (spawned `tclsh server.tcl --stdio`, or a daemon),
# so it needs the same UTF-8 source guard the GUI entry point carries: Tcl 8.6 decodes
# scripts with the SYSTEM encoding, which is cp1252 on Windows, and the core's own
# non-ASCII literals (agent tool text, error messages) would arrive mojibake. Setting
# it here covers every module the apply block sources below; the re-read covers this
# file. No-op where the system encoding is already UTF-8.
if {[encoding system] ne "utf-8"} {
	encoding system utf-8
	source -encoding utf-8 [info script]
	return
}

# tcllib, through the gate that names the OS package instead of printing a trace
# (D116). A core spawned over a pipe has nowhere to put a trace anyway: the GUI is
# reading that channel for JSON, and stderr goes to a console the user may not have.
source [file join [file dirname [info script]] deps.tcl]
rio::deps::require json

apply {{} {
	set dir [file dirname [file normalize [info script]]]
	source [file join $dir core.tcl]   ;# loads doc/dispatch/ops + default buffer
	source [file join $dir wire.tcl]
	# The spawned core carries the agent (D30). The PROVIDER-API RUNTIME (D66) is
	# loaded first — the shared rio::llm::* helpers (transport + JSON, plugins/lib)
	# every provider builds on — so both the in-tree providers and any INSTALLED one
	# find it already present. rio::agent::register_provider and rio::secret::* came
	# with core.tcl above; together they are the surface `provider-api = 1` freezes.
	source [file join $dir .. plugins lib json.tcl]
	source [file join $dir .. plugins lib transport.tcl]
	# `echo` (registered in agent.tcl) is now the ONLY built-in provider (D69): both
	# Claude and OpenAI/ChatGPT are INSTALLABLE provider extensions (D66/D69) — each
	# lands in the core's provider store and is sourced by load_all below, not from the
	# tree. The tree carries no provider payload, only the shared runtime (plugins/lib).
	# Now source every installed, version-supported provider from the store (D66),
	# AFTER the built-in and the runtime — restart-to-activate: a provider installed
	# this session becomes live on the NEXT start, never sourced into a running core.
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

# --- stdio transport (AGENTS.md D30) ----------------------------------------
#
# The same dispatch over a single pipe: the "client" is stdin (requests) + stdout
# (responses and broadcast events). Used when a frontend spawns the core as a child
# and talks over its stdio — locally, or tunnelled through `ssh host … --stdio`. No
# listening socket, so nothing on a shared host to connect to; the lifecycle is the
# pipe's (EOF on stdin ⇒ the parent went away ⇒ exit).
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
	# Same handler, same emit contract as the socket path — events to stdout (via the
	# emit), the response to stdout too; the frontend tells them apart by shape (D11).
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
# Start listening; returns the actual port (so callers can use 0 for ephemeral).
# Binds LOOPBACK by default: the core has no auth or encryption (the SSH-tunnel
# model, AGENTS.md D29), so it must not face the public interface unasked. Pass
# `addr` "any" (or "") to bind all interfaces — an explicit, opt-in exposure.
proc rio::server::listen {{port 7711} {addr 127.0.0.1}} {
	if {$addr eq "" || $addr eq "any"} {
		set srv [socket -server rio::server::accept $port]
	} else {
		set srv [socket -server rio::server::accept -myaddr $addr $port]
	}
	return [lindex [fconfigure $srv -sockname] 2]
}

if {[info exists ::argv0] && [file normalize $::argv0] eq [file normalize [info script]]} {
	# --stdio: serve over the pipe (the default frontend transport, D30). Banner to
	# stderr only — stdout IS the protocol stream.
	if {[lsearch -exact $::argv --stdio] >= 0} {
		rio::server::serve_stdio
		puts stderr "rio-core: serving on stdio — Tk-free, pid [pid]"
		vwait forever   ;# blocks until EOF on stdin makes stdio_readable exit
	} else {
		# Otherwise listen on a TCP socket. Default to loopback; --any (or
		# RIO_BIND=0.0.0.0) opts into all interfaces.
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
