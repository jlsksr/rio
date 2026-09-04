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

# agent.approve {turn, decision} -> {id} ; resolves a proposed edit awaiting the
# user's decision ("approve" | "reject"). The suspended turn resumes and its
# remaining content streams as agent.* events on that turn's original emit (D26 s5).
# A turn with nothing pending is a `bad_request` error.
proc rio::ops::agent_approve {params} {
	foreach k {turn decision} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "agent.approve requires $k"
		}
	}
	set id [rio::agent::approve [dict get $params turn] [dict get $params decision]]
	return [dict create result [dict create id $id]]
}
rio::dispatch::register agent.approve rio::ops::agent_approve

# agent.proposal {turn} -> {name, path, original, proposed} ; the full original and
# proposed text of a write awaiting review for `turn` (D28). The compare/diff view
# pulls this on demand to render the two versions side by side; the agent.propose
# event stays lean. A turn with nothing pending is a `bad_request`.
proc rio::ops::agent_proposal {params} {
	if {![dict exists $params turn]} {
		rio::error::raise bad_request "agent.proposal requires turn"
	}
	return [dict create result [rio::agent::proposal [dict get $params turn]]]
}
rio::dispatch::register agent.proposal rio::ops::agent_proposal

# agent.reset -> {} ; clears the conversation.
proc rio::ops::agent_reset {params} {
	rio::agent::reset
	return [dict create result {}]
}
rio::dispatch::register agent.reset rio::ops::agent_reset

# --- provider / key / policy controls (D30) ----------------------------------
#
# The agent is a core concern reached over the channel, so its settings are ops,
# not in-process calls: a frontend (the GUI, local or remote) drives them the same
# way. The provider runs and the key lives WHEREVER THE CORE RUNS (server-side for
# a remote core; D21's 0600 store) — the frontend never holds the credential (D3).

# agent.provider.set {name} -> {name} ; choose the live provider by name
# (echo | a plugin-registered provider such as claude). Unknown name is bad_request.
proc rio::ops::agent_provider_set {params} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "agent.provider.set requires name"
	}
	set name [rio::agent::use_provider [dict get $params name]]
	return [dict create result [dict create name $name]]
}
rio::dispatch::register agent.provider.set rio::ops::agent_provider_set

# agent.key.set {key ?name?} -> {} ; store a keyed provider's credential (an API
# key) in the core's 0600 secret store (D21). `name` picks which provider's store
# (claude | openai | …); omitted, it targets the active provider. The frontend
# hands the key across once and never keeps it.
proc rio::ops::agent_key_set {params} {
	if {![dict exists $params key]} {
		rio::error::raise bad_request "agent.key.set requires key"
	}
	set name [expr {[dict exists $params name] ? [dict get $params name] : ""}]
	rio::agent::key_set [dict get $params key] $name
	return [dict create result {}]
}
rio::dispatch::register agent.key.set rio::ops::agent_key_set

# agent.key.clear {?name?} -> {} ; forget a keyed provider's stored credential
# (defaults to the active provider, as agent.key.set does).
proc rio::ops::agent_key_clear {params} {
	set name [expr {[dict exists $params name] ? [dict get $params name] : ""}]
	rio::agent::key_clear $name
	return [dict create result {}]
}
rio::dispatch::register agent.key.clear rio::ops::agent_key_clear

# agent.providers -> {providers:[{name, label, keyed, key_set, signup}]} ; every
# registered provider, so a frontend renders its picker and per-provider key dialog
# from data the provider declares rather than hardcoding names (D30; serves the
# installable-provider milestone). A non-flat result — the wire layer registers a
# shape encoder (D25).
proc rio::ops::agent_providers {params} {
	return [dict create result [dict create providers [rio::agent::providers_info]]]
}
rio::dispatch::register agent.providers rio::ops::agent_providers

# agent.autoaccept.set {on} -> {on} ; toggle the approval gate (D26 s5). When on,
# a proposed edit applies without waiting for the user's Approve/Reject.
proc rio::ops::agent_autoaccept_set {params} {
	if {![dict exists $params on]} {
		rio::error::raise bad_request "agent.autoaccept.set requires on"
	}
	set on [expr {[dict get $params on] ? 1 : 0}]
	rio::agent::set_auto_accept $on
	return [dict create result [dict create on $on]]
}
rio::dispatch::register agent.autoaccept.set rio::ops::agent_autoaccept_set

# agent.status -> {provider, auto_accept, key_set} ; the agent's current settings,
# so a frontend renders its menus/dialogs without holding the state itself (D3).
# `key_set` is whether the ACTIVE provider has a key stored (0 for a keyless one
# like echo); per-provider key state is in agent.providers. All leaves are
# strings — the default wire encoder applies.
proc rio::ops::agent_status {params} {
	return [dict create result [dict create \
		provider    [rio::agent::provider_name] \
		auto_accept [rio::agent::auto_accept] \
		key_set     [rio::agent::key_status]]]
}
rio::dispatch::register agent.status rio::ops::agent_status

# agent.history -> {messages:[{role,text}]} ; the conversation so far (newest
# last). A non-flat result (an array), so the wire layer registers a shape
# encoder (D25; see rio::wire).
proc rio::ops::agent_history {params} {
	return [dict create result [dict create messages [rio::agent::history]]]
}
rio::dispatch::register agent.history rio::ops::agent_history
