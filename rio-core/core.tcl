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
	foreach m {error.tcl document.tcl dispatch.tcl fs.tcl conf.tcl theme.tcl exec.tcl git.tcl project.tcl \
			ops-buffer.tcl ops-fs.tcl ops-undo.tcl ops-session.tcl ops-theme.tcl ops-exec.tcl ops-git.tcl ops-project.tcl} {
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
