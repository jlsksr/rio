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

# session.hello {?...?} -> {protocol, name, version, ops, fsroot}
#   protocol — the version above; the client must speak it.
#   name     — this implementation's identity.
#   version  — this core's RELEASE version (rio::version, D123). Not a contract:
#              nothing branches on it. `protocol` says whether the two can talk;
#              this says WHICH rio is on the far end, which is the fact a bug
#              report about a --connect session actually needs and the one thing
#              the frontend could not otherwise know about a core it did not spawn.
#   ops      — the ops actually registered right now (live, never stale).
#   fsroot   — the root of THIS core's filesystem: "/" on POSIX, "C:/" on Windows.
# Conventionally a client's first request. Params (the client's own capabilities)
# are accepted but not yet acted on; that negotiation can grow here later. A pure
# query — emits no events.
#
# `fsroot` exists because the frontend must not guess it. A frontend browses the
# CORE's disk (D30), and the two can be different platforms: a Windows GUI on a Linux
# core was hardcoding "/" (right by luck), while the same GUI on a *local* Windows
# core needed "C:/" and got an unlistable path. The core is the only party that knows,
# so it says. Additive, so it does NOT bump `protocol`: an older core simply omits the
# key and a client falls back, which is the D19 forward-compatibility rule applied to
# the protocol itself. `version` (D123) is additive on exactly the same terms.
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
