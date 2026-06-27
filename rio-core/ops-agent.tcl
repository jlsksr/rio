# rio-core — the agent.* op namespace (AGENTS.md D20, D26).
#
# Thin handlers over rio::agent. agent.send is the core's first STREAMING op
# (register_stream): it receives the live `emit` and returns only an ack, while
# the turn's content streams back as agent.* events (D26). agent.reset and
# agent.history are ordinary request/response ops over the conversation state.

# agent.send {text} -> {started, turn} ; streams agent.delta -> agent.message
# (or agent.error). The reply is an ack — the content is the events, not the
# response (D26).
proc rio::ops::agent_send {params emit} {
	if {![dict exists $params text]} {
		rio::error::raise bad_request "agent.send requires text"
	}
	return [rio::agent::send [dict get $params text] $emit]
}
rio::dispatch::register_stream agent.send rio::ops::agent_send

# agent.reset -> {} ; clears the conversation.
proc rio::ops::agent_reset {params} {
	rio::agent::reset
	return [dict create result {}]
}
rio::dispatch::register agent.reset rio::ops::agent_reset

# agent.history -> {messages:[{role,text}]} ; the conversation so far (newest
# last). A non-flat result (an array), so the wire layer registers a shape
# encoder (D25; see rio::wire).
proc rio::ops::agent_history {params} {
	return [dict create result [dict create messages [rio::agent::history]]]
}
rio::dispatch::register agent.history rio::ops::agent_history
