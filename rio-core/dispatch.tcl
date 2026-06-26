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

namespace eval rio::dispatch {
	variable ops {}   ;# dict: op-name -> handler command
}

proc rio::dispatch::register {op handler} {
	variable ops
	dict set ops $op $handler
}

# Handle one request. `emit` is a command prefix invoked once per event with the
# event dict appended. Returns the response dict.
proc rio::dispatch::handle {msg emit} {
	variable ops
	set id [expr {[dict exists $msg id] ? [dict get $msg id] : ""}]
	if {![dict exists $msg op]} {
		return [dict create id $id ok false error "missing op"]
	}
	set op [dict get $msg op]
	if {![dict exists $ops $op]} {
		return [dict create id $id ok false error "unknown op: $op"]
	}
	set params [expr {[dict exists $msg params] ? [dict get $msg params] : {}}]
	if {[catch {[dict get $ops $op] $params} ret]} {
		return [dict create id $id ok false error $ret]
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
