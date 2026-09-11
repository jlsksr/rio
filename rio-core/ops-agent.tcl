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

# agent.stop {?turn?} -> {stopped N} ; stop a turn in flight (D104). Omit `turn` to stop
# whatever is running — which is what a frontend's Stop button means. Each stopped turn is
# announced as an `agent.stopped` event so EVERY attached frontend takes its working
# indicator down, not just the one that clicked (D3/D30). Stopping nothing is not an error:
# the click may have raced the turn's last event.
proc rio::ops::agent_stop {params} {
	set turn [expr {[dict exists $params turn] ? [dict get $params turn] : ""}]
	set stopped [rio::agent::stop $turn]
	set evs {}
	foreach t $stopped {
		lappend evs [dict create event agent.stopped params [dict create turn $t]]
	}
	return [dict create result [dict create stopped [llength $stopped]] events $evs]
}
rio::dispatch::register agent.stop rio::ops::agent_stop

# agent.reset -> {} ; clears the conversation.
proc rio::ops::agent_reset {params} {
	rio::agent::reset
	return [dict create result {}]
}
rio::dispatch::register agent.reset rio::ops::agent_reset

# --- command allow-list (D84) -------------------------------------------------
#
# Standing approval for trusted commands: a human-authored allow-list, persisted in the
# core's XDG agent dir / open project (D79's home). A rule is an argv PREFIX (a list of
# leading tokens); a command whose argv starts with a rule's tokens runs without the
# approval bar (rio::agent::_do_exec consults it, D84). THREE SCOPES mirror the prompt
# layers: `global` (every project), `provider` (the named/active provider only, echo
# excluded), `project` (the open project's .rio/). `matches` unions the active layers.
# Like every agent setting these are ops, so a remote core owns the lists on ITS disk
# (D30). The list changes ONLY whether the human bar appears — prepare_exec always runs.
#
# `scope` defaults to `global` and `name` to the active provider, so the pre-scope flat
# calls still work. Provider `name` is validated as a registered non-echo provider.
proc rio::ops::_agent_allow_scope {params} {
	set scope [expr {[dict exists $params scope] ? [dict get $params scope] : "global"}]
	if {$scope ni {global provider project}} {
		rio::error::raise bad_request "agent.allow.*: unknown scope '$scope'"
	}
	set name [expr {[dict exists $params name] ? [dict get $params name] : ""}]
	if {$scope eq "provider"} {
		if {$name eq ""} { set name [rio::agent::provider_name] }
		if {$name eq "echo"} {
			rio::error::raise bad_request "the echo provider has no allow-list"
		}
		if {$name ni [rio::agent::provider_names]} {
			rio::error::raise bad_request "unknown agent provider: $name"
		}
	}
	if {$scope eq "project" && [rio::project::root] eq ""} {
		rio::error::raise bad_request "no project is open"
	}
	return [list $scope $name]
}

# agent.allow.list {?scope? ?name?} -> {rules:[[token,…],…]} ; one scope's list, for a
# manager view. Each rule is an array of argv-prefix token strings (wire encoder, D25).
proc rio::ops::agent_allow_list {params} {
	lassign [_agent_allow_scope $params] scope name
	return [dict create result [dict create rules [rio::agent::allow::rules $scope $name]]]
}
rio::dispatch::register agent.allow.list rio::ops::agent_allow_list

# agent.allow.add {rule ?scope? ?name?} -> {} ; trust an argv prefix in one scope.
# `rule` is a JSON array of strings — a one-element rule trusts a program with any args,
# a full-argv rule trusts only that exact command. An empty rule is bad_request (it
# would trust everything). Adding a rule already present is a no-op (dedup).
proc rio::ops::agent_allow_add {params} {
	if {![dict exists $params rule]} {
		rio::error::raise bad_request "agent.allow.add requires rule"
	}
	set rule [dict get $params rule]
	if {[llength $rule] == 0} {
		rio::error::raise bad_request "agent.allow.add: rule is empty"
	}
	lassign [_agent_allow_scope $params] scope name
	rio::agent::allow::add $scope $name $rule
	return [dict create result {}]
}
rio::dispatch::register agent.allow.add rio::ops::agent_allow_add

# agent.allow.remove {rule ?scope? ?name?} -> {} ; forget an exact-equal rule from one
# scope. A rule not present is a no-op.
proc rio::ops::agent_allow_remove {params} {
	if {![dict exists $params rule]} {
		rio::error::raise bad_request "agent.allow.remove requires rule"
	}
	lassign [_agent_allow_scope $params] scope name
	rio::agent::allow::remove $scope $name [dict get $params rule]
	return [dict create result {}]
}
rio::dispatch::register agent.allow.remove rio::ops::agent_allow_remove

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

# The prompt layers a frontend may name (D34/D70/D79/D101/D105), in composition order.
# `base` and `plan` are rio's own shipped layers; the other three are the user's.
namespace eval rio::ops { variable prompt_layers {base system provider project plan} }

# Validate a {which ?name?} pair for the three prompt ops and return the provider name
# ("" unless `which` is provider). One gate for all three, because "which prompt do you
# mean" has exactly one right answer whether you are listing, reading or editing it.
# `allow` narrows the acceptable set (agent.prompt.get also takes `composed`).
proc rio::ops::_prompt_which {params allow op} {
	if {![dict exists $params which]} {
		rio::error::raise bad_request "$op requires which"
	}
	set which [dict get $params which]
	if {$which ni $allow} {
		rio::error::raise bad_request "$op: unknown prompt '$which'"
	}
	if {$which eq "project" && [rio::project::root] eq ""} {
		rio::error::raise bad_request "no project is open"
	}
	set name ""
	if {$which eq "provider"} {
		if {![dict exists $params name]} {
			rio::error::raise bad_request "$op provider requires name"
		}
		set name [dict get $params name]
		if {$name eq "echo"} {
			rio::error::raise bad_request "the echo provider has no system prompt"
		}
		if {$name ni [rio::agent::provider_names]} {
			rio::error::raise bad_request "unknown agent provider: $name"
		}
	}
	return $name
}

# agent.prompt.list {} -> {prompts: [{which,name,path,origin,exists,builtin,active,chars}]} ;
# the whole system prompt laid out layer by layer, in the order they are composed (D105).
# `origin` says where each layer's file actually comes from — `shipped` (rio's own copy),
# `user` (the XDG agent dir, including an override of a shipped layer), `project`, or
# `none` — and `active` says whether that layer is contributing to what the provider is
# being sent RIGHT NOW, for the live provider and the live mode. This is the op behind
# Preferences ▸ Agent ▸ Agent Prompts…: the point is that nothing about the agent's
# instructions is hidden from the person whose project they act on. Non-flat result — the
# wire layer registers a shape encoder (D25).
proc rio::ops::agent_prompt_list {params} {
	set ls [rio::agent::prompt::layers [rio::agent::provider_name] [rio::agent::mode]]
	return [dict create result [dict create prompts $ls]]
}
rio::dispatch::register agent.prompt.list rio::ops::agent_prompt_list

# agent.prompt.get {which ?name?} -> {which, path, origin, text} ; one layer's text, for
# READING (D105) — including rio's shipped `base` and `plan`, which have no editable file
# of their own, and `composed`, the finished string the provider would be sent right now.
# The core reads it on its own disk, so a remote core shows the prompts that are really in
# effect there (D30). `plan` comes back whatever the current mode is: being asked to read
# it is a different question from whether it is live. A layer with no file yields empty
# `text` and `origin none` — absent is a normal state, not an error.
proc rio::ops::agent_prompt_get {params} {
	variable prompt_layers
	set name [_prompt_which $params [concat $prompt_layers composed] agent.prompt.get]
	set which [dict get $params which]
	set path ""
	set origin composed
	if {$which ne "composed"} {
		set l [rio::agent::prompt::layer $which $name [rio::agent::mode]]
		set path [dict get $l path] ; set origin [dict get $l origin]
	}
	set txt [rio::agent::prompt::text $which $name \
		[rio::agent::provider_name] [rio::agent::mode]]
	return [dict create result [dict create \
		which $which path $path origin $origin text $txt]]
}
rio::dispatch::register agent.prompt.get rio::ops::agent_prompt_get

# agent.prompt.edit {which ?name?} -> {path, created} ; resolve a WRITABLE prompt file
# (D70/D79/D105) and ensure it exists so a frontend can open it in the editor. `which` is
# `system` (the user's standing prompt for all projects, in the XDG agent dir), `provider`
# (that provider's own prompt, `providers/<name>.md` in the same dir — `name` required,
# must be a registered provider and not echo), `project` (`.rio/agent.md` at the open
# project root), or one of rio's shipped layers, `base` / `plan` — for which the writable
# file is the OVERRIDE in the user's agent dir, seeded with a copy of the text it
# overrides (rio's own copy is never edited in place: an upgrade would take the edit
# away, and on a packaged install it may not even be writable). The core owns the path —
# a remote core resolves it on its OWN disk (D30) — and creates the file if absent
# (`created` says which). `project` with no open project, and `provider` with a missing/
# unknown/echo name, are bad_request. Flat result, so the default wire encoder applies.
proc rio::ops::agent_prompt_edit {params} {
	variable prompt_layers
	set name [_prompt_which $params $prompt_layers agent.prompt.edit]
	set which [dict get $params which]
	set r [rio::agent::prompt::ensure $which $name]
	if {$r eq ""} {
		rio::error::raise bad_request "cannot resolve the $which prompt path"
	}
	return [dict create result [dict create \
		path [dict get $r path] created [dict get $r created]]]
}
rio::dispatch::register agent.prompt.edit rio::ops::agent_prompt_edit

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

# agent.mode.set {mode} -> {mode} ; switch between `build` and `plan` (D101). In plan
# mode the core hands the provider only the read tools and present_plan, and adds the
# plan prompt layer — so what the agent may do changes here, in the core, not in a
# provider. An unknown mode is a bad_request. Approving a presented plan flips the mode
# back to `build` on its own and announces it with an `agent.mode` event.
proc rio::ops::agent_mode_set {params} {
	if {![dict exists $params mode]} {
		rio::error::raise bad_request "agent.mode.set requires mode"
	}
	return [dict create result [dict create mode [rio::agent::set_mode [dict get $params mode]]]]
}
rio::dispatch::register agent.mode.set rio::ops::agent_mode_set

# agent.status -> {provider, auto_accept, mode, key_set} ; the agent's current settings,
# so a frontend renders its menus/dialogs without holding the state itself (D3).
# `key_set` is whether the ACTIVE provider has a key stored (0 for a keyless one
# like echo); per-provider key state is in agent.providers. All leaves are
# strings — the default wire encoder applies.
proc rio::ops::agent_status {params} {
	return [dict create result [dict create \
		provider    [rio::agent::provider_name] \
		auto_accept [rio::agent::auto_accept] \
		mode        [rio::agent::mode] \
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
