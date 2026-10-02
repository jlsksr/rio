# extensions/claude — the claude-api face (D26).
#
# MIT, like rio (D121). The notice is in this file because an installed
# extension has no LICENSE beside it (D122).
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
# The Claude provider. It authenticates with an Anthropic API key, the one
# sanctioned path for a third-party client, and drives rio::claude::infer.
# This face owns the auth header (x-api-key), the config and the key's
# storage, nothing else; another way to authenticate would be another face.
#
# Whatever may change upstream (endpoint, model, API version, timeout) is
# data in `config`, settable at runtime (D26). The network is a seam, so
# the tests run offline.

package require json

namespace eval rio::claude::api {
	# The documented Messages API; no beta header. The system prompt is not
	# here: the core composes it per turn (D34).
	variable config [dict create \
		messages_url      https://api.anthropic.com/v1/messages \
		models_url        https://api.anthropic.com/v1/models \
		anthropic_version 2023-06-01 \
		model             claude-sonnet-5 \
		effort            default \
		max_tokens        4096 \
		request_timeout   600000 \
		secret_name       claude-api]

	# How an effort is spelled in the request; %v is the value. Data, so a
	# rename upstream is a one-line change (D26). `default` is never sent.
	variable effort_json {"output_config":{"effort":"%v"}}

	# The models in the picker (D106). Short, and soon stale, which is fine:
	# any id can be typed, and refresh lists what the key can reach.
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

	# What each model can do: id -> {effort {supported 0|1 values {...}}}.
	# Empty until a refresh. Effort is per model (Haiku 4.5 answers one with
	# a 400, D106), so rio reads the listing's capabilities.effort and keeps
	# no table.
	variable caps {}

	# Network seams: the streaming transport for a turn, a plain GET for the
	# model list (plugins/lib/transport.tcl). Tests put fakes here.
	variable transport rio::llm::http::stream
	variable fetcher   rio::llm::http::get
}

# Set one config key: a user setting, a test, a model choice.
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
	# The core owns the system prompt (D34). It goes into a copy, so
	# `config` stays clean; infer skips an empty one.
	set conf $config
	dict set conf system $system
	dict set conf effort_json [_effort_json]
	rio::claude::infer $conf $conversation $tools $auth $transport $post
}

# --- the options a frontend may offer (D106) ---------------------------------
#
# Model and effort. The core routes them by name and never learns what they
# mean.

# What the chosen model does with effort: {known 0|1 supported 0|1 values
# {...}}. Before a refresh nothing is known: offer the shipped values and
# let the API refuse.
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

# The effort fragment for the request, or "" for `default`: the request rio
# has always sent.
#
# Also "" for a model known to refuse an effort. The choice is per provider
# and support is per model, so Opus's choice would cost Haiku a 400. The
# option's hint says so.
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
	# For a model that takes no effort, show what is sent: nothing.
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

# Set an option: check it, apply it, save it for the next start. A model is
# free text (a new release); an effort must be a declared value, or the API
# rejects the turn.
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

# List the models this key can reach, from the models endpoint.
# Asynchronous (D10): the callback announces the result. A failure keeps
# the list as it was.
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

# The models response -> the picker's choices:
#
#   {"data":[{"id":..., "display_name":...}, ...]}
#
# No display_name: the id is the label. Unreadable: say so, keep the list.
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

# One model's effort capability from its listing entry, or "" when the
# listing has none (an older API, a trimming proxy). Under `capabilities`:
#
#   "effort":{"supported":true,"low":{"supported":true},...}
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

# Whether a key is stored: the GUI offers Set or Clear.
proc rio::claude::api::configured {} {
	variable config
	return [rio::secret::has [dict get $config secret_name]]
}

# Store the API key: a 0600 secret, apart from settings (D21).
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

# Register by name (D26, D30), so a frontend can select this face over the
# channel: agent.provider.set claude. The key capability routes
# agent.key.set/clear/status here; the agent layer never sees a credential
# (D21).
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

# Adopt last session's choices (D106), from a flat, hand-editable file:
# $XDG_CONFIG_HOME/rio/agent/providers/claude.conf. An unknown key is
# ignored; no file means the shipped defaults.
proc rio::claude::api::_adopt_settings {} {
	variable config
	foreach k {model effort} {
		set v [rio::agent::settings::get claude $k]
		if {$v ne ""} { dict set config $k $v }
	}
}
rio::claude::api::_adopt_settings
