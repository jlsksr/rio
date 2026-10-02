# rio-core — request dispatch (D11, D2).
#
# The same for every transport.
#
#   request {id op params} ──► handler ──► response {id ok result}
#                                 │        or       {id ok:false error}
#                                 └──► events ──► emit ──► every client
#
# Events go to an `emit` callback, not to the caller: only the transport
# knows who is attached (D3).
#
# A handler takes `params` (a dict) and returns a dict:
#   result <dict>          — the response payload (default {})
#   events <list of dicts> — events {event <name> params <dict>} (optional)
# It fails by rio::error::raise (error.tcl).
#
# A streaming handler (D26) is called as `handler params emit`: it emits
# events over time and returns only an ack.

namespace eval rio::dispatch {
	variable ops {}        ;# dict: op-name -> handler command
	variable streaming {}  ;# dict: op-name -> 1 for a streaming op
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

# Register a streaming op (D26).
proc rio::dispatch::register_stream {op handler} {
	variable ops
	variable streaming
	dict set ops $op $handler
	dict set streaming $op 1
}

# Every registered op's name, sorted. session.hello reports them.
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
	# `op` is for the wire layer, to pick a result encoder (D25).
	return [dict create id $id ok true result $result op $op]
}
