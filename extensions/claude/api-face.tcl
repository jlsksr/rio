# extensions/claude — the claude-api face (AGENTS.md D26).
#
# MIT-licensed, like rio itself (D121). The notice is IN this file because an installed
# extension travels alone: rio writes the payload into your extension directory, and there
# is no LICENSE beside it there (D122).
#
# Copyright (c) 2026 Julius Kaiser <jkdata@mailbox.org>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies
# or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
# OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# The official, supported Claude provider: it authenticates with an Anthropic
# API key (pay-per-token) and drives the shared inference core (rio::claude::infer).
# This is the only sanctioned, stable, ToS-compliant path for a third-party
# integration, so it is the path rio ships. The face owns ONLY its auth strategy
# (the `x-api-key` header), a config block, and the key's storage; the durable
# inference code is shared, leaving room for other auth strategies later without a
# rewrite.
#
# Resilience (D26): every volatile detail — endpoint, model, API version, and the
# request-timeout budget — lives in `config` as DATA, overridable at runtime, so an
# upstream change is a one-line edit, not a rebuild. Failures surface as classified
# agent.error events (from the inference core) with an actionable next step.
#
# Network is a SEAM (transport), so the whole flow is testable offline; the real
# tcltls transport (transport.tcl) is the default.

package require json

namespace eval rio::claude::api {
	# Config-as-data: the documented Anthropic Messages API. No beta header is sent
	# — this is the plain, supported request. The `system` prompt is not a static
	# config key: the core composes it per turn and the provider merges it in (D34).
	variable config [dict create \
		messages_url      https://api.anthropic.com/v1/messages \
		models_url        https://api.anthropic.com/v1/models \
		anthropic_version 2023-06-01 \
		model             claude-sonnet-5 \
		effort            default \
		max_tokens        4096 \
		request_timeout   600000 \
		secret_name       claude-api]

	# How an effort choice is spelled on the wire — the JSON fragment merged into the
	# request, with %v standing for the chosen value. Config-as-data like everything
	# else volatile here (D26): if Anthropic renames the field, this line changes and
	# nothing else does. `default` is never sent — see _effort_json.
	variable effort_json {"output_config":{"effort":"%v"}}

	# The models offered in the picker (D106). A SHIPPED list, deliberately short: it
	# is a convenience, not a source of truth — the option is `free`, so any id can be
	# typed, and `refresh` replaces this list with whatever the account can actually
	# reach today. A list like this goes stale; the two escapes are why that is ok.
	variable models {
		{value claude-opus-5    label "Opus 5"}
		{value claude-sonnet-5  label "Sonnet 5"}
		{value claude-haiku-4-5 label "Haiku 4.5"}
	}
	variable efforts {
		{value default label "Provider default"}
		{value low     label "Low"}
		{value medium  label "Medium"}
		{value high    label "High"}
	}

	# What each model can do, as the models endpoint reports it: id -> {effort {…}}.
	# Empty until a refresh fills it. Effort is NOT universal — Haiku 4.5 answers a
	# request carrying one with "This model does not support the effort parameter"
	# (HTTP 400, found by the live check, D106) — and which models take it, and which
	# values, is exactly the kind of fact that goes stale in a hardcoded table. The
	# listing carries `capabilities.effort`, so rio asks instead of remembering.
	variable caps {}

	# Network seams: the shared tcltls streaming transport for a turn and the plain
	# GET for a models listing (plugins/lib/transport.tcl); tests inject fakes.
	variable transport rio::llm::http::stream
	variable fetcher   rio::llm::http::get
}

# Override one config key (a user setting, a test, or a model choice).
proc rio::claude::api::configure {key val} {
	variable config
	dict set config $key $val
}
proc rio::claude::api::cget {key} {
	variable config
	return [dict get $config $key]
}

# --- the provider (agent contract: conversation tools system post) -----------
proc rio::claude::api::provider {conversation tools system post} {
	variable config
	variable transport
	set key [_api_key]
	if {$key eq ""} {
		{*}$post error not_configured \
			"No Claude API key — add one in Extensions ▸ Claude…"
		return
	}
	set auth [list x-api-key $key]
	# The core owns the system prompt (D34); merge it into a LOCAL config copy so
	# the persistent config dict stays clean. infer skips an empty `system`.
	set conf $config
	dict set conf system $system
	dict set conf effort_json [_effort_json]
	rio::claude::infer $conf $conversation $tools $auth $transport $post
}

# --- the options a frontend may offer (D106) ---------------------------------
#
# Which model, and how much effort to ask it for. The core routes these by name and
# never learns what they mean; the wire spelling and the shipped choices are this
# face's business, and its alone.

# What the CHOSEN model does with effort: {supported 0|1 values {…}}. Known only for a
# model the listing described — until a refresh, nothing is known, and the honest answer
# is to offer the shipped values and let the API be the judge (it refuses clearly).
proc rio::claude::api::_effort_caps {} {
	variable config
	variable caps
	variable efforts
	set shipped {}
	foreach c $efforts { if {[dict get $c value] ne "default"} { lappend shipped [dict get $c value] } }
	set m [dict get $config model]
	if {![dict exists $caps $m effort]} { return [dict create known 0 supported 1 values $shipped] }
	set e [dict get $caps $m effort]
	return [dict create known 1 \
		supported [dict get $e supported] values [dict get $e values]]
}

# The effort fragment for the live choice, or "" for `default` — which means "send
# the request rio has always sent". Any other value is opt-in, so installing this
# version changes nothing about a turn until the user asks it to.
#
# "" also when this model is KNOWN not to take an effort: the choice is per provider
# while support is per model, so switching from Opus to Haiku would otherwise carry a
# parameter we have been told it refuses, and lose the turn to a 400. Not sending it is
# not a silent override — the option says so in its own hint and offers nothing else.
proc rio::claude::api::_effort_json {} {
	variable config
	variable effort_json
	set e [dict get $config effort]
	if {$e eq "" || $e eq "default"} { return "" }
	if {![dict get [_effort_caps] supported]} { return "" }
	return [string map [list %v $e] $effort_json]
}

proc rio::claude::api::options {} {
	variable config
	variable models
	variable efforts
	set ec [_effort_caps]
	set hint "How much thinking to ask for. Provider default sends nothing."
	if {![dict get $ec supported]} {
		set choices [list [dict create value default label "Provider default"]]
		set hint "[dict get $config model] does not take an effort — the API says so, so rio doesn't send one."
	} else {
		set choices {}
		foreach c $efforts {
			set v [dict get $c value]
			if {$v eq "default" || $v in [dict get $ec values]} { lappend choices $c }
		}
		# A refreshed model may offer values this build never shipped (xhigh, max).
		foreach v [dict get $ec values] {
			if {$v ni [_choice_values $choices]} {
				lappend choices [dict create value $v label [string totitle $v]]
			}
		}
	}
	# When the model is known not to take one, the VALUE shown is what will actually be
	# sent — nothing — rather than a leftover from another model.
	set ev [expr {[dict get $ec supported] ? [dict get $config effort] : "default"}]
	return [list \
		[dict create name model label Model \
			hint "Which Claude answers. Refresh to list what your key can reach." \
			value [dict get $config model] free 1 refresh 1 choices $models] \
		[dict create name effort label Effort hint $hint \
			value $ev free 0 refresh 0 choices $choices]]
}

proc rio::claude::api::_choice_values {choices} {
	set out {}
	foreach c $choices { lappend out [dict get $c value] }
	return $out
}

# Choose a value: validate, apply to the live config, and remember it for the next
# core start. A model is free-form (a new release, a name this build has never heard
# of); an effort must be one of the declared values, because an unknown one would be
# spelled into the request and rejected by the API mid-turn.
proc rio::claude::api::option_set {name value} {
	variable config
	variable efforts
	switch -- $name {
		model {
			if {[string trim $value] eq ""} {
				rio::error::raise bad_request "model must not be empty"
			}
			dict set config model [string trim $value]
		}
		effort {
			set ok {}
			foreach c $efforts { lappend ok [dict get $c value] }
			if {$value ni $ok} {
				rio::error::raise bad_request "effort must be one of: [join $ok {, }]"
			}
			dict set config effort $value
		}
		default { rio::error::raise bad_request "unknown option: $name" }
	}
	rio::agent::settings::store claude $name [dict get $config $name]
	return
}

# Re-list the models this key can actually reach, from the documented models endpoint.
# Asynchronous (D10): the answer arrives on the callback, which announces it. A failure
# leaves the shipped list exactly as it was — a picker that empties itself because the
# network blinked is worse than a stale one.
proc rio::claude::api::option_refresh {name announce} {
	variable config
	variable fetcher
	if {$name ne "model"} { rio::error::raise bad_request "cannot refresh: $name" }
	set key [_api_key]
	if {$key eq ""} {
		{*}$announce "No Claude API key — add one in Extensions ▸ Claude…"
		return
	}
	{*}$fetcher [dict create \
		url [dict get $config models_url] \
		headers [list x-api-key $key anthropic-version [dict get $config anthropic_version]]] \
		[list rio::claude::api::_models_done $announce]
	return
}

# The models response -> the picker's choices. Anthropic answers
# {"data":[{"id":..., "display_name":...}, …]}; a missing display_name falls back to
# the id, and anything unparseable is reported rather than silently emptying the list.
proc rio::claude::api::_models_done {announce status err body} {
	variable models
	variable caps
	if {$status == 0} {
		{*}$announce "Couldn't reach the Claude API ($err)"
		return
	}
	if {$status != 200} {
		{*}$announce "The Claude API refused the model list (HTTP $status)"
		return
	}
	if {[catch {json::json2dict $body} d] || ![dict exists $d data]} {
		{*}$announce "Couldn't read the model list from the Claude API"
		return
	}
	set out {} ; set cp {}
	foreach m [dict get $d data] {
		if {![dict exists $m id]} continue
		set id [dict get $m id]
		lappend out [dict create value $id \
			label [expr {[dict exists $m display_name] ? [dict get $m display_name] : $id}]]
		set e [_effort_capability $m]
		if {$e ne ""} { dict set cp $id effort $e }
	}
	if {[llength $out]} { set models $out ; set caps $cp }
	{*}$announce
	return
}

# One model's effort capability from its listing entry, or "" when the listing says
# nothing about it (an older API, a proxy that trims the payload — then rio keeps
# asking the API rather than assuming either way). The shape is
# capabilities.effort.supported plus a sub-object per value:
#   "effort":{"supported":true,"low":{"supported":true},"xhigh":{"supported":true},…}
proc rio::claude::api::_effort_capability {m} {
	if {![dict exists $m capabilities effort]} { return "" }
	set e [dict get $m capabilities effort]
	set sup [expr {[dict exists $e supported] && [dict get $e supported] ? 1 : 0}]
	set vals {}
	dict for {k v} $e {
		if {$k eq "supported"} continue
		if {[catch {dict get $v supported} s]} continue
		if {$s} { lappend vals $k }
	}
	return [dict create supported $sup values $vals]
}

# Whether a key is stored (the GUI offers Set / Clear accordingly).
proc rio::claude::api::configured {} {
	variable config
	return [rio::secret::has [dict get $config secret_name]]
}

# Store / replace the API key (a 0600 secret, apart from settings; D21).
proc rio::claude::api::set_key {key} {
	variable config
	rio::secret::save [dict get $config secret_name] [dict create api_key $key]
}

proc rio::claude::api::clear_key {} {
	variable config
	rio::secret::forget [dict get $config secret_name]
}

# The stored API key, or "" if none is set.
proc rio::claude::api::_api_key {} {
	variable config
	set s [rio::secret::get [dict get $config secret_name]]
	return [expr {[dict exists $s api_key] ? [dict get $s api_key] : ""}]
}

# Register with the agent's named-provider registry (D26/D30) so a frontend can
# select this face by name over the channel (agent.provider.set claude). The key
# capability routes agent.key.set/clear/status here — the API key is this face's to
# keep (D21), the agent layer stays credential-blind.
rio::agent::register_provider claude rio::claude::api::provider \
	-label  Claude \
	-signup console.anthropic.com \
	-key [dict create \
		set    rio::claude::api::set_key \
		clear  rio::claude::api::clear_key \
		status rio::claude::api::configured] \
	-options [dict create \
		list    rio::claude::api::options \
		set     rio::claude::api::option_set \
		refresh rio::claude::api::option_refresh]

# Adopt the choices the user made last time (D106). They live in a flat, hand-editable
# file the core owns the location of — $XDG_CONFIG_HOME/rio/agent/providers/claude.conf
# — beside this provider's prompt layer and allow-list. An unknown key there is ignored
# and an absent file leaves the shipped defaults standing.
proc rio::claude::api::_adopt_settings {} {
	variable config
	foreach k {model effort} {
		set v [rio::agent::settings::get claude $k]
		if {$v ne ""} { dict set config $k $v }
	}
}
rio::claude::api::_adopt_settings
