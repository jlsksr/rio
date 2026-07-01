# rio-core — package entry point.
#
# Loads the document model, dispatch, and op namespaces, and exposes the
# in-process transport (AGENTS.md D2's default path): rio::core::call runs a
# request synchronously and returns both the response and any events it emitted.
# A socket transport (server mode, same dispatch) is a later increment.

namespace eval rio {}
namespace eval rio::core {
	variable evbuf {}
}

apply {{} {
	set dir [file dirname [file normalize [info script]]]
	foreach m {error.tcl document.tcl dispatch.tcl fs.tcl conf.tcl secret.tcl theme.tcl exec.tcl git.tcl project.tcl workspace.tcl diff.tcl agent.tcl agent-tools.tcl \
			ops-buffer.tcl ops-fs.tcl ops-undo.tcl ops-session.tcl ops-theme.tcl ops-exec.tcl ops-git.tcl ops-project.tcl ops-workspace.tcl ops-diff.tcl ops-agent.tcl} {
		source [file join $dir $m]
	}
}}

# A default buffer exists so callers can edit without first opening a file
# (file I/O / multi-buffer management arrives with the fs.* ops).
set rio::ops::default [rio::doc::new ""]

# In-process call: returns {response <dict> events <list>}.
proc rio::core::call {op params} {
	variable evbuf
	set evbuf {}
	set resp [rio::dispatch::handle \
		[dict create op $op params $params] \
		[list rio::core::_sink]]
	return [dict create response $resp events $evbuf]
}

proc rio::core::_sink {ev} {
	variable evbuf
	lappend evbuf $ev
}

# In-process STREAMING call (D26): like `call`, but events are delivered LIVE to
# `emit` as they happen rather than batched into the return — because a streaming
# op (agent.send) keeps emitting after this returns its ack. `emit` is a command
# prefix invoked with each event dict; the return is just the ack response dict.
proc rio::core::call_stream {op params emit} {
	return [rio::dispatch::handle [dict create op $op params $params] $emit]
}
