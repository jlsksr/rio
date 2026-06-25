# rio-core — JSON wire encoding for the socket transport (AGENTS.md D11).
#
# The canonical internal form is plain Tcl dicts (D11: the in-process path uses
# them with no serialization). JSON exists only at the socket boundary, and a
# *generic* dict->JSON encoder is impossible — Tcl can't distinguish the string
# "hi there" from the two-element list {hi there}. So encoding is SHAPE-AWARE:
#
#   - The envelope shape is fixed: id (wire string), ok (bare true/false),
#     and either result (object) or error (string).
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

# A response dict {id, ok, result|error} -> a JSON line.
proc rio::wire::response {resp} {
	set id [str [dict get $resp id]]
	if {[dict get $resp ok]} {
		return "{\"id\":$id,\"ok\":true,\"result\":[obj [dict get $resp result]]}"
	}
	return "{\"id\":$id,\"ok\":false,\"error\":[str [dict get $resp error]]}"
}

# An event dict {event, params} -> a JSON line.
proc rio::wire::event {ev} {
	return "{\"event\":[str [dict get $ev event]],\"params\":[obj [dict get $ev params]]}"
}
