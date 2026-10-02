# rio-core — the session.* op namespace (D11, O2).
#
# A client may be another version than the core, so it greets the core first.

namespace eval rio::ops {
	# The protocol version: an integer, bumped only by a breaking change. An
	# added key or op leaves it alone (D123).
	#   2: an error reply carries {code, message}, not a bare string.
	variable protocol 2
}

# session.hello {?...?} -> {protocol, name, version, ops, fsroot}
#   protocol — the version above; the client must speak it
#   name     — this implementation's name
#   version  — this core's release version (D123), for a bug report; nothing
#              branches on it
#   ops      — the ops registered now
#   fsroot   — the root of this core's filesystem: "/" on POSIX, "C:/" on
#              Windows. A frontend browses the core's disk (D30) and must not
#              guess it (D55).
# A client's first request. Its params are accepted and ignored. No events.
proc rio::ops::session_hello {params} {
	variable protocol
	return [dict create result [dict create \
		protocol $protocol \
		name     rio-core \
		version  $rio::version \
		ops      [rio::dispatch::opnames] \
		fsroot   [file normalize /]]]
}
rio::dispatch::register session.hello rio::ops::session_hello
