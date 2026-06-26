# rio-core — JSON wire encoding for the socket transport (AGENTS.md D11).
#
# The canonical internal form is plain Tcl dicts (D11: the in-process path uses
# them with no serialization). JSON exists only at the socket boundary, and a
# *generic* dict->JSON encoder is impossible — Tcl can't distinguish the string
# "hi there" from the two-element list {hi there}. So encoding is SHAPE-AWARE:
#
#   - The envelope shape is fixed: id (wire string), ok (bare true/false),
#     and either result (object) or error (a flat {code, message} object, O2).
#   - result and event params are flat objects whose leaf values are emitted as
#     JSON strings. That is exact for every current message (text, line.col
#     indices, ids-as-opaque-strings, removed text).
#
# When an op eventually needs a non-string leaf (a number, a nested object, an
# array), that op declares its shape — we do not guess types from Tcl values.
# Inbound parsing uses tcllib's json::json2dict, which is unambiguous.

namespace eval rio::wire {}

# A JSON string literal. (Control chars beyond these are out of scope for now.)
proc rio::wire::str {s} {
	return "\"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $s]\""
}

# A flat Tcl dict -> a JSON object with string values.
proc rio::wire::obj {d} {
	set parts {}
	dict for {k v} $d { lappend parts "[str $k]:[str $v]" }
	return "{[join $parts ,]}"
}

# A JSON array from a list of already-encoded JSON fragments. The caller decides
# how each element is shaped (with str/obj/arr) — keeping the "no guessing from
# Tcl values" rule (D25): arr never inspects what it joins.
proc rio::wire::arr {items} {
	return "\[[join $items ,]\]"
}

# A JSON array of strings — the common case of arr, where each element is a
# string leaf (the caller declares it's strings, so str applies to each).
proc rio::wire::strarr {items} {
	set out {}
	foreach s $items { lappend out [str $s] }
	return [arr $out]
}

# A JSON object whose VALUES are each encoded by `cmd` (a command prefix taking
# one value). Lets an op declare "object of <shape>" — e.g. an object of objects
# — without the encoder guessing the shape from Tcl values (D25).
proc rio::wire::objmap {d cmd} {
	set parts {}
	dict for {k v} $d { lappend parts "[str $k]:[{*}$cmd $v]" }
	return "{[join $parts ,]}"
}

# Result-shape registry. Almost every result is a flat object (obj), which is
# exact for string leaves. The few ops with a richer result — an array, a nested
# object — register an encoder here, keyed by op name (D25: the op declares its
# shape, the encoder is told it rather than inferring it). `response` consults
# this and falls back to obj.
namespace eval rio::wire { variable results {} }

proc rio::wire::result_encoder {op cmd} {
	variable results
	dict set results $op $cmd
}

# buffer.list: result is {buffers <array of flat objects>}.
proc rio::wire::_result_buffer_list {result} {
	set items {}
	foreach b [dict get $result buffers] { lappend items [obj $b] }
	return "{\"buffers\":[arr $items]}"
}
rio::wire::result_encoder buffer.list rio::wire::_result_buffer_list

# session.hello: {protocol, name} are string leaves; `ops` is an array of strings.
proc rio::wire::_result_session_hello {result} {
	set parts {}
	lappend parts "\"protocol\":[str [dict get $result protocol]]"
	lappend parts "\"name\":[str [dict get $result name]]"
	lappend parts "\"ops\":[strarr [dict get $result ops]]"
	return "{[join $parts ,]}"
}
rio::wire::result_encoder session.hello rio::wire::_result_session_hello

# git.status: `branch` is a string leaf; `changes` is an array of flat objects.
proc rio::wire::_result_git_status {result} {
	set items {}
	foreach c [dict get $result changes] { lappend items [obj $c] }
	return "{\"branch\":[str [dict get $result branch]],\"changes\":[arr $items]}"
}
rio::wire::result_encoder git.status rio::wire::_result_git_status

# git.log: `commits` is an array of flat objects.
proc rio::wire::_result_git_log {result} {
	set items {}
	foreach c [dict get $result commits] { lappend items [obj $c] }
	return "{\"commits\":[arr $items]}"
}
rio::wire::result_encoder git.log rio::wire::_result_git_log

# fs.list: `path` is a string leaf; `entries` is an array of flat objects.
proc rio::wire::_result_fs_list {result} {
	set items {}
	foreach e [dict get $result entries] { lappend items [obj $e] }
	return "{\"path\":[str [dict get $result path]],\"entries\":[arr $items]}"
}
rio::wire::result_encoder fs.list rio::wire::_result_fs_list

# theme.get: `colors` is a flat object; `fonts` is an object OF flat objects.
proc rio::wire::_result_theme_get {result} {
	set parts {}
	lappend parts "\"colors\":[obj [dict get $result colors]]"
	lappend parts "\"fonts\":[objmap [dict get $result fonts] rio::wire::obj]"
	return "{[join $parts ,]}"
}
rio::wire::result_encoder theme.get rio::wire::_result_theme_get

# A response dict {id, ok, result|error, ?op?} -> a JSON line. `op` (present on
# ok replies) selects a shape-specific result encoder; without one, the result
# is a flat object.
proc rio::wire::response {resp} {
	variable results
	set id [str [dict get $resp id]]
	if {![dict get $resp ok]} {
		# error is a flat {code, message} object (the taxonomy, O2).
		return "{\"id\":$id,\"ok\":false,\"error\":[obj [dict get $resp error]]}"
	}
	set r [dict get $resp result]
	if {[dict exists $resp op] && [dict exists $results [dict get $resp op]]} {
		set body [[dict get $results [dict get $resp op]] $r]
	} else {
		set body [obj $r]
	}
	return "{\"id\":$id,\"ok\":true,\"result\":$body}"
}

# An event dict {event, params} -> a JSON line.
proc rio::wire::event {ev} {
	return "{\"event\":[str [dict get $ev event]],\"params\":[obj [dict get $ev params]]}"
}
