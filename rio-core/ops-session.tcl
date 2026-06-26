# rio-core — the session.* op namespace (AGENTS.md D11, O2).
#
# Capability / version negotiation. The protocol's in-process default path needs
# none of this (one process, both halves the same code), but a SEPARATE client —
# a reattaching socket editor, the TUI, a plugin — may be a different version, so
# it greets the core first and learns what it's talking to before relying on a
# feature.

namespace eval rio::ops {
	# The wire protocol version. A single integer that bumps on a BREAKING change
	# to the protocol (an op's params/result shape changing incompatibly, the
	# envelope changing). This is the number a client checks for compatibility.
	# v2: error replies carry a {code, message} object instead of a bare string
	# (the taxonomy, O2).
	variable protocol 2
}

# session.hello {?...?} -> {protocol, name, ops}
#   protocol — the version above; the client must speak it.
#   name     — this implementation's identity.
#   ops      — the ops actually registered right now (live, never stale).
# Conventionally a client's first request. Params (the client's own capabilities)
# are accepted but not yet acted on; that negotiation can grow here later. A pure
# query — emits no events.
proc rio::ops::session_hello {params} {
	variable protocol
	return [dict create result [dict create \
		protocol $protocol \
		name     rio-core \
		ops      [rio::dispatch::opnames]]]
}
rio::dispatch::register session.hello rio::ops::session_hello
