# rio-core — request dispatch (AGENTS.md D11, D2).
#
# The transport-independent heart of the protocol. A request is a dict
# {id, op, params}; dispatch routes op to a registered handler and shapes the
# reply as {id, ok, result} or {id, ok:false, error} (D11). Handlers may also
# produce events, which are *not* returned to the caller but pushed to an
# `emit` callback — because events broadcast to every attached view (D3/D11),
# and only the transport knows who is attached. This separation is what makes
# the same handlers work in-process and over a socket (D2).
#
# A handler takes `params` (a dict) and returns a dict:
#   result <dict>          — the response payload (default {})
#   events <list of dicts> — each an event {event <name> params <dict>} (optional)
#
# A handler signals failure by raising via rio::error::raise; the error reply is
# a flat {code, message} object (the taxonomy in error.tcl, O2).

namespace eval rio::dispatch {
	variable ops {}        ;# dict: op-name -> handler command
	variable streaming {}  ;# dict: op-name -> 1 for streaming ops (D26). A
	                       ;# streaming handler is called as `handler params emit`
	                       ;# and emits events LIVE over time (typically from a
	                       ;# coroutine), returning only an immediate ack; an
	                       ;# ordinary handler is `handler params` and returns its
	                       ;# events in a batch for dispatch to replay.
}

# Shape an error reply: machine-readable code + human message (D11/O2).
proc rio::dispatch::_fail {id code message} {
	return [dict create id $id ok false \
		error [dict create code $code message $message]]
}

proc rio::dispatch::register {op handler} {
	variable ops
	dict set ops $op $handler
}

# Register a STREAMING op (D26): its handler receives the live `emit` callback so
# it can broadcast events over time and returns only an immediate ack response.
proc rio::dispatch::register_stream {op handler} {
	variable ops
	variable streaming
	dict set ops $op $handler
	dict set streaming $op 1
}

# The names of every registered op, sorted. session.hello reports these so a
# client learns what this core supports without a hand-maintained list (O2).
proc rio::dispatch::opnames {} {
	variable ops
	return [lsort [dict keys $ops]]
}

# Handle one request. `emit` is a command prefix invoked once per event with the
# event dict appended. Returns the response dict.
proc rio::dispatch::handle {msg emit} {
	variable ops
	variable streaming
	set id [expr {[dict exists $msg id] ? [dict get $msg id] : ""}]
	if {![dict exists $msg op]} {
		return [_fail $id bad_request "missing op"]
	}
	set op [dict get $msg op]
	if {![dict exists $ops $op]} {
		return [_fail $id unknown_op "unknown op: $op"]
	}
	set params [expr {[dict exists $msg params] ? [dict get $msg params] : {}}]
	# A streaming op (D26) is handed the live `emit` so it can broadcast events
	# itself over time; it returns just an ack. An ordinary op returns its events
	# (if any) for us to replay through `emit` below.
	if {[dict exists $streaming $op]} {
		set rc [catch {[dict get $ops $op] $params $emit} ret opts]
	} else {
		set rc [catch {[dict get $ops $op] $params} ret opts]
	}
	if {$rc} {
		return [_fail $id [rio::error::code_of $opts] $ret]
	}
	set result [expr {[dict exists $ret result] ? [dict get $ret result] : {}}]
	if {[dict exists $ret events]} {
		foreach ev [dict get $ret events] {
			{*}$emit $ev
		}
	}
	# `op` rides along so the wire layer can pick a shape-specific result encoder
	# (D25); in-process callers ignore it. Error replies need no op (no result).
	return [dict create id $id ok true result $result op $op]
}
