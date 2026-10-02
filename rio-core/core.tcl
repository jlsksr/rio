# rio-core — package entry point.
#
# Sources the core: document model, dispatch, ops. rio::core::call and
# call_stream invoke an op from inside the core, for the agent and for tests.
# The transports are in server.tcl.

namespace eval rio {}
namespace eval rio::core {
	variable evbuf {}
}

apply {{} {
	set dir [file dirname [file normalize [info script]]]
	foreach m {version.tcl error.tcl document.tcl dispatch.tcl fs.tcl conf.tcl autosave.tcl secret.tcl theme.tcl exec.tcl git.tcl project.tcl workspace.tcl diff.tcl tls.tcl http.tcl sig.tcl agent-prompt.tcl agent-settings.tcl agent.tcl agent-tools.tcl agent-allow.tcl provider.tcl \
			ops-buffer.tcl ops-fs.tcl ops-autosave.tcl ops-undo.tcl ops-session.tcl ops-theme.tcl ops-exec.tcl ops-git.tcl ops-project.tcl ops-workspace.tcl ops-diff.tcl ops-agent.tcl ops-repo.tcl ops-sig.tcl ops-tls.tcl ops-provider.tcl} {
		source [file join $dir $m]
	}
}}

# A default buffer, for a request that names none.
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

# In-process streaming call (D26): events go to `emit` as they happen, since
# a streaming op keeps emitting after its ack. Returns the ack.
proc rio::core::call_stream {op params emit} {
	return [rio::dispatch::handle [dict create op $op params $params] $emit]
}
