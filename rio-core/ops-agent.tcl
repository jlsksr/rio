# rio-core — the agent.* op namespace (D20, D26).
#
# Thin handlers over rio::agent. A streaming op (register_stream) gets the
# live `emit` and answers with an ack; its content follows as events (D26).

# agent.send {text, ?buffer, start, end?} -> {started, turn} ; streams
# agent.delta, then agent.message or agent.error. `buffer` with `start` and
# `end` scopes the turn to that range (D113). A missing buffer, or a bad or
# empty range, is refused before the turn starts.
proc rio::ops::agent_send {params emit} {
	if {![dict exists $params text]} {
		rio::error::raise bad_request "agent.send requires text"
	}
	set scope {}
	if {[dict exists $params buffer]} {
		foreach k {start end} {
			if {![dict exists $params $k]} {
				rio::error::raise bad_request "agent.send with a buffer requires $k"
			}
		}
		set id [dict get $params buffer]
		if {![rio::doc::exists $id]} {
			rio::error::raise bad_request "agent.send: no such buffer: $id"
		}
		set start [dict get $params start] ; set end [dict get $params end]
		if {[catch {rio::doc::range_text $id $start $end} text]} {
			rio::error::raise bad_request "agent.send: $text"
		}
		if {$text eq ""} {
			rio::error::raise bad_request "agent.send: the selection is empty"
		}
		set scope [dict create buffer $id start $start end $end original $text]
	}
	return [rio::agent::send [dict get $params text] $emit $scope]
}
rio::dispatch::register_stream agent.send rio::ops::agent_send

# agent.approve {turn, decision} -> {id} ; decide a pending proposal:
# "approve" or "reject". The turn resumes on its own emit. Nothing pending is
# a bad_request.
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

# agent.proposal {turn} -> {name, path, original, proposed} ; the full texts
# of a pending write, for the compare view (D28). Nothing pending is a
# bad_request.
proc rio::ops::agent_proposal {params} {
	if {![dict exists $params turn]} {
		rio::error::raise bad_request "agent.proposal requires turn"
	}
	return [dict create result [rio::agent::proposal [dict get $params turn]]]
}
rio::dispatch::register agent.proposal rio::ops::agent_proposal

# agent.stop {?turn?} -> {stopped N} ; stop a turn in flight (D104); without
# `turn`, every one. Each stopped turn is announced as `agent.stopped`, so
# every attached frontend sees it. Stopping nothing is not an error.
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
# Standing approval for commands the user trusts. A rule is an argv prefix:
#
#   rule {git status}   allows  git status, git status -s
#   rule {make}         allows  make with any arguments
#
# Three scopes, as for the prompts: `global`, `provider` (not echo),
# `project` (the open project's .rio/). A command matching a rule in any
# active scope runs without asking. Only the confirmation is skipped;
# prepare_exec always runs. The lists are on the core's disk (D30).
#
# Returns {scope name}. `scope` defaults to `global`, `name` to the active
# provider.
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

# agent.allow.list {?scope? ?name?} -> {rules:[[token,…],…]} ; one scope's rules.
proc rio::ops::agent_allow_list {params} {
	lassign [_agent_allow_scope $params] scope name
	return [dict create result [dict create rules [rio::agent::allow::rules $scope $name]]]
}
rio::dispatch::register agent.allow.list rio::ops::agent_allow_list

# agent.allow.add {rule ?scope? ?name?} -> {} ; trust an argv prefix in one
# scope. `rule` is a JSON array of strings. An empty rule is a bad_request: it
# would trust everything. A rule already present is a no-op.
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
# The agent's settings are ops, so a local and a remote frontend drive them
# alike. The provider runs, and its key is stored, where the core runs (D21).
# The frontend never keeps the key (D3).

# agent.provider.set {name} -> {name} ; choose the live provider. An unknown
# name is a bad_request.
proc rio::ops::agent_provider_set {params} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "agent.provider.set requires name"
	}
	set name [rio::agent::use_provider [dict get $params name]]
	return [dict create result [dict create name $name]]
}
rio::dispatch::register agent.provider.set rio::ops::agent_provider_set

# agent.key.set {key ?name?} -> {} ; store a provider's API key in the core's
# 0600 secret store (D21). `name` defaults to the active provider.
proc rio::ops::agent_key_set {params} {
	if {![dict exists $params key]} {
		rio::error::raise bad_request "agent.key.set requires key"
	}
	set name [expr {[dict exists $params name] ? [dict get $params name] : ""}]
	rio::agent::key_set [dict get $params key] $name
	return [dict create result {}]
}
rio::dispatch::register agent.key.set rio::ops::agent_key_set

# agent.key.clear {?name?} -> {} ; forget a provider's stored key.
proc rio::ops::agent_key_clear {params} {
	set name [expr {[dict exists $params name] ? [dict get $params name] : ""}]
	rio::agent::key_clear $name
	return [dict create result {}]
}
rio::dispatch::register agent.key.clear rio::ops::agent_key_clear

# agent.providers -> {providers:[{name, label, keyed, key_set, signup,
# options, profiles}]} ; every registered provider, so a frontend builds its
# picker and key dialog from data (D30).
proc rio::ops::agent_providers {params} {
	return [dict create result [dict create providers [rio::agent::providers_info]]]
}
rio::dispatch::register agent.providers rio::ops::agent_providers

# --- a provider's runtime options (D106) -------------------------------------
#
# Model, effort, whatever a provider declares. The ops carry an option's
# name, never its meaning. `provider` defaults to the active one.

# The provider an option op targets: the named one, else the active one.
# Resolved here, so every reply names the provider it answered for.
proc rio::ops::_option_provider {params} {
	if {[dict exists $params provider] && [dict get $params provider] ne ""} {
		return [dict get $params provider]
	}
	return [rio::agent::provider_name]
}

# agent.options.list {?provider?} -> {provider, options:[{name,label,hint,value,free,
# refresh,file,kind,group,quick, choices:[{value,label}]}]} ; what this provider
# lets you choose now. The keys: see rio::agent::_option_norm.
# A provider without options answers with an empty list. A provider this core
# does not carry is a bad_request (D106).
proc rio::ops::agent_options_list {params} {
	set name [_option_provider $params]
	if {![rio::agent::provider_known $name]} {
		rio::error::raise bad_request "unknown agent provider: $name"
	}
	return [dict create result [dict create \
		provider $name options [rio::agent::options $name]]]
}
rio::dispatch::register agent.options.list rio::ops::agent_options_list

# agent.option.set {name value ?provider?} -> {provider, name, value} ; choose
# a value. The reply carries what the provider accepted. An unknown provider
# or option, or a refused value, is a bad_request. Announces agent.options.
proc rio::ops::agent_option_set {params emit} {
	foreach k {name value} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "agent.option.set requires $k"
		}
	}
	set prov [_option_provider $params]
	set val [rio::agent::option_set [dict get $params name] [dict get $params value] $prov]
	rio::agent::announce_options $prov $emit
	return [dict create result [dict create \
		provider $prov name [dict get $params name] value $val]]
}
rio::dispatch::register_stream agent.option.set rio::ops::agent_option_set

# agent.options.refresh {name ?provider?} -> {started} ; re-fetch an option's
# choices, e.g. from a models endpoint. The reply is an ack; the new list is
# announced as `agent.options` (D10: the core never blocks).
proc rio::ops::agent_options_refresh {params emit} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "agent.options.refresh requires name"
	}
	rio::agent::options_refresh [dict get $params name] $emit [_option_provider $params]
	return [dict create result [dict create started 1]]
}
rio::dispatch::register_stream agent.options.refresh rio::ops::agent_options_refresh

# agent.option.file {name ?provider?} -> {provider, name, path, created} ;
# resolve and create the file an option's value names, so a frontend can open
# it (D131). The path is on the core's disk (D30). An option not flagged
# `file` is a bad_request.
proc rio::ops::agent_option_file {params} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "agent.option.file requires name"
	}
	set prov [_option_provider $params]
	set r [rio::agent::option_file [dict get $params name] $prov]
	return [dict create result [dict create \
		provider $prov name [dict get $params name] \
		path [dict get $r path] \
		created [expr {[dict exists $r created] ? [dict get $r created] : 0}]]]
}
rio::dispatch::register agent.option.file rio::ops::agent_option_file

# --- a provider's profiles (D131) --------------------------------------------
#
# Named configurations of a provider, one active. The ops carry a profile's
# name, never its meaning. Each verb announces `agent.options`, because a
# profile change can change the options.

# agent.profiles.list {?provider?} -> {provider, active, profiles:[{name, active}]} ;
# a provider's profiles and the active one. A provider without profiles
# answers with an empty list. An unknown provider is a bad_request.
proc rio::ops::agent_profiles_list {params} {
	set name [_option_provider $params]
	if {![rio::agent::provider_known $name]} {
		rio::error::raise bad_request "unknown agent provider: $name"
	}
	set r [rio::agent::profiles $name]
	set active [dict get $r active]
	set out {}
	foreach p [dict get $r profiles] {
		lappend out [dict create name $p active [expr {$p eq $active ? 1 : 0}]]
	}
	return [dict create result [dict create \
		provider $name active $active profiles $out]]
}
rio::dispatch::register agent.profiles.list rio::ops::agent_profiles_list

# agent.profile.set {name ?provider?} -> {provider, name} ; make this profile
# active. The reply names the one the provider activated, which may differ if
# the named one is gone.
proc rio::ops::agent_profile_set {params emit} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "agent.profile.set requires name"
	}
	set prov [_option_provider $params]
	set n [rio::agent::profile_set [dict get $params name] $prov]
	rio::agent::announce_options $prov $emit
	return [dict create result [dict create provider $prov name $n]]
}
rio::dispatch::register_stream agent.profile.set rio::ops::agent_profile_set

# agent.profile.add {name ?from? ?provider?} -> {provider, name} ; a new
# profile: a copy of `from`, or the provider's defaults. It is not made active.
proc rio::ops::agent_profile_add {params emit} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "agent.profile.add requires name"
	}
	set prov [_option_provider $params]
	set from [expr {[dict exists $params from] ? [dict get $params from] : ""}]
	set n [rio::agent::profile_add [dict get $params name] $from $prov]
	rio::agent::announce_options $prov $emit
	return [dict create result [dict create provider $prov name $n]]
}
rio::dispatch::register_stream agent.profile.add rio::ops::agent_profile_add

# agent.profile.remove {name ?provider?} -> {provider, name, active} ; delete
# one. `active` is the profile active afterwards.
proc rio::ops::agent_profile_remove {params emit} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "agent.profile.remove requires name"
	}
	set prov [_option_provider $params]
	rio::agent::profile_remove [dict get $params name] $prov
	rio::agent::announce_options $prov $emit
	return [dict create result [dict create provider $prov \
		name [dict get $params name] active [rio::agent::profile_name $prov]]]
}
rio::dispatch::register_stream agent.profile.remove rio::ops::agent_profile_remove

# agent.profile.rename {name to ?provider?} -> {provider, name} ; rename one, in place.
proc rio::ops::agent_profile_rename {params emit} {
	foreach k {name to} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "agent.profile.rename requires $k"
		}
	}
	set prov [_option_provider $params]
	set n [rio::agent::profile_rename [dict get $params name] [dict get $params to] $prov]
	rio::agent::announce_options $prov $emit
	return [dict create result [dict create provider $prov name $n]]
}
rio::dispatch::register_stream agent.profile.rename rio::ops::agent_profile_rename

# The prompt layers a frontend may name (D34/D70/D79/D101/D105), in composition order.
# `base` and `plan` are rio's own shipped layers; the other three are the user's.
namespace eval rio::ops { variable prompt_layers {base system provider project plan} }

# Validate {which ?name?} for the prompt ops. Returns the provider name, ""
# unless `which` is provider. `allow` is the set of layers accepted.
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
# the system prompt's layers in composition order (D105).
#   origin — shipped | user | project | none
#   active — is the layer part of what the provider is sent now?
# Behind Preferences ▸ Agent ▸ Agent Prompts….
proc rio::ops::agent_prompt_list {params} {
	set ls [rio::agent::prompt::layers [rio::agent::provider_name] [rio::agent::mode]]
	return [dict create result [dict create prompts $ls]]
}
rio::dispatch::register agent.prompt.list rio::ops::agent_prompt_list

# agent.prompt.get {which ?name?} -> {which, path, origin, text} ; one layer's
# text, for reading (D105). `which` is a layer, or `composed` for the string
# the provider would get now. `plan` is returned in any mode. A layer without
# a file gives empty `text` and `origin none`.
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

# agent.prompt.edit {which ?name?} -> {path, created} ; make sure a layer's
# writable file exists, so a frontend can open it (D70/D79/D105). For `base`
# and `plan` that is the user's override, seeded with a copy. The path is on
# the core's disk (D30). See rio::agent::prompt::ensure.
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

# agent.mode.set {mode} -> {mode} ; `build` or `plan` (D101). An unknown mode
# is a bad_request. Approving a plan sets `build` by itself and announces it
# as `agent.mode`.
proc rio::ops::agent_mode_set {params} {
	if {![dict exists $params mode]} {
		rio::error::raise bad_request "agent.mode.set requires mode"
	}
	return [dict create result [dict create mode [rio::agent::set_mode [dict get $params mode]]]]
}
rio::dispatch::register agent.mode.set rio::ops::agent_mode_set

# agent.status -> {provider, profile, auto_accept, mode, key_set, options} ;
# the agent's settings, so a frontend holds no state of its own (D3).
#   key_set — has the active provider a key stored?
#   profile — the active profile, "" for a provider without profiles (D131)
proc rio::ops::agent_status {params} {
	return [dict create result [dict create \
		provider    [rio::agent::provider_name] \
		profile     [rio::agent::profile_name] \
		auto_accept [rio::agent::auto_accept] \
		mode        [rio::agent::mode] \
		key_set     [rio::agent::key_status] \
		options     [rio::agent::options_summary]]]
}
rio::dispatch::register agent.status rio::ops::agent_status

# agent.history -> {messages:[{role,text}]} ; the conversation, newest last.
proc rio::ops::agent_history {params} {
	return [dict create result [dict create messages [rio::agent::history]]]
}
rio::dispatch::register agent.history rio::ops::agent_history
