# extensions/openai — the OpenAI-compatible API face (AGENTS.md D8, D26).
#
# An OpenAI-compatible agent provider: it authenticates with a Bearer API key and
# drives the shared inference core (rio::openai::infer). Hosted ChatGPT is the
# default endpoint, but because the endpoint is config-as-data the same face drives
# any OpenAI-compatible server — Ollama, llama-server, LM Studio, vLLM — which is
# the in-box local-LLM provider AGENTS.md D8 names. The face owns only its auth
# strategy (the `Authorization: Bearer` header), a config block, and the key's
# storage; the durable inference code is shared.
#
# Resilience (D26): every volatile detail — endpoint, model, the token-cap param
# name, the timeout budget — lives in `config` as DATA, overridable at runtime, so
# a model or server change is a one-line edit, not a rebuild. Network is a SEAM
# (the shared transport), so the whole flow is testable offline.

package require json

namespace eval rio::openai::api {
	# Config-as-data. `token_param` is the request key for the output cap: hosted
	# newer OpenAI models require `max_completion_tokens`, while older models and
	# most local OpenAI-compatible servers take `max_tokens` — switch it here for a
	# model/server that wants the other, no code change. `messages_url` points at a
	# local server (e.g. http://localhost:11434/v1/chat/completions for Ollama) to
	# use a local model. The `system` prompt is not static config: the core composes
	# it per turn and the provider merges it in (D34).
	variable config [dict create \
		messages_url    https://api.openai.com/v1/chat/completions \
		models_url      "" \
		model           gpt-4o \
		effort          default \
		token_param     max_tokens \
		token_models    "" \
		max_tokens      4096 \
		request_timeout 600000 \
		secret_name     openai-api]

	# How an effort choice is spelled on the wire, %v standing for the value (D106).
	# Config-as-data like the rest: a server that wants a different key is one line.
	variable effort_json {"reasoning_effort":"%v"}

	# The models offered in the picker. Short and shipped: the option is `free` (type
	# any id) and `refresh` re-lists from the server itself — which is the only
	# sensible answer for a local Ollama / llama-server / LM Studio, whose models are
	# whatever that machine happens to have pulled.
	variable models {
		{value gpt-4o      label "GPT-4o"}
		{value gpt-4o-mini label "GPT-4o mini"}
	}
	variable efforts {
		{value default label "Provider default"}
		{value low     label "Low"}
		{value medium  label "Medium"}
		{value high    label "High"}
	}

	# Network seams: the shared tcltls streaming transport for a turn and the plain
	# GET for a models listing (plugins/lib/transport.tcl); tests inject fakes.
	variable transport rio::llm::http::stream
	variable fetcher   rio::llm::http::get
}

# Override one config key (a user setting, a test, a model or endpoint choice).
proc rio::openai::api::configure {key val} {
	variable config
	dict set config $key $val
}
proc rio::openai::api::cget {key} {
	variable config
	return [dict get $config $key]
}

# --- the provider (agent contract: conversation tools system post) -----------
proc rio::openai::api::provider {conversation tools system post} {
	variable config
	variable transport
	set key [_api_key]
	if {$key eq ""} {
		{*}$post error not_configured \
			"No OpenAI API key — add one in Preferences ▸ Agent (a local OpenAI-compatible server may need none: set its URL and any placeholder key)"
		return
	}
	set auth [list Authorization "Bearer $key"]
	# The core owns the system prompt (D34); merge it into a LOCAL config copy so the
	# persistent config dict stays clean. infer skips an empty `system`.
	set conf $config
	dict set conf system $system
	dict set conf effort_json [_effort_json]
	# Which token-cap parameter this model wants, and where to record the answer if
	# the server corrects us (D106c).
	dict set conf token_param [_token_param]
	dict set conf token_learn rio::openai::api::_token_learned
	rio::openai::infer $conf $conversation $tools $auth $transport $post
}

# --- the token cap's parameter name, learned per model (D106c) ----------------

# `token_models` is the list of model ids this provider has been TOLD want
# `max_completion_tokens` — by the server, in a 400. Everything else gets the
# configured default (`max_tokens`, which is what local OpenAI-compatible servers
# and the older hosted models take). Config-as-data still: the list is an ordinary
# settings key a user can read, edit or empty by hand.
proc rio::openai::api::_token_param {} {
	variable config
	if {[lsearch -exact [dict get $config token_models] [dict get $config model]] >= 0} {
		return max_completion_tokens
	}
	return [dict get $config token_param]
}

# Remember what the refusal taught us, so the retry happens once per model ever and
# not once per turn. Persisted beside the model and effort choices (D106).
proc rio::openai::api::_token_learned {model param} {
	variable config
	if {$param ne "max_completion_tokens" || $model eq ""} return
	set l [dict get $config token_models]
	if {[lsearch -exact $l $model] >= 0} return
	lappend l $model
	dict set config token_models $l
	catch {rio::agent::settings::store openai token_models $l}
}

# --- the options a frontend may offer (D106) ---------------------------------

# The effort fragment for the live choice, or "" for `default`. Default matters more
# here than anywhere: `reasoning_effort` is REJECTED by a non-reasoning model (gpt-4o)
# and by most local servers, so rio keeps sending exactly what it always sent until
# the user picks otherwise.
proc rio::openai::api::_effort_json {} {
	variable config
	variable effort_json
	set e [dict get $config effort]
	if {$e eq "" || $e eq "default"} { return "" }
	return [string map [list %v $e] $effort_json]
}

proc rio::openai::api::options {} {
	variable config
	variable models
	variable efforts
	return [list \
		[dict create name model label Model \
			hint "Which model answers. Refresh to list what this server offers." \
			value [dict get $config model] free 1 refresh 1 choices $models] \
		[dict create name effort label Effort \
			hint "Reasoning effort. Provider default sends nothing — gpt-4o and most local servers refuse the field." \
			value [dict get $config effort] free 0 refresh 0 choices $efforts]]
}

proc rio::openai::api::option_set {name value} {
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
	rio::agent::settings::store openai $name [dict get $config $name]
	return
}

# The models endpoint. Derived from `messages_url` unless one is configured, so
# pointing this face at a local server stays the ONE-line change it has always been:
# .../v1/chat/completions -> .../v1/models, which Ollama, llama-server, LM Studio and
# vLLM all answer.
proc rio::openai::api::_models_url {} {
	variable config
	set u [dict get $config models_url]
	if {$u ne ""} { return $u }
	set base [dict get $config messages_url]
	if {[string match */chat/completions $base]} {
		return "[string range $base 0 end-17]/models"   ;# drop "/chat/completions"
	}
	return $base
}

# Re-list what this server offers. Asynchronous (D10); a failure leaves the choices
# alone and says why.
proc rio::openai::api::option_refresh {name announce} {
	variable fetcher
	if {$name ne "model"} { rio::error::raise bad_request "cannot refresh: $name" }
	set key [_api_key]
	set headers {}
	# A local server usually needs no key; the hosted API always does. Send one when
	# we have one, and let the server say no when we don't.
	if {$key ne ""} { set headers [list Authorization "Bearer $key"] }
	{*}$fetcher [dict create url [_models_url] headers $headers] \
		[list rio::openai::api::_models_done $announce]
	return
}

# The listing -> the picker's choices. The OpenAI shape is {"data":[{"id":…}, …]},
# which every compatible server copies; the id is both value and label (these servers
# publish no display name).
proc rio::openai::api::_models_done {announce status err body} {
	variable models
	if {$status == 0} {
		{*}$announce "Couldn't reach the model list ($err)"
		return
	}
	if {$status != 200} {
		{*}$announce "The server refused the model list (HTTP $status)"
		return
	}
	if {[catch {json::json2dict $body} d] || ![dict exists $d data]} {
		{*}$announce "Couldn't read the model list from the server"
		return
	}
	set out {}
	foreach m [dict get $d data] {
		if {![dict exists $m id]} continue
		lappend out [dict create value [dict get $m id] label [dict get $m id]]
	}
	if {[llength $out]} { set models [lsort -index 1 $out] }
	{*}$announce
	return
}

# Whether a key is stored (the GUI offers Set / Clear accordingly).
proc rio::openai::api::configured {} {
	variable config
	return [rio::secret::has [dict get $config secret_name]]
}

# Store / replace the API key (a 0600 secret, apart from settings; D21).
proc rio::openai::api::set_key {key} {
	variable config
	rio::secret::save [dict get $config secret_name] [dict create api_key $key]
}

proc rio::openai::api::clear_key {} {
	variable config
	rio::secret::forget [dict get $config secret_name]
}

# The stored API key, or "" if none is set.
proc rio::openai::api::_api_key {} {
	variable config
	set s [rio::secret::get [dict get $config secret_name]]
	return [expr {[dict exists $s api_key] ? [dict get $s api_key] : ""}]
}

# Register with the agent's named-provider registry (D26/D30) so a frontend can
# select this face by name over the channel (agent.provider.set openai) and render
# its picker/key dialog from the declared label + signup. The key capability routes
# agent.key.* to this face's own 0600 store — its key coexists with Claude's.
rio::agent::register_provider openai rio::openai::api::provider \
	-label  ChatGPT \
	-signup platform.openai.com/api-keys \
	-key [dict create \
		set    rio::openai::api::set_key \
		clear  rio::openai::api::clear_key \
		status rio::openai::api::configured] \
	-options [dict create \
		list    rio::openai::api::options \
		set     rio::openai::api::option_set \
		refresh rio::openai::api::option_refresh]

# Adopt the choices the user made last time (D106), from the flat, hand-editable
# $XDG_CONFIG_HOME/rio/agent/providers/openai.conf — beside this provider's prompt
# layer and allow-list. Absent file, shipped defaults.
proc rio::openai::api::_adopt_settings {} {
	variable config
	# token_models is not a user CHOICE but something the server taught this provider
	# (D106c) — it persists the same way, so a restart doesn't re-learn it.
	foreach k {model effort token_models} {
		set v [rio::agent::settings::get openai $k]
		if {$v ne ""} { dict set config $k $v }
	}
}
rio::openai::api::_adopt_settings
